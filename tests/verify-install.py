#!/usr/bin/env python3
"""
POST-INSTALLATION verification: checks files ON DISK against target manifests.

The package provides three tiers of verification:

  validate-config.py   -> validates SOURCE (do manifests agree with each other?)
  install --dry-run    -> validates PLAN (what would be written?)
  verify-install.py    -> validates RESULT (are written files correct?)

The third is the only one that answers "is the workstation configured as it should be?"
after deployment has completed -- crucial for fleet management where installers ran
weeks ago and configuration drift might have occurred.

Path resolution and merge strategies are IMPORTED from lib/apply_targets.py rather than
reimplemented: a verifier that resolves paths differently from the engine would inspect
the wrong file and return a false OK.

Does not inspect secrets. It verifies key presence and configuration content only
for files written by the package; it never prints developer configuration values.

Usage:
    python tests/verify-install.py                     # current profile
    python tests/verify-install.py --only claude       # subset
    python tests/verify-install.py --home /home/alice  # specific profile
    python tests/verify-install.py --expect-managed    # requires admin layer
    python tests/verify-install.py --quiet             # summary only

Exit codes:
    0  all compliant
    1  at least one discrepancy
    2  usage error (invalid manifest, unknown selector, missing HOME)
"""

import argparse
import datetime
import json
import os
import shutil
import sys
import time
import uuid

# The engine is the source of truth for paths, selectors, and manifest parsing.
sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib"))
try:
    from apply_targets import (  # noqa: E402
        TargetError, apply_payload_by_os, current_os, dump_json, expand,
        filter_by_selector, load_all_targets, read_text,
    )
except ImportError as exc:  # pragma: no cover
    print("[ERROR] could not import lib/apply_targets.py: %s" % exc)
    sys.exit(2)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_TTY = sys.stdout.isatty()
_G, _Y, _R, _C, _D, _N = (
    ("\033[0;32m", "\033[1;33m", "\033[0;31m", "\033[0;36m", "\033[0;90m", "\033[0m")
    if _TTY else ("", "", "", "", "", "")
)

_counts = {"OK": 0, "WARN": 0, "FAIL": 0}
QUIET = False
OUTPUT_MODE = "Console"
RUN_ID = ""
STARTED_AT_UTC = ""
STARTED_MONOTONIC = 0.0


def emit_event(event, phase=""):
    if OUTPUT_MODE != "Json":
        return
    print(json.dumps({
        "schema_version": 1,
        "event": event,
        "phase": phase,
        "run_id": RUN_ID,
        "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "runner": "verify-install",
        "scope": "endpoint",
    }, separators=(",", ":")))


def chk(passed, label, detail="", warn_only=False):
    if passed:
        tag, cor = "OK  ", _G
        _counts["OK"] += 1
    elif warn_only:
        tag, cor = "WARN", _Y
        _counts["WARN"] += 1
    else:
        tag, cor = "FAIL", _R
        _counts["FAIL"] += 1
    if OUTPUT_MODE == "Console" and (not QUIET or not passed):
        linha = "  [%s%s%s] %s" % (cor, tag, _N, label)
        if detail:
            linha += "  %s--  %s%s" % (_D, detail, _N)
        print(linha)
    return passed


def section(t):
    if OUTPUT_MODE == "Console" and not QUIET:
        print("\n%s%s%s" % (_C, t, _N))


def read_json_file(p):
    try:
        return json.loads(read_text(p)), None
    except Exception as exc:
        return None, str(exc)


# ----------------------------------------------------------------- strategies

def ver_overwrite(spec, dst):
    """File owned entirely by AgentShield: must match source."""
    if "payload_file" in spec:
        src = os.path.join(ROOT, spec["payload_file"])
        if not chk(os.path.isfile(src), "  source exists in repo",
                   spec["payload_file"]):
            return
        origin = read_text(src)
        label = spec["payload_file"]
    else:
        origin = dump_json(spec["payload"])
        label = "inline manifest payload"

    a, b = origin.strip(), read_text(dst).strip()
    chk(a == b, "  content identical to source (%s)" % label,
        "ok" if a == b else "source=%d chars, disk=%d -- re-run installer"
        % (len(a), len(b)))


def ver_md_block(spec, dst):
    """Marked markdown block: 2 boundary markers and body == core + appendix."""
    disk = read_text(dst)
    marker = spec["marker"]
    n = disk.count(marker)
    if not chk(n == 2, "  delimited block", "%d markers (2 expected)" % n):
        return
    i = disk.index(marker) + len(marker)
    j = disk.index(marker, i)
    body = disk[i:j].strip()

    parts = []
    for rel in spec["compose"]:
        p = os.path.join(ROOT, rel)
        if not os.path.isfile(p):
            chk(False, "  compose missing in repo", rel)
            return
        parts.append(read_text(p).rstrip("\n"))
    expected = "\n\n---\n\n".join(parts).strip()

    chk(body == expected, "  block == composed source",
        "ok" if body == expected
        else "disk=%d chars, source=%d -- re-run installer"
             % (len(body), len(expected)))

    outside = (disk[:disk.index(marker)] + disk[j + len(marker):]).strip()
    if outside and OUTPUT_MODE == "Console" and not QUIET:
        print("  %s[info]%s   developer content outside block preserved  %s--  %d chars%s"
              % (_D, _N, _D, len(outside), _N))


def ver_merge_permission_lists(spec, dst):
    d, err = read_json_file(dst)
    if not chk(d is not None, "  valid JSON", err or ""):
        return
    parent = spec["list_parent"]
    ours = spec["payload"][parent]
    has = d.get(parent, {})
    for bucket in spec["lists"]:
        expected = ours.get(bucket, [])
        present = has.get(bucket, [])
        missing = [r for r in expected if r not in present]
        chk(not missing, "  %s: %d rule(s) applied" % (bucket, len(expected)),
            ("missing %d: %s" % (len(missing), missing[:3])) if missing else "")
    for k, v in ours.items():
        if k in spec["lists"]:
            continue
        chk(has.get(k) == v, "  %s = %r" % (k, v), repr(has.get(k)))
    extras = sorted(k for k in d if k != parent)
    if extras and OUTPUT_MODE == "Console" and not QUIET:
        print("  %s[info]%s   developer keys preserved  %s--  %s%s"
              % (_D, _N, _D, ", ".join(extras), _N))


def ver_merge_mcp(spec, dst):
    d, err = read_json_file(dst)
    if not chk(d is not None, "  valid JSON", err or ""):
        return
    k = spec.get("mcp_key", "mcpServers")
    ours = spec["payload"][k]
    has = d.get(k, {})
    missing = [s for s in ours if s not in has]
    chk(not missing, "  MCP applied", missing or ", ".join(sorted(ours)))
    for name, cfg in sorted(ours.items()):
        if name not in has:
            continue
        chk(has[name].get("args") == cfg.get("args"),
            "    %s: args preserved array" % name, repr(has[name].get("args")))
        chk(has[name].get("command") == cfg.get("command"),
            "    %s: command correct" % name, repr(has[name].get("command")))
    others = sorted(s for s in has if s not in ours)
    if others and OUTPUT_MODE == "Console" and not QUIET:
        print("  %s[info]%s   developer MCP servers preserved  %s--  %s%s"
              % (_D, _N, _D, ", ".join(others), _N))


def ver_merge_missing_keys(spec, dst):
    d, err = read_json_file(dst)
    if not chk(d is not None, "  valid JSON", err or ""):
        return
    missing = [k for k in spec["payload"] if k not in d]
    chk(not missing, "  %d key(s) applied" % len(spec["payload"]),
        missing or "")
    for k, v in spec["payload"].items():
        if k in d and d[k] != v:
            chk(False, "  %s: developer value takes precedence" % k,
                "package only adds missing keys -- expected behavior",
                warn_only=True)


VERIFIERS = {
    "overwrite": ver_overwrite,
    "md-block": ver_md_block,
    "merge-permission-lists": ver_merge_permission_lists,
    "merge-mcp": ver_merge_mcp,
    "merge-missing-keys": ver_merge_missing_keys,
}


# --------------------------------------------------------------------- layers

def verify_target(target, home, os_key, require_admin):
    specs = [f for f in target["files"] if os_key in f["dest"]]
    if not specs:
        return
    section("-- %s" % target["label"])

    for spec in specs:
        try:
            dst = expand(spec["dest"][os_key], home, os_key)
        except TargetError as exc:
            chk(False, "  path not resolved", str(exc))
            continue

        sup = spec.get("superseded_by")
        if sup and os_key in sup:
            try:
                sup_path = expand(sup[os_key], home, os_key)
            except TargetError:
                sup_path = None
            if sup_path and os.path.isfile(sup_path):
                sup_name = os.path.basename(dst)
                marker = spec.get("marker")
                disk = read_text(dst) if os.path.isfile(dst) else ""
                chk(marker not in disk,
                    "%s: block ceded to managed layer" % sup_name,
                    "superseded by %s" % sup_path if marker not in disk
                    else "block STILL present -- guidelines would load twice")
                continue

        try:
            spec = apply_payload_by_os(spec, home, os_key)
        except TargetError as exc:
            chk(False, "  payload_by_os not applied", str(exc))
            continue

        name = os.path.basename(dst)

        if spec.get("strategy") == "remove":
            chk(not os.path.isfile(dst),
                "%s: absent (correct)" % name,
                dst if not os.path.isfile(dst)
                else "PRESENT -- exclusive MCP control active, 'claude mcp add' blocked")
            continue

        if spec.get("only_if_parent_exists") and not os.path.isdir(os.path.dirname(dst)):
            chk(False, "%s: not verified (parent directory does not exist)" % name,
                "expected for this packaging", warn_only=True)
            continue

        exists = os.path.isfile(dst)
        if not exists:
            if target["scope"] == "machine" and not require_admin:
                chk(False, "%s: absent" % name,
                    "admin layer not applied (use --expect-managed to require)",
                    warn_only=True)
            else:
                chk(False, "%s absent" % name, dst)
            continue

        chk(True, "%s" % name, dst)
        fn = VERIFIERS.get(spec["strategy"])
        if fn is None:
            chk(False, "  strategy without verifier", spec["strategy"])
            continue
        try:
            fn(spec, dst)
        except Exception as exc:
            chk(False, "  verification error", "%s: %s" % (type(exc).__name__, exc))


def verify_git(home):
    """Local audit layer: independent of platform and installed AI tools."""
    section("-- Local audit layer (git)")

    gitconfig = os.path.join(home, ".gitconfig")
    if chk(os.path.isfile(gitconfig), ".gitconfig exists", gitconfig):
        txt = read_text(gitconfig)
        for key in ("hooksPath", "templateDir"):
            chk(key.lower() in txt.lower(), "  %s configured" % key)

    hook_src = os.path.join(ROOT, "hooks", "pre-commit")
    for rel, label in ((os.path.join(".git-hooks", "pre-commit"), "global hook"),
                       (os.path.join(".git-template", "hooks", "pre-commit"),
                        "template for new repos")):
        p = os.path.join(home, rel)
        if not chk(os.path.isfile(p), "%s installed" % label, p):
            continue
        a, b = read_text(hook_src), read_text(p)
        chk(a == b, "  identical to hooks/pre-commit",
            "" if a == b else "DIVERGES -- re-run installer")

    p = os.path.join(home, ".git-hooks", "pre-commit")
    if os.path.isfile(p):
        content = read_text(p)
        raw = open(p, "rb").read()
        chk("exit 1" not in content, "  audit-only (no exit 1)")
        chk(content.rstrip().endswith("exit 0"), "  ends with exit 0")
        chk("SKIP_SECURITY_HOOK" in content, "  escape hatch present")
        chk(b"\r" not in raw, "  pure LF line endings",
            "" if b"\r" not in raw else "CRLF breaks shebang execution under sh")


def verify_scanners():
    """Missing scanner degrades hook but does not break it -- WARN, not FAIL."""
    section("-- Scanners in PATH")
    for t in ("gitleaks", "semgrep", "trivy"):
        found = shutil.which(t)
        chk(bool(found), "%s" % t,
            found or "missing -- hook skips this check with warning",
            warn_only=True)


# ----------------------------------------------------------------------- main

def main():
    global QUIET, OUTPUT_MODE, RUN_ID, STARTED_AT_UTC, STARTED_MONOTONIC
    ap = argparse.ArgumentParser(
        description="Verifies disk installation against target manifests.")
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--home", help="profile to verify (default: current user)")
    ap.add_argument("--only", default="all",
                    help="comma-separated selectors (same vocabulary as installer)")
    ap.add_argument("--os", dest="os_key",
                    choices=["windows", "linux", "darwin"], default=current_os())
    ap.add_argument("--expect-managed", action="store_true",
                    help="treats missing admin layer as FAILURE")
    ap.add_argument("--machine-detector", action="store_true",
                    help="verify only managed controls and emit detector-compatible output")
    ap.add_argument("--skip-git", action="store_true")
    ap.add_argument("--quiet", action="store_true",
                    help="legacy console mode: show failures and summary only")
    ap.add_argument("--output-mode", choices=["Console", "Json", "Quiet"],
                    default="Console",
                    help="Console (default), Json events, or a final Quiet JSON result")
    args = ap.parse_args()

    if args.machine_detector:
        args.only = "managed"
        args.expect_managed = True
        args.skip_git = True

    QUIET = args.quiet
    OUTPUT_MODE = args.output_mode
    RUN_ID = str(uuid.uuid4())
    STARTED_AT_UTC = datetime.datetime.now(datetime.timezone.utc).isoformat()
    STARTED_MONOTONIC = time.monotonic()
    root = os.path.abspath(args.root)
    home = os.path.abspath(os.path.expanduser(args.home or "~"))

    targets = load_all_targets(root)
    only = {x.strip() for x in args.only.split(",") if x.strip()}
    targets = filter_by_selector(targets, only)

    emit_event("start")
    if OUTPUT_MODE == "Console" and not QUIET:
        print("=" * 78)
        print("POST-INSTALLATION VERIFICATION | OS: %s | only: %s"
              % (args.os_key, args.only))
        print("HOME: %s" % home)
        print("=" * 78)

    emit_event("phase", "target_configuration")
    for target in sorted(targets, key=lambda a: (a["scope"], a["id"])):
        verify_target(target, home, args.os_key, args.expect_managed)

    if not args.skip_git and "all" in only:
        emit_event("phase", "local_audit")
        verify_git(home)
        verify_scanners()

    exit_code = 1 if _counts["FAIL"] else 0
    status = "failed" if exit_code else "success"
    if OUTPUT_MODE == "Console":
        print("\n" + "=" * 78)
        print("RESULT: %d OK, %d WARN, %d FAIL"
              % (_counts["OK"], _counts["WARN"], _counts["FAIL"]))
        print("=" * 78)
        print("AGENTSHIELD: VERIFY DONE ok=%d warn=%d fail=%d only=%s"
              % (_counts["OK"], _counts["WARN"], _counts["FAIL"], args.only))
    else:
        result = {
            "schema_version": 1,
            "event": "result",
            "run_id": RUN_ID,
            "started_at_utc": STARTED_AT_UTC,
            "duration_ms": round((time.monotonic() - STARTED_MONOTONIC) * 1000),
            "status": status,
            "exit_code": exit_code,
            "runner": "detect-managed" if args.machine_detector else "verify-install",
            "scope": "machine" if args.machine_detector else "endpoint",
            "selected": sorted(only),
            "expect_managed": args.expect_managed,
            "counts": {"ok": _counts["OK"], "warn": _counts["WARN"],
                       "failed": _counts["FAIL"]},
        }
        if args.machine_detector:
            result["compliant"] = exit_code == 0
        print(json.dumps(result, separators=(",", ":")))
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("[ERROR] interrupted")
        sys.exit(1)
