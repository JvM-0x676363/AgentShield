#!/usr/bin/env python3
"""Remove newly created files only when a private receipt matches their bytes."""

import argparse
import hashlib
import json
import os
import pathlib
import stat
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "lib"))
from git_config_receipt import PAIR_KEYS, read_key, restore_key, restore_pair  # noqa: E402


def read_regular(path):
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("unsafe_file_type")
    return pathlib.Path(path).read_bytes()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def check_receipt_location(path):
    directory = os.path.dirname(os.path.abspath(path))
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o077:
        raise ValueError("receipt_directory_not_private")
    if hasattr(os, "geteuid") and info.st_uid != os.geteuid():
        raise ValueError("receipt_directory_wrong_owner")
    receipt = os.lstat(path)
    if receipt.st_mode & 0o077:
        raise ValueError("receipt_not_private")
    if hasattr(os, "geteuid") and receipt.st_uid != os.geteuid():
        raise ValueError("receipt_wrong_owner")


def plan(receipt):
    if not isinstance(receipt, dict) or receipt.get("schema_version") != 1 or receipt.get("runner") != "agentshield-rollback":
        raise ValueError("invalid_receipt")
    operations = receipt.get("operations")
    if not isinstance(operations, list) or len(operations) != 1:
        raise ValueError("empty_receipt")
    seen, planned = set(), []
    for item in operations:
        if not isinstance(item, dict) or item.get("kind") not in ("created_file", "appended_block", "json_added_keys", "git_config", "git_config_pair"):
            raise ValueError("unsupported_operation")
        kind = item["kind"]
        dest = item.get("destination")
        if not isinstance(dest, str) or not os.path.isabs(dest) or dest in seen:
            raise ValueError("invalid_destination")
        identity = tuple(item.get(key) for key in ("installed_device", "installed_inode", "installed_mtime_ns"))
        if any(type(value) is not int or value < 0 for value in identity):
            raise ValueError("invalid_file_identity")
        seen.add(dest)
        current_info = os.lstat(dest)
        if (current_info.st_dev, current_info.st_ino, current_info.st_mtime_ns) != identity:
            raise ValueError("destination_replaced_or_reinstalled")
        if kind == "git_config":
            key = item.get("key")
            installed = item.get("installed_value")
            previous = item.get("previous_value")
            if (key not in ("core.hooksPath", "init.templateDir") or
                    "previous_value" not in item or
                    not isinstance(installed, str) or not os.path.isabs(installed) or
                    any(character in installed for character in ("\0", "\r", "\n")) or
                    (previous is not None and (not isinstance(previous, str) or
                                               any(character in previous for character in ("\0", "\r", "\n"))))):
                raise ValueError("invalid_git_config_operation")
            if read_key(dest, key) != installed:
                raise ValueError("git_config_value_changed")
            planned.append((kind, dest, installed, identity, item))
            continue
        if kind == "git_config_pair":
            values = item.get("values")
            if not isinstance(values, dict) or set(values) != set(PAIR_KEYS):
                raise ValueError("invalid_git_config_pair")
            for key in PAIR_KEYS:
                entry = values[key]
                if not isinstance(entry, dict) or set(entry) != {"installed_value", "previous_value"}:
                    raise ValueError("invalid_git_config_pair")
                installed = entry["installed_value"]
                previous = entry["previous_value"]
                if (not isinstance(installed, str) or not os.path.isabs(installed) or
                        any(char in installed for char in ("\0", "\r", "\n")) or
                        (previous is not None and (not isinstance(previous, str) or
                                                   any(char in previous for char in ("\0", "\r", "\n"))))):
                    raise ValueError("invalid_git_config_pair")
                if read_key(dest, key) != installed:
                    raise ValueError("git_config_value_changed")
            planned.append((kind, dest, values, identity, item))
            continue
        expected = item.get("installed_sha256")
        if not isinstance(expected, str) or len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
            raise ValueError("invalid_digest")
        current_bytes = read_regular(dest)
        if sha(current_bytes) != expected:
            raise ValueError("destination_changed")
        if kind == "appended_block":
            prior_length = item.get("prior_length")
            prior_digest = item.get("prior_sha256")
            suffix_digest = item.get("suffix_sha256")
            if (type(prior_length) is not int or not 0 <= prior_length < len(current_bytes) or
                    any(not isinstance(value, str) or len(value) != 64 or
                        any(char not in "0123456789abcdef" for char in value)
                        for value in (prior_digest, suffix_digest))):
                raise ValueError("invalid_append_metadata")
            if sha(current_bytes[:prior_length]) != prior_digest or sha(current_bytes[prior_length:]) != suffix_digest:
                raise ValueError("append_content_changed")
        added_keys = item.get("added_keys")
        if kind == "json_added_keys":
            if not isinstance(added_keys, dict) or not added_keys or any(not isinstance(key, str) for key in added_keys):
                raise ValueError("invalid_added_keys")
            try:
                current_json = json.loads(read_regular(dest))
            except (UnicodeError, json.JSONDecodeError) as exc:
                raise ValueError("invalid_installed_json") from exc
            if not isinstance(current_json, dict) or any(key not in current_json or current_json[key] != value for key, value in added_keys.items()):
                raise ValueError("installed_keys_changed")
        planned.append((kind, dest, expected, identity, item))
    return planned


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        if os.name == "nt":
            raise ValueError("windows_native_rollback_pending")
        check_receipt_location(args.receipt)
        planned = plan(json.loads(read_regular(args.receipt)))
        if args.apply:
            if any(kind == "json_added_keys" for kind, _, _, _, _ in planned):
                raise ValueError("json_inverse_not_yet_available")
            # Recheck each file immediately before removal. A changed file is
            # preserved and reported as a conflict.
            for kind, dest, expected, identity, item in planned:
                if kind == "git_config":
                    restore_key(dest, item["key"], expected, item["previous_value"], identity)
                    continue
                if kind == "git_config_pair":
                    restore_pair(dest, expected, identity)
                    continue
                current_info = os.lstat(dest)
                if (current_info.st_dev, current_info.st_ino, current_info.st_mtime_ns) != identity:
                    raise ValueError("destination_replaced_or_reinstalled")
                if sha(read_regular(dest)) != expected:
                    raise ValueError("destination_changed")
                if kind == "appended_block":
                    flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
                    fd = os.open(dest, flags)
                    try:
                        file_info = os.fstat(fd)
                        if (not stat.S_ISREG(file_info.st_mode) or file_info.st_nlink != 1 or
                                (file_info.st_dev, file_info.st_ino, file_info.st_mtime_ns) != identity):
                            raise ValueError("destination_changed")
                        with os.fdopen(os.dup(fd), "rb") as source:
                            content = source.read()
                        if (sha(content) != expected or
                                sha(content[:item["prior_length"]]) != item["prior_sha256"] or
                                sha(content[item["prior_length"]:]) != item["suffix_sha256"]):
                            raise ValueError("destination_changed")
                        path_info = os.lstat(dest)
                        if (path_info.st_dev, path_info.st_ino, path_info.st_mtime_ns) != identity:
                            raise ValueError("destination_changed")
                        os.ftruncate(fd, item["prior_length"])
                        os.fsync(fd)
                    finally:
                        os.close(fd)
                else:
                    os.unlink(dest)
        status = "ready"
        if args.apply:
            status = "restored" if planned[0][0] in ("git_config", "git_config_pair", "appended_block") else "removed"
        result = {"schema_version": 1, "runner": "rollback", "status": status, "dry_run": not args.apply, "files": len(planned), "exit_code": 0}
        code = 0
    except (OSError, ValueError, TypeError, KeyError, UnicodeError, json.JSONDecodeError) as error:
        reason = str(error) if isinstance(error, ValueError) else "metadata_unavailable"
        result = {"schema_version": 1, "runner": "rollback", "status": "partial" if reason == "git_config_partial_restore" else "blocked", "reason": reason, "exit_code": 2}
        code = 2
    print(json.dumps(result, separators=(",", ":")))
    return code


if __name__ == "__main__":
    sys.exit(main())
