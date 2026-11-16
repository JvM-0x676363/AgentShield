"""Isolated tests for the Unix rollback receipt prototype."""

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
sys.path.insert(0, str(ROOT / "scripts" / "rollback"))

from rollback_receipt import assert_empty_private_directory, record_appended_block, record_created_file, record_json_added_keys  # noqa: E402
from rollback import check_receipt_location, plan  # noqa: E402
from git_config_receipt import read_key, set_pair_with_receipt, set_with_receipt  # noqa: E402


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
        self.destination.write_bytes(b'{"user":"kept"}\n')
        with self.assertRaisesRegex(ValueError, "destination_"):
            plan(receipt)

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
        self.assertEqual(json.loads(rejected.stdout)["reason"], "batch_apply_not_available")
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
