import QtQuick
import Quickshell.Io

// One `worldline …` invocation at a time. Every action the cockpit takes goes through the
// CLI as an argv array (never a shell string), so an agent-chosen alias or path is data.
// `run(argv, done, limits)` returns false when a call is already in flight. `done(exitCode,
// stdout, stderr, facts)` fires exactly once per started call, after the process has exited
// and both streams have drained; `facts.stdoutBytes` is the exact byte count of stdout.
//
// Every call is bounded. The shell is long-lived, and what a call prints can carry text an
// agent controls (its stderr, a mission, a path), so nothing it prints may exhaust or hold the
// shell (marketplace review of 1.3.2, omarchy-plugin-marketplace#7900):
// - at most `limits.stdoutBytes` of stdout and `limits.stderrBytes` of stderr are kept. Each
//   stream is measured as it arrives, one pipe read at a time, so the shell never holds more
//   than a limit plus one read;
// - a call still running after `limits.seconds` is stopped.
// A call that crosses either bound is killed (SIGKILL) and what it printed is discarded; `done`
// receives exit 137 and a `worldline: CLI_OUTPUT_TOO_LARGE: …` or `worldline: CLI_DEADLINE: …`
// line on stderr, which Model.parseCliError reads like any other refusal. A command that cannot
// be started reports `worldline: CLI_UNAVAILABLE: …` the same way.
Item {
  id: root

  readonly property bool busy: process.running
  property var _done: null
  property string lastCommand: ""
  // Extra environment for the CLI. The isolated-daemon harness sets HOME/XDG_* here so every
  // command addresses the private daemon instead of the operator's real one.
  property var environment: ({})
  // The bounds of a call that names none of its own.
  property int seconds: 120
  property int stdoutBytes: 4194304
  property int stderrBytes: 262144

  property var _limits: ({ seconds: 120, stdoutBytes: 4194304, stderrBytes: 262144 })
  property string _label: ""
  property string _stopped: ""   // the refusal line once a bound stopped the call
  // Whether this call's streams delivered anything. An incremental collector keeps its last
  // value when a new call prints nothing, so an empty stream must not read as the previous one.
  property bool _gotOut: false
  property bool _gotErr: false

  function run(argv, done, limits) {
    if (process.running) return false
    var given = limits || {}
    root._limits = {
      seconds: given.seconds > 0 ? given.seconds : root.seconds,
      stdoutBytes: given.stdoutBytes > 0 ? given.stdoutBytes : root.stdoutBytes,
      stderrBytes: given.stderrBytes > 0 ? given.stderrBytes : root.stderrBytes
    }
    root._stopped = ""
    root._gotOut = false
    root._gotErr = false
    root._done = done
    root.lastCommand = argv.join(" ")
    root._label = argv.slice(0, 2).join(" ")
    process.command = argv
    // Armed before the start: a start that fails can report itself before `running = true` returns.
    deadline.interval = root._limits.seconds * 1000
    deadline.restart()
    process.running = true
    return true
  }

  function _halt(line) {
    if (root._stopped !== "") return
    root._stopped = line
    process.signal(9)
  }

  function _measure(collector, limit, stream) {
    if (root._stopped === "" && collector.data.byteLength > limit)
      root._halt("worldline: CLI_OUTPUT_TOO_LARGE: " + root._label + " wrote more than " + limit
                 + " bytes to " + stream + "; it was stopped and its output discarded")
  }

  function _finish(exitCode, stdout, stderr, facts) {
    deadline.stop()
    var callback = root._done
    root._done = null
    if (callback) callback(exitCode, stdout, stderr, facts)
  }

  Timer {
    id: deadline
    repeat: false
    onTriggered: {
      if (process.running)
        root._halt("worldline: CLI_DEADLINE: " + root._label + " did not finish within " + root._limits.seconds
                   + " s; the CLI was stopped (a request it had already sent may still complete: check status)")
    }
  }

  Process {
    id: process
    running: false
    environment: root.environment
    stdout: StdioCollector {
      id: out
      waitForEnd: false
      onDataChanged: { root._gotOut = true; root._measure(out, root._limits.stdoutBytes, "stdout") }
    }
    stderr: StdioCollector {
      id: err
      waitForEnd: false
      onDataChanged: { root._gotErr = true; root._measure(err, root._limits.stderrBytes, "stderr") }
    }
    onExited: function(exitCode, exitStatus) {
      if (root._stopped !== "") {
        root._finish(137, "", root._stopped, { stdoutBytes: 0 })
        return
      }
      root._finish(exitCode, root._gotOut ? String(out.text || "") : "", root._gotErr ? String(err.text || "") : "",
                   { stdoutBytes: root._gotOut ? out.data.byteLength : 0 })
    }
    // Quickshell emits `exited` before `runningChanged` for a process that ran, and only
    // `runningChanged` for one that could not be started; a callback still waiting here is that case.
    onRunningChanged: {
      if (!process.running && root._done !== null)
        root._finish(127, "", "worldline: CLI_UNAVAILABLE: " + root._label + " could not be started", { stdoutBytes: 0 })
    }
  }
}
