#!/usr/bin/env python3
"""Read-only validation of final engine/plugin commits and their external release manifest.

The plugin inventory names an earlier code-inventory source commit. The final engine commit
names the final plugin commit. A CI-generated release manifest can therefore bind both final
identities without either repository having to name its own future commit.

Required inputs are explicit full commit identities, not values selected from the manifest.
Without --manifest this checks the source pair before the release gate writes its manifest.
With --manifest it additionally checks that external binding. It never publishes or fetches.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("plugin_engine_inventory", HERE / "engine-codes.py")
assert SPEC is not None and SPEC.loader is not None
INVENTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INVENTORY)


class PairRefused(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise PairRefused(message)


def git(repository: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "--no-replace-objects", "-C", str(repository), *args],
                            capture_output=True, check=False)
    if result.returncode:
        raise PairRefused(f"git {' '.join(args)}: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def commit_archive(repository: Path, commit: str) -> bytes:
    require(bool(re.fullmatch(r"[0-9a-f]{40}", commit)), "a full immutable commit identity is required")
    resolved = git(repository, "rev-parse", "--verify", commit + "^{commit}").decode().strip()
    require(resolved == commit, "commit identity did not resolve exactly")
    return git(repository, "archive", "--format=tar", commit)


def unpack(archive: bytes, destination: Path) -> None:
    with tarfile.open(fileobj=io.BytesIO(archive)) as handle:
        handle.extractall(destination, filter="data")


def constants(path: Path, names: tuple[str, ...]) -> dict:
    result = {}
    for node in ast.parse(path.read_text(encoding="utf-8"), str(path)).body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name) and target.id in names:
                    require(target.id not in result, f"{path.name}: repeated {target.id}")
                    result[target.id] = ast.literal_eval(node.value)
    require(set(result) == set(names), f"{path.name}: missing declared constants")
    return result


def scanned_codes(tree: Path) -> list[str]:
    scanner = INVENTORY.Engine(tree)
    scanner.walk()
    require(not scanner.unresolved, "unresolved engine code sites: " + "; ".join(scanner.unresolved))
    return sorted(scanner.codes)


def validate_pair(engine_repository: Path, engine_commit: str,
                  plugin_repository: Path, plugin_commit: str, manifest: dict | None = None) -> dict:
    engine_archive = commit_archive(engine_repository, engine_commit)
    plugin_archive = commit_archive(plugin_repository, plugin_commit)
    plugin_archive_sha256 = hashlib.sha256(plugin_archive).hexdigest()
    with tempfile.TemporaryDirectory(prefix="worldline-release-pair-") as scratch:
        base = Path(scratch)
        engine, plugin, source = base / "engine", base / "plugin", base / "inventory-source"
        unpack(engine_archive, engine)
        unpack(plugin_archive, plugin)
        codes = scanned_codes(engine)
        code_set = INVENTORY.digest(codes)
        generated = constants(engine / "runtime/worldline/engine_codes.py", ("CODES", "CODE_SET_SHA256"))
        require(list(generated["CODES"]) == codes and generated["CODE_SET_SHA256"] == code_set,
                "final engine generated vocabulary is stale")
        engine_version = constants(engine / "runtime/worldline/__init__.py", ("__version__",))["__version__"]
        compatibility = json.loads((engine / "plugin-compatibility.json").read_text())
        compatibility_sha256 = hashlib.sha256(json.dumps(
            compatibility, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        ).encode("utf-8")).hexdigest()
        require(compatibility.get("schema") == "worldline-plugin-compatibility-v1",
                "final engine compatibility schema is unsupported")
        require(compatibility.get("engine") == engine_version, "final engine compatibility version differs")
        pin = compatibility.get("plugin") or {}
        require(pin.get("repository") == "worldline-omarchy", "final engine names another plugin repository")
        require(pin.get("commit") == plugin_commit, "final engine does not pin the expected plugin commit")
        require(pin.get("archiveSha256") == plugin_archive_sha256, "final plugin archive digest differs")
        plugin_version = json.loads((plugin / "manifest.json").read_text())["version"]
        require(pin.get("tag") == "v" + plugin_version, "final plugin version differs from engine pin")
        require(compatibility.get("codeSetSha256") == code_set, "final engine compatibility code set differs")
        inventory = json.loads((plugin / "tools/engine-codes.json").read_text())
        require(inventory.get("schema") == "worldline-engine-codes/1", "plugin inventory schema is unsupported")
        require(inventory.get("codes") == codes and inventory.get("codeSetSha256") == code_set,
                "final plugin inventory differs from final engine vocabulary")
        declaration = re.findall(r'var\s+SUPPORTED_CODE_SET_SHA256\s*=\s*"([0-9a-f]{64})"',
                                 (plugin / "Model.js").read_text())
        require(declaration == [code_set], "final plugin runtime compatibility digest differs")
        inventory_source = inventory.get("engine") or {}
        require(inventory_source.get("source") == "git archive of the commit",
                "plugin inventory was not generated from an immutable source commit")
        source_commit = inventory_source.get("commit") or ""
        unpack(commit_archive(engine_repository, source_commit), source)
        require(scanned_codes(source) == codes, "inventory source vocabulary differs from final engine")
        source_version = constants(source / "runtime/worldline/__init__.py", ("__version__",))["__version__"]
        require(inventory_source.get("version") == source_version, "inventory source version differs")
        engine_tree = git(engine_repository, "rev-parse", engine_commit + "^{tree}").decode().strip()
        if manifest is not None:
            require(isinstance(manifest, dict) and manifest.get("schemaVersion") == 1,
                    "external release manifest schema is unsupported")
            require(manifest.get("accepted") is True, "external release manifest does not accept release")
            require(manifest.get("commit") == engine_commit and manifest.get("tree") == engine_tree,
                    "external release manifest names a different final engine identity")
            require(manifest.get("version") == engine_version and manifest.get("tag") == "v" + engine_version,
                    "external release manifest engine version differs")
            require(manifest.get("pluginCompatibility") == compatibility,
                    "external release manifest does not bind the final plugin compatibility record")
        return {
            "schema": "worldline-release-pair-validation-v1", "accepted": True,
            "engineCommit": engine_commit, "engineTree": engine_tree,
            "pluginCommit": plugin_commit, "pluginArchiveSha256": plugin_archive_sha256,
            "pluginCompatibilitySha256": compatibility_sha256,
            "inventorySourceCommit": source_commit, "codeSetSha256": code_set,
            "externalManifestChecked": manifest is not None,
            "nonClaims": ["This validates identity and vocabulary, not behavior or full assurance.",
                          "The archive digest is canonical git archive --format=tar; downloaded release artifacts require their own verification.",
                          "This does not authenticate the external manifest or authorize publication or installation."],
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-repo", required=True, type=Path)
    parser.add_argument("--engine-commit", required=True)
    parser.add_argument("--plugin-repo", required=True, type=Path)
    parser.add_argument("--plugin-commit", required=True)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text()) if args.manifest else None
        result = validate_pair(args.engine_repo, args.engine_commit, args.plugin_repo, args.plugin_commit, manifest)
    except (PairRefused, INVENTORY.Unresolved, OSError, ValueError, TypeError, KeyError, SyntaxError) as exc:
        print(json.dumps({"schema": "worldline-release-pair-validation-v1", "accepted": False,
                          "reason": str(exc)}, sort_keys=True))
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
