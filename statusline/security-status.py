#!/usr/bin/env python3
"""
Security statusline for Claude Code.

Displays, on a fixed terminal line, whether guardrails are active and
the outcome of the latest commit security scan.

Why this exists: the pre-commit hook is audit-only and policy enforcement is
declarative -- neither displays continuously on screen. This line reads directly from disk.

COST CONSTRAINT: Runs on every render. Does not execute scanners, does not scan PATH,
does not make network calls. Only reads two small files. If anything fails,
prints what it can and exits 0 -- a statusline that crashes a session is worse than no statusline.

Input: Claude Code JSON on stdin (optional; not required).
Output: A single line.
"""
import io
import json
import os
import sys
from datetime import datetime, timezone

# Where the administrative layer lives on each platform. Presence of the file
# indicates the layer was deployed on this machine.
MANAGED = {
    "win32": r"C:\Program Files\ClaudeCode\managed-settings.json",
    "darwin": "/Library/Application Support/ClaudeCode/managed-settings.json",
    "linux": "/etc/claude-code/managed-settings.json",
}


def load_json(path):
    try:
        with io.open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def admin_status():
    """on = enforcement layer present AND configured with requisite keys."""
    path = MANAGED.get(sys.platform)
    if not path or not os.path.isfile(path):
        return "off"
    data = load_json(path)
    if not isinstance(data, dict):
        return "?"
    perms = data.get("permissions", {})
    if perms.get("allowManagedPermissionRulesOnly") and \
            perms.get("disableBypassPermissionsMode") == "disable":
        return "on"
    return "partial"


def relative_age(ts):
    """'2min', '3h', '5d' -- or None if timestamp is unreadable."""
    try:
        when = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc)
    except Exception:
        return None
    seconds = (datetime.now(timezone.utc) - when).total_seconds()
    if seconds < 0:
        return None
    if seconds < 90:
        return "%ds" % int(seconds)
    if seconds < 5400:
        return "%dmin" % int(seconds / 60)
    if seconds < 172800:
        return "%dh" % int(seconds / 3600)
    return "%dd" % int(seconds / 86400)


def scan_status():
    path = os.path.join(
        os.path.expanduser("~"), ".git-hooks", "last-scan.json")
    data = load_json(path)
    if not isinstance(data, dict):
        return "scan:--"
    res = data.get("result") or data.get("resultado", "?")
    age = relative_age(data.get("ts", ""))
    repo = data.get("repo", "")
    txt = "scan:%s" % res
    if res in ("findings", "achados"):
        tools = [k for k in ("gitleaks", "semgrep", "trivy")
                 if data.get(k) in ("findings", "achados")]
        if tools:
            txt += "(%s)" % ",".join(tools)
    if age:
        txt += " %s ago" % age
    if repo and repo != "?":
        txt += " (%s)" % repo
    return txt


def main():
    # Consume stdin to avoid hanging the pipe; content is not currently used.
    try:
        if not sys.stdin.isatty():
            sys.stdin.read()
    except Exception:
        pass

    parts = ["[sec]", "admin:%s" % admin_status(), scan_status()]
    sys.stdout.write("  ".join(parts))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.stdout.write("[sec] unavailable")
    sys.exit(0)
