#!/usr/bin/env python3
"""
Manifest-driven target application engine (targets/*.json).

Replaces hand-written per-tool blocks in install.sh and deploy.sh.
Its PowerShell counterpart (lib/ApplyTargets.ps1) implements the SAME
contract for Windows installers -- both read the same manifests.
There is intentionally no Python dependency on Windows.

Usage:
    python3 lib/apply_targets.py --root . --scope user  --home /home/alice
    python3 lib/apply_targets.py --root . --scope machine
    python3 lib/apply_targets.py --root . --scope user  --home ~ --dry-run

Exit codes:
    0  all targets applied successfully (or dry-run)
    1  at least one target failed, or missing required privileges
    2  usage error / invalid manifest / unknown selector
    3  valid selection, but no targets matched (phase skipped)
"""

import argparse
import copy
import json
import os
import platform
import shutil
import sys
import time

# --- output ------------------------------------------------------------------
# No color when stdout is not a TTY (remote runners like RTR/SCCM capture stdout).
_TTY = sys.stdout.isatty()
_G, _Y, _R, _C, _D, _N = (
    ("\033[0;32m", "\033[1;33m", "\033[0;31m", "\033[0;36m", "\033[0;90m", "\033[0m")
    if _TTY else ("", "", "", "", "", "")
)


def info(m):
    print(f"{_G}[INFO]{_N} {m}")


def warn(m):
    print(f"{_Y}[WARN]{_N} {m}")


def err(m):
    print(f"{_R}[ERROR]{_N} {m}")


def detail(m):
    print(f"{_D}       {m}{_N}")


class TargetError(Exception):
    """Failure in one target. Does not abort the run: other targets proceed."""


# --- path resolution ---------------------------------------------------------

def current_os():
    s = platform.system().lower()
    if s.startswith("win"):
        return "windows"
    if s == "darwin":
        return "darwin"
    return "linux"


def expand(template, home, os_key):
    """
    Expands manifest tokens. Uses explicit tokens rather than os.path.expandvars
    because HOME must be injectable: deployment iterates user profiles and must
    not depend on process environment variables (under SYSTEM, USERPROFILE points
    to systemprofile).
    """
    if ("${HOME}" in template or "${APPDATA}" in template) and not home:
        raise TargetError("template requires HOME/APPDATA and no --home was provided")

    if os_key == "windows":
        appdata = os.path.join(home, "AppData", "Roaming")
        prog = os.environ.get("ProgramFiles", r"C:\Program Files")
        pdata = os.environ.get("ProgramData", r"C:\ProgramData")
    else:
        appdata = os.path.join(home, ".config")
        prog = "/usr/local"
        pdata = "/etc"

    out = (template
           .replace("${HOME}", home)
           .replace("${APPDATA}", appdata)
           .replace("${PROGRAMFILES}", prog)
           .replace("${PROGRAMDATA}", pdata))

    if "${" in out:
        raise TargetError(f"unexpanded token in '{template}' -> '{out}'")

    return os.path.normpath(out) if os_key == current_os() else out


def apply_payload_by_os(spec, home, os_key):
    """Injects per-OS values into payload with tokens expanded.

    Used when values require absolute paths resolved at installation time
    (e.g., statusLine.command).
    """
    novo = copy.deepcopy(spec)
    arquivos_por_os = novo.get("payload_file_by_os")
    if arquivos_por_os:
        if os_key not in arquivos_por_os:
            raise TargetError(f"payload_file_by_os does not define OS '{os_key}'")
        novo["payload_file"] = arquivos_por_os[os_key]

    por_os = novo.get("payload_by_os")
    if not por_os:
        return novo
    for dotted, variantes in por_os.items():
        if os_key not in variantes:
            raise TargetError(
                f"payload_by_os['{dotted}'] does not define OS '{os_key}'")
        valor = expand(variantes[os_key], home, os_key)

        partes = dotted.split(".")
        no = novo.get("payload")
        if not isinstance(no, dict):
            raise TargetError(
                f"payload_by_os requires a 'payload' object (target missing payload?)")
        for p in partes[:-1]:
            prox = no.get(p)
            if not isinstance(prox, dict):
                raise TargetError(
                    f"payload_by_os: '{dotted}' not found in payload "
                    f"(stopped at '{p}')")
            no = prox
        if partes[-1] not in no:
            raise TargetError(
                f"payload_by_os: '{dotted}' not found in payload")
        no[partes[-1]] = valor
    return novo


# --- io ----------------------------------------------------------------------

def read_text(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return f.read()


def write_text(path, content, dry_run):
    """UTF-8 without BOM, LF newlines."""
    if dry_run:
        detail(f"[dry-run] would write {path} ({len(content)} bytes)")
        return
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)


def dump_json(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def load_json_tolerant(path, tolerate_jsonc):
    """
    Reads existing JSON. Returns (data, ok). ok=False means parse failed;
    caller preserves the original file rather than overwriting.
    """
    try:
        raw = read_text(path)
    except OSError as e:
        raise TargetError(f"could not read {path}: {e}")

    if not raw.strip():
        return {}, True

    try:
        return json.loads(raw), True
    except json.JSONDecodeError as e:
        if tolerate_jsonc:
            warn(f"  {os.path.basename(path)} is not strict JSON (comments?) -- preserved without modification")
            detail(f"parse: {e}")
            return None, False
        raise TargetError(f"invalid JSON in {path}: {e}")


def backup(path, dry_run):
    if not os.path.exists(path):
        return
    dst = path + ".bak"
    if dry_run:
        detail(f"[dry-run] backup -> {dst}")
        return
    shutil.copy2(path, dst)
    detail(f"backup -> {os.path.basename(dst)}")


# --- strategies --------------------------------------------------------------

def strat_overwrite(spec, dst, root, dry_run):
    """Overwrites entire destination file (managed / owned files)."""
    if "payload_file" in spec:
        src = os.path.join(root, spec["payload_file"])
        if not os.path.isfile(src):
            raise TargetError(f"payload_file not found: {spec['payload_file']}")
        content = read_text(src)
        if spec.get("format") == "json":
            try:
                json.loads(content)
            except json.JSONDecodeError as e:
                raise TargetError(f"payload_file {spec['payload_file']} is not valid JSON: {e}")
    else:
        content = dump_json(spec["payload"])

    if spec.get("backup", True):
        backup(dst, dry_run)
    write_text(dst, content, dry_run)
    return "written (overwrite)"


def _union(existing, new):
    """Union preserving order: existing items kept, new items appended."""
    out = list(existing)
    seen = set(out)
    for item in new:
        if item not in seen:
            out.append(item)
            seen.add(item)
    return out


def strat_merge_permission_lists(spec, dst, root, dry_run):
    parent = spec["list_parent"]
    lists = spec["lists"]
    payload = spec["payload"][parent]

    if not os.path.exists(dst):
        write_text(dst, dump_json(spec["payload"]), dry_run)
        return "created"

    data, ok = load_json_tolerant(dst, spec.get("tolerate_jsonc", False))
    if not ok:
        return "preserved (parse failed)"
    if not isinstance(data, dict):
        raise TargetError(f"{dst}: expected top-level object")

    backup(dst, dry_run)
    block = data.setdefault(parent, {})
    if not isinstance(block, dict):
        raise TargetError(f"{dst}: '{parent}' exists and is not an object")

    added = 0
    for name in lists:
        incoming = payload.get(name, [])
        if not incoming:
            continue
        before = block.get(name, [])
        if not isinstance(before, list):
            raise TargetError(f"{dst}: '{parent}.{name}' exists and is not a list")
        merged = _union(before, incoming)
        added += len(merged) - len(before)
        block[name] = merged

    for k, v in payload.items():
        if k not in lists:
            block[k] = v

    write_text(dst, dump_json(data), dry_run)
    return f"merged (+{added} rules)"


def strat_merge_mcp(spec, dst, root, dry_run):
    key = spec.get("mcp_key", "mcpServers")
    payload = spec["payload"][key]

    if not os.path.exists(dst):
        write_text(dst, dump_json(spec["payload"]), dry_run)
        return "created"

    data, ok = load_json_tolerant(dst, spec.get("tolerate_jsonc", False))
    if not ok:
        return "preserved (parse failed)"
    if not isinstance(data, dict):
        raise TargetError(f"{dst}: expected top-level object")

    backup(dst, dry_run)
    servers = data.setdefault(key, {})
    if not isinstance(servers, dict):
        raise TargetError(f"{dst}: '{key}' exists and is not an object")
    servers.update(payload)

    write_text(dst, dump_json(data), dry_run)
    return f"merged ({len(payload)} servers)"


def strat_merge_missing_keys(spec, dst, root, dry_run):
    payload = spec["payload"]

    if not os.path.exists(dst):
        write_text(dst, dump_json(payload), dry_run)
        return "created"

    data, ok = load_json_tolerant(dst, spec.get("tolerate_jsonc", False))
    if not ok:
        return "preserved (parse failed)"
    if not isinstance(data, dict):
        raise TargetError(f"{dst}: expected top-level object")

    backup(dst, dry_run)
    added = [k for k in payload if k not in data]
    for k in added:
        data[k] = payload[k]

    write_text(dst, dump_json(data), dry_run)
    return f"merged (+{len(added)} keys)" if added else "unchanged (keys already present)"


def strat_md_block(spec, dst, root, dry_run):
    marker = spec["marker"]
    parts = []
    for rel in spec["compose"]:
        src = os.path.join(root, rel)
        if not os.path.isfile(src):
            raise TargetError(f"compose file not found: {rel}")
        parts.append(read_text(src).rstrip("\n"))
    body = "\n\n---\n\n".join(parts)
    block = f"{marker}\n{body}\n{marker}\n"

    if not os.path.exists(dst):
        write_text(dst, block, dry_run)
        return "created"

    existing = read_text(dst)
    if marker in existing:
        first = existing.index(marker)
        rest = existing[first + len(marker):]
        if marker in rest:
            end = first + len(marker) + rest.index(marker) + len(marker)
            content = existing[:first].rstrip("\n") + "\n\n" + block + existing[end:].lstrip("\n")
            write_text(dst, content, dry_run)
            return "block updated"
        warn(f"  unclosed opening marker in {os.path.basename(dst)} -- appending new block")

    content = existing.rstrip("\n") + "\n\n" + block
    write_text(dst, content, dry_run)
    return "block appended"


def remove_md_block(spec, dst, dry_run):
    """Removes our managed block from a file when superseded by an admin layer."""
    if not os.path.isfile(dst):
        return None

    existing = read_text(dst)
    marker = spec["marker"]
    if marker not in existing:
        return None

    first = existing.index(marker)
    rest = existing[first + len(marker):]
    if marker not in rest:
        warn(f"  unclosed marker in {os.path.basename(dst)} -- block NOT removed")
        return None

    end = first + len(marker) + rest.index(marker) + len(marker)
    before = existing[:first].rstrip('\n')
    after = existing[end:].lstrip('\n')
    if before and after:
        content = before + '\n\n' + after
    else:
        content = (before + '\n' + after).lstrip('\n')
    write_text(dst, content, dry_run)
    return "block removed"


def strat_remove(spec, dst, root, dry_run):
    """Deletes a destination file previously distributed."""
    if not os.path.isfile(dst):
        return "absent -- nothing to remove"
    if dry_run:
        return "would remove (no longer distributed)"
    os.remove(dst)
    return "file removed (no longer distributed)"


STRATEGIES = {
    "overwrite": strat_overwrite,
    "remove": strat_remove,
    "merge-permission-lists": strat_merge_permission_lists,
    "merge-mcp": strat_merge_mcp,
    "merge-missing-keys": strat_merge_missing_keys,
    "md-block": strat_md_block,
}


def dry_run_result(result):
    """Render a planned action without claiming a filesystem mutation."""
    if result == "written (overwrite)":
        return "would overwrite"
    if result == "created":
        return "would create"
    if result.startswith("merged"):
        return "would merge" + result[len("merged"):]
    if result == "block updated":
        return "would update block"
    if result == "block appended":
        return "would append block"
    if result == "block removed":
        return "would remove block"
    if result == "file removed (no longer distributed)":
        return "would remove file (no longer distributed)"
    return result


# --- execution ---------------------------------------------------------------

def is_admin():
    if current_os() == "windows":
        try:
            import ctypes
            return bool(ctypes.windll.shell32.IsUserAnAdmin())
        except Exception:
            return False
    return os.geteuid() == 0


def run_preflight(target, home, os_key):
    for check in target.get("preflight", []):
        if check.get("type") != "warn-if-exists":
            continue
        tmpl = check["path"].get(os_key)
        if not tmpl:
            continue
        try:
            path = expand(tmpl, home, os_key)
        except TargetError:
            detail(f"preflight not verified (no HOME in this run): {tmpl}")
            continue
        if os.path.exists(path):
            warn(f"  {os.path.basename(path)}: {check['message']}")


def apply_target(target, root, home, os_key, dry_run):
    """Returns (ok, fail, skip_os, skip_admin)."""
    label = target["label"]
    enforcement = target.get("enforcement", {}).get(os_key)

    files = [f for f in target["files"] if os_key in f["dest"]]
    if not files:
        return 0, 0, 1, 0

    tag = ""
    if enforcement == "hard":
        tag = f" {_C}[enforcement: managed]{_N}"
    elif enforcement == "advisory":
        tag = f" {_D}[advisory: user editable]{_N}"
    info(f"{label}{tag}")

    if target.get("requires_admin") and not is_admin() and not dry_run:
        warn("  lacks Admin/root privileges -- target SKIPPED (config was not applied)")
        return 0, 0, 0, len(files)

    run_preflight(target, home, os_key)

    ok = fail = 0
    for spec in files:
        dst = expand(spec["dest"][os_key], home, os_key)

        sup = spec.get("superseded_by")
        if sup:
            if os_key not in sup:
                err(f"  superseded_by does not define OS '{os_key}'")
                fail += 1
                continue
            sup_path = expand(sup[os_key], home, os_key)
            if os.path.isfile(sup_path):
                res = remove_md_block(spec, dst, dry_run)
                if res:
                    info(f"  OK {dst}")
                    detail(f"{res} -- superseded by {sup_path}")
                    ok += 1
                else:
                    detail(f"skipped: already covered by {sup_path}")
                continue

        if spec.get("only_if_parent_exists"):
            parent = os.path.dirname(dst)
            if not os.path.isdir(parent):
                detail(f"skipped (does not exist): {parent}")
                continue

        spec = apply_payload_by_os(spec, home, os_key)

        fn = STRATEGIES.get(spec["strategy"])
        if not fn:
            err(f"  unknown strategy: {spec['strategy']}")
            fail += 1
            continue
        try:
            result = fn(spec, dst, root, dry_run)
            if dry_run:
                result = dry_run_result(result)
            info(f"  OK {dst}")
            detail(result)
            ok += 1
        except TargetError as e:
            err(f"  FAIL {dst}")
            detail(str(e))
            fail += 1
        except OSError as e:
            err(f"  FAIL {dst}")
            detail(f"{type(e).__name__}: {e}")
            fail += 1

    for note in target.get("notes", []):
        detail(f"note: {note}")

    return ok, fail, 0, 0


def load_all_targets(root):
    """Loads and validates all manifests without filtering."""
    tdir = os.path.join(root, "targets")
    if not os.path.isdir(tdir):
        err(f"manifests directory not found: {tdir}")
        sys.exit(2)

    targets = []
    for name in sorted(os.listdir(tdir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(tdir, name)
        try:
            data = json.loads(read_text(path))
        except (json.JSONDecodeError, OSError) as e:
            err(f"invalid manifest {name}: {e}")
            sys.exit(2)

        stem = name[:-5]
        if data.get("id") != stem:
            err(f"manifest {name}: id '{data.get('id')}' does not match filename")
            sys.exit(2)
        for field in ("label", "tool", "scope", "files"):
            if field not in data:
                err(f"manifest {name}: missing required field '{field}'")
                sys.exit(2)

        targets.append(data)

    if not targets:
        err(f"no manifests found in {tdir}")
        sys.exit(2)
    return targets


def known_selectors(targets):
    out = {"all"}
    for t in targets:
        out.add(t["id"])
        out.update(t.get("selectors", []))
    return out


def filter_by_selector(targets, only):
    """Resolves --only selectors. Aborts on unknown selectors (seletor desconhecido)."""
    if not only:
        return targets

    valid = known_selectors(targets)
    bad = sorted(s for s in only if s not in valid)
    if bad:
        err(f"unknown selector (seletor desconhecido): {', '.join(bad)}")
        err(f"valid selectors: {', '.join(sorted(valid))}")
        sys.exit(2)

    if "all" in only:
        return targets

    out = []
    for t in targets:
        names = {t["id"]} | set(t.get("selectors", []))
        if names & only:
            out.append(t)
    return out


def print_target_list(targets, os_key):
    print(f"{_C}Available targets (OS: {os_key}){_N}\n")
    print(f"  {'ID':<17} {'SCOPE':<8} {'ADMIN':<6} {'ENFORCE':<9} SELECTORS")
    print("  " + "-" * 76)
    for t in sorted(targets, key=lambda x: (x["scope"], x["id"])):
        enf = t.get("enforcement", {}).get(os_key, "-")
        avail = any(os_key in f["dest"] for f in t["files"])
        adm = "yes" if t.get("requires_admin") else "no"
        sels = ", ".join(sorted(set(t.get("selectors", [])) | {t["id"]}))
        mark = "" if avail else "   (not available on this OS)"
        print(f"  {t['id']:<17} {t['scope']:<8} {adm:<6} {enf:<9} {sels}{mark}")
    print(f"\n  Groups: {_C}all{_N} (all targets), {_C}managed{_N} (all machine-scope targets),")
    print(f"          {_C}claude{_N} / {_C}codex{_N} / {_C}antigravity{_N} / {_C}vscode{_N} (by tool)")
    print("\n  Examples: --only codex,antigravity    --only managed    --only claude-managed")


def main():
    ap = argparse.ArgumentParser(description="Applies targets/*.json manifests.")
    ap.add_argument("--root", default=".", help="repository root path")
    ap.add_argument("--scope", choices=["user", "machine", "all"], default="all")
    ap.add_argument("--home", help="target user HOME directory (required for user scope)")
    ap.add_argument("--os", dest="os_key", choices=["windows", "linux", "darwin"],
                    default=current_os(), help="overrides detected OS (testing)")
    ap.add_argument("--only", default="all",
                    help="comma-separated selectors: all | tool (claude, codex, antigravity, vscode) | group (managed) | target id. Default: all")
    ap.add_argument("--list-targets", action="store_true",
                    help="lists available targets and selectors, then exits")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    all_targets = load_all_targets(root)

    if args.list_targets:
        print_target_list(all_targets, args.os_key)
        return 0

    only = {x.strip() for x in args.only.split(",") if x.strip()}
    targets = filter_by_selector(all_targets, only)

    scopes = ["user", "machine"] if args.scope == "all" else [args.scope]
    selected = [t for t in targets if t["scope"] in scopes]

    needs_home = any(t["scope"] == "user" for t in selected)
    if needs_home and not args.home:
        err("--home is required when a user-scope target is selected")
        sys.exit(2)
    home = os.path.abspath(os.path.expanduser(args.home)) if args.home else ""

    if not selected:
        warn(f"no target matches --only '{args.only}' in scope '{args.scope}'")
        print("APPLY-TARGETS: DONE ok=0 fail=0 skip_os=0 skip_admin=0 selected=0")
        return 3

    if args.dry_run:
        warn("DRY-RUN: nothing will be written")
    sel_desc = "all" if "all" in only else ",".join(sorted(only))
    print(f"{_C}OS: {args.os_key} | scope: {','.join(scopes)} | "
          f"only: {sel_desc} | targets: {len(selected)}{_N}")
    if len(selected) < len([t for t in all_targets if t["scope"] in scopes]):
        omitted = sorted(t["id"] for t in all_targets
                         if t["scope"] in scopes and t not in selected)
        warn(f"PARTIAL INSTALLATION -- not selected: {', '.join(omitted)}")
    if home:
        print(f"{_C}HOME: {home}{_N}")
    print()

    tot_ok = tot_fail = tot_skip_os = tot_skip_admin = 0
    for t in selected:
        o, f, sos, sadm = apply_target(t, root, home, args.os_key, args.dry_run)
        tot_ok += o
        tot_fail += f
        tot_skip_os += sos
        tot_skip_admin += sadm
        if not (sos and not o and not f):
            print()

    print(f"APPLY-TARGETS: DONE ok={tot_ok} fail={tot_fail} "
          f"skip_os={tot_skip_os} skip_admin={tot_skip_admin} "
          f"selected={len(selected)}")

    if tot_fail:
        err(f"{tot_fail} target(s) failed")
        return 1
    if tot_skip_admin:
        err(f"{tot_skip_admin} file(s) skipped due to missing privileges -- "
            f"requested config was NOT applied")
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        err("interrupted")
        sys.exit(1)
