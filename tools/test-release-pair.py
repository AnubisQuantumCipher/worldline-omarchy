#!/usr/bin/env python3
"""Benign temporary Git fixtures for the release-pair identity check; no runtime is run."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location("release_pair", Path(__file__).with_name("check-release-pair.py"))
assert SPEC is not None and SPEC.loader is not None
PAIR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PAIR)


class ReleasePair(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="worldline-pair-fixture-")
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name)
        self.engine, self.plugin = base / "engine", base / "plugin"
        for repo in (self.engine, self.plugin):
            repo.mkdir()
            subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True)
        codes = ["CORE_FIXTURE_IO", "FIXTURE_REFUSED"]
        self.digest = PAIR.INVENTORY.digest(codes)
        self.write(self.engine, "core/worldline_core.h", "#define WL_COLLAPSE_AUTHORIZED 0u\n#define WL_ERR_FIXTURE_IO 1\n")
        self.write(self.engine, "runtime/worldline/__init__.py", '__version__ = "1.9.2"\n')
        self.write(self.engine, "runtime/worldline/ordinary.py", 'raise WorldlineError("FIXTURE_REFUSED", "fixture")\n')
        self.write(self.engine, "runtime/worldline/engine_codes.py", f"CODES = {tuple(codes)!r}\nCODE_SET_SHA256 = {self.digest!r}\n")
        self.source_commit = self.commit(self.engine, "inventory source fixture")
        self.write(self.plugin, "manifest.json", json.dumps({"version": "1.3.5"}))
        self.write(self.plugin, "Model.js", f'var SUPPORTED_CODE_SET_SHA256 = "{self.digest}"\n')
        self.write(self.plugin, "tools/engine-codes.json", json.dumps({
            "schema": "worldline-engine-codes/1", "codes": codes, "codeSetSha256": self.digest,
            "engine": {"commit": self.source_commit, "version": "1.9.2", "source": "git archive of the commit"},
        }))
        self.plugin_commit = self.commit(self.plugin, "plugin fixture")
        archive_digest = hashlib.sha256(PAIR.commit_archive(self.plugin, self.plugin_commit)).hexdigest()
        self.compatibility = {
            "schema": "worldline-plugin-compatibility-v1", "engine": "1.9.2", "codeSetSha256": self.digest,
            "plugin": {"repository": "worldline-omarchy", "tag": "v1.3.5", "commit": self.plugin_commit,
                       "archiveSha256": archive_digest},
        }
        self.write(self.engine, "plugin-compatibility.json", json.dumps(self.compatibility))
        self.engine_commit = self.commit(self.engine, "final engine pin fixture")
        self.manifest = {
            "schemaVersion": 1, "accepted": True, "commit": self.engine_commit,
            "tree": PAIR.git(self.engine, "rev-parse", self.engine_commit + "^{tree}").decode().strip(),
            "version": "1.9.2", "tag": "v1.9.2", "pluginCompatibility": self.compatibility,
        }

    @staticmethod
    def write(repo: Path, name: str, text: str) -> None:
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    @staticmethod
    def commit(repo: Path, message: str) -> str:
        PAIR.git(repo, "add", ".")
        PAIR.git(repo, "-c", "user.name=fixture", "-c", "user.email=fixture@invalid", "commit", "-q", "-m", message)
        return PAIR.git(repo, "rev-parse", "HEAD").decode().strip()

    def validate(self, manifest: dict | None = None) -> dict:
        return PAIR.validate_pair(self.engine, self.engine_commit, self.plugin, self.plugin_commit, manifest)

    def test_inventory_source_and_final_engine_are_distinct_without_a_cycle(self) -> None:
        self.assertNotEqual(self.source_commit, self.engine_commit)
        result = self.validate(self.manifest)
        self.assertTrue(result["accepted"])
        self.assertTrue(result["externalManifestChecked"])
        self.assertEqual(result["inventorySourceCommit"], self.source_commit)
        self.assertEqual(result["pluginCommit"], self.plugin_commit)
        self.assertEqual(result["engineCommit"], self.engine_commit)
        self.assertEqual(result["codeSetSha256"], self.digest)
        self.assertEqual(result["pluginCompatibilitySha256"], hashlib.sha256(json.dumps(
            self.compatibility, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        ).encode("utf-8")).hexdigest())

    def test_pre_manifest_check_does_not_claim_external_binding(self) -> None:
        self.assertFalse(self.validate()["externalManifestChecked"])

    def test_incomplete_or_different_external_pair_refuses(self) -> None:
        for changes in ({"accepted": False}, {"commit": self.source_commit}, {"tree": "missing"},
                        {"pluginCompatibility": {}}, {"version": "1.9.1"}):
            with self.subTest(changes=changes):
                with self.assertRaises(PAIR.PairRefused):
                    self.validate({**self.manifest, **changes})

    def test_unassigned_plugin_pin_refuses(self) -> None:
        compatibility = copy.deepcopy(self.compatibility)
        compatibility["plugin"]["commit"] = None
        self.write(self.engine, "plugin-compatibility.json", json.dumps(compatibility))
        self.engine_commit = self.commit(self.engine, "unassigned pair fixture")
        with self.assertRaisesRegex(PAIR.PairRefused, "does not pin"):
            self.validate()

    def test_different_plugin_archive_refuses(self) -> None:
        compatibility = copy.deepcopy(self.compatibility)
        compatibility["plugin"]["archiveSha256"] = "unassigned"
        self.write(self.engine, "plugin-compatibility.json", json.dumps(compatibility))
        self.engine_commit = self.commit(self.engine, "unassigned archive fixture")
        with self.assertRaisesRegex(PAIR.PairRefused, "archive digest differs"):
            self.validate()

    def test_uncommitted_working_tree_does_not_change_identity_inputs(self) -> None:
        self.write(self.plugin, "Model.js", "uncommitted scratch content\n")
        self.write(self.engine, "runtime/worldline/ordinary.py", "uncommitted scratch content\n")
        self.assertTrue(self.validate(self.manifest)["accepted"])


if __name__ == "__main__":
    unittest.main()
