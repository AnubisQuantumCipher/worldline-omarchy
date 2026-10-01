#!/usr/bin/env python3
"""Record every program a command tree executes, by ptrace, with no root and nothing but the
Python standard library.

    python3 tools/exec-trace.py --log FILE [--deadline SECONDS]
                                [--allow-exe PATH]... [--allow-prefix DIR]... -- COMMAND [ARG...]

Every process the command starts is followed: across fork, vfork and clone, through each
execve. Each successful execve is recorded as one JSON line, {"pid", "t", "exe", "argv",
"script", "denied"}, whatever path the program was named by, whatever PATH or environment the
caller set, and whether or not the process was put in the background or left its session. `t`
is seconds since the command started (monotonic). The tracer returns only when every traced
process has exited, so a background process that outlives the command is still observed. If the
deadline passes first, every remaining process is killed and the tracer exits 124.

With --allow-exe or --allow-prefix, an exec of anything else is killed at the exec stop, before
the new program runs a single instruction, and recorded with "denied": true. A program is
allowed when its executable (resolved) is an --allow-exe or lies under an --allow-prefix; when
that executable is an interpreter (a shell or Python) and its first argument is an existing file,
the script must lie under an --allow-prefix too. This keeps a command under test away from the
host's own programs (a desktop shell it must never restart) even when it names them by absolute
path. Without either option nothing is denied.

The exit status is the command's own, or 124 on the deadline. A tracer failure exits 125.

What this cannot see: an execve that fails (no program runs); work done without exec, inside a
process that is already running (a builtin, or a program that opens a socket itself); a process
that escapes tracing by detaching itself, which a traced process cannot do to its own tracer.
Linux only (aarch64 and x86_64).
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import signal
import sys
import time

PTRACE_TRACEME = 0
PTRACE_CONT = 7
PTRACE_SETOPTIONS = 0x4200
PTRACE_GETEVENTMSG = 0x4201
PTRACE_O_TRACEFORK = 0x02
PTRACE_O_TRACEVFORK = 0x04
PTRACE_O_TRACECLONE = 0x08
PTRACE_O_TRACEEXEC = 0x10
PTRACE_O_EXITKILL = 0x100000
PTRACE_EVENT_FORK, PTRACE_EVENT_VFORK, PTRACE_EVENT_CLONE, PTRACE_EVENT_EXEC = 1, 2, 3, 4
PTRACE_EVENT_STOP = 128
WALL = 0x40000000
INTERPRETERS = ("sh", "bash", "dash", "zsh", "ksh", "python", "python3")

_libc = ctypes.CDLL(None, use_errno=True)
_libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
_libc.ptrace.restype = ctypes.c_long


class Deadline(Exception):
    pass


def ptrace(request: int, pid: int, data: int = 0, addr: int = 0) -> None:
    if _libc.ptrace(request, pid, ctypes.c_void_p(addr), ctypes.c_void_p(data)) == -1:
        error = ctypes.get_errno()
        raise OSError(error, f"ptrace({request:#x}, {pid}): {os.strerror(error)}")


def event_message(pid: int) -> int:
    value = ctypes.c_ulong(0)
    if _libc.ptrace(PTRACE_GETEVENTMSG, pid, None, ctypes.byref(value)) == -1:
        error = ctypes.get_errno()
        raise OSError(error, f"ptrace(GETEVENTMSG, {pid}): {os.strerror(error)}")
    return int(value.value)


def _proc(pid: int) -> tuple[str, list[str], str]:
    try:
        exe = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        exe = ""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as handle:
            raw = handle.read()
        argv = [part.decode("utf-8", "replace") for part in raw.split(b"\0")[:-1]]
    except OSError:
        argv = []
    try:
        cwd = os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        cwd = "/"
    return exe, argv, cwd


def _is_interpreter(exe: str) -> bool:
    name = os.path.basename(exe)
    return name in INTERPRETERS or (name.startswith("python3.") and name[8:].replace(".", "").isdigit())


def script_of(exe: str, argv: list[str], cwd: str) -> str:
    """The script an interpreter was started on: its first argument when that is an existing
    regular file (the kernel puts a #! script's path there), resolved; otherwise ""."""
    if not _is_interpreter(exe) or len(argv) < 2 or argv[1].startswith("-"):
        return ""
    candidate = argv[1] if os.path.isabs(argv[1]) else os.path.join(cwd, argv[1])
    try:
        return os.path.realpath(candidate) if os.path.isfile(candidate) else ""
    except OSError:
        return ""


class Policy:
    def __init__(self, exes: list[str], prefixes: list[str]):
        self.active = bool(exes or prefixes)
        self.exes = {os.path.realpath(path) for path in exes}
        self.prefixes = [os.path.realpath(prefix).rstrip("/") + "/" for prefix in prefixes]

    def _under(self, path: str) -> bool:
        return any(path.startswith(prefix) for prefix in self.prefixes)

    def allows(self, exe: str, script: str) -> bool:
        if not self.active:
            return True
        real = os.path.realpath(exe) if exe else ""
        if not real or not (real in self.exes or self._under(real)):
            return False
        return not script or self._under(script)


def trace(command: list[str], log_path: str, deadline: float, policy: Policy) -> int:
    child = os.fork()
    if child == 0:
        try:
            ptrace(PTRACE_TRACEME, 0)
            os.kill(os.getpid(), signal.SIGSTOP)
            os.execvp(command[0], command)
        except BaseException as exc:  # noqa: BLE001 - the child must never return into the tracer
            print(f"exec-trace: cannot start {command[0]}: {exc}", file=sys.stderr)
        os._exit(125)

    options = (PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK | PTRACE_O_TRACECLONE
               | PTRACE_O_TRACEEXEC | PTRACE_O_EXITKILL)
    _, status = os.waitpid(child, WALL)
    if not os.WIFSTOPPED(status):
        print("exec-trace: the command did not stop for tracing", file=sys.stderr)
        return 125
    ptrace(PTRACE_SETOPTIONS, child, options)
    started = time.monotonic()

    def expire(_signum, _frame):
        raise Deadline()

    previous = signal.signal(signal.SIGALRM, expire)
    signal.setitimer(signal.ITIMER_REAL, deadline)
    # A process is live from the moment its parent's fork event names it (not from its own first
    # stop, which may be reported after the parent has already exited), until it exits.
    live = {child}
    seen_first_stop: set[int] = {child}
    root_status: int | None = None
    try:
        ptrace(PTRACE_CONT, child, 0)
        with open(log_path, "a", encoding="utf-8") as log:
            while live:
                try:
                    pid, status = os.waitpid(-1, WALL)
                except ChildProcessError:
                    break
                if os.WIFEXITED(status) or os.WIFSIGNALED(status):
                    live.discard(pid)
                    if pid == child:
                        root_status = os.waitstatus_to_exitcode(status)
                    continue
                if not os.WIFSTOPPED(status):
                    continue
                live.add(pid)
                stop = os.WSTOPSIG(status)
                event = status >> 16
                deliver = 0
                if stop == signal.SIGTRAP and event == PTRACE_EVENT_EXEC:
                    try:
                        former = event_message(pid)  # a non-leader thread that execs takes the leader's id
                        if former != pid:
                            live.discard(former)
                    except OSError:
                        pass
                    exe, argv, cwd = _proc(pid)
                    script = script_of(exe, argv, cwd)
                    denied = not policy.allows(exe, script)
                    log.write(json.dumps({"pid": pid, "t": round(time.monotonic() - started, 4), "exe": exe,
                                          "argv": argv, "script": script, "denied": denied}) + "\n")
                    log.flush()
                    if denied:
                        # Killed before its first instruction: the exec is recorded, the program never runs.
                        os.kill(pid, signal.SIGKILL)
                elif stop == signal.SIGTRAP and event in (PTRACE_EVENT_FORK, PTRACE_EVENT_VFORK, PTRACE_EVENT_CLONE):
                    try:
                        live.add(event_message(pid))  # traced already; it reports its own first stop
                    except OSError:
                        pass
                elif stop == signal.SIGSTOP and event == 0 and pid not in seen_first_stop:
                    seen_first_stop.add(pid)  # the first stop of a newly traced process
                elif event == PTRACE_EVENT_STOP:
                    pass
                else:
                    deliver = stop  # an ordinary signal: pass it on
                try:
                    ptrace(PTRACE_CONT, pid, deliver)
                except OSError:
                    pass  # it died between the stop and the continue; its exit is still reported
    except Deadline:
        for pid in list(live):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        print(f"exec-trace: deadline of {deadline:g}s passed; killed {sorted(live)}", file=sys.stderr)
        return 124
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
    return 125 if root_status is None else root_status


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--log", required=True)
    parser.add_argument("--deadline", type=float, default=120.0)
    parser.add_argument("--allow-exe", action="append", default=[])
    parser.add_argument("--allow-prefix", action="append", default=[])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("no command")
    return trace(command, args.log, args.deadline, Policy(args.allow_exe, args.allow_prefix))


if __name__ == "__main__":
    sys.exit(main())
