#!/usr/bin/env python3
"""Run the AgentShield local scanner baseline without user-profile state."""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


IAC_SUFFIXES = {".tf", ".yaml", ".yml", ".json"}
DEPENDENCY_FILES = {
    "package.json", "package-lock.json", "npm-shrinkwrap.json", "yarn.lock",
    "pnpm-lock.yaml", "requirements.txt", "poetry.lock", "pipfile.lock",
    "pyproject.toml", "go.mod", "go.sum", "cargo.lock", "pom.xml",
    "build.gradle", "build.gradle.kts", "gemfile.lock", "composer.lock",
}
IGNORED_SCAN_DIRS = {".git", ".venv", "node_modules", "vendor", "dist", "build"}


def run(command, *, cwd, env=None):
    try:
        return subprocess.run(
            command,
            cwd=str(cwd),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode
    except OSError:
        return 127


def git_root(path):
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=str(path),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
    except OSError:
        return path
    if completed.returncode == 0:
        return Path(completed.stdout.strip()).resolve()
    return path


def staged_names(root):
    try:
        completed = subprocess.run(
            ["git", "diff", "--cached", "--name-only", "-z", "--diff-filter=ACM"],
            cwd=str(root),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        return []
    if completed.returncode != 0:
        return []
    names = [item for item in completed.stdout.decode("utf-8", "surrogateescape").split("\0") if item]
    return names


def has_dependency_manifest(scan_path):
    if scan_path.is_file():
        return scan_path.name.lower() in DEPENDENCY_FILES
    for directory, subdirectories, filenames in os.walk(scan_path):
        subdirectories[:] = [name for name in subdirectories if name not in IGNORED_SCAN_DIRS]
        if any(filename.lower() in DEPENDENCY_FILES for filename in filenames):
            return True
    return False


def result(scanner, status, exit_code=None, detail=None):
    item = {"scanner": scanner, "status": status}
    if exit_code is not None:
        item["scanner_exit_code"] = exit_code
    if detail:
        item["detail"] = detail
    return item


def scan_gitleaks(root, scan_path, staged, config_path=None):
    binary = shutil.which("gitleaks")
    if not binary:
        return result("gitleaks", "environment_blocked", detail="binary_not_found")
    if config_path and not config_path.is_file():
        return result("gitleaks", "environment_blocked", detail="config_not_found")
    if staged:
        mode = "git" if run([binary, "git", "--help"], cwd=root) == 0 else "protect"
        command = [binary, mode, "--staged", "--redact", "--no-banner", "--log-level", "error", "."]
    else:
        command = [binary, "dir", "--redact", "--no-banner", "--log-level", "error", "--exit-code", "1", str(scan_path)]
    if config_path:
        command.extend(["--config", str(config_path)])
    code = run(command, cwd=root)
    if code == 0:
        return result("gitleaks", "clean", code)
    if code == 1:
        return result("gitleaks", "findings", code)
    return result("gitleaks", "environment_blocked", code)


def scan_trivy(root, scan_path, staged):
    binary = shutil.which("trivy")
    if not binary:
        return result("trivy", "environment_blocked", detail="binary_not_found")
    names = staged_names(root) if staged else []
    scan_config = not staged or any(Path(name).suffix.lower() in IAC_SUFFIXES for name in names)
    scan_dependencies = (any(Path(name).name.lower() in DEPENDENCY_FILES for name in names)
                         if staged else has_dependency_manifest(scan_path))
    outcomes = {}

    if scan_config:
        code = run([
            binary, "config", "--severity", "HIGH,CRITICAL", "--exit-code", "2",
            "--quiet", "--skip-version-check", "--skip-check-update", str(scan_path),
        ], cwd=root)
        outcomes["config"] = "findings" if code == 2 else "clean" if code == 0 else "environment_blocked"

    if scan_dependencies:
        dependency_target = root if staged else scan_path
        code = run([
            binary, "fs", "--scanners", "vuln", "--severity", "HIGH,CRITICAL",
            "--exit-code", "2", "--quiet", "--skip-version-check", "--skip-db-update",
            str(dependency_target),
        ], cwd=root)
        outcomes["dependencies"] = "findings" if code == 2 else "clean" if code == 0 else "environment_blocked"

    if not outcomes:
        return result("trivy", "not_applicable", detail="no_iac_or_dependency_files_staged")
    detail = ",".join("{}={}".format(name, state) for name, state in outcomes.items())
    if "findings" in outcomes.values():
        return result("trivy", "findings", detail=detail)
    if "environment_blocked" in outcomes.values():
        return result("trivy", "environment_blocked", detail=detail)
    return result("trivy", "clean", detail=detail)


def overall_status(results):
    states = {item["status"] for item in results}
    if "environment_blocked" in states:
        return "environment_blocked", 2
    if "findings" in states:
        return "findings", 1
    return "clean", 0


def write_state(path, payload):
    if not path:
        return
    try:
        destination = Path(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_suffix(destination.suffix + ".tmp")
        temporary.write_text(json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8")
        temporary.replace(destination)
    except OSError:
        pass


def console(payload):
    labels = {
        "clean": "CLEAN",
        "findings": "FINDINGS",
        "not_applicable": "N/A",
        "environment_blocked": "BLOCKED",
    }
    print("[AGENTSHIELD SCAN] local baseline")
    for item in payload["scanners"]:
        suffix = ""
        if item.get("detail"):
            suffix = " ({})".format(item["detail"])
        elif "scanner_exit_code" in item:
            suffix = " (rc={})".format(item["scanner_exit_code"])
        print("  {}: {}{}".format(item["scanner"], labels[item["status"]], suffix))
    print("[AGENTSHIELD SCAN] result: {}".format(payload["status"]))


def parse_args():
    parser = argparse.ArgumentParser(description="Run AgentShield local security scanners.")
    parser.add_argument("--path", default=".", help="Repository or directory to scan (default: current directory).")
    parser.add_argument("--gitleaks-config", help="Optional explicit Gitleaks configuration for a reviewed test or policy.")
    parser.add_argument("--staged", action="store_true", help="Limit Trivy eligibility to staged files.")
    parser.add_argument("--state-path", help="Optional path for a compact scan-state JSON record.")
    parser.add_argument("--output-mode", default="Console", choices=("Console", "Json", "Quiet"))
    return parser.parse_args()


def main():
    args = parse_args()
    started = time.monotonic()
    target = Path(args.path).resolve()
    if not target.exists():
        payload = {
            "schema_version": 1,
            "event": "result",
            "status": "environment_blocked",
            "exit_code": 2,
            "runner": "agent-shield-scan",
            "detail": "scan_path_not_found",
            "scanners": [],
        }
        print(json.dumps(payload, separators=(",", ":")))
        return 2

    root = git_root(target)
    gitleaks_config = Path(args.gitleaks_config).resolve() if args.gitleaks_config else None
    results = [
        scan_gitleaks(root, target, args.staged, gitleaks_config),
        scan_trivy(root, target, args.staged),
    ]
    status, exit_code = overall_status(results)
    payload = {
        "schema_version": 1,
        "event": "result",
        "run_id": "{}-{}".format(int(time.time()), os.getpid()),
        "timestamp_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "duration_ms": int((time.monotonic() - started) * 1000),
        "status": status,
        "exit_code": exit_code,
        "runner": "agent-shield-scan",
        "scope": "staged" if args.staged else "repository",
        "scanners": results,
    }
    write_state(args.state_path, payload)
    if args.output_mode == "Console":
        console(payload)
    else:
        print(json.dumps(payload, separators=(",", ":")))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
