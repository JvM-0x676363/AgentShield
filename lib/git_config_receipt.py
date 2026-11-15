"""Change only two AgentShield Git keys with an opt-in rollback receipt."""

import os
import pathlib
import stat
import subprocess

from rollback_receipt import ensure_private_directory, record_git_config


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
    result = subprocess.run(
        ["git", "config", "--file", config_path, key, installed_value],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    if result.returncode != 0 or read_key(config_path, key) != installed_value:
        raise ValueError("git_config_write_failed")
    return record_git_config(config_path, key, installed_value, previous, receipt_dir)


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
