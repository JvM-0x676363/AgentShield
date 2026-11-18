"""Change only two AgentShield Git keys with an opt-in rollback receipt."""

import argparse
import json
import os
import pathlib
import stat
import subprocess

from rollback_receipt import clear_provisional, ensure_private_directory, record_git_config, record_git_config_pair, record_manual_review


SUPPORTED_KEYS = frozenset(("core.hooksPath", "init.templateDir"))


def _regular_or_absent(path):
    if not os.path.lexists(path):
        return
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("unsafe_git_config_type")


def _safe_parents(path):
    parent = pathlib.Path(os.path.abspath(path)).parent
    for directory in (parent, *parent.parents):
        info = os.lstat(directory)
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError("git_config_parent_symlink")


def read_key(config_path, key):
    if key not in SUPPORTED_KEYS:
        raise ValueError("unsupported_git_key")
    _regular_or_absent(config_path)
    result = subprocess.run(
        ["git", "config", "--file", config_path, "--null", "--get-all", key],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
    )
    if result.returncode == 1 and not result.stdout:
        return None
    if result.returncode != 0:
        raise ValueError("git_config_read_failed")
    values = result.stdout.rstrip(b"\0").split(b"\0")
    if len(values) != 1:
        raise ValueError("git_config_multiple_values")
    try:
        value = values[0].decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("git_config_invalid_encoding") from exc
    if any(character in value for character in ("\0", "\r", "\n")):
        raise ValueError("git_config_invalid_value")
    return value


def set_with_receipt(config_path, key, installed_value, receipt_dir):
    if key not in SUPPORTED_KEYS or not isinstance(installed_value, str) or not os.path.isabs(installed_value) or any(character in installed_value for character in ("\0", "\r", "\n")):
        raise ValueError("invalid_git_config_operation")
    config_path = os.path.abspath(config_path)
    _safe_parents(config_path)
    ensure_private_directory(receipt_dir)
    previous = read_key(config_path, key)
    if previous == installed_value:
        return None
    guard = record_manual_review(config_path, receipt_dir, "receipt_incomplete")
    result = subprocess.run(
        ["git", "config", "--file", config_path, key, installed_value],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    if result.returncode != 0 or read_key(config_path, key) != installed_value:
        raise ValueError("git_config_write_failed")
    receipt = record_git_config(config_path, key, installed_value, previous, receipt_dir)
    clear_provisional(receipt_dir, guard, receipt)
    return receipt


def restore_key(config_path, key, installed_value, previous_value, identity):
    _safe_parents(config_path)
    _regular_or_absent(config_path)
    info = os.lstat(config_path)
    if (info.st_dev, info.st_ino, info.st_mtime_ns) != identity:
        raise ValueError("git_config_changed")
    if read_key(config_path, key) != installed_value:
        raise ValueError("git_config_value_changed")
    if previous_value is None:
        command = ["git", "config", "--file", config_path, "--unset-all", key]
    else:
        command = ["git", "config", "--file", config_path, key, previous_value]
    result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    if result.returncode != 0:
        raise ValueError("git_config_restore_failed")
    if read_key(config_path, key) != previous_value:
        raise ValueError("git_config_restore_failed")


PAIR_KEYS = ("core.hooksPath", "init.templateDir")


def set_pair_with_receipt(config_path, installed_values, receipt_dir):
    if not isinstance(installed_values, dict) or set(installed_values) != set(PAIR_KEYS):
        raise ValueError("invalid_git_config_pair")
    if any(not isinstance(installed_values[key], str) or
           not os.path.isabs(installed_values[key]) or
           any(char in installed_values[key] for char in ("\0", "\r", "\n"))
           for key in PAIR_KEYS):
        raise ValueError("invalid_git_config_pair")
    config_path = os.path.abspath(config_path)
    _safe_parents(config_path)
    ensure_private_directory(receipt_dir)
    previous = {key: read_key(config_path, key) for key in PAIR_KEYS}
    if all(previous[key] == installed_values[key] for key in PAIR_KEYS):
        return None
    guard = record_manual_review(config_path, receipt_dir, "receipt_incomplete")
    for key in PAIR_KEYS:
        if previous[key] == installed_values[key]:
            continue
        result = subprocess.run(
            ["git", "config", "--file", config_path, key, installed_values[key]],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
        if result.returncode != 0 or read_key(config_path, key) != installed_values[key]:
            raise ValueError("git_config_pair_write_failed")
    values = {key: {"installed_value": installed_values[key], "previous_value": previous[key]}
              for key in PAIR_KEYS}
    receipt = record_git_config_pair(config_path, values, receipt_dir)
    clear_provisional(receipt_dir, guard, receipt)
    return receipt


def restore_pair(config_path, values, identity):
    _safe_parents(config_path)
    _regular_or_absent(config_path)
    info = os.lstat(config_path)
    if (info.st_dev, info.st_ino, info.st_mtime_ns) != identity:
        raise ValueError("git_config_changed")
    if any(read_key(config_path, key) != values[key]["installed_value"] for key in PAIR_KEYS):
        raise ValueError("git_config_value_changed")
    for key in reversed(PAIR_KEYS):
        previous = values[key]["previous_value"]
        if previous == values[key]["installed_value"]:
            continue
        command = (["git", "config", "--file", config_path, "--unset-all", key]
                   if previous is None else ["git", "config", "--file", config_path, key, previous])
        try:
            result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            if result.returncode != 0 or read_key(config_path, key) != previous:
                raise ValueError("git_config_restore_failed")
        except (OSError, ValueError) as exc:
            raise ValueError("git_config_partial_restore") from exc
    if any(read_key(config_path, key) != values[key]["previous_value"] for key in PAIR_KEYS):
        raise ValueError("git_config_partial_restore")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-path", required=True)
    parser.add_argument("--hooks-dir", required=True)
    parser.add_argument("--template-dir", required=True)
    parser.add_argument("--receipt-dir", required=True)
    args = parser.parse_args()
    try:
        receipt = set_pair_with_receipt(args.config_path, {
            "core.hooksPath": args.hooks_dir,
            "init.templateDir": args.template_dir,
        }, args.receipt_dir)
        result = {"schema_version": 1, "runner": "git-config-receipt", "status": "recorded" if receipt else "unchanged", "exit_code": 0}
        code = 0
    except (OSError, ValueError) as exc:
        result = {"schema_version": 1, "runner": "git-config-receipt", "status": "failed", "reason": str(exc) if isinstance(exc, ValueError) else "metadata_unavailable", "exit_code": 1}
        code = 1
    print(json.dumps(result, separators=(",", ":")))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
