#!/usr/bin/env python3
"""Generate the list of every code a WORLDLINE engine checkout can report, and its digest.

    python3 tools/engine-codes.py ENGINE_CHECKOUT [--rev REV]            print the list as JSON
    python3 tools/engine-codes.py ENGINE_CHECKOUT [--rev REV] --write    rewrite tools/engine-codes.json
    python3 tools/engine-codes.py ENGINE_CHECKOUT [--rev REV] --check    exit 1 if tools/engine-codes.json differs

With --rev, the list is made from that commit of the checkout (git archive of runtime/ and core/),
not from its working tree; a release pairs with a commit, so the recorded list should come from one.

A code is anything the engine can put where the plugin reads a code: the first argument of a
WorldlineError (or the fixed code of one of its subclasses), a daemon or client error response,
the `code` of an error recorded on a transaction, job, world or watch, and the kernel's collapse
decisions and error names in core/worldline_core.h. Stdlib only; the engine is parsed, never run.

The walk refuses (exit 2) when a WorldlineError is raised with a code it cannot resolve to
string literals, rather than leaving that code out: every such site must be covered by a rule
below, so a new variable-code site in the engine stops the generator until someone writes one.

The digest is sha256 over the sorted codes, each followed by one newline (UTF-8). An engine that
publishes its code-set digest must compute it the same way for the plugin to accept it.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

CODE = re.compile(r"^[A-Z][A-Z0-9_]*[A-Z0-9]$")
HERE = Path(__file__).resolve().parent
OUTPUT = HERE / "engine-codes.json"


class Unresolved(Exception):
    pass


def digest(codes: list[str]) -> str:
    return hashlib.sha256("".join(code + "\n" for code in sorted(set(codes))).encode("utf-8")).hexdigest()


def string_constants(node: ast.AST) -> list[str]:
    return [n.value for n in ast.walk(node) if isinstance(n, ast.Constant) and isinstance(n.value, str) and CODE.match(n.value)]


class Engine:
    def __init__(self, checkout: Path):
        self.checkout = checkout
        self.package = checkout / "runtime" / "worldline"
        if not self.package.is_dir():
            raise SystemExit(f"engine-codes: {checkout} has no runtime/worldline")
        self.modules: dict[str, ast.Module] = {}
        for path in sorted(self.package.rglob("*.py")):
            self.modules[str(path.relative_to(self.package))] = ast.parse(path.read_text(encoding="utf-8"), str(path))
        self.codes: dict[str, set[str]] = {}
        self.unresolved: list[str] = []

    # ------------------------------------------------------------------ helpers

    def add(self, code: str, where: str) -> None:
        if not CODE.match(code):
            raise Unresolved(f"{where}: {code!r} is not a code")
        self.codes.setdefault(code, set()).add(where)

    def static_codes(self, module: str, node: ast.AST, seen: frozenset[str] = frozenset()) -> list[str]:
        """Only literal values and explicit alternatives are evidence of a named code.

        A string argument to an arbitrary call does not determine its returned value.
        Refuse such expressions instead of mistaking an incidental literal for a code.
        """
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return [node.value]
        if isinstance(node, ast.IfExp):
            return self.static_codes(module, node.body, seen) + self.static_codes(module, node.orelse, seen)
        if isinstance(node, (ast.Tuple, ast.List, ast.Set)):
            return [code for item in node.elts for code in self.static_codes(module, item, seen)]
        if isinstance(node, ast.Name):
            codes = self.module_constant(module, node.id, seen)
            if not codes:
                raise Unresolved(f"{module}:{node.lineno}: unknown code constant {node.id}")
            return codes
        raise Unresolved(f"{module}:{getattr(node, 'lineno', '?')}: nonliteral code value {ast.unparse(node)}")

    def module_constant(self, module: str, name: str, seen: frozenset[str] = frozenset()) -> list[str]:
        identity = module + ":" + name
        if identity in seen:
            raise Unresolved(f"{identity}: cyclic code constant")
        seen = seen | {identity}
        tree = self.modules.get(module)
        if tree is None:
            raise Unresolved(f"{module}: missing code declaration module")
        for node in tree.body:
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
                return self.static_codes(module, node.value, seen)
            if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == name and node.value:
                return self.static_codes(module, node.value, seen)
            if isinstance(node, ast.ImportFrom) and node.module and node.level == 1:
                for alias in node.names:
                    if (alias.asname or alias.name) == name:
                        target = node.module.replace(".", "/") + ".py"
                        if target in self.modules:
                            return self.module_constant(target, alias.name, seen)
        return []

    def local_assignments(self, module: str, function: ast.AST, name: str) -> list[str]:
        found: list[str] = []
        for node in ast.walk(function):
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
                found.extend(self.static_codes(module, node.value))
            if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id == name and node.value:
                found.extend(self.static_codes(module, node.value))
        return found

    def header(self) -> tuple[list[str], list[str]]:
        text = (self.checkout / "core" / "worldline_core.h").read_text(encoding="utf-8")
        decisions = re.findall(r"^#define WL_COLLAPSE_([A-Z_]+) \d+u", text, re.M)
        errors = re.findall(r"^#define WL_ERR_([A-Z_]+) \d+", text, re.M)
        return decisions, errors

    # ------------------------------------------------------------------ the walk

    def subclasses(self) -> dict[str, str]:
        """WorldlineError subclasses with a fixed code: name -> code."""
        fixed: dict[str, str] = {}
        for module, tree in self.modules.items():
            for node in ast.walk(tree):
                if not isinstance(node, ast.ClassDef):
                    continue
                if not any(isinstance(b, ast.Name) and b.id == "WorldlineError" for b in node.bases):
                    continue
                for call in ast.walk(node):
                    if (isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute) and call.func.attr == "__init__"
                            and call.args and isinstance(call.args[0], ast.Constant) and isinstance(call.args[0].value, str)):
                        fixed[node.name] = call.args[0].value
                        self.add(call.args[0].value, f"{module}:{call.lineno}")
        return fixed

    def resolve(self, module: str, function: ast.AST | None, node: ast.AST, where: str) -> list[str]:
        decisions, errors = self.header()
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            return [node.value]
        if isinstance(node, ast.Name):
            # This named kernel boundary returns one of the header's decision names.
            if node.id == "decision" and module == "transaction.py":
                return [d for d in decisions if d != "AUTHORIZED"]
            found = self.module_constant(module, node.id)
            if not found and function is not None:
                found = self.local_assignments(module, function, node.id)
            if found:
                return found
            raise Unresolved(f"{where}: variable {node.id} has no string value here")
        if isinstance(node, ast.IfExp):
            # "A" if condition else "B": either branch can be the code.
            return self.resolve(module, function, node.body, where) + self.resolve(module, function, node.orelse, where)
        if (isinstance(node, ast.Attribute) and node.attr == "code" and isinstance(node.value, ast.Name)
                and function is not None):
            # named = some_function(...); WorldlineError(named.code, ...): the codes that
            # function's own WorldlineErrors carry (transaction.py re-raises storage_error's).
            codes = self._codes_of_assigned_call(module, function, node.value.id)
            if codes:
                return codes
            raise Unresolved(f"{where}: {ast.unparse(node)} is not the code of a known function's error")
        if isinstance(node, ast.Attribute) and node.attr == "outcome":
            # An admission refusal names its outcome (admission.OUTCOMES, except ADMITTED).
            outcomes = [c for c in self.module_constant("admission.py", "OUTCOMES") if c != "ADMITTED"]
            if not outcomes:
                raise Unresolved(f"{where}: admission outcomes are undeclared")
            return outcomes
        if isinstance(node, ast.JoinedStr):
            text = ast.unparse(node)
            if text.startswith("f'CORE_{") or text.startswith('f"CORE_{'):
                return ["CORE_" + name for name in errors] + self._dict_values("core.py", "_ERROR_NAMES", prefix="CORE_")
            raise Unresolved(f"{where}: f-string code {text}")
        if isinstance(node, ast.Call):
            text = ast.unparse(node)
            if isinstance(node.func, ast.Name) and node.func.id == "getattr" and len(node.args) == 3:
                # getattr(exc, "code", DEFAULT): the default, plus every code the module's own
                # failure type is raised with.
                return string_constants(node.args[2]) + self._backend_codes(module)
            if isinstance(node.func, ast.Name) and node.func.id == "str" and "error.get(" in text:
                # client.py: a daemon error response's own code, or DAEMON_ERROR when it has none.
                return string_constants(node)
            raise Unresolved(f"{where}: call {text}")
        raise Unresolved(f"{where}: {ast.unparse(node)}")

    def _codes_of_assigned_call(self, module: str, function: ast.AST, name: str) -> list[str]:
        for node in ast.walk(function):
            if (isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets)
                    and isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name)):
                target = self._find_function(module, node.value.func.id)
                if target is not None:
                    target_module, target_function = target
                    codes: list[str] = []
                    for call in ast.walk(target_function):
                        if (isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and call.func.id == "WorldlineError"
                                and call.args):
                            codes.extend(self.resolve(target_module, target_function, call.args[0], f"{target_module}:{call.lineno}"))
                    return codes
        return []

    def _find_function(self, module: str, name: str) -> tuple[str, ast.AST] | None:
        tree = self.modules[module]
        for node in tree.body:
            if isinstance(node, ast.FunctionDef) and node.name == name:
                return module, node
            if isinstance(node, ast.ImportFrom) and node.module and node.level == 1:
                for alias in node.names:
                    if (alias.asname or alias.name) == name:
                        target = node.module.replace(".", "/") + ".py"
                        if target in self.modules:
                            return self._find_function(target, alias.name)
        for node in ast.walk(tree):  # a function imported inside a function body
            if isinstance(node, ast.ImportFrom) and node.module and node.level == 1:
                for alias in node.names:
                    if (alias.asname or alias.name) == name:
                        target = node.module.replace(".", "/") + ".py"
                        if target in self.modules:
                            return self._find_function(target, alias.name)
        return None

    def _tuple_names(self, module: str, name: str) -> list[str]:
        tree = self.modules[module]
        for node in tree.body:
            if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
                out: list[str] = []
                for element in getattr(node.value, "elts", []):
                    if isinstance(element, ast.Name):
                        out.extend(self.module_constant(module, element.id))
                    else:
                        out.extend(string_constants(element))
                return out
        return []

    def _dict_values(self, module: str, name: str, prefix: str = "") -> list[str]:
        tree = self.modules[module]
        for node in tree.body:
            target = node.target if isinstance(node, ast.AnnAssign) else (node.targets[0] if isinstance(node, ast.Assign) else None)
            if isinstance(target, ast.Name) and target.id == name and isinstance(node.value, ast.Dict):
                return [prefix + v.value for v in node.value.values if isinstance(v, ast.Constant) and isinstance(v.value, str)]
        return []

    def _backend_codes(self, module: str) -> list[str]:
        codes: list[str] = []
        for node in ast.walk(self.modules[module]):
            if isinstance(node, ast.FunctionDef) and node.name == "_refuse":
                for default in node.args.defaults:
                    codes.extend(string_constants(default))
            if isinstance(node, ast.Call):
                name = node.func.id if isinstance(node.func, ast.Name) else None
                if name == "BackendFailure" and node.args:
                    codes.extend(string_constants(node.args[0]))
                if name == "_refuse":
                    for keyword in node.keywords:
                        if keyword.arg == "code":
                            codes.extend(string_constants(keyword.value))
                    if len(node.args) >= 2:
                        codes.extend(string_constants(node.args[1]))
        return codes

    def walk(self) -> None:
        decisions, errors = self.header()
        for name in decisions:
            if name != "AUTHORIZED":
                self.add(name, "core/worldline_core.h")
        for name in errors:
            self.add("CORE_" + name, "core/worldline_core.h")
        fixed = self.subclasses()
        for module, tree in self.modules.items():
            functions = [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]

            def enclosing(node: ast.AST) -> ast.AST | None:
                best = None
                for function in functions:
                    if function.lineno <= node.lineno <= (function.end_lineno or function.lineno):
                        if best is None or function.lineno >= best.lineno:
                            best = function
                return best

            for node in ast.walk(tree):
                if isinstance(node, ast.Call):
                    name = node.func.id if isinstance(node.func, ast.Name) else (node.func.attr if isinstance(node.func, ast.Attribute) else None)
                    where = f"{module}:{node.lineno}"
                    if name == "WorldlineError" and node.args:
                        try:
                            for code in self.resolve(module, enclosing(node), node.args[0], where):
                                self.add(code, where)
                        except Unresolved as exc:
                            self.unresolved.append(str(exc))
                    elif name == "WorldlineError":
                        if not any(keyword.arg == "code" for keyword in node.keywords):
                            self.unresolved.append(f"{where}: WorldlineError has no explicit code argument")
                        for keyword in node.keywords:
                            if keyword.arg == "code":
                                try:
                                    for code in self.resolve(module, enclosing(node), keyword.value, where):
                                        self.add(code, where)
                                except Unresolved as exc:
                                    self.unresolved.append(str(exc))
                # A code written into a record or an error response: {"code": "X", ...}, or
                # the conditional {"code": "A" if ... else "B"}.
                if isinstance(node, ast.Dict):
                    for key, value in zip(node.keys, node.values):
                        if isinstance(key, ast.Constant) and key.value == "code" and value is not None:
                            for code in string_constants(value):
                                self.add(code, f"{module}:{node.lineno}")
                # error={"code": ...} is covered above; a code passed as error_code="X" too.
                if isinstance(node, ast.keyword) and node.arg in {"error_code"}:
                    for code in string_constants(node.value):
                        self.add(code, f"{module}:{getattr(node.value, 'lineno', 0)}")
        del fixed


def engine_identity(checkout: Path, tree: Path, rev: str | None) -> dict[str, str]:
    version = ""
    init = tree / "runtime" / "worldline" / "__init__.py"
    match = re.search(r'__version__\s*=\s*"([^"]+)"', init.read_text(encoding="utf-8"))
    if match:
        version = match.group(1)
    commit = subprocess.run(["git", "-C", str(checkout), "rev-parse", f"{rev or 'HEAD'}^{{commit}}"], capture_output=True, text=True).stdout.strip()
    if rev is not None:
        source = "git archive of the commit"
    else:
        dirty = subprocess.run(["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=all", "--", "runtime", "core"],
                               capture_output=True, text=True).stdout.strip()
        source = "working tree, clean at the commit" if not dirty else "working tree WITH UNCOMMITTED CHANGES (not a release pairing)"
    return {"version": version, "commit": commit, "source": source}


def generate(checkout: Path, rev: str | None = None) -> dict:
    with tempfile.TemporaryDirectory(prefix="engine-codes-") as scratch:
        tree = checkout
        if rev is not None:
            archive = Path(scratch) / "tree.tar"
            made = subprocess.run(["git", "-C", str(checkout), "archive", "-o", str(archive), rev, "runtime", "core"], capture_output=True, text=True)
            if made.returncode != 0:
                raise SystemExit(f"engine-codes: git archive {rev}: {made.stderr.strip()}")
            tree = Path(scratch) / "tree"
            with tarfile.open(archive) as handle:
                handle.extractall(tree, filter="data")
        engine = Engine(tree)
        engine.walk()
        identity = engine_identity(checkout, tree, rev)
    if engine.unresolved:
        raise SystemExit("engine-codes: cannot resolve these code sites (add a rule):\n  " + "\n  ".join(engine.unresolved))
    codes = sorted(engine.codes)
    return {
        "schema": "worldline-engine-codes/1",
        "engine": identity,
        "generator": "tools/engine-codes.py",
        "digestRule": "sha256 over the sorted codes, each followed by one newline",
        "codeSetSha256": digest(codes),
        "count": len(codes),
        "codes": codes,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--rev", default=None, help="make the list from this commit of the checkout")
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = generate(args.checkout.resolve(), args.rev)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.write:
        OUTPUT.write_text(text, encoding="utf-8")
        print(f"engine-codes: wrote {result['count']} codes, {result['codeSetSha256']}, engine {result['engine']['version']} {result['engine']['commit'][:12]}")
        return 0
    if args.check:
        recorded = json.loads(OUTPUT.read_text(encoding="utf-8"))
        if recorded.get("codes") != result["codes"] or recorded.get("codeSetSha256") != result["codeSetSha256"]:
            missing = sorted(set(result["codes"]) - set(recorded.get("codes", [])))
            extra = sorted(set(recorded.get("codes", [])) - set(result["codes"]))
            print(f"engine-codes: tools/engine-codes.json is not this engine's list (missing {missing}, extra {extra})", file=sys.stderr)
            return 1
        print(f"engine-codes: tools/engine-codes.json matches engine {result['engine']['version']} ({result['count']} codes, {result['codeSetSha256']})")
        return 0
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
