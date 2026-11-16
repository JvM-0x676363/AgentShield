"""Record newly created AgentShield files without copying user data."""

import argparse
import hashlib
import json
import os
import stat
import tempfile
import uuid


def assert_private_directory(path):
    if not os.path.isabs(path):
        raise ValueError("receipt_directory_not_absolute")
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o077:
        raise ValueError("receipt_directory_not_private")
    if hasattr(os, "geteuid") and info.st_uid != os.geteuid():
        raise ValueError("receipt_directory_wrong_owner")


def ensure_private_directory(path):
    if not os.path.isabs(path):
        raise ValueError("receipt_directory_not_absolute")
    os.makedirs(path, mode=0o700, exist_ok=True)
    assert_private_directory(path)


def assert_empty_private_directory(path):
    assert_private_directory(path)
    with os.scandir(path) as entries:
        if next(entries, None) is not None:
            raise ValueError("receipt_directory_not_empty")


def resolved_parent(path):
    return os.path.realpath(os.path.dirname(os.path.abspath(path)))


def record_manual_review(destination, receipt_dir):
    """Mark a changed existing target whose prior state cannot be restored."""
    ensure_private_directory(receipt_dir)
    if not os.path.isabs(destination):
        raise ValueError("destination_not_absolute")
    identifier = uuid.uuid4().hex
    payload = {
        "schema_version": 1,
        "runner": "agentshield-rollback",
        "operations": [{
            "kind": "manual_review",
            "destination": os.path.abspath(destination),
            "reason": "existing_target_has_no_inverse",
        }],
    }
    fd, staged = tempfile.mkstemp(prefix=".receipt-", dir=receipt_dir)
    try:
        os.chmod(staged, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(payload, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(staged, os.path.join(receipt_dir, identifier + ".json"))
    finally:
        if os.path.exists(staged):
            os.unlink(staged)
    return identifier


def record_created_file(destination, installed_content, receipt_dir):
    """Write an immutable receipt for a file that did not exist before install."""
    ensure_private_directory(receipt_dir)
    info = os.lstat(destination)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("unsafe_destination_type")
    if info.st_size != len(installed_content):
        raise ValueError("installed_size_changed")
    identifier = uuid.uuid4().hex
    payload = {
        "schema_version": 1,
        "runner": "agentshield-rollback",
        "operations": [{
            "kind": "created_file",
            "destination": os.path.abspath(destination),
            "parent_realpath": resolved_parent(destination),
            "installed_sha256": hashlib.sha256(installed_content).hexdigest(),
            "installed_device": info.st_dev,
            "installed_inode": info.st_ino,
            "installed_mtime_ns": info.st_mtime_ns,
        }],
    }
    fd, staged = tempfile.mkstemp(prefix=".receipt-", dir=receipt_dir)
    try:
        os.chmod(staged, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(payload, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(staged, os.path.join(receipt_dir, identifier + ".json"))
    finally:
        if os.path.exists(staged):
            os.unlink(staged)
    return identifier


def record_json_added_keys(destination, installed_content, receipt_dir, added_keys):
    """Record top-level keys introduced by merge-missing-keys."""
    if not added_keys:
        return None
    ensure_private_directory(receipt_dir)
    info = os.lstat(destination)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("unsafe_destination_type")
    if info.st_size != len(installed_content):
        raise ValueError("installed_size_changed")
    identifier = uuid.uuid4().hex
    payload = {
        "schema_version": 1,
        "runner": "agentshield-rollback",
        "operations": [{
            "kind": "json_added_keys",
            "destination": os.path.abspath(destination),
            "parent_realpath": resolved_parent(destination),
            "installed_sha256": hashlib.sha256(installed_content).hexdigest(),
            "installed_device": info.st_dev,
            "installed_inode": info.st_ino,
            "installed_mtime_ns": info.st_mtime_ns,
            "added_keys": added_keys,
        }],
    }
    fd, staged = tempfile.mkstemp(prefix=".receipt-", dir=receipt_dir)
    try:
        os.chmod(staged, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(payload, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(staged, os.path.join(receipt_dir, identifier + ".json"))
    finally:
        if os.path.exists(staged):
            os.unlink(staged)
    return identifier


def record_git_config(config_path, key, installed_value, previous_value, receipt_dir):
    """Record one Git key without copying the surrounding configuration."""
    if key not in ("core.hooksPath", "init.templateDir"):
        raise ValueError("unsupported_git_key")
    if not isinstance(installed_value, str) or not os.path.isabs(installed_value) or any(character in installed_value for character in ("\0", "\r", "\n")):
        raise ValueError("invalid_installed_value")
    if previous_value is not None and not isinstance(previous_value, str):
        raise ValueError("invalid_previous_value")
    ensure_private_directory(receipt_dir)
    info = os.lstat(config_path)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("unsafe_git_config_type")
    identifier = uuid.uuid4().hex
    payload = {
        "schema_version": 1,
        "runner": "agentshield-rollback",
        "operations": [{
            "kind": "git_config",
            "destination": os.path.abspath(config_path),
            "parent_realpath": resolved_parent(config_path),
            "key": key,
            "installed_value": installed_value,
            "previous_value": previous_value,
            "installed_device": info.st_dev,
            "installed_inode": info.st_ino,
            "installed_mtime_ns": info.st_mtime_ns,
        }],
    }
    fd, staged = tempfile.mkstemp(prefix=".receipt-", dir=receipt_dir)
    try:
        os.chmod(staged, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(payload, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(staged, os.path.join(receipt_dir, identifier + ".json"))
    finally:
        if os.path.exists(staged):
            os.unlink(staged)
    return identifier


def record_appended_block(destination, prior_bytes, installed_bytes, receipt_dir):
    """Record append boundaries and hashes without persisting user content."""
    if not installed_bytes.startswith(prior_bytes) or len(installed_bytes) <= len(prior_bytes):
        raise ValueError("not_an_append")
    ensure_private_directory(receipt_dir)
    info = os.lstat(destination)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("unsafe_destination_type")
    if info.st_size != len(installed_bytes):
        raise ValueError("installed_size_changed")
    suffix = installed_bytes[len(prior_bytes):]
    identifier = uuid.uuid4().hex
    payload = {
        "schema_version": 1,
        "runner": "agentshield-rollback",
        "operations": [{
            "kind": "appended_block",
            "destination": os.path.abspath(destination),
            "parent_realpath": resolved_parent(destination),
            "installed_sha256": hashlib.sha256(installed_bytes).hexdigest(),
            "prior_length": len(prior_bytes),
            "prior_sha256": hashlib.sha256(prior_bytes).hexdigest(),
            "suffix_sha256": hashlib.sha256(suffix).hexdigest(),
            "installed_device": info.st_dev,
            "installed_inode": info.st_ino,
            "installed_mtime_ns": info.st_mtime_ns,
        }],
    }
    fd, staged = tempfile.mkstemp(prefix=".receipt-", dir=receipt_dir)
    try:
        os.chmod(staged, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(payload, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(staged, os.path.join(receipt_dir, identifier + ".json"))
    finally:
        if os.path.exists(staged):
            os.unlink(staged)
    return identifier


def record_git_config_pair(config_path, values, receipt_dir):
    """Record the final state of both AgentShield Git keys in one receipt."""
    required = {"core.hooksPath", "init.templateDir"}
    if not isinstance(values, dict) or set(values) != required:
        raise ValueError("invalid_git_config_pair")
    for key in required:
        entry = values[key]
        if not isinstance(entry, dict) or set(entry) != {"installed_value", "previous_value"}:
            raise ValueError("invalid_git_config_pair")
        installed = entry["installed_value"]
        previous = entry["previous_value"]
        if (not isinstance(installed, str) or not os.path.isabs(installed) or
                any(character in installed for character in ("\0", "\r", "\n")) or
                (previous is not None and (not isinstance(previous, str) or
                                           any(character in previous for character in ("\0", "\r", "\n"))))):
            raise ValueError("invalid_git_config_pair")
    ensure_private_directory(receipt_dir)
    info = os.lstat(config_path)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("unsafe_git_config_type")
    payload = {
        "schema_version": 1,
        "runner": "agentshield-rollback",
        "operations": [{
            "kind": "git_config_pair",
            "destination": os.path.abspath(config_path),
            "parent_realpath": resolved_parent(config_path),
            "values": values,
            "installed_device": info.st_dev,
            "installed_inode": info.st_ino,
            "installed_mtime_ns": info.st_mtime_ns,
        }],
    }
    identifier = uuid.uuid4().hex
    fd, staged = tempfile.mkstemp(prefix=".receipt-", dir=receipt_dir)
    try:
        os.chmod(staged, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(payload, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(staged, os.path.join(receipt_dir, identifier + ".json"))
    finally:
        if os.path.exists(staged):
            os.unlink(staged)
    return identifier


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--created-file", required=True)
    parser.add_argument("--receipt-dir", required=True)
    args = parser.parse_args()
    try:
        if not os.path.isabs(args.created_file):
            raise ValueError("destination_not_absolute")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(args.created_file, flags)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 1024 * 1024:
                raise ValueError("unsafe_destination_type_or_size")
            with os.fdopen(os.dup(fd), "rb") as source:
                content = source.read(1024 * 1024 + 1)
            if len(content) != info.st_size or os.fstat(fd).st_mtime_ns != info.st_mtime_ns:
                raise ValueError("destination_changed")
        finally:
            os.close(fd)
        record_created_file(args.created_file, content, args.receipt_dir)
    except (OSError, ValueError):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
