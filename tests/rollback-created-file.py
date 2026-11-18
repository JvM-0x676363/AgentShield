"""Isolated tests for the Unix rollback receipt prototype."""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(ROOT / "scripts" / "rollback"))

from rollback_receipt import assert_empty_private_directory, record_appended_block, record_created_file, record_json_added_keys  # noqa: E402
from rollback import apply_directory, check_receipt_location, plan, restore_json_added_keys  # noqa: E402
from git_config_receipt import read_key, set_pair_with_receipt, set_with_receipt  # noqa: E402
import apply_targets as target_engine  # noqa: E402


@unittest.skipIf(os.name == "nt", "Unix receipt permissions required")
class CreatedFileReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = pathlib.Path(self.temp.name)
        self.receipts = base / "receipts"
        self.destination = base / "managed.txt"
        self.destination.write_bytes(b"managed baseline\n")

    def receipt(self):
        record_created_file(str(self.destination), b"managed baseline\n", str(self.receipts))
        receipt_path = next(self.receipts.glob("*.json"))
        check_receipt_location(str(receipt_path))
        return json.loads(receipt_path.read_text(encoding="utf-8"))

    def test_created_file_is_ready(self):
        self.assertEqual(len(plan(self.receipt())), 1)
        self.assertEqual(list(self.receipts.glob("*.before")), [])

    def test_receipt_directory_must_start_empty(self):
        self.receipts.mkdir(mode=0o700)
        assert_empty_private_directory(str(self.receipts))
        record_created_file(str(self.destination), b"managed baseline\n", str(self.receipts))
        with self.assertRaisesRegex(ValueError, "receipt_directory_not_empty"):
            assert_empty_private_directory(str(self.receipts))

    def test_edited_file_is_preserved(self):
        receipt = self.receipt()
        self.destination.write_bytes(b"user edit\n")
        with self.assertRaisesRegex(ValueError, "destination_"):
            plan(receipt)

    def test_reinstalled_same_bytes_is_not_old_install(self):
        receipt = self.receipt()
        self.destination.write_bytes(b"managed baseline\n")
        os.utime(self.destination, ns=(self.destination.stat().st_atime_ns, receipt["operations"][0]["installed_mtime_ns"] + 1_000_000_000))
        with self.assertRaisesRegex(ValueError, "destination_replaced_or_reinstalled"):
            plan(receipt)

    def test_symlink_is_rejected(self):
        receipt = self.receipt()
        self.destination.unlink()
        try:
            self.destination.symlink_to(self.receipts / "missing")
        except OSError:
            self.skipTest("symlink creation unavailable")
        with self.assertRaisesRegex(ValueError, "destination_replaced_or_reinstalled"):
            plan(receipt)

    def test_parent_link_retarget_is_rejected(self):
        base = pathlib.Path(self.temp.name)
        original = base / "original"
        replacement = base / "replacement"
        original.mkdir()
        replacement.mkdir()
        link = base / "current"
        try:
            link.symlink_to(original, target_is_directory=True)
        except OSError:
            self.skipTest("symlink creation unavailable")
        destination = link / "managed.txt"
        (original / "managed.txt").write_bytes(b"managed baseline\n")
        record_created_file(str(destination), b"managed baseline\n", str(self.receipts))
        receipt = json.loads(next(self.receipts.glob("*.json")).read_text())
        self.assertEqual(len(plan(receipt)), 1)
        link.unlink()
        link.symlink_to(replacement, target_is_directory=True)
        (replacement / "managed.txt").write_bytes(b"managed baseline\n")
        with self.assertRaisesRegex(ValueError, "destination_parent_changed"):
            plan(receipt)

    def test_receipt_symlink_is_rejected(self):
        self.receipt()
        receipt = next(self.receipts.glob("*.json"))
        link = self.receipts / "linked.json"
        try:
            link.symlink_to(receipt)
        except OSError:
            self.skipTest("symlink creation unavailable")
        with self.assertRaisesRegex(ValueError, "unsafe_receipt_type"):
            check_receipt_location(str(link))

    def test_broad_receipt_directory_is_rejected(self):
        self.receipts.mkdir(mode=0o755)
        self.receipts.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "receipt_directory_not_private"):
            record_created_file(str(self.destination), b"managed baseline\n", str(self.receipts))
        self.assertEqual(self.destination.read_bytes(), b"managed baseline\n")

    def test_relative_receipt_directory_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "receipt_directory_not_absolute"):
            record_created_file(str(self.destination), b"managed baseline\n", "relative-receipts")

    def test_added_json_key_can_be_previewed(self):
        content = b'{"user":"kept","managed":null}\n'
        self.destination.write_bytes(content)
        record_json_added_keys(str(self.destination), content, str(self.receipts), {"managed": None})
        receipt_path = next(self.receipts.glob("*.json"))
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertEqual(plan(receipt)[0][0], "json_added_keys")
        refused = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt", str(receipt_path), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(refused.returncode, 2)
        self.assertEqual(json.loads(refused.stdout)["reason"], "json_inverse_not_yet_available")
        self.assertEqual(self.destination.read_bytes(), content)
        self.destination.write_bytes(b'{"user":"kept"}\n')
        with self.assertRaisesRegex(ValueError, "destination_"):
            plan(receipt)

    def reversible_json_receipt(self):
        prior = b'{\n  "user": "kept"\n}\n'
        installed = b'{\n  "user": "kept",\n  "managed": null\n}\n'
        self.destination.write_bytes(prior)
        os.utime(self.destination, ns=(1_700_000_000_000_000_000,
                                        1_700_000_000_000_000_000))
        prior_info = os.lstat(self.destination)
        self.destination.write_bytes(installed)
        record_json_added_keys(str(self.destination), installed, str(self.receipts),
                               {"managed": None}, prior_content=prior,
                               prior_info=prior_info)
        receipt_path = next(self.receipts.glob("*.json"))
        return prior, installed, prior_info, receipt_path

    def test_canonical_json_key_is_restored_with_metadata(self):
        prior, installed, prior_info, receipt_path = self.reversible_json_receipt()
        preview = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertEqual(json.loads(preview.stdout)["status"], "ready")
        self.assertEqual(self.destination.read_bytes(), installed)
        applied = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt-dir", str(self.receipts), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
        self.assertEqual(json.loads(applied.stdout)["status"], "restored")
        self.assertEqual(self.destination.read_bytes(), prior)
        restored_info = os.lstat(self.destination)
        self.assertEqual(restored_info.st_mtime_ns, prior_info.st_mtime_ns)
        self.assertEqual(restored_info.st_mode, prior_info.st_mode)
        self.assertEqual((restored_info.st_uid, restored_info.st_gid),
                         (prior_info.st_uid, prior_info.st_gid))

    def test_canonical_json_inverse_rejects_edits_and_metadata_drift(self):
        prior, installed, _, receipt_path = self.reversible_json_receipt()
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.destination.write_bytes(installed + b" ")
        with self.assertRaisesRegex(ValueError, "destination_"):
            plan(receipt)
        self.destination.write_bytes(installed)
        receipt["operations"][0]["installed_mtime_ns"] = os.lstat(self.destination).st_mtime_ns
        os.chmod(self.destination, 0o600 if (os.stat(self.destination).st_mode & 0o777) != 0o600 else 0o640)
        with self.assertRaisesRegex(ValueError, "destination_metadata_changed"):
            plan(receipt)

    def test_canonical_json_inverse_rejects_unreconstructable_prior(self):
        _, _, _, receipt_path = self.reversible_json_receipt()
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["operations"][0]["prior_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "prior_json_cannot_be_reconstructed"):
            plan(receipt)

    def test_canonical_permission_lists_restore_only_appended_rules(self):
        spec = {"list_parent": "permissions", "lists": ["allow", "deny"],
                "payload": {"permissions": {"allow": ["Read(new)"],
                                            "deny": ["Bash(blocked)"],
                                            "defaultMode": "default"}}}
        prior = {"theme": "user", "permissions": {"allow": ["Read(existing)"],
                 "deny": [], "defaultMode": "default"}}
        original = target_engine.dump_json(prior).encode("utf-8")
        self.destination.write_bytes(original)
        os.utime(self.destination, ns=(1_700_000_000_000_000_000,
                                        1_700_000_000_000_000_000))
        prior_mtime = os.lstat(self.destination).st_mtime_ns
        with mock.patch.object(target_engine, "RECEIPT_DIR", str(self.receipts)):
            target_engine.strat_merge_permission_lists(spec, str(self.destination), str(ROOT), False)
        receipt_path = next(self.receipts.glob("*.json"))
        receipt = json.loads(receipt_path.read_text())
        operation = receipt["operations"][0]
        self.assertEqual(operation["kind"], "json_list_append")
        self.assertEqual(operation["prior_lengths"], {"allow": 1, "deny": 0})
        self.assertNotIn("Read(existing)", receipt_path.read_text())
        self.assertEqual(plan(receipt)[0][0], "json_list_append")
        applied = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt-dir", str(self.receipts), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
        self.assertEqual(self.destination.read_bytes(), original)
        self.assertEqual(os.lstat(self.destination).st_mtime_ns, prior_mtime)

    def test_permission_list_inverse_blocks_changed_file_and_prior_hash(self):
        spec = {"list_parent": "permissions", "lists": ["allow"],
                "payload": {"permissions": {"allow": ["Read(new)"]}}}
        prior = target_engine.dump_json({"permissions": {"allow": ["Read(existing)"]}}).encode("utf-8")
        self.destination.write_bytes(prior)
        with mock.patch.object(target_engine, "RECEIPT_DIR", str(self.receipts)):
            target_engine.strat_merge_permission_lists(spec, str(self.destination), str(ROOT), False)
        receipt = json.loads(next(self.receipts.glob("*.json")).read_text())
        receipt["operations"][0]["prior_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "prior_json_cannot_be_reconstructed"):
            plan(receipt)
        self.destination.write_bytes(prior)
        with self.assertRaisesRegex(ValueError, "destination_"):
            plan(receipt)

    def test_permission_list_inverse_requires_canonical_append_only_change(self):
        spec = {"list_parent": "permissions", "lists": ["allow"],
                "payload": {"permissions": {"allow": ["Read(new)"],
                                            "defaultMode": "default"}}}
        for name, prior in (
                ("custom", b'{"permissions":{"allow":[],"defaultMode":"default"}}\n'),
                ("overwrite", target_engine.dump_json({"permissions": {
                    "allow": [], "defaultMode": "custom"}}).encode("utf-8")),
                ("missing-list", target_engine.dump_json({"permissions": {
                    "defaultMode": "default"}}).encode("utf-8"))):
            with self.subTest(name=name):
                destination = pathlib.Path(self.temp.name) / (name + ".json")
                receipts = pathlib.Path(self.temp.name) / (name + "-receipts")
                destination.write_bytes(prior)
                with mock.patch.object(target_engine, "RECEIPT_DIR", str(receipts)):
                    target_engine.strat_merge_permission_lists(spec, str(destination), str(ROOT), False)
                receipt = json.loads(next(receipts.glob("*.json")).read_text())
                self.assertEqual(receipt["operations"][0]["kind"], "manual_review")
                self.assertEqual(receipt["operations"][0]["reason"],
                                 "existing_target_has_no_inverse")

    def test_canonical_mcp_merge_restores_only_new_server(self):
        spec = {"payload": {"mcpServers": {"semgrep": {"command": "semgrep"}}}}
        prior = target_engine.dump_json({"mcpServers": {
            "user-server": {"command": "user-tool"}}, "user": True}).encode("utf-8")
        self.destination.write_bytes(prior)
        os.utime(self.destination, ns=(1_700_000_000_000_000_000,
                                        1_700_000_000_000_000_000))
        prior_mtime = os.lstat(self.destination).st_mtime_ns
        with mock.patch.object(target_engine, "RECEIPT_DIR", str(self.receipts)):
            target_engine.strat_merge_mcp(spec, str(self.destination), str(ROOT), False)
        receipt_path = next(self.receipts.glob("*.json"))
        receipt = json.loads(receipt_path.read_text())
        self.assertEqual(receipt["operations"][0]["kind"], "json_mcp_added_servers")
        self.assertEqual(receipt["operations"][0]["added_servers"], ["semgrep"])
        self.assertNotIn("user-tool", receipt_path.read_text())
        self.assertEqual(plan(receipt)[0][0], "json_mcp_added_servers")
        applied = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt-dir", str(self.receipts), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
        self.assertEqual(self.destination.read_bytes(), prior)
        self.assertEqual(os.lstat(self.destination).st_mtime_ns, prior_mtime)

    def test_mcp_inverse_requires_new_server_and_canonical_json(self):
        spec = {"payload": {"mcpServers": {"semgrep": {"command": "semgrep"}}}}
        for name, prior in (
                ("overwrite", target_engine.dump_json({"mcpServers": {
                    "semgrep": {"command": "custom"}}}).encode("utf-8")),
                ("custom", b'{"mcpServers":{}}\n')):
            with self.subTest(name=name):
                destination = pathlib.Path(self.temp.name) / (name + ".json")
                receipts = pathlib.Path(self.temp.name) / (name + "-receipts")
                destination.write_bytes(prior)
                with mock.patch.object(target_engine, "RECEIPT_DIR", str(receipts)):
                    target_engine.strat_merge_mcp(spec, str(destination), str(ROOT), False)
                receipt = json.loads(next(receipts.glob("*.json")).read_text())
                self.assertEqual(receipt["operations"][0]["kind"], "manual_review")
                self.assertEqual(receipt["operations"][0]["reason"],
                                 "existing_target_has_no_inverse")

    def test_canonical_json_reports_partial_after_write_failure(self):
        prior, _, _, receipt_path = self.reversible_json_receipt()
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        kind, destination, expected, identity, operation = plan(receipt)[0]
        self.assertEqual(kind, "json_added_keys")
        with mock.patch("rollback.os.fsync", side_effect=OSError("injected")):
            with self.assertRaisesRegex(ValueError, "json_partial_restore"):
                restore_json_added_keys(destination, expected, identity, operation)
        self.assertEqual(self.destination.read_bytes(), prior)

    def test_batch_reports_partial_when_first_receipt_partially_restores(self):
        self.reversible_json_receipt()
        child_result = mock.Mock(returncode=2, stdout='{"status":"partial","exit_code":2}')
        with mock.patch("rollback.subprocess.run", return_value=child_result):
            report = apply_directory(str(self.receipts))
        self.assertEqual((report["status"], report["applied"]), ("partial", 0))

    def test_target_engine_records_inverse_only_for_canonical_prior_json(self):
        spec = {"payload": {"managed": None}}
        self.destination.write_bytes(b'{\n  "user": "kept"\n}\n')
        with mock.patch.object(target_engine, "RECEIPT_DIR", str(self.receipts)):
            target_engine.strat_merge_missing_keys(spec, str(self.destination), str(ROOT), False)
        canonical_receipt = json.loads(next(self.receipts.glob("*.json")).read_text())
        self.assertEqual(canonical_receipt["operations"][0]["inverse_version"], 1)
        self.assertEqual(self.destination.read_bytes(),
                         b'{\n  "user": "kept",\n  "managed": null\n}\n')

        other = pathlib.Path(self.temp.name) / "custom-format.json"
        other.write_bytes(b'{"user":"kept"}\n')
        second_receipts = pathlib.Path(self.temp.name) / "other-receipts"
        with mock.patch.object(target_engine, "RECEIPT_DIR", str(second_receipts)):
            target_engine.strat_merge_missing_keys(spec, str(other), str(ROOT), False)
        custom_receipt = json.loads(next(second_receipts.glob("*.json")).read_text())
        self.assertNotIn("inverse_version", custom_receipt["operations"][0])

    def test_run_apply_blocks_all_when_json_inverse_is_preview_only(self):
        self.receipt()
        original = b'{"user":"kept","managed":null}\n'
        settings = pathlib.Path(self.temp.name) / "settings.json"
        settings.write_bytes(original)
        record_json_added_keys(str(settings), original, str(self.receipts), {"managed": None})
        result = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt-dir", str(self.receipts), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        report = json.loads(result.stdout)
        self.assertEqual((report["status"], report["applied"], report["ready"], report["blocked"]),
                         ("blocked", 0, 1, 1))
        self.assertTrue(self.destination.exists())
        self.assertEqual(settings.read_bytes(), original)

    def test_run_apply_blocks_all_when_existing_change_needs_review(self):
        self.receipt()
        existing = pathlib.Path(self.temp.name) / "existing.json"
        existing.write_bytes(b'{"user":"kept"}\n')
        marked = subprocess.run([
            sys.executable, str(ROOT / "lib" / "rollback_receipt.py"),
            "--manual-review", str(existing), "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(marked.returncode, 0, marked.stdout + marked.stderr)
        result = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt-dir", str(self.receipts), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        report = json.loads(result.stdout)
        self.assertEqual((report["status"], report["applied"], report["ready"], report["blocked"]),
                         ("blocked", 0, 1, 1))
        self.assertTrue(self.destination.exists())
        self.assertEqual(existing.read_bytes(), b'{"user":"kept"}\n')

    def test_interrupted_created_file_keeps_provisional_receipt(self):
        created = pathlib.Path(self.temp.name) / "new.json"
        with mock.patch.object(target_engine, "RECEIPT_DIR", str(self.receipts)):
            with mock.patch.object(target_engine, "record_created_file", side_effect=ValueError("simulated_failure")):
                with self.assertRaisesRegex(target_engine.TargetError, "rollback receipt failed"):
                    target_engine.write_text(str(created), '{"managed":true}\n', False)
        self.assertTrue(created.exists())
        receipt = next(self.receipts.glob("*.json"))
        metadata = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(metadata["operations"][0]["reason"], "receipt_incomplete")
        blocked = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt-dir", str(self.receipts), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(blocked.returncode, 2)
        self.assertEqual(json.loads(blocked.stdout)["status"], "blocked")
        self.assertTrue(created.exists())

    def test_provisional_cli_clears_only_after_created_receipt(self):
        created = pathlib.Path(self.temp.name) / "new-hook"
        provisional = subprocess.run([
            sys.executable, str(ROOT / "lib" / "rollback_receipt.py"),
            "--provisional", str(created), "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(provisional.returncode, 0, provisional.stdout + provisional.stderr)
        identifier = provisional.stdout.strip()
        self.assertRegex(identifier, r"^[0-9a-f]{32}$")
        early = subprocess.run([
            sys.executable, str(ROOT / "lib" / "rollback_receipt.py"),
            "--clear-provisional", identifier, "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(early.returncode, 1)
        self.assertTrue((self.receipts / (identifier + ".json")).exists())
        created.write_bytes(b"managed hook\n")
        record_created_file(str(created), b"managed hook\n", str(self.receipts))
        before = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt-dir", str(self.receipts), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(json.loads(before.stdout)["status"], "blocked")
        self.assertTrue(created.exists())
        cleared = subprocess.run([
            sys.executable, str(ROOT / "lib" / "rollback_receipt.py"),
            "--clear-provisional", identifier, "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(cleared.returncode, 0, cleared.stdout + cleared.stderr)
        self.assertEqual(len(list(self.receipts.glob("*.json"))), 1)
        ready = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(json.loads(ready.stdout)["status"], "ready")

    def test_unix_engine_marks_existing_overwrite_for_manual_review(self):
        base = pathlib.Path(self.temp.name)
        fixture = base / "fixture"
        (fixture / "targets").mkdir(parents=True)
        home = base / "home"
        home.mkdir()
        existing = home / "existing.json"
        existing.write_bytes(b'{"user":"kept"}\n')
        os_key = "darwin" if sys.platform == "darwin" else "linux"
        manifest = {
            "id": "pilot", "label": "Rollback synthetic target", "tool": "test",
            "scope": "user", "requires_admin": False, "selectors": ["pilot"],
            "files": [{"dest": {os_key: "${HOME}/existing.json"}, "strategy": "overwrite",
                       "backup": False, "payload": {"managed": True}}],
        }
        (fixture / "targets" / "pilot.json").write_text(json.dumps(manifest), encoding="utf-8")
        installed = subprocess.run([
            sys.executable, str(ROOT / "lib" / "apply_targets.py"),
            "--root", str(fixture), "--scope", "user", "--home", str(home),
            "--os", os_key, "--only", "pilot", "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        receipt = next(self.receipts.glob("*.json"))
        self.assertEqual(json.loads(receipt.read_text())["operations"][0]["kind"], "manual_review")
        self.assertTrue(existing.exists())

    def test_appended_block_restores_prior_bytes(self):
        prior = b"user guidance\n"
        installed = prior + b"\n<!-- security-team-block -->\nmanaged\n<!-- security-team-block -->\n"
        self.destination.write_bytes(installed)
        record_appended_block(str(self.destination), prior, installed, str(self.receipts))
        receipt = next(self.receipts.glob("*.json"))
        self.assertEqual(plan(json.loads(receipt.read_text()))[0][0], "appended_block")
        restored = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt", str(receipt), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertEqual(json.loads(restored.stdout)["status"], "restored")
        self.assertEqual(self.destination.read_bytes(), prior)

    def test_appended_block_conflict_preserves_edit(self):
        prior = b"user guidance\n"
        installed = prior + b"\nmanaged\n"
        self.destination.write_bytes(installed)
        record_appended_block(str(self.destination), prior, installed, str(self.receipts))
        receipt = next(self.receipts.glob("*.json"))
        self.destination.write_bytes(installed + b"user edit")
        refused = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt", str(receipt), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(json.loads(refused.stdout)["status"], "blocked")
        self.assertEqual(self.destination.read_bytes(), installed + b"user edit")

    def test_unix_engine_receipt_and_rollback(self):
        base = pathlib.Path(self.temp.name)
        fixture = base / "fixture"
        target_dir = fixture / "targets"
        target_dir.mkdir(parents=True)
        home = base / "home"
        home.mkdir()
        manifest = {
            "id": "pilot", "label": "Rollback synthetic target", "tool": "test",
            "scope": "user", "requires_admin": False, "selectors": ["pilot"],
            "files": [{
                "dest": {"linux": "${HOME}/managed.json", "darwin": "${HOME}/managed.json"},
                "strategy": "overwrite", "format": "json", "backup": False,
                "payload": {"enabled": True},
            }],
        }
        (target_dir / "pilot.json").write_text(json.dumps(manifest), encoding="utf-8")
        os_key = "darwin" if sys.platform == "darwin" else "linux"
        installed = subprocess.run([
            sys.executable, str(ROOT / "lib" / "apply_targets.py"),
            "--root", str(fixture), "--scope", "user", "--home", str(home),
            "--os", os_key, "--only", "pilot", "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        managed = home / "managed.json"
        self.assertTrue(managed.is_file())
        receipt = next(self.receipts.glob("*.json"))
        preview = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt", str(receipt),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(json.loads(preview.stdout)["status"], "ready")
        removed = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt", str(receipt), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(json.loads(removed.stdout)["status"], "removed")
        self.assertFalse(managed.exists())

    def test_created_hook_receipt_cli(self):
        hook = pathlib.Path(self.temp.name) / "pre-commit"
        hook.write_bytes(b"#!/bin/sh\nexit 0\n")
        recorded = subprocess.run([
            sys.executable, str(ROOT / "lib" / "rollback_receipt.py"),
            "--created-file", str(hook), "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(recorded.returncode, 0, recorded.stderr)
        receipt = next(self.receipts.glob("*.json"))
        self.assertEqual(plan(json.loads(receipt.read_text()))[0][0], "created_file")
        removed = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt", str(receipt), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(removed.returncode, 0, removed.stdout + removed.stderr)
        self.assertFalse(hook.exists())

    def test_run_preview_reports_conflicts_without_removal(self):
        self.receipt()
        command = [sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
                   "--receipt-dir", str(self.receipts)]
        ready = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(ready.returncode, 0, ready.stdout + ready.stderr)
        self.assertEqual(json.loads(ready.stdout)["ready"], 1)
        self.assertTrue(self.destination.exists())
        second = pathlib.Path(self.temp.name) / "second.txt"
        second.write_bytes(b"managed baseline\n")
        record_created_file(str(second), b"managed baseline\n", str(self.receipts))
        second.write_bytes(b"user edit\n")
        conflict = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(conflict.returncode, 2)
        report = json.loads(conflict.stdout)
        self.assertEqual((report["receipts"], report["ready"], report["blocked"]), (2, 1, 1))
        self.assertNotIn(str(self.destination), conflict.stdout)
        self.assertTrue(self.destination.exists())
        self.assertTrue(second.exists())
        rejected = subprocess.run(command + ["--apply"], capture_output=True, text=True, check=False)
        self.assertEqual(json.loads(rejected.stdout)["status"], "blocked")
        self.assertTrue(self.destination.exists())
        self.assertTrue(second.exists())

    def test_run_apply_removes_distinct_created_files(self):
        self.receipt()
        second = pathlib.Path(self.temp.name) / "second.txt"
        second.write_bytes(b"second managed file\n")
        record_created_file(str(second), b"second managed file\n", str(self.receipts))
        applied = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt-dir", str(self.receipts), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
        report = json.loads(applied.stdout)
        self.assertEqual((report["status"], report["applied"], report["ready"]),
                         ("restored", 2, 0))
        self.assertFalse(self.destination.exists())
        self.assertFalse(second.exists())

    def test_run_preview_rejects_duplicate_destination(self):
        self.receipt()
        record_created_file(str(self.destination), b"managed baseline\n", str(self.receipts))
        preview = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(preview.returncode, 2)
        report = json.loads(preview.stdout)
        self.assertEqual((report["ready"], report["blocked"]), (0, 2))
        self.assertTrue(all(item["reason"] == "duplicate_destination" for item in report["items"]))
        self.assertTrue(self.destination.exists())

    def test_unix_engine_appended_guidance_rollback(self):
        base = pathlib.Path(self.temp.name)
        fixture = base / "fixture"
        (fixture / "targets").mkdir(parents=True)
        (fixture / "policy").mkdir()
        (fixture / "policy" / "guidance.md").write_text("managed guidance", encoding="utf-8")
        home = base / "home"
        home.mkdir()
        guidance = home / "AGENTS.md"
        prior = b"user guidance\n"
        guidance.write_bytes(prior)
        os_key = "darwin" if sys.platform == "darwin" else "linux"
        manifest = {
            "id": "pilot", "label": "Rollback synthetic target", "tool": "test",
            "scope": "user", "requires_admin": False, "selectors": ["pilot"],
            "files": [{
                "dest": {os_key: "${HOME}/AGENTS.md"}, "strategy": "md-block",
                "marker": "<!-- security-team-block -->", "compose": ["policy/guidance.md"],
            }],
        }
        (fixture / "targets" / "pilot.json").write_text(json.dumps(manifest), encoding="utf-8")
        installed = subprocess.run([
            sys.executable, str(ROOT / "lib" / "apply_targets.py"),
            "--root", str(fixture), "--scope", "user", "--home", str(home),
            "--os", os_key, "--only", "pilot", "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        self.assertEqual(len(list(self.receipts.glob("*.json"))), 1)
        receipt = next(self.receipts.glob("*.json"))
        self.assertEqual(json.loads(receipt.read_text())["operations"][0]["kind"], "appended_block")
        restored = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt", str(receipt), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertEqual(guidance.read_bytes(), prior)

    def test_git_key_restores_without_touching_other_key(self):
        config = pathlib.Path(self.temp.name) / "gitconfig"
        for key, value in (("user.name", "kept"), ("core.hooksPath", "/old-hooks")):
            result = subprocess.run(
                ["git", "config", "--file", str(config), key, value],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
            )
            self.assertEqual(result.returncode, 0)
        set_with_receipt(str(config), "core.hooksPath", "/new-hooks", str(self.receipts))
        receipt = next(self.receipts.glob("*.json"))
        self.assertEqual(read_key(str(config), "core.hooksPath"), "/new-hooks")
        restored = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt", str(receipt), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertEqual(json.loads(restored.stdout)["status"], "restored")
        self.assertEqual(read_key(str(config), "core.hooksPath"), "/old-hooks")
        untouched = subprocess.run(
            ["git", "config", "--file", str(config), "--get", "user.name"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(untouched.stdout.strip(), "kept")

    def test_git_key_conflict_preserves_user_value(self):
        config = pathlib.Path(self.temp.name) / "gitconfig"
        set_with_receipt(str(config), "init.templateDir", "/managed-template", str(self.receipts))
        receipt = next(self.receipts.glob("*.json"))
        changed = subprocess.run(
            ["git", "config", "--file", str(config), "init.templateDir", "/user-template"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
        self.assertEqual(changed.returncode, 0)
        refused = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt", str(receipt), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(json.loads(refused.stdout)["status"], "blocked")
        self.assertEqual(read_key(str(config), "init.templateDir"), "/user-template")

    def test_git_pair_restores_both_keys(self):
        config = pathlib.Path(self.temp.name) / "gitconfig"
        for key, value in (("user.name", "kept"), ("core.hooksPath", "/old-hooks")):
            result = subprocess.run(["git", "config", "--file", str(config), key, value],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            self.assertEqual(result.returncode, 0)
        set_pair_with_receipt(str(config), {
            "core.hooksPath": "/new-hooks", "init.templateDir": "/new-template",
        }, str(self.receipts))
        receipt = next(self.receipts.glob("*.json"))
        self.assertEqual(plan(json.loads(receipt.read_text()))[0][0], "git_config_pair")
        restored = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt", str(receipt), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(restored.returncode, 0, restored.stdout + restored.stderr)
        self.assertEqual(json.loads(restored.stdout)["status"], "restored")
        self.assertEqual(read_key(str(config), "core.hooksPath"), "/old-hooks")
        self.assertIsNone(read_key(str(config), "init.templateDir"))
        self.assertEqual(subprocess.run(["git", "config", "--file", str(config), "--get", "user.name"],
                                        capture_output=True, text=True, check=False).stdout.strip(), "kept")

    def test_git_pair_receipt_failure_keeps_manual_review_marker(self):
        config = pathlib.Path(self.temp.name) / "gitconfig"
        with mock.patch("git_config_receipt.record_git_config_pair", side_effect=OSError("simulated_receipt_failure")):
            with self.assertRaisesRegex(OSError, "simulated_receipt_failure"):
                set_pair_with_receipt(str(config), {
                    "core.hooksPath": "/new-hooks", "init.templateDir": "/new-template",
                }, str(self.receipts))
        self.assertEqual(read_key(str(config), "core.hooksPath"), "/new-hooks")
        receipts = list(self.receipts.glob("*.json"))
        self.assertEqual(len(receipts), 1)
        self.assertEqual(json.loads(receipts[0].read_text())["operations"][0]["reason"], "receipt_incomplete")
        self.assertEqual(apply_directory(str(self.receipts))["status"], "blocked")

    def test_git_pair_conflict_preserves_both_keys(self):
        config = pathlib.Path(self.temp.name) / "gitconfig"
        set_pair_with_receipt(str(config), {
            "core.hooksPath": "/new-hooks", "init.templateDir": "/new-template",
        }, str(self.receipts))
        receipt = next(self.receipts.glob("*.json"))
        subprocess.run(["git", "config", "--file", str(config), "core.hooksPath", "/user-hooks"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        refused = subprocess.run([
            sys.executable, str(ROOT / "scripts" / "rollback" / "rollback.py"),
            "--receipt", str(receipt), "--apply",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(json.loads(refused.stdout)["status"], "blocked")
        self.assertEqual(read_key(str(config), "core.hooksPath"), "/user-hooks")
        self.assertEqual(read_key(str(config), "init.templateDir"), "/new-template")

    def test_git_pair_cli_records_one_receipt(self):
        config = pathlib.Path(self.temp.name) / "gitconfig"
        result = subprocess.run([
            sys.executable, str(ROOT / "lib" / "git_config_receipt.py"),
            "--config-path", str(config), "--hooks-dir", "/new-hooks",
            "--template-dir", "/new-template", "--receipt-dir", str(self.receipts),
        ], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "recorded")
        receipts = list(self.receipts.glob("*.json"))
        self.assertEqual(len(receipts), 1)
        self.assertEqual(json.loads(receipts[0].read_text())["operations"][0]["kind"], "git_config_pair")


if __name__ == "__main__":
    unittest.main()
