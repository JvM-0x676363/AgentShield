"""Record newly created AgentShield files without copying user data."""

import argparse
import hashlib
import json
import os
import re
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


def record_manual_review(destination, receipt_dir, reason="existing_target_has_no_inverse"):
    """Mark a target that cannot safely participate in batch rollback."""
    ensure_private_directory(receipt_dir)
    if not os.path.isabs(destination):
        raise ValueError("destination_not_absolute")
    if reason not in ("existing_target_has_no_inverse", "receipt_incomplete"):
        raise ValueError("invalid_manual_review_reason")
    identifier = uuid.uuid4().hex
    payload = {
        "schema_version": 1,
        "runner": "agentshield-rollback",
        "operations": [{
            "kind": "manual_review",
            "destination": os.path.abspath(destination),
            "reason": reason,
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


def clear_provisional(receipt_dir, identifier):
    """Clear only a private provisional marker after its inverse is saved."""
    assert_private_directory(receipt_dir)
    if not re.fullmatch(r"[0-9a-f]{32}", identifier):
        raise ValueError("invalid_provisional_id")
    path = os.path.join(receipt_dir, identifier + ".json")
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_mode & 0o077:
        raise ValueError("unsafe_provisional_receipt")
    if hasattr(os, "geteuid") and info.st_uid != os.geteuid():
        raise ValueError("provisional_receipt_wrong_owner")
    if info.st_size > 1024 * 1024:
        raise ValueError("provisional_receipt_too_large")
    with open(path, "r", encoding="utf-8") as source:
        receipt = json.load(source)
    operations = receipt.get("operations") if isinstance(receipt, dict) else None
    if (not isinstance(receipt, dict) or receipt.get("schema_version") != 1 or
            receipt.get("runner") != "agentshield-rollback" or
            not isinstance(operations, list) or len(operations) != 1 or
            not isinstance(operations[0], dict) or operations[0].get("kind") != "manual_review" or
            operations[0].get("reason") != "receipt_incomplete"):
        raise ValueError("not_a_provisional_receipt")
    destination = operations[0].get("destination")
    if not isinstance(destination, str) or not os.path.isabs(destination):
        raise ValueError("invalid_provisional_destination")
    inverse_found = False
    with os.scandir(receipt_dir) as entries:
        for entry in entries:
            if not re.fullmatch(r"[0-9a-f]{32}\.json", entry.name) or entry.path == path:
                continue
            candidate_info = os.lstat(entry.path)
            if (not stat.S_ISREG(candidate_info.st_mode) or candidate_info.st_nlink != 1 or
                    candidate_info.st_mode & 0o077 or candidate_info.st_size > 1024 * 1024):
                continue
            with open(entry.path, "r", encoding="utf-8") as source:
                candidate = json.load(source)
            candidate_ops = candidate.get("operations") if isinstance(candidate, dict) else None
            if (isinstance(candidate, dict) and candidate.get("schema_version") == 1 and
                    candidate.get("runner") == "agentshield-rollback" and
                    isinstance(candidate_ops, list) and len(candidate_ops) == 1 and
                    isinstance(candidate_ops[0], dict) and candidate_ops[0].get("kind") == "created_file" and
                    candidate_ops[0].get("destination") == destination):
                inverse_found = True
                break
    if not inverse_found:
        raise ValueError("inverse_receipt_missing")
    os.unlink(path)


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


def record_json_added_keys(destination, installed_content, receipt_dir, added_keys,
                           prior_content=None, prior_info=None):
    """Record added keys; canonical prior JSON can be restored without copying it."""
    if not added_keys:
        return None
    ensure_private_directory(receipt_dir)
    info = os.lstat(destination)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("unsafe_destination_type")
    if info.st_size != len(installed_content):
        raise ValueError("installed_size_changed")
    if (prior_content is None) != (prior_info is None):
        raise ValueError("incomplete_prior_json_state")
    if prior_content is not None:
        if (not isinstance(prior_content, bytes) or len(prior_content) > 1024 * 1024 or
                len(installed_content) > 1024 * 1024 or
                info.st_dev != prior_info.st_dev or info.st_ino != prior_info.st_ino or
                stat.S_IMODE(info.st_mode) != stat.S_IMODE(prior_info.st_mode) or
                info.st_uid != prior_info.st_uid or info.st_gid != prior_info.st_gid):
            raise ValueError("prior_json_state_changed")
    identifier = uuid.uuid4().hex
    operation = {
        "kind": "json_added_keys",
        "destination": os.path.abspath(destination),
        "parent_realpath": resolved_parent(destination),
        "installed_sha256": hashlib.sha256(installed_content).hexdigest(),
        "installed_device": info.st_dev,
        "installed_inode": info.st_ino,
        "installed_mtime_ns": info.st_mtime_ns,
        "added_keys": added_keys,
    }
    if prior_content is not None:
        operation.update({
            "inverse_version": 1,
            "prior_sha256": hashlib.sha256(prior_content).hexdigest(),
            "prior_mtime_ns": prior_info.st_mtime_ns,
            "prior_mode": stat.S_IMODE(prior_info.st_mode),
            "prior_uid": prior_info.st_uid,
            "prior_gid": prior_info.st_gid,
        })
    payload = {
        "schema_version": 1,
        "runner": "agentshield-rollback",
        "operations": [operation],
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


def record_json_list_append(destination, installed_content, receipt_dir, parent,
                            prior_lengths, prior_content, prior_info):
    """Record canonical append-only list merges without retaining prior values."""
    if (not isinstance(parent, str) or not parent or
            not isinstance(prior_lengths, dict) or not prior_lengths or
            any(not isinstance(name, str) or not name or type(length) is not int or length < 0
                for name, length in prior_lengths.items()) or
            not isinstance(prior_content, bytes) or len(prior_content) > 1024 * 1024 or
            len(installed_content) > 1024 * 1024):
        raise ValueError("invalid_json_list_inverse")
    ensure_private_directory(receipt_dir)
    info = os.lstat(destination)
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
            info.st_size != len(installed_content) or
            info.st_dev != prior_info.st_dev or info.st_ino != prior_info.st_ino or
            stat.S_IMODE(info.st_mode) != stat.S_IMODE(prior_info.st_mode) or
            info.st_uid != prior_info.st_uid or info.st_gid != prior_info.st_gid):
        raise ValueError("prior_json_state_changed")
    with open(destination, "rb") as source:
        if source.read(1024 * 1024 + 1) != installed_content:
            raise ValueError("installed_content_changed")
    identifier = uuid.uuid4().hex
    payload = {
        "schema_version": 1,
        "runner": "agentshield-rollback",
        "operations": [{
            "kind": "json_list_append",
            "inverse_version": 1,
            "destination": os.path.abspath(destination),
            "parent_realpath": resolved_parent(destination),
            "parent": parent,
            "prior_lengths": prior_lengths,
            "prior_sha256": hashlib.sha256(prior_content).hexdigest(),
            "prior_mtime_ns": prior_info.st_mtime_ns,
            "prior_mode": stat.S_IMODE(prior_info.st_mode),
            "prior_uid": prior_info.st_uid,
            "prior_gid": prior_info.st_gid,
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
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--created-file")
    source.add_argument("--manual-review")
    source.add_argument("--provisional")
    source.add_argument("--clear-provisional")
    parser.add_argument("--receipt-dir", required=True)
    args = parser.parse_args()
    try:
        if args.clear_provisional is not None:
            clear_provisional(args.receipt_dir, args.clear_provisional)
            return 0
        if args.provisional is not None:
            if not os.path.isabs(args.provisional) or os.path.lexists(args.provisional):
                raise ValueError("provisional_destination_invalid")
            print(record_manual_review(args.provisional, args.receipt_dir, "receipt_incomplete"))
            return 0
        destination = args.created_file or args.manual_review
        if not os.path.isabs(destination):
            raise ValueError("destination_not_absolute")
        if args.manual_review:
            info = os.lstat(destination)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise ValueError("unsafe_destination_type")
            record_manual_review(destination, args.receipt_dir)
            return 0
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(destination, flags)
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
        record_created_file(destination, content, args.receipt_dir)
    except (OSError, ValueError):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
