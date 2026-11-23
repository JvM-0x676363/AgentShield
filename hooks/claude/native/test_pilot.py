"""Run synthetic protocol checks without loading Claude or changing settings."""

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path


def run(executable, expected_sha256):
    try:
        binary = Path(executable).resolve(strict=True)
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        if not re.fullmatch(r"[a-fA-F0-9]{64}", expected_sha256) or digest != expected_sha256.lower():
            raise ValueError("hash mismatch")
    except (OSError, ValueError):
        return {"status": "blocked", "detail": "artifact_verification_failed"}, 2

    marker = "AK" + "IA" + "Z" * 16
    cases = [
        ("clean_write", "Write", {"content": "synthetic test", "file_path": "pilot.txt"}, False),
        ("secret_write", "Write", {"content": marker}, True),
        ("secret_edit", "Edit", {"new_string": marker}, True),
        ("secret_notebook", "NotebookEdit", {"new_source": marker}, True),
        ("secret_multiedit", "MultiEdit", {"edits": [{"new_string": marker}]}, True),
        ("invalid_content", "Write", {"content": 12}, True),
        ("unsupported_tool", "Unknown", {}, True),
        ("malformed_json", None, None, True),
    ]
    child_env = {"NODE_OPTIONS": "--require nonexistent-synthetic-module"}
    if os.name == "nt" and "SystemRoot" in os.environ:
        child_env["SystemRoot"] = os.environ["SystemRoot"]
    checks = []
    for name, tool, tool_input, deny in cases:
        data = json.dumps({"hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": tool_input}) if tool else "{"
        try:
            result = subprocess.run(
                [str(binary)], input=data.encode("utf-8"), capture_output=True,
                timeout=5, check=False, env=child_env,
            )
            output = json.loads(result.stdout)
            decision = output.get("hookSpecificOutput", {})
            expected = (
                decision.get("hookEventName") == "PreToolUse" and decision.get("permissionDecision") == "deny"
                if deny else output == {}
            )
            passed = result.returncode == 0 and not result.stderr and expected and marker.encode() not in result.stdout and b"pilot.txt" not in result.stdout
        except (OSError, subprocess.TimeoutExpired, ValueError, AttributeError):
            passed = False
        checks.append({"name": name, "passed": bool(passed)})
    failed = sum(not item["passed"] for item in checks)
    return {
        "status": "failed" if failed else "passed", "artifact_sha256": digest,
        "checks": checks, "failed": failed,
    }, int(bool(failed))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True)
    parser.add_argument("--expected-sha256", required=True)
    args = parser.parse_args()
    result, code = run(args.executable, args.expected_sha256)
    print(json.dumps({
        "schema_version": 1, "runner": "native-hook-pilot", **result,
        "claude_integration": "not_tested", "endpoint_configuration_changed": False,
    }, separators=(",", ":")))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
