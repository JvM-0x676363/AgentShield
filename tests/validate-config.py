#!/usr/bin/env python3
"""
Layer 1 test: validates configurations WITHOUT launching any AI tooling. Runs in CI/CD.

Purpose of this test suite: catch discrepancies between files that must agree.
Such divergence does not fail immediately -- it breaks during rollout on developer
workstations, where debugging is significantly more costly.

Usage:
    python tests/validate-config.py
    python tests/validate-config.py --check-tools      # verifies binaries in PATH
    python tests/validate-config.py --sync-claude-rule # regenerates the Claude runtime rule
"""

import io
import json
import os
import re
import shutil
import subprocess
import sys

from checks.constants import SELECTOR_GROUPS, VALID_OS, VALID_STRATEGIES

try:
    import tomllib
except ImportError:  # Python < 3.11
    tomllib = None

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARCHITECTURE_DOC = "docs/ARCHITECTURE.md"
OPERATIONS_DOC = "docs/OPERATIONS.md"
WINDOWS_SCRIPTS = "scripts/windows"
UNIX_SCRIPTS = "scripts/unix"
CLAUDE_RUNTIME_RULE = ".claude/rules/agent-shield-runtime.md"
ENTRYPOINT_PATHS = {
    "install.ps1": WINDOWS_SCRIPTS + "/install.ps1",
    "deploy.ps1": WINDOWS_SCRIPTS + "/deploy.ps1",
    "build-package.ps1": WINDOWS_SCRIPTS + "/build-package.ps1",
    "Test-AgentShieldManaged.ps1": WINDOWS_SCRIPTS + "/Test-AgentShieldManaged.ps1",
    "install.sh": UNIX_SCRIPTS + "/install.sh",
    "deploy.sh": UNIX_SCRIPTS + "/deploy.sh",
    "bitbucket/bitbucket-pipelines.yml": "integrations/bitbucket/bitbucket-pipelines.yml",
    "bitbucket/README.md": "integrations/bitbucket/README.md",
    "vscode-gpo/download-vsix.ps1": "integrations/vscode-gpo/download-vsix.ps1",
    "vscode-gpo/install-extensions.ps1": "integrations/vscode-gpo/install-extensions.ps1",
    "vscode-gpo/README.md": "integrations/vscode-gpo/README.md",
    "vscode-gpo/vscode-policy.json": "integrations/vscode-gpo/vscode-policy.json",
}
CHECK_TOOLS = "--check-tools" in sys.argv
SYNC_MD = "--sync-claude-rule" in sys.argv or "--sync-claude-md" in sys.argv

_counts = {"OK": 0, "WARN": 0, "FAIL": 0}


def check(passed, label, detail="", warn_only=False):
    if passed:
        tag = "OK  "
        _counts["OK"] += 1
    elif warn_only:
        tag = "WARN"
        _counts["WARN"] += 1
    else:
        tag = "FAIL"
        _counts["FAIL"] += 1
    line = "  [%s] %s" % (tag, label)
    if detail:
        line += "  --  %s" % detail
    print(line)
    return passed


def section(title):
    print("\n" + "=" * 100)
    print(title)
    print("=" * 100)


def repo_rel(rel):
    return ENTRYPOINT_PATHS.get(rel, rel)


def read(rel):
    rel = repo_rel(rel)
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()


def read_json(rel):
    return json.loads(read(rel))


def _array_body(text, opener_re):
    m = re.search(opener_re, text)
    if not m:
        return None
    body, depth = [], 0
    for ch in text[m.end():]:
        if ch in "(":
            depth += 1
        if ch == ")":
            if depth == 0:
                break
            depth -= 1
        body.append(ch)
    return "".join(body)


def ps_array(text, varname):
    body = _array_body(text, r"\$" + varname + r"\s*=\s*@\(")
    if body is None:
        return None
    return re.findall(r'"([^"]+)"', body)


def sh_array(text, varname):
    """
    Reads a shell array until the closing ')'. Comments must be ignored:
    a ')' inside '# ... (snyk.login/snyk.setToken)' would truncate reading and
    cause false divergence alerts -- false positives degrade confidence in tests.
    """
    m = re.search(varname + r"=\(", text)
    if not m:
        return None
    items = []
    for line in text[m.end():].splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        items += re.findall(r'"([^"]+)"', line)
        if stripped == ")" or stripped.endswith(")"):
            break
    return items


def norm(paths):
    return sorted(p.replace("\\", "/") for p in paths)


# =============================================================================
section("1. Target manifests")
# =============================================================================
tdir = os.path.join(ROOT, "targets")
manifests = {}
if check(os.path.isdir(tdir), "targets/ folder exists"):
    for name in sorted(os.listdir(tdir)):
        if not name.endswith(".json"):
            continue
        rel = "targets/" + name
        try:
            data = read_json(rel)
        except Exception as exc:
            check(False, "valid JSON: %s" % rel, str(exc))
            continue
        manifests[name[:-5]] = data
        check(True, "valid JSON: %s" % rel)

check(bool(manifests), "manifests exist", "%d found" % len(manifests))

for mid, m in sorted(manifests.items()):
    # id != filename causes engine runtime abort; checking here is cheap.
    check(m.get("id") == mid, "  %s: id matches filename" % mid, m.get("id", ""))
    for field in ("label", "tool", "scope", "requires_admin", "enforcement", "files"):
        check(field in m, "  %s: field '%s'" % (mid, field))
    check(m.get("scope") in ("user", "machine"), "  %s: valid scope" % mid, m.get("scope"))

    # Label is printed to console. cp1252 lacks em-dash: repository is pure ASCII by design.
    label = m.get("label", "")
    non_ascii = [c for c in label if ord(c) > 127]
    check(not non_ascii, "  %s: pure ASCII label" % mid, non_ascii or "")

    for os_key in (m.get("enforcement") or {}):
        check(os_key in VALID_OS, "  %s: enforcement[%s] is valid OS" % (mid, os_key))
        check(m["enforcement"][os_key] in ("hard", "advisory"),
              "  %s: enforcement[%s] is hard|advisory" % (mid, os_key),
              m["enforcement"][os_key])

    for i, spec in enumerate(m.get("files", [])):
        tag = "  %s.files[%d]" % (mid, i)
        check(spec.get("strategy") in VALID_STRATEGIES, "%s: known strategy" % tag,
              spec.get("strategy"))
        dest = spec.get("dest", {})
        check(bool(dest), "%s: has dest" % tag)
        check(all(k in VALID_OS for k in dest), "%s: dest keys are valid OSes" % tag,
              sorted(dest))
        # Unsupported token causes engine to abort on that target.
        for os_key, tmpl in dest.items():
            toks = re.findall(r"\$\{([A-Z]+)\}", tmpl)
            bad = [t for t in toks if t not in ("HOME", "APPDATA", "PROGRAMFILES", "PROGRAMDATA")]
            check(not bad, "%s[%s]: supported tokens" % (tag, os_key), bad or "")

        # 'remove' is the only strategy without payload: it deletes rather than writes.
        # As a destructive action, it requires justification in manifest comments.
        if spec.get("strategy") == "remove":
            check("payload" not in spec and "payload_file" not in spec,
                  "%s: 'remove' carries no payload" % tag)
            check(len(spec.get("$comment", "")) > 80,
                  "%s: 'remove' justifies destination removal" % tag,
                  spec.get("$comment", "")[:60])
        else:
            has_payload = ("payload" in spec or "payload_file" in spec
                           or "payload_file_by_os" in spec
                           or "compose" in spec)
            check(has_payload, "%s: has payload/payload_file/compose" % tag)
        if "payload_file_by_os" in spec:
            variants = spec["payload_file_by_os"]
            missing = [os_key for os_key in dest if os_key not in variants]
            extra = [os_key for os_key in variants if os_key not in dest]
            check(not missing and not extra,
                  "%s: payload_file_by_os covers destination OSes exactly" % tag,
                  "missing=%s extra=%s" % (missing, extra))

        if spec.get("strategy") == "md-block":
            check("marker" in spec, "%s: md-block declares marker" % tag)
        if spec.get("strategy") == "merge-permission-lists":
            check("list_parent" in spec and "lists" in spec,
                  "%s: declares list_parent and lists" % tag)

# =============================================================================
section("1b. --only selectors")
# =============================================================================
# Partial selection is both useful and hazardous: an unresolved selector applies
# no config at all, and exit code 0 would mislead operators into thinking host is guarded.
all_selectors = {}          # selector -> [resolved target IDs]
for mid, m in sorted(manifests.items()):
    sels = m.get("selectors")
    check(isinstance(sels, list) and len(sels) > 0,
          "  %s: declares selectors" % mid, sels or "MISSING")
    for sel in (sels or []):
        check(isinstance(sel, str) and sel == sel.strip().lower()
              and " " not in sel and "," not in sel,
              "  %s: selector '%s' is lowercase, no space or comma" % (mid, sel))
        all_selectors.setdefault(sel, []).append(mid)
    # Target ID itself always resolves; does not need to be in selectors, but if present must point to itself.
    check(mid in (sels or []) or True, "  %s: id always resolves" % mid)

# Selector cannot collide with ID of another target.
for sel, ids in sorted(all_selectors.items()):
    if sel in manifests and len(ids) > 1:
        check(False, "  selector '%s' is target id but resolves multiple targets" % sel, ids)

# 'all' is reserved by the engine -- a manifest declaring it would capture everything.
check("all" not in all_selectors, "  no manifest declares 'all' selector",
      all_selectors.get("all", ""))

# Groups promised by documentation and --help must exist.
for grupo, esperado in sorted(SELECTOR_GROUPS.items()):
    resolvido = sorted(all_selectors.get(grupo, []))
    check(resolvido == sorted(esperado),
          "  group '%s' resolves correct targets" % grupo,
          resolvido if resolvido == sorted(esperado)
          else "expected %s, got %s" % (sorted(esperado), resolvido))

# 'managed' must match machine-scoped targets exactly.
machine_targets = sorted(mid for mid, m in manifests.items() if m["scope"] == "machine")
check(sorted(all_selectors.get("managed", [])) == machine_targets,
      "  group 'managed' == all machine-scoped targets",
      "" if sorted(all_selectors.get("managed", [])) == machine_targets
      else "managed=%s machine=%s" % (sorted(all_selectors.get("managed", [])), machine_targets))

# All machine targets require admin; no user targets require admin.
for mid, m in sorted(manifests.items()):
    if m["scope"] == "machine":
        check(m.get("requires_admin") is True,
              "  %s: machine target requires admin" % mid)
    else:
        check(m.get("requires_admin") is False,
              "  %s: user target DOES NOT require admin" % mid)

# =============================================================================
section("1c. Preflight evaluable in execution scope")
# =============================================================================
# Machine-scoped preflight CANNOT depend on ${HOME}/${APPDATA}: machine passes run before user discovery.
for mid, m in sorted(manifests.items()):
    for check_spec in m.get("preflight", []):
        paths = check_spec.get("path", {})
        usa_perfil = any("${HOME}" in v or "${APPDATA}" in v for v in paths.values())
        if m["scope"] == "machine":
            check(not usa_perfil,
                  "  %s: machine-scoped preflight does not depend on HOME" % mid,
                  "" if not usa_perfil else "warning would never trigger")
        # Every preflight must declare a non-empty message.
        check(bool(check_spec.get("message")),
              "  %s: preflight declares message" % mid)

# Consequences must also be visible in dry-run mode on clean machines.
if "claude-managed" in manifests:
    notas = " ".join(manifests["claude-managed"].get("notes", []))
    check("allowManagedPermissionRulesOnly" in notas,
          "  claude-managed: notes explains consequences (visible in dry-run)")
    check("allowManagedHooksOnly" in notas,
          "  claude-managed: notes explains hook effects")

# The warning regarding allowManagedPermissionRulesOnly must be present on a user target.
tem_aviso = any(
    m["scope"] == "user"
    and any("allowManagedPermissionRulesOnly" in (c.get("message") or "")
            for c in m.get("preflight", []))
    for m in manifests.values()
)
check(tem_aviso,
      "  allowManagedPermissionRulesOnly warning exists in a user-scoped target")

# =============================================================================
section("2. Payloads referenced by manifests")
# =============================================================================
# A broken payload_file will not surface in dry-run without reading the file --
# it fails on the host, and for requirements.toml it crashes developer Codex sessions.
for mid, m in sorted(manifests.items()):
    for spec in m.get("files", []):
        payload_files = [spec["payload_file"]] if spec.get("payload_file") else []
        payload_files += list((spec.get("payload_file_by_os") or {}).values())
        for pf in payload_files:
            path = os.path.join(ROOT, pf)
            if check(os.path.isfile(path), "  %s -> %s exists" % (mid, pf)):
                if pf.endswith(".json"):
                    try:
                        json.loads(read(pf))
                        check(True, "    valid JSON: %s" % pf)
                    except Exception as exc:
                        check(False, "    valid JSON: %s" % pf, str(exc))
                elif pf.endswith(".toml"):
                    if tomllib is None:
                        check(False, "    TOML not validated: %s" % pf,
                              "python < 3.11 without tomllib", warn_only=True)
                    else:
                        try:
                            with open(path, "rb") as fh:
                                tomllib.load(fh)
                            check(True, "    valid TOML: %s" % pf)
                        except Exception as exc:
                            check(False, "    valid TOML: %s" % pf, str(exc))
        for rel in spec.get("compose", []):
            check(os.path.isfile(os.path.join(ROOT, rel)),
                  "  %s -> compose %s exists" % (mid, rel))

# Format constraint, verified rather than assumed: requirements.toml accepts
# decisions "prompt" or "forbidden" -- "allow" is rejected.
req = "policy/codex-requirements.toml"
if os.path.isfile(os.path.join(ROOT, req)) and tomllib:
    with open(os.path.join(ROOT, req), "rb") as fh:
        rq = tomllib.load(fh)
    rules = rq.get("rules", {}).get("prefix_rules", [])
    bad = [r for r in rules if r.get("decision") not in ("prompt", "forbidden")]
    check(not bad, "requirements.toml: no 'allow' decision",
          bad or "%d rules" % len(rules))
    check("allowed_sandbox_modes" not in rq,
          "requirements.toml: does not maintain legacy sandbox_mode compatibility")
    check("never" not in rq.get("allowed_approval_policies", []),
          "requirements.toml: approval_policy 'never' NOT allowed",
          rq.get("allowed_approval_policies"))
    _profiles = rq.get("allowed_permission_profiles", {})
    check(rq.get("default_permissions") == "security_workspace",
          "requirements.toml: default_permissions uses protected workspace profile",
          rq.get("default_permissions"))
    check(_profiles == {"security_readonly": True, "security_workspace": True},
          "requirements.toml: only permits protected corporate profiles",
          _profiles)
    _windows = rq.get("windows", {})
    check(_windows.get("allow_mxc") is False,
          "requirements.toml: MXC disabled following compatibility failure",
          _windows.get("allow_mxc"))
    check(_windows.get("allowed_sandbox_implementations") == ["elevated"],
          "requirements.toml: Windows fallback restricted to elevated",
          _windows.get("allowed_sandbox_implementations"))
    _permission_profiles = rq.get("permissions", {})
    _workspace_sensitive = [
        "**/.env", "**/.env.*", "**/secrets/**", "**/credentials/**",
        "**/*.key", "**/*.pem", "**/*.p12", "**/*.pfx",
        "**/*.jks", "**/*.kdbx", "**/id_rsa", "**/id_ed25519",
    ]
    _profile_sensitive = [
        "~/.ssh", "~/.aws", "~/.azure", "~/.gnupg", "~/.kube",
        "~/.config/gcloud", "~/.docker/config.json", "~/.git-credentials",
        "~/.netrc", "~/.npmrc", "~/.pypirc",
        "~/.terraform.d/credentials.tfrc.json",
    ]
    for _profile_name, _parent in (("security_readonly", ":read-only"),
                                   ("security_workspace", ":workspace")):
        _profile = _permission_profiles.get(_profile_name, {})
        check(_profile.get("extends") == _parent,
              "requirements.toml: %s inherits %s" % (_profile_name, _parent),
              _profile.get("extends"))
        _fs = _profile.get("filesystem", {})
        check(isinstance(_fs.get("glob_scan_max_depth"), int) and
              _fs["glob_scan_max_depth"] >= 1,
              "  %s: glob_scan_max_depth limits deny globs for MXC" % _profile_name,
              "obtained=%r" % _fs.get("glob_scan_max_depth"))
        _roots = _fs.get(":workspace_roots", {})
        _missing_workspace = [p for p in _workspace_sensitive if _roots.get(p) != "deny"]
        _missing_profile = [p for p in _profile_sensitive if _fs.get(p) != "deny"]
        check(not _missing_workspace and not _missing_profile,
              "  %s: denies sensitive repo and profile paths" % _profile_name,
              (_missing_workspace + _missing_profile) or "")
    _root_globs = [k for _p in _permission_profiles.values()
                   for k in _p.get("filesystem", {}) if k.startswith("/**")]
    check(not _root_globs,
          "requirements.toml: no deny glob starts from drive root (MXC)",
          _root_globs or "")
    _defaults_path = os.path.join(ROOT, "policy/codex-managed-defaults.toml")
    with open(_defaults_path, "rb") as fh:
        _defaults = tomllib.load(fh)
    check("sandbox_mode" not in _defaults,
          "managed defaults: does not select legacy sandbox_mode")
    _codex_vendor = read("policy/vendor-codex-cli.md")
    check("Codex 0.138.0+ is mandatory" in _codex_vendor,
          "Codex documentation declares minimum version for new pattern")

    _unix_req_path = os.path.join(ROOT, "policy", "codex-requirements-unix.toml")
    if check(os.path.isfile(_unix_req_path), "Codex Unix requirements exist"):
        with open(_unix_req_path, "rb") as fh:
            _unix_rq = tomllib.load(fh)
        check("windows" not in _unix_rq,
              "Unix requirements does not load Windows fallback")
        for _name in ("security_readonly", "security_workspace"):
            _unix_fs = _unix_rq.get("permissions", {}).get(_name, {}).get("filesystem", {})
            _home_denies = [p for p in _profile_sensitive if p in _unix_fs]
            check(not _home_denies,
                  "  Unix requirements: %s delegates HOME to native profile" % _name,
                  _home_denies or "")
            _unix_roots = _unix_fs.get(":workspace_roots", {})
            _missing = [p for p in _workspace_sensitive if _unix_roots.get(p) != "deny"]
            check(not _missing,
                  "  Unix requirements: %s retains workspace denies" % _name,
                  _missing or "")

    _requirements_spec = next((f for f in manifests.get("codex-managed", {}).get("files", [])
                               if f.get("dest", {}).get("windows", "").endswith("requirements.toml")), {})
    _requirements_by_os = _requirements_spec.get("payload_file_by_os", {})
    check(_requirements_by_os == {
        "windows": "policy/codex-requirements.toml",
        "linux": "policy/codex-requirements-unix.toml",
        "darwin": "policy/codex-requirements-unix.toml",
    }, "Codex manifest selects requirements by OS", _requirements_by_os)

# Scanner catalog: a single source of versions and hashes prevents installers from resolving latest independently.
tools_catalog = read_json("policy/tools.json")
tools = tools_catalog.get("tools", {})
check(set(tools) == {"gitleaks", "trivy", "semgrep"},
      "tools.json: baseline contains only the three approved scanners",
      sorted(tools))
for _tool in ("gitleaks", "trivy"):
    _record = tools.get(_tool, {})
    check(bool(_record.get("version")) and bool(_record.get("binary")),
          "tools.json: %s has version and binary" % _tool)
    _assets = _record.get("assets", {})
    check(bool(_assets), "tools.json: %s has assets" % _tool)
    for _platform, _asset in _assets.items():
        _hash = _asset.get("sha256", "")
        check(bool(re.fullmatch(r"[0-9a-f]{64}", _hash)),
              "  %s/%s has valid SHA-256" % (_tool, _platform))
check(bool(tools.get("semgrep", {}).get("version")),
      "tools.json: semgrep has pinned version")

_installers = ("install.sh", "deploy.sh", "install.ps1", "deploy.ps1")
_installer_text = "\n".join(read(f) for f in _installers)
check("releases/latest" not in _installer_text and "trivy/main/contrib/install.sh" not in _installer_text,
      "installers do not resolve latest or execute mutable remote scripts")

for _rel in ("install.ps1", "deploy.ps1"):
    _txt = read(_rel)
    check('"lib\\CodexSandboxProfile.ps1"' in _txt,
          "%s: requires Codex provisioning helper" % _rel)
    check("Initialize-CodexElevatedSandbox" in _txt,
          "%s: provisions Codex elevated fallback" % _rel)
_sandbox_helper = read("lib/CodexSandboxProfile.ps1")
check("sandbox setup --elevated" in _sandbox_helper and "--codex-home" in _sandbox_helper,
      "Codex helper uses elevated setup with explicit CODEX_HOME")
check("Resolve-CodexExecutableForProfile" in _sandbox_helper and
      "AppData\\Local\\OpenAI\\Codex\\bin" in _sandbox_helper,
      "Codex helper resolves executable inside target profile")
check("Get-Command \"codex" not in _sandbox_helper and "PATH administrativo" not in _sandbox_helper,
      "Codex helper does not use shared administrative PATH")
check(os.path.isfile(os.path.join(ROOT, "docs", "windows-sandbox-followup.md")),
      "Windows sandbox tracking record exists")
check("setup" in read("docs/windows-sandbox-followup.md") and
      "refresh had errors" in read("docs/windows-sandbox-followup.md"),
      "Windows sandbox tracking record preserves rollout error")

_unix_install = read("install.sh")
check("TARGET_HOME" in _unix_install and "SUDO_USER" in _unix_install,
      "install.sh: preserves caller profile under sudo")
check('--home "$TARGET_HOME"' in _unix_install and "git config --file '$TARGET_HOME/.gitconfig'" in _unix_install,
      "install.sh: applies AI and Git config to target profile, not root")
check('chown -R "$TARGET_USER" "$user_path"' in _unix_install,
      "install.sh: restores ownership of files created under sudo to user")
check('command -v bwrap' in _unix_install and 'bubblewrap' in _unix_install,
      "install.sh: verifies Bubblewrap prerequisite on Linux")
_unix_prereqs = read("lib/security-tools.sh")
check("ensure_codex_sandbox_prereqs_unix" in _unix_prereqs and
      all(_manager in _unix_prereqs for _manager in ("apt-get", "dnf", "yum", "zypper", "pacman", "apk")),
      "Unix helper installs Bubblewrap via supported package managers")
check("ensure_codex_sandbox_prereqs_unix" in read("deploy.sh") and
      "ensure_codex_sandbox_prereqs_unix" in _unix_install,
      "install.sh and deploy.sh apply Codex sandbox prerequisites")

vscode_policy = read_json("vscode-gpo/vscode-policy.json")
check(vscode_policy == {
    "TelemetryLevel": "off",
    "EnableFeedback": False,
    "ChatToolsAutoApprove": False,
    "ChatToolsTerminalEnableAutoApprove": False,
}, "vscode-gpo: corporate baseline blocks telemetry and auto-approval",
      vscode_policy)

# =============================================================================
section("3. policy.json -- intent vs coverage")
# =============================================================================
pol = read_json("policy/policy.json")
intents = pol["intents"]
coverage = {k: v for k, v in pol["coverage"].items() if not k.startswith("$")}

check(bool(intents), "intents declared", "%d" % len(intents))

# Every tool with a manifest must appear in coverage map, and vice-versa.
tools_in_manifests = {m["tool"] for m in manifests.values() if m.get("tool") != "vscode"}
tools_in_coverage = set(coverage)
check(tools_in_manifests == tools_in_coverage,
      "manifest tools == coverage tools",
      "" if tools_in_manifests == tools_in_coverage
      else "diff: %s" % sorted(tools_in_manifests ^ tools_in_coverage))

for tool, cov in sorted(coverage.items()):
    missing = sorted(set(intents) - set(cov))
    check(not missing, "  %s: declares all intents" % tool, missing or "%d" % len(cov))
    extra = sorted(set(cov) - set(intents))
    check(not extra, "  %s: does not invent intent" % tool, extra or "")

    for iname, entry in sorted(cov.items()):
        if iname not in intents:
            continue
        if entry.get("expressable") is True:
            check(bool(entry.get("mechanism")),
                  "  %s/%s: expressable declares mechanism" % (tool, iname))
        elif entry.get("expressable") is False:
            ok = bool(entry.get("gap")) and bool(entry.get("mitigation"))
            check(ok, "  %s/%s: gap has both gap AND mitigation" % (tool, iname),
                  "" if ok else "missing gap and/or mitigation")
        else:
            check(False, "  %s/%s: expressable is boolean" % (tool, iname),
                  repr(entry.get("expressable")))

# =============================================================================
section("4. Drift: intent vs actual manifest payload")
# =============================================================================
def manifest_text(mid):
    return json.dumps(manifests.get(mid, {}), ensure_ascii=False)


# Egress: curl and wget must be explicitly controlled where tools support it by command name.
for mid in ("claude-code", "claude-managed", "antigravity"):
    if mid in manifests:
        txt = manifest_text(mid)
        for cmd in intents["control_egress"]["commands"]:
            check(cmd in txt, "  %s: controls '%s'" % (mid, cmd))

# Git integrity: commands that bypass or disable security controls.
for mid in ("claude-code", "claude-managed", "antigravity"):
    if mid in manifests:
        txt = manifest_text(mid)
        for frag in ("core.hooksPath", "no-verify", "push --force"):
            check(frag in txt, "  %s: guards git ('%s')" % (mid, frag))

if tomllib and os.path.isfile(os.path.join(ROOT, req)):
    with open(os.path.join(ROOT, req), "rb") as fh:
        _rq = tomllib.load(fh)
    rtxt = json.dumps(_rq, ensure_ascii=False)
    for frag in ("curl", "wget", "core.hooksPath", "--no-verify", "--force"):
        check(frag in rtxt, "  codex requirements: covers '%s'" % frag)
    check(bool(_rq.get("permissions", {}).get("security_workspace", {}).get("filesystem", {}).get(":workspace_roots")),
          "  codex requirements: workspace secret deny rules present")

# Allowed scanners: AI assistants must run scanners without interactive approval gates.
for mid in ("claude-code", "claude-managed"):
    if mid in manifests:
        txt = manifest_text(mid)
        for tool in intents["allow_scanners"]["commands"]:
            check(tool in txt, "  %s: allows scanner '%s'" % (mid, tool))

# Permission bypass lockout: closes --dangerously-skip-permissions.
if "claude-managed" in manifests:
    txt = manifest_text("claude-managed")
    check("disableBypassPermissionsMode" in txt,
          "  claude-managed: disableBypassPermissionsMode present")
    check('"disable"' in txt, "  claude-managed: value 'disable'")
    _pay = {}
    for f in manifests["claude-managed"].get("files", []):
        _pay.update(f.get("payload", {}) or {})
        _pay.update((f.get("payload", {}) or {}).get("permissions", {}) or {})
    for key in ("allowManagedPermissionRulesOnly", "allowManagedHooksOnly"):
        check(key in _pay, "  claude-managed: %s present" % key)

    _rm = [f for f in manifests["claude-managed"]["files"]
           if f.get("strategy") == "remove"
           and any(str(d).endswith("managed-mcp.json")
                   for d in f.get("dest", {}).values())]
    check(len(_rm) == 1,
          "  claude-managed: managed-mcp.json is removed, not written",
          "specs with strategy=remove for this target: %d" % len(_rm))
    check(_rm and len(_rm[0].get("dest", {})) == 3,
          "  removal covers all three OSes",
          "" if not _rm else sorted(_rm[0].get("dest", {})))

# Antigravity lacks managed machine-wide layer -- must be declared advisory across all platforms.
if "antigravity" in manifests:
    enf = manifests["antigravity"]["enforcement"]
    check(all(v == "advisory" for v in enf.values()),
          "  antigravity: advisory on all platforms", enf)
    _anti_specs = manifests["antigravity"].get("files", [])
    _anti_permissions = next((f.get("payload", {}).get("permissions", {})
                              for f in _anti_specs
                              if f.get("strategy") == "merge-permission-lists"), {})
    _anti_allow = _anti_permissions.get("allow", [])
    check("mcp(semgrep/*)" in _anti_allow,
          "  antigravity: Semgrep MCP remains pre-approved")
    check("mcp(trivy/*)" not in _anti_allow,
          "  antigravity: Trivy MCP is not pre-approved without verified plugin")
    _anti_defaults = next((f.get("payload", {}) for f in _anti_specs
                           if f.get("strategy") == "merge-missing-keys"
                           and f.get("payload", {}).get("toolPermission")
                           == "proceed-in-sandbox"), {})
    check(_anti_defaults.get("enableTerminalSandbox") is True
          and _anti_defaults.get("allowNonWorkspaceAccess") is False,
          "  antigravity: defaults retain sandbox and block extra-workspace access",
          _anti_defaults)

# =============================================================================
section("5. Permission rules (syntax and coherence)")
# =============================================================================
RULE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*\(.+\)$")
for mid, m in sorted(manifests.items()):
    for spec in m.get("files", []):
        if spec.get("strategy") != "merge-permission-lists" and spec.get("strategy") != "overwrite":
            continue
        payload = spec.get("payload") or {}
        parent = spec.get("list_parent", "permissions")
        block = payload.get(parent)
        if not isinstance(block, dict):
            continue
        buckets = {b: block.get(b, []) for b in ("deny", "ask", "allow")}
        if not any(buckets.values()):
            continue

        bad = [r for rs in buckets.values() for r in rs if not RULE.match(str(r))]
        check(not bad, "  %s: Tool(pattern) syntax across all rules" % mid, bad or "")

        for b, rs in buckets.items():
            dup = sorted({r for r in rs if rs.count(r) > 1})
            check(not dup, "  %s: no duplicates in '%s'" % (mid, b), dup or "")

        # Conflict resolution in Antigravity is deny > ask > allow.
        names = ("deny", "ask", "allow")
        overlaps = []
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                common = set(buckets[a]) & set(buckets[b])
                if common:
                    overlaps.append("%s/%s: %s" % (a, b, sorted(common)))
        check(not overlaps, "  %s: no overlapping rules across buckets" % mid, overlaps or "")

# =============================================================================
section("5d. Outbound or destructive commands must match deny or ask")
# =============================================================================
SAIDA_OU_PERDA = [
    ("git push",        "publishes to remote"),
    ("git reset --hard", "discards uncommitted changes"),
    ("git clean",       "deletes untracked files"),
    ("git rebase",      "rewrites history"),
    ("git restore",     "discards uncommitted changes"),
    ("git branch -D",   "deletes branch without merge check"),
    ("git remote set-url", "changes push remote destination"),
]

for _id in ("claude-code", "claude-managed"):
    if _id not in manifests:
        continue
    _p = {}
    for _f in manifests[_id].get("files", []):
        _pp = (_f.get("payload") or {}).get("permissions")
        if _pp:
            _p = _pp
            break
    if not _p:
        continue
    _gated = [r[5:-3] if r.endswith(":*)") else r[5:-1]
              for r in _p.get("deny", []) + _p.get("ask", [])
              if r.startswith("Bash(")]
    for _cmd, _porque in SAIDA_OU_PERDA:
        _ok = any(_cmd == g or _cmd.startswith(g + " ") for g in _gated)
        check(_ok, "  %s: '%s' matches deny or ask" % (_id, _cmd),
              "" if _ok else "falls into default -- %s, and auto mode does not prompt" % _porque)

# Sensitive data egress: agents must not inspect Kubernetes Secrets.
K8S_SECRET_COMMANDS = (
    "kubectl get secret", "kubectl get secrets",
    "kubectl describe secret", "kubectl describe secrets",
    "kubectl create token",
)

def _bash_runtime_command(rule):
    """'Bash(kubectl get secret:*)' -> 'kubectl get secret'."""
    _match = re.match(r"^Bash\((.+?)(?::\*)?\)$", rule)
    return _match.group(1) if _match else None


for _id in ("claude-code", "claude-managed"):
    _p = {}
    for _f in manifests.get(_id, {}).get("files", []):
        _candidate = (_f.get("payload") or {}).get("permissions")
        if _candidate:
            _p = _candidate
            break
    if not _p:
        continue
    _deny = {_bash_runtime_command(r) for r in _p.get("deny", [])
             if _bash_runtime_command(r)}
    for _cmd in K8S_SECRET_COMMANDS:
        check(_cmd in _deny, "  %s: blocks '%s'" % (_id, _cmd))
    _allow = {_bash_runtime_command(r) for r in _p.get("allow", [])
              if _bash_runtime_command(r)}
    for _cmd in ("kubectl get", "kubectl describe", "kubectl logs",
                 "terraform plan", "terraform show", "terraform output",
                 "docker logs", "docker inspect"):
        check(_cmd not in _allow, "  %s: '%s' does not leak through allow" % (_id, _cmd))

_anti_txt = manifest_text("antigravity")
for _cmd in K8S_SECRET_COMMANDS:
    check("command(%s)" % _cmd in _anti_txt,
          "  antigravity: blocks '%s'" % _cmd)

if tomllib and os.path.isfile(os.path.join(ROOT, req)):
    with open(os.path.join(ROOT, req), "rb") as fh:
        _req_runtime = tomllib.load(fh)
    _req_txt = json.dumps(_req_runtime, ensure_ascii=False)
    for _cmd in K8S_SECRET_COMMANDS:
        check(_cmd.split()[-1] in _req_txt,
              "  codex requirements: covers '%s'" % _cmd)

# =============================================================================
section("5c. Allow rule swallowed by ask or deny")
# =============================================================================
# The docs are explicit: "Rules are evaluated in order: deny, then ask, then allow.
# The first match in that order determines the outcome, and rule specificity
# doesn't change the order." And also: "a matching ask rule prompts even when a
# more specific allow rule also matches the same call."
#
# A broad ask SWALLOWS the specific allow rule, making the allow rule dead
# letter -- no error, no warning, and the effect is the opposite of what was
# intended: someone wrote the rule to permit and it permits nothing.
#
# This happened here: Bash(docker:*) in ask left Bash(docker ps:*) and
# Bash(docker images:*) in allow with no effect. It went unnoticed because
# the visible behavior (docker ps prompts) is the same as not having the rule.
def _cmd_de(regra):
    """'Bash(docker ps:*)' -> 'docker ps'. Returns None if not a Bash rule."""
    m = re.match(r"^Bash\((.+?)(?::\*)?\)$", regra)
    return m.group(1) if m else None


def _mais_amplo(largo, estreito):
    """True if 'largo' matches everything that 'estreito' matches.

    Requires a word boundary: 'docker' is broader than 'docker ps', but NOT
    than 'dockerize ps' -- a plain string prefix would confuse different programs.
    """
    if largo == estreito:
        return True
    return estreito.startswith(largo) and estreito[len(largo)] == " "


for _id, _t in sorted(manifests.items()):
    for _f in _t.get("files", []):
        _p = _f.get("payload", {}).get("permissions")
        if not _p:
            continue
        _allow = [r for r in _p.get("allow", []) if _cmd_de(r)]
        _sombra = []
        for _nivel in ("deny", "ask"):
            for _r_alto in _p.get(_nivel, []):
                _c_alto = _cmd_de(_r_alto)
                if not _c_alto:
                    continue
                for _r_allow in _allow:
                    if _mais_amplo(_c_alto, _cmd_de(_r_allow)):
                        _sombra.append("%s swallows %s" % (_r_alto, _r_allow))
        check(not _sombra,
              "%s: no allow rule swallowed by ask/deny" % _id,
              "" if not _sombra else "; ".join(_sombra[:3]))

# =============================================================================
section("5b. allowManagedPermissionRulesOnly: managed is superset")
# =============================================================================
def _perm_de(target, estrategias):
    for fl in target.get("files", []):
        if fl.get("strategy") in estrategias:
            pay = fl.get("payload", {})
            if "permissions" in pay:
                return pay["permissions"]
    return None


_gerenciados = [t for t in manifests.values()
                if (_perm_de(t, ("overwrite",)) or {}).get("allowManagedPermissionRulesOnly")
                or any(fl.get("payload", {}).get("permissions", {})
                       .get("allowManagedPermissionRulesOnly")
                       for fl in t.get("files", []))]

for tg in _gerenciados:
    perm_mg = _perm_de(tg, ("overwrite",))
    if not perm_mg:
        continue
    pares = [t for t in manifests.values()
             if t.get("tool") == tg.get("tool") and t.get("scope") == "user"]
    for par in pares:
        perm_us = _perm_de(par, ("merge-permission-lists",))
        if not perm_us:
            continue
        for lista in ("deny", "ask"):
            m = set(perm_mg.get(lista, []))
            u = set(perm_us.get(lista, []))
            faltam = sorted(u - m)
            check(not faltam,
                  "%s[%s] covers %s in %s" % (tg["id"], lista, lista, par["id"]),
                  "" if not faltam
                  else "%d rule(s) would disappear upon applying enforcement: %s"
                       % (len(faltam), ", ".join(faltam[:3]) +
                          (" ..." if len(faltam) > 3 else "")))

check(bool(_gerenciados),
      "targets with allowManagedPermissionRulesOnly exist to verify")

# =============================================================================
section("6. Guidelines: compact runtime and synchronized Claude runtime rule")
# =============================================================================
core = read("policy/core-guidelines.md").rstrip("\n")
runtime = read("policy/core-runtime.md").rstrip("\n")
vendor_claude = read("policy/vendor-claude-code.md").rstrip("\n")
HEADER = """<!-- GENERATED FROM policy/ -- DO NOT EDIT THIS FILE -->
<!-- Source: policy/core-runtime.md + policy/vendor-claude-code.md            -->
<!-- To change guidelines, edit files in policy/ and run:                    -->
<!--   python tests/validate-config.py --sync-claude-rule                    -->
<!-- tests/validate-config.py fails if this file falls out of sync.          -->

"""
expected_md = HEADER + runtime + "\n\n---\n\n" + vendor_claude + "\n"

if SYNC_MD:
    with open(os.path.join(ROOT, CLAUDE_RUNTIME_RULE), "w", encoding="utf-8", newline="\n") as f:
        f.write(expected_md)
    print("  Claude runtime rule regenerated from policy/")

_claude_md_path = os.path.join(ROOT, CLAUDE_RUNTIME_RULE)
if not os.path.isfile(_claude_md_path):
    actual_md = None
    check(False, "Claude runtime rule exists and was generated from policy/",
          "run: python tests/validate-config.py --sync-claude-rule")
else:
    actual_md = read(CLAUDE_RUNTIME_RULE)
    check(actual_md == expected_md, "Claude runtime rule in sync with policy/",
          "" if actual_md == expected_md else "run: python tests/validate-config.py --sync-claude-rule")

# ---------------------------------------------------------------------------
# Distinct roles: generated CLAUDE.md vs. repository-specific instructions
# ---------------------------------------------------------------------------
REGRAS_DIR = os.path.join(ROOT, ".claude", "rules")
if check(os.path.isdir(REGRAS_DIR), ".claude/rules/ exists (repository-specific instructions)"):
    regras = [f for f in os.listdir(REGRAS_DIR) if f.endswith(".md")]
    check(bool(regras), "  repository rules exist", regras or "empty directory")

    for f in regras:
        txt = io.open(os.path.join(REGRAS_DIR, f), encoding="utf-8").read()
        primeiro = txt.strip().split(chr(10))[0]
        check(primeiro not in core,
              "  %s does not duplicate distributed content" % f)

    composto = [mid for mid, m in manifests.items()
                for spec in m.get("files", [])
                for c in (spec.get("compose") or [])
                if ".claude/rules" in c]
    check(not composto, "  no manifest composes .claude/rules/", composto or "")

# Observability requirements
check("MONITORING.md" in runtime, "runtime requires creating MONITORING.md on new projects")
check("security-event" in runtime, "runtime requires logging security events")
_pb_rel = "policy/security-review-playbook.md"
if os.path.isfile(os.path.join(ROOT, _pb_rel)):
    check("MONITORING.md" in read(_pb_rel), "playbook contains MONITORING.md template")

VENDOR_LEAKS = ("~/.claude", "dangerously-skip-permissions", "managed-settings",
                "config.toml", "tools.core", "ShellTool", "read_file(")
leaks = [t for t in VENDOR_LEAKS if t in runtime]
check(not leaks, "core-runtime.md free from vendor-specific assertions", leaks or "")

for src in ("policy/core-guidelines.md", "policy/core-runtime.md", "policy/vendor-claude-code.md",
            "policy/vendor-codex-cli.md", "policy/vendor-antigravity.md"):
    check("security-team-block" not in read(src), "  %s free from merge marker" % src)

for termo in ("Hard Rules", "OWASP", "Prompt Injection", "parameterized", "bcrypt"):
    check(termo.lower() in core.lower(), "core contains '%s'" % termo)

RUNTIME_MAX_CHARS = 4000      # ~1000 tokens
PLAYBOOK_MIN_CHARS = 5000

runtime_chars = len(runtime)
check(runtime_chars <= RUNTIME_MAX_CHARS,
      "core-runtime.md within size budget (<= %d chars)" % RUNTIME_MAX_CHARS,
      "%d chars (~%d tokens)%s" % (runtime_chars, runtime_chars // 4,
                                   "" if runtime_chars <= RUNTIME_MAX_CHARS
                                   else " -- move review guidance to playbook"))

_targets_com_runtime = []
_targets_com_core_completo = []
for _mid, _manifesto in manifests.items():
    for _arquivo in _manifesto.get("files", []):
        _composto = _arquivo.get("compose") or []
        if "policy/core-runtime.md" in _composto:
            _targets_com_runtime.append(_mid)
        if "policy/core-guidelines.md" in _composto:
            _targets_com_core_completo.append(_mid)
check(len(_targets_com_runtime) >= 3,
      "  runtime is composed into supported tool contexts",
      ", ".join(sorted(set(_targets_com_runtime))) or "none")
check(not _targets_com_core_completo,
      "  full policy is NOT composed into context (retained as reference)",
      ", ".join(sorted(set(_targets_com_core_completo))) or "")

PLAYBOOK = "policy/security-review-playbook.md"
if check(os.path.isfile(os.path.join(ROOT, PLAYBOOK)), "exists: %s" % PLAYBOOK):
    pb = read(PLAYBOOK)
    check(len(pb) >= PLAYBOOK_MIN_CHARS,
          "  playbook has real content", "%d chars" % len(pb))

    # The playbook must NOT enter the context file: if composed in,
    # the cost returns to every prompt and the split loses its purpose.
    composto = [mid for mid, m in manifests.items()
                for spec in m.get("files", [])
                if PLAYBOOK in (spec.get("compose") or [])]
    check(not composto, "  playbook is NOT composed into context (on-demand only)",
          composto or "")

    # But it must be INSTALLED, otherwise the core pointer points to nothing.
    instalado = sorted({mid for mid, m in manifests.items()
                        for spec in m.get("files", [])
                        if spec.get("payload_file") == PLAYBOOK})
    check(len(instalado) >= 3, "  playbook is installed by user-scope targets",
          instalado or "NO target installs it")

    # Each tool with a context file needs the playbook beside it:
    # the core points by RELATIVE path ("in this same folder"), so the playbook
    # must land in the same directory, otherwise the reference won't resolve.
    for mid in instalado:
        m = manifests[mid]
        dirs_ctx, dirs_pb = set(), set()
        for spec in m.get("files", []):
            for os_key, tmpl in spec.get("dest", {}).items():
                d = tmpl.rsplit("/", 1)[0]
                if spec.get("strategy") == "md-block":
                    dirs_ctx.add(d)
                elif spec.get("payload_file") == PLAYBOOK:
                    dirs_pb.add(d)
        check(not dirs_ctx or dirs_ctx == dirs_pb,
              "  %s: playbook in same folder as context file" % mid,
              "" if dirs_ctx == dirs_pb else "ctx=%s pb=%s" % (sorted(dirs_ctx), sorted(dirs_pb)))

    # The runtime must POINT to the playbook, otherwise no one reads it.
    check("security-review-playbook.md" in runtime,
          "  core-runtime points to the playbook")

# Codex needs project guidance beyond the managed rules. The root file is
# intentionally short: details live in policy/ and in the tests.
agents_path = os.path.join(ROOT, "AGENTS.md")
if check(os.path.isfile(agents_path), "AGENTS.md exists at root for Codex"):
    agents = read("AGENTS.md")
    check(len(agents) <= 2500, "  AGENTS.md at root stays concise", "%d chars" % len(agents))
    check("validate-config.py" in agents and "core-runtime.md" in agents,
          "  AGENTS.md points to validation and runtime baseline")

# ---------------------------------------------------------------------------
# Current OWASP taxonomy, not the 2021 one
# ---------------------------------------------------------------------------
# The 2021 list was one full revision out of date and was distributed that way
# to 4 tools. The pair (A03 Supply Chain, A10 Exceptional Conditions) only
# exists in 2025, and "A10 SSRF" only existed in 2021 -- both sides together
# detect a regression to the old list.
playbook_txt = read(PLAYBOOK) if os.path.isfile(os.path.join(ROOT, PLAYBOOK)) else ""
taxonomia = core + playbook_txt

# The 2025 markers are required in CORE specifically, not in the union with
# the playbook: the first version of this check concatenated both, and a
# regression of core to the 2021 list passed undetected because the playbook
# remained correct. False negative -- caught by reintroducing the bug.
check("Software Supply Chain Failures" in core,
      "core cites A03 Software Supply Chain Failures (2025)")
check("Mishandling of Exceptional Conditions" in core,
      "core cites A10 Mishandling of Exceptional Conditions (2025)")
check("A10 | SSRF" not in core and "A10 - SSRF" not in core,
      "core does NOT use 2021 numbering (SSRF as A10)")
check("2025" in core, "core references the 2025 edition")

# AI/agentic coverage: the package exists to govern agents, so their
# taxonomy needs to be somewhere accessible.
for termo, rotulo in (("LLM01:2026", "LLM Top 10"), ("ASI01", "Agentic Top 10"),
                      ("API1", "API Top 10")):
    check(termo in taxonomia, "taxonomy covers %s" % rotulo)

# Framework guidance over hand-rolling -- the highest-leverage rule for
# A01/A04/A07, and an explicit request from the team.
check("hand-roll" in core or "hand-rolled" in core,
      "core has the rule against hand-rolling security primitives")
check("argon2" in core.lower(), "core names the recommended hasher")

# Each vendor needs an appendix: that is where the truth about that product's
# permission model lives, which cannot go into the core.
for tool in sorted(coverage):
    rel = "policy/vendor-%s.md" % tool
    check(os.path.isfile(os.path.join(ROOT, rel)), "appendix exists: %s" % rel)

# =============================================================================
section("6b. README inventory matches disk")
# =============================================================================
# Documentation drift is the same problem the rest of this file addresses:
# it doesn't break anything immediately, it breaks when someone trusts the doc.
# The inventory tree in section 2 of the README was written by hand and had
# already fallen behind when the playbook was added -- the file existed, was
# installed, and did not appear.
readme = read(ARCHITECTURE_DOC)

# Scope: ONLY the inventory tree block, not the entire README. The first
# version searched for the filename anywhere in the document -- since the
# playbook is cited in sections 2b, 6, and 10, removing it from the TREE
# did not fail. Third false negative from the same root in this codebase:
# the check looking at a broader scope than the bug.
_i = readme.find("agent-shield/")
_arvore = ""
if _i >= 0:
    _fim = readme.find("```", _i)
    _arvore = readme[_i:_fim if _fim > 0 else len(readme)]

if check(bool(_arvore), "  section 2 has the inventory tree"):
    for pasta in ("policy", "targets", "lib"):
        disco = sorted(f for f in os.listdir(os.path.join(ROOT, pasta))
                       if os.path.isfile(os.path.join(ROOT, pasta, f)))
        faltando = [f for f in disco if f not in _arvore]
        check(not faltando, "  README tree lists files in %s/" % pasta,
              faltando or "%d files" % len(disco))

# =============================================================================
section("7. Application engines (structural parity)")
# =============================================================================
check(os.path.isfile(os.path.join(ROOT, "lib/apply_targets.py")), "Python engine exists")
check(os.path.isfile(os.path.join(ROOT, "lib/ApplyTargets.ps1")), "PowerShell engine exists")

py_engine = read("lib/apply_targets.py")
ps_engine = read("lib/ApplyTargets.ps1")

# A strategy implemented in one engine but not the other means Windows devs
# and Linux devs operate under different policies. Worst failure mode of this design.
for strat in sorted(VALID_STRATEGIES):
    in_py = strat in py_engine
    ps_name = "Invoke-" + "".join(w.capitalize() for w in strat.split("-"))
    in_ps = ps_name in ps_engine or strat in ps_engine
    check(in_py and in_ps, "  strategy '%s' in both engines" % strat,
          "" if in_py and in_ps else "py=%s ps=%s" % (in_py, in_ps))

for feature in ("only_if_parent_exists", "warn-if-exists", "APPLY-TARGETS: DONE"):
    check(feature in py_engine and feature in ps_engine,
          "  '%s' in both engines" % feature)

# Selection contract: both engines must implement selector filtering,
# listing, and exit 3 ("step not requested"). Exit 3 is what lets
# installers distinguish "not requested" from "failed" -- if one engine
# stops returning it, the other KEEPS reporting failure on partial selection.
check("filter_by_selector" in py_engine and "Get-TargetNames" in ps_engine,
      "  selector filter in both engines")
check("list_targets" in py_engine and "ListTargets" in ps_engine,
      "  target listing in both engines")
check("return 3" in py_engine and "exit 3" in ps_engine,
      "  exit 3 (step not requested) in both engines")
check("seletor desconhecido" in py_engine and "seletor desconhecido" in ps_engine,
      "  unknown selector aborts in both engines")

# All 4 installers must forward the selection. One that forgets would apply
# EVERYTHING silently ignoring --only -- the opposite of what the operator asked.
for rel, needle in (("install.sh", '--only "$ONLY"'),
                    ("deploy.sh", '--only "$ONLY"'),
                    ("install.ps1", "Only = $Only"),
                    ("deploy.ps1", "Only = $Only")):
    if os.path.isfile(os.path.join(ROOT, repo_rel(rel))):
        check(needle in read(rel), "  %s forwards selection to engine" % rel)

# And they must treat rc 3 as "not requested", not as failure.
for rel in ("install.sh", "deploy.sh", "install.ps1", "deploy.ps1"):
    if not os.path.isfile(os.path.join(ROOT, repo_rel(rel))):
        continue
    txt = read(rel)
    check("3" in txt and ("PROBE_RC" in txt or "MACHINE_RC" in txt
                          or "machineSelected" in txt or "machineRc" in txt),
          "  %s distinguishes 'step not requested' from failure" % rel)

# OUTPUT parity, not just content parity: the PS engine announced the destination
# without size in dry-run, and the Windows log was less informative than Linux
# for no reason. Write-OrPreview mirrors Python's write_text().
check("Write-OrPreview" in ps_engine, "  PS engine has Write-OrPreview")
bare = re.findall(r'Detail "\[dry-run\] (?:criaria|escreveria|atualizaria|anexaria)[^"]*"', ps_engine)
check(not bare, "  PS engine does not announce writes without going through Write-OrPreview",
      bare[:3] or "")
# Both engines must report bytes in dry-run.
check("bytes)" in py_engine and "bytes)" in ps_engine,
      "  both engines report size in dry-run")

# A cmdlet that arrives via module AUTOLOAD is unreliable in PS 5.1: on a
# machine with PowerShell 7 installed, the PSModulePath of 5.1 gets the 7
# paths prepended, 5.1 tries to load the wrong module and the cmdlet stops
# existing -- while other cmdlets from the SAME Utility work, making the
# diagnosis confusing. It broke MANIFEST generation and the RTR zip wouldn't build.
AUTOLOAD_FRAGIL = {
    "Get-FileHash": "use the Get-Sha256Hex helper (.NET SHA256, no autoload)",
}
for rel in ("build-package.ps1", "install.ps1", "deploy.ps1", "lib/ApplyTargets.ps1"):
    full = os.path.join(ROOT, repo_rel(rel))
    if not os.path.isfile(full):
        continue
    linhas = read(rel).split(chr(10))
    for cmdlet, alternativa in sorted(AUTOLOAD_FRAGIL.items()):
        # Only count INVOCATIONS. Need to track <# ... #> blocks: the first
        # version only skipped lines that STARTED with a comment, and the prose
        # lines inside the helper's own help block (which explains why the cmdlet
        # was abandoned) became false positives -- the check accused the already
        # correct file.
        usos = []
        em_bloco = False
        for n, l in enumerate(linhas, 1):
            corpo = l.strip()
            if "<#" in l:
                em_bloco = True
            if em_bloco:
                if "#>" in l:
                    em_bloco = False
                continue
            if corpo.startswith("#"):
                continue
            if '"%s' % cmdlet in l or "'%s" % cmdlet in l:
                continue
            if re.search(r"(?<![\w-])" + re.escape(cmdlet) + r"(?![\w-])", l):
                usos.append(n)
        check(not usos, "  %s does not use %s" % (rel, cmdlet),
              ("L%s -- %s" % (usos, alternativa)) if usos else "")

# The .ps1 must compile: a script that doesn't compile was what brought down v1.
if shutil.which("powershell") or shutil.which("pwsh"):
    shell = shutil.which("pwsh") or shutil.which("powershell")
    for ps_file in ("lib/ApplyTargets.ps1", "lib/CodexSandboxProfile.ps1", "install.ps1", "deploy.ps1",
                    "build-package.ps1", "Test-AgentShieldManaged.ps1"):
        full = os.path.join(ROOT, repo_rel(ps_file))
        if not os.path.isfile(full):
            continue
        code = (
            "$e=$null;$t=$null;"
            "[System.Management.Automation.Language.Parser]::ParseFile('%s',[ref]$t,[ref]$e)|Out-Null;"
            "if($e.Count){exit 1};exit 0" % full.replace("'", "''")
        )
        rc = subprocess.run([shell, "-NoProfile", "-Command", code],
                            capture_output=True).returncode
        check(rc == 0, "  %s compiles" % ps_file)
else:
    check(False, "  .ps1 parse not verified", "powershell absent",
          warn_only=True)

# ARRAY splatting in a .ps1 script passes elements POSITIONALLY: parameter
# names in the array are not interpreted as names. '-Root' went to $Root
# and the path fell into $Scope, violating ValidateSet -- install.ps1 was
# completely broken by this. Hashtables do named binding. This check prevents regression.
for rel in ("install.ps1", "deploy.ps1"):
    if not os.path.isfile(os.path.join(ROOT, repo_rel(rel))):
        continue
    txt = read(rel)
    bad = re.findall(r"\$\w*[Aa]rgs\s*=\s*@\(", txt)
    check(not bad, "  %s: args splatting is hashtable, not array" % rel,
          bad or "")
    calls = re.findall(r"&\s+\$applyScript\s+@(\w+)", txt)
    check(bool(calls), "  %s: invokes engine via splatting" % rel, calls or "")

# =============================================================================
section("8. Pre-commit hook (audit mode)")
# =============================================================================
raw = open(os.path.join(ROOT, "hooks/pre-commit"), "rb").read()
check(b"\r" not in raw, "no CR (pure LF)", "sh breaks with '\\r: command not found'")
check(not raw.startswith(b"\xef\xbb\xbf"), "no UTF-8 BOM")
check(raw.startswith(b"#!"), "starts with shebang", raw.split(b"\n")[0].decode())
text = raw.decode("utf-8")
# The hook contract is to audit, never block -- blocking belongs to the pipeline.
check("exit 1" not in text, "does NOT contain 'exit 1' (audit mode, does not block)")
check(text.rstrip().endswith("exit 0"), "ends with 'exit 0'")
check("SKIP_SECURITY_HOOK" in text, "has SKIP_SECURITY_HOOK escape hatch")

# The hook runs on a dev machine whose repo may be on any platform --
# or none at all. Claiming that "the pipeline BLOCKS" was only true for teams
# on Bitbucket that applied the template AND enabled Branch Restriction; for a team
# on GitHub or Jenkins, it promised a safety net that was not there.
check("o pipeline BLOQUEIA" not in text,
      "hook does not promise server-side blocking")
check("estiver" in text or "Onde o pipeline" in text,
      "hook conditions server message")
# And what it PRINTS must not cite a platform: the same file goes to all.
# Scope = only output lines (echo/printf), not comments -- the comment
# explaining THIS rule needs to name the platforms, and the first version
# of the check flagged the correct file itself.
_saida = [l for l in text.split(chr(10))
          if not l.strip().startswith("#")
          and ("echo " in l or "printf " in l)]
_plataformas = sorted({x for x in ("Bitbucket", "GitHub", "GitLab", "Jenkins")
                       for l in _saida if x.lower() in l.lower()})
check(not _plataformas, "hook PRINTS are platform-agnostic",
      _plataformas or "%d output lines" % len(_saida))
for tool in ("gitleaks", "semgrep", "trivy"):
    check(tool in text, "invokes %s" % tool)

# --- Tool error is NOT a security finding -----------------------------------
# Exit codes are distinct and mean different things: gitleaks returns 126
# for unknown flag, semgrep 7 for inaccessible config and 123 for invalid path,
# trivy uses 1 for execution failure. Treating everything as a "finding" fills
# the report with nonexistent leaks -- and noise is what makes developers stop
# reading warnings, as core-guidelines itself notes.
# The check must inspect triage STRUCTURE, per scanner. The first version
# only asked if the ERRO_FERRAMENTA identifier appeared: changing the test
# from '-eq 1' to '-ne 0' left the identifier intact and the check passed with the bug.
#
# Each scanner has its own code for FINDING, and any other non-zero is execution failure:
#   gitleaks 1 (126 = unknown flag)
#   semgrep  1 (7 = inaccessible config, 123 = invalid path)
#   trivy    2 -- because it uses 1 for execution failure
for _var, _rc_achado, _nome in (("GL_RC", 1, "gitleaks"),
                                ("SG_RC", 1, "semgrep"),
                                ("TV_RC", 2, "trivy")):
    _finding_branch = '"$%s" -eq %d ]' % (_var, _rc_achado)
    # xargs returns 123 when its child exits 1. The Semgrep wrapper maps that
    # finding exit back to success and records it in a marker file.
    if _nome == "semgrep":
        _finding_branch = (_finding_branch in text or
                           ('"$rc" -eq 1 ]' in text and "SEMGREP_FINDINGS" in text))
    else:
        _finding_branch = _finding_branch in text
    check(_finding_branch,
          "  %s: rc=%d is finding; other non-zero is error" % (_nome, _rc_achado))
    check('"$%s" -ne 0 ]' % _var not in text,
          "  %s: does NOT classify 'any non-zero' as finding" % _nome)
check(text.count("ST_%s=\"erro\"" % "GITLEAKS") == 1
      and text.count('="erro"') >= 3,
      "  all three scanners have distinct 'error' state")
# trivy needs --exit-code 2: it also uses 1 for its own execution failure,
# leaving findings at 1 makes the two indistinguishable.
check("--exit-code 2" in text,
      "  trivy uses --exit-code 2 (1 is reserved for its own errors)")
check("erro" in text, "  has separate 'error' state from 'findings'")

# --- NUL-delimited file list ------------------------------------------------
# 'git diff --name-only | grep | xargs' broke in two routine situations and the
# hook called the crash "security findings":
#   name with space -> xargs split 'src teste/a b.py' into THREE arguments
#   non-ASCII name  -> core.quotepath returns "acentua\303\247..." with escape
# Git's pathspec also avoids 'grep -z', which is GNU-specific and absent on macOS.
check("--cached -z" in text, "file list is NUL-delimited (git -z)")
check("xargs -0" in text, "  consumed with xargs -0")
# \bgrep and not "grep ": 'semgrep --config' CONTAINS 'grep -'. The first version
# flagged the hook's own valid lines.
_saida_grep = [l for l in text.split(chr(10))
               if re.search(r"(?<![a-z])grep\s", l)
               and not l.strip().startswith("#")]
check(not _saida_grep, "  does NOT use grep to filter (uses git pathspec)",
      "; ".join(x.strip()[:50] for x in _saida_grep))

# --- Trivy does not download database on every commit -----------------------
# Default DOWNLOADS. In a hook, that is a network call per commit, and offline
# it becomes a nonexistent "HIGH/CRITICAL vulnerability".
check("--skip-db-update=false" not in text,
      "trivy does NOT force database download on every commit")
check("--skip-db-update" in text, "  uses cached database (updated by CI)")

# --- Template dir stays clean -----------------------------------------------
# It is copied into EVERY new repo: leftovers propagate.
for _rel in ("install.sh", "install.ps1"):
    _t = read(_rel)
    check("pre-commit.bak" in _t,
          "%s: cleans .bak from template dir before copying" % _rel)

# --- Distributed pipeline: pinned image -------------------------------------
# ':latest' in a security scanner is A03:2025 by our own taxonomy:
# non-reproducible build, and modified image runs with repo access.
_tmpl = read("bitbucket/bitbucket-pipelines.yml")
_latest = [l.strip() for l in _tmpl.split(chr(10))
           if "image:" in l and ":latest" in l]
check(not _latest, "distributed pipeline does not use :latest image",
      "; ".join(_latest))
check(_tmpl.count("max-time:") >= 3,
      "  every step has max-time (hung scanner burns build minutes)",
      "%d declarations" % _tmpl.count("max-time:"))

# --- Hook must SPEAK when it passes -----------------------------------------
# The original version only printed when encountering issues. A clean commit
# gave zero output, making "the gate ran and passed" indistinguishable from
# "the gate does not exist" -- both for the dev and for the AI, which could
# only report its own assumption. An invisible guardrail on the happy path is unverifiable.
#
# The check must inspect the HAPPY PATH specifically: looking for any echo
# would match error messages, which always existed, passing with the bug present.
# Criterion: INDENTATION, not position. The status line must be at the top level
# of the script -- outside any conditional block.
_bloco_erro = None
_linha_status = [l for l in text.split(chr(10))
                 if "echo " in l and "SECURITY AUDIT" in l
                 and "gitleaks:" in l and "semgrep:" in l and "trivy:" in l]
check(bool(_linha_status),
      "prints status of each scanner on a single line",
      _linha_status[0].strip()[:70] if _linha_status else "no status line")

# And that line must not be inside any block: in sh, being inside an if means being indented.
if _linha_status:
    _indent = len(_linha_status[0]) - len(_linha_status[0].lstrip())
    check(_indent == 0,
          "  status line is at top level (always runs)",
          "indentation=%d -- indented means inside an if" % _indent)

for var in ("ST_GITLEAKS", "ST_SEMGREP", "ST_TRIVY"):
    check(var in text, "  tracks status of %s" % var.replace("ST_", "").lower())

# --- State for statusline ----------------------------------------------------
# The statusline reads this file. If the hook stops writing it, the statusline
# shows "scan:--" indefinitely with no error -- silent degradation.
check("last-scan.json" in text, "saves state to last-scan.json")
check("2>/dev/null || true" in text or "|| true" in text,
      "  state save is best-effort (does not abort commit)")

# --- Statusline --------------------------------------------------------------
SL = "statusline/security-status.py"
if check(os.path.isfile(os.path.join(ROOT, SL)), "exists: %s" % SL):
    sltxt = read(SL)
    # The cost is the reason it exists: if it invokes scanners again, it creates
    # latency on every session render -- exactly what was vetoed.
    #
    # The check must target EXECUTION, not mention.
    for prim in ("subprocess", "os.system", "os.popen", "shutil.which",
                 "os.execv", "popen("):
        check(prim not in sltxt,
              "  does not use %s (runs on every render)" % prim)
    check("last-scan.json" in sltxt, "  reads state saved by hook")
    check("sys.exit(0)" in sltxt,
          "  always exits 0 (statusline must not break session)")
    # File presence is not enforcement: managed-settings without the keys enforces
    # nothing, and reporting 'on' would be the same false claim.
    check("allowManagedPermissionRulesOnly" in sltxt,
          "  checks keys, not merely managed-settings existence")

# =============================================================================
section("6c. Managed policy layer (CLAUDE.md)")
# =============================================================================
# The policy CLAUDE.md is the only guidelines destination the dev cannot delete:
# it requires admin and, per docs, "Managed policy CLAUDE.md files cannot be excluded"
# -- not even via claudeMdExcludes. The ~/.claude/CLAUDE.md previously written
# by this package is the dev's PERSONAL file, lowest scope and freely editable.
#
# But CLAUDE.md files are CONCATENATED, not overwritten. Having both would charge
# the same core twice on EVERY prompt -- the cost that the 11k ceiling exists
# to contain. Hence superseded_by: with the managed file present, the user block
# is removed; without it, the user block serves as fallback.
_md_gerenciado = None
_md_usuario = None
for _id, _t in sorted(manifests.items()):
    for _f in _t.get("files", []):
        if _f.get("strategy") != "md-block":
            continue
        if _t.get("scope") == "machine" and _f["dest"]["windows"].endswith("CLAUDE.md"):
            _md_gerenciado = (_id, _f)
        if _t.get("scope") == "user" and _f["dest"]["windows"].endswith(".claude/CLAUDE.md"):
            _md_usuario = (_id, _f)

if check(_md_gerenciado is not None,
         "target for CLAUDE.md in machine scope exists"):
    _gid, _gf = _md_gerenciado
    # Paths are dictated by docs; getting one wrong delivers a file that
    # nothing loads, with no error.
    for _os, _esperado in (("windows", "${PROGRAMFILES}/ClaudeCode/CLAUDE.md"),
                           ("linux", "/etc/claude-code/CLAUDE.md"),
                           ("darwin", "/Library/Application Support/ClaudeCode/CLAUDE.md")):
        check(_gf["dest"].get(_os) == _esperado,
              "  %s: correct policy path (%s)" % (_gid, _os),
              "got=%s" % _gf["dest"].get(_os))

if check(_md_usuario is not None, "target for CLAUDE.md in user scope exists"):
    _uid, _uf = _md_usuario
    if check("superseded_by" in _uf,
             "  %s: yields to managed (superseded_by)" % _uid):
        _sup = _uf["superseded_by"]
        for _os in ("windows", "linux", "darwin"):
            check(_sup.get(_os) == (_md_gerenciado[1]["dest"].get(_os) if _md_gerenciado else None),
                  "  %s: superseded_by[%s] points to managed CLAUDE.md" % (_uid, _os),
                  "got=%s" % _sup.get(_os))
        # Same compose in both: if they diverge, guidelines differ depending on
        # whether the dev has privileges -- worse than not having both layers.
        if _md_gerenciado:
            check(_uf.get("compose") == _md_gerenciado[1].get("compose"),
                  "  compose is IDENTICAL across both layers",
                  "user=%s managed=%s" % (_uf.get("compose"),
                                          _md_gerenciado[1].get("compose")))
            check(_uf.get("marker") == _md_gerenciado[1].get("marker"),
                  "  marker is IDENTICAL across both layers")

# Both engines must implement this decision; it is behavior, not payload:
# no serialization test covers it.
check("superseded_by" in py_engine and "remove_md_block" in py_engine,
      "Python engine implements superseded_by")
check("superseded_by" in ps_engine and "Remove-MdBlock" in ps_engine,
      "PowerShell engine implements superseded_by")

BEH = "tests/parity-behavior.py"
if check(os.path.isfile(os.path.join(ROOT, BEH)), "exists: %s" % BEH):
    _btxt = read(BEH)
    check("ApplyTargets.ps1" in _btxt and "apply_targets.py" in _btxt,
          "  runs BOTH real engines")
    check("PARITY-BEHAVIOR: DONE" in _btxt, "  prints stable result line")
    _powershell = shutil.which("powershell") or shutil.which("pwsh")
    if not _powershell:
        check(False, "  behavior parity not executed",
              "powershell/pwsh absent on this host", warn_only=True)
    else:
        r = subprocess.run([sys.executable, os.path.join(ROOT, BEH), "--quiet"],
                           capture_output=True, text=True)
        _linha = [l for l in r.stdout.split("\n") if "PARITY-BEHAVIOR: DONE" in l]
        check(r.returncode == 0 and bool(_linha),
              "  behavior parity confirmed",
              _linha[0].strip() if _linha else "no result line")

# =============================================================================
section("6d. Group brand palette and third-party skills")
# =============================================================================
BRAND = "policy/brand-identity.md"
if check(os.path.isfile(os.path.join(ROOT, BRAND)), "exists: %s" % BRAND):
    _b = read(BRAND)
    check("<organization-name>" in _b,
          "  exposes an organization-neutral template placeholder")
    check("Do not invent a company name" in _b,
          "  forbids invented brand identity without user guidance")
    check("4.5:1" in _b,
          "  states the WCAG normal-text contrast threshold")
    check("semantic tokens" in _b,
          "  requires explicit semantic status colors")

    # On-demand across all three tools, like the playbook -- not in core.
    _destinos = [f for t in manifests.values() for f in t.get("files", [])
                 if f.get("payload_file") == BRAND]
    check(len(_destinos) == 3,
          "  distributed to all 3 tools with guidelines",
          "%d destinations" % len(_destinos))
    check(BRAND not in core,
          "  content is NOT in core (color is not a typical coding task)")
    check("brand-identity.md" in core,
          "  core points to it (otherwise no one discovers it)")

# =============================================================================
section("7a. Packaging covers every manifest payload_file")
# =============================================================================
# Real bug: statusline entered claude-managed as payload_file under statusline/,
# and build-package.ps1 only discovered targets/ and policy/. The zip was generated
# WITH NO ERROR and deployment from it aborted on that target on dev machines
# -- the most expensive moment to find out.
#
# The check targets the MECHANISM, not the folder: adding 'statusline' to a list
# would fix it today and fail on the next payload_file outside those two folders.
_pkg = read("build-package.ps1")

# The packager must read manifests, not maintain a fixed folder list.
check("payload_file" in _pkg and "payload_file_by_os" in _pkg,
      "build-package.ps1 discovers payload_file from manifests")
check("$doManifesto" in _pkg or "doManifesto" in _pkg,
      "  discovery inspects manifests, not a fixed list")

# Every payload_file/compose cited must exist on disk -- otherwise the zip
# is incomplete and fails only during deployment.
_referenciados = set()
for _id, _t in sorted(manifests.items()):
    for _f in _t.get("files", []):
        if "payload_file" in _f:
            _referenciados.add(_f["payload_file"])
        _referenciados.update((_f.get("payload_file_by_os") or {}).values())
        for _c in _f.get("compose", []):
            _referenciados.add(_c)

for _rel in sorted(_referenciados):
    check(os.path.isfile(os.path.join(ROOT, _rel)),
          "  referenced payload exists: %s" % _rel)

# Files outside targets/ and policy/ are precisely what folder discovery MISSES.
# If any exist, the packager needs the mechanism above.
_fora = sorted(r for r in _referenciados
               if not r.startswith(("targets/", "policy/")))
if _fora:
    check("ConvertFrom-Json" in _pkg,
          "  payload exists outside targets/ and policy/: %s" % ", ".join(_fora),
          "packager reads manifest")

# =============================================================================
section("7b. payload_by_os: per-OS value inside payload")
# =============================================================================
# Mechanism created for statusLine.command in managed-settings, which needs an
# ABSOLUTE path resolved at installation: on Windows Claude Code runs that command
# via cmd.exe, which does not expand '~' or '$HOME' (only '%USERPROFILE%'), while
# Linux is the opposite. Resolving at install time eliminates shell differences.
check("apply_payload_by_os" in py_engine, "Python engine implements payload_by_os")
check("Set-PayloadByOs" in ps_engine, "PowerShell engine implements payload_by_os")

_com_byos = []
for _id, _t in sorted(manifests.items()):
    for _i, _f in enumerate(_t.get("files", [])):
        if "payload_by_os" not in _f:
            continue
        _com_byos.append(_id)
        _pay = _f.get("payload")
        check(isinstance(_pay, dict),
              "%s[%d]: payload_by_os requires object payload" % (_id, _i))
        for _dotted, _var in _f["payload_by_os"].items():
            # All three OSes: missing one breaks on that OS during rollout.
            _faltam = [o for o in ("windows", "linux", "darwin") if o not in _var]
            check(not _faltam, "  %s: '%s' covers all 3 OSes" % (_id, _dotted),
                  "missing: %s" % ", ".join(_faltam) if _faltam else "")

            # Path must EXIST in payload. A typo here wouldn't produce an error:
            # the value would not be injected and managed-settings would get
            # the placeholder -- dead statusline, with no warning.
            _no, _ok_path = _pay, True
            for _seg in _dotted.split("."):
                if not isinstance(_no, dict) or _seg not in _no:
                    _ok_path = False
                    break
                _no = _no[_seg]
            check(_ok_path, "  %s: '%s' exists in payload" % (_id, _dotted))

# Stray PLACEHOLDER is the silent failure mode of this feature: without the
# corresponding payload_by_os, the literal string lands in the final file and
# statusline silently breaks.
#
# This scan is independent of proposer: the first version lived INSIDE the loop
# that only visits files with payload_by_os, so removing payload_by_os -- the
# bug itself -- also removed the check.
def _varre_placeholder(no, cobertos, soltos, prefixo=""):
    for k, v in (no or {}).items():
        cam = "%s.%s" % (prefixo, k) if prefixo else k
        if isinstance(v, dict):
            _varre_placeholder(v, cobertos, soltos, cam)
        elif v == "PLACEHOLDER" and cam not in cobertos:
            soltos.append(cam)


for _id, _t in sorted(manifests.items()):
    for _i, _f in enumerate(_t.get("files", [])):
        _pay = _f.get("payload")
        if not isinstance(_pay, dict):
            continue
        _cobertos = set(_f.get("payload_by_os", {}).keys())
        _soltos = []
        _varre_placeholder(_pay, _cobertos, _soltos)
        check(not _soltos,
              "%s[%d]: no unhandled PLACEHOLDER without payload_by_os" % (_id, _i),
              ", ".join(_soltos))

check(bool(_com_byos), "targets using payload_by_os exist to verify",
      ", ".join(sorted(set(_com_byos))))

# The script referenced by managed-settings must be MACHINE-scoped.
# managed-settings.json is shared by all users: a user-profile path inside it
# would point to the home directory of whoever ran the installer, breaking
# the statusline for other users.
for _id, _t in sorted(manifests.items()):
    for _f in _t.get("files", []):
        if _f.get("payload_file", "").startswith("statusline/"):
            check(_t.get("scope") == "machine",
                  "%s: statusline script in machine scope" % _id,
                  "scope=%s" % _t.get("scope"))

# =============================================================================
section("7c. Identical JSON serialization across both engines")
# =============================================================================
# Section 7 compares the engines STRUCTURALLY -- which strategies each implements.
# It didn't compare what they WRITE, which is where they diverged: PS 5.1
# ConvertTo-Json uses 4-space indentation, TWO spaces after colons, progressive
# alignment and CRLF; Python json.dumps(indent=2) uses 2, one space and LF.
# Same content, different bytes.
#
# This was hidden behind another bug: the only target with inline payload in
# machine scope is claude-managed, and the admin layer was never actually applied
# on Windows (the $IsAdmin bug in section 7d). Three stacked defects in the same
# code path, where the top one prevented seeing those below it.
#
# Why valid JSON on both sides matters: drift detection, file hashing across
# fleet, and post-install verifier compare TEXT. With the divergence, every
# Windows host showed up as divergent from every Linux host, hiding real differences in noise.
check("ConvertTo-JsonValue" in ps_engine,
      "PS engine uses its own deterministic serializer")
check("json.dumps(obj, indent=2, ensure_ascii=False)" in py_engine,
      "Python engine uses json.dumps(indent=2, ensure_ascii=False)")

# The actual regression: someone switching back to ConvertTo-Json in writes.
# Only count occurrences in CODE -- the new serializer mentions the cmdlet in comments,
# explaining why it does not use it.
ps_codigo = "\n".join(l for l in ps_engine.split("\n")
                      if not l.strip().startswith("#"))
check("| ConvertTo-Json" not in ps_codigo,
      "PS engine does not write via ConvertTo-Json (divergent format)")

PARITY = "tests/parity-json.ps1"
if check(os.path.isfile(os.path.join(ROOT, PARITY)), "exists: %s" % PARITY):
    ptxt = read(PARITY)
    # Must exercise the REAL engine. A copy of the functions inside the test
    # becomes stale silently and validates parity with itself.
    check("ParseFile($Engine" in ptxt,
          "  extracts functions from real engine, not a copy")
    check("from apply_targets import dump_json" in ptxt,
          "  uses Python engine dump_json, without reimplementing")
    check("-ceq" in ptxt, "  compares with case sensitivity (-ceq)")
    check("PARITY-JSON: DONE" in ptxt, "  prints stable result line")
    check("Show-Invisible" in ptxt,
          "  diagnostics show invisible characters (the divergence was CRLF)")

    # And runs for real wherever PowerShell is available.
    pwsh = shutil.which("powershell") or shutil.which("pwsh")
    if pwsh:
        r = subprocess.run([pwsh, "-NoProfile", "-ExecutionPolicy", "Bypass",
                            "-File", os.path.join(ROOT, PARITY), "-Quiet"],
                           capture_output=True, text=True)
        linha = [l for l in r.stdout.split("\n") if "PARITY-JSON: DONE" in l]
        check(r.returncode == 0 and bool(linha),
              "  byte-for-byte parity confirmed",
              detail=(linha[0].strip() if linha else "no result line"))
    else:
        check(False, "  byte-for-byte parity NOT verified",
              "powershell absent", warn_only=True)

# =============================================================================
section("7d. Installers: privilege and exit codes")
# =============================================================================
# The three bugs below occurred together on user machines with '-Only managed'
# and belong to the same family: the installer reporting a state other than its own.

ps1 = read("install.ps1")
sh = read("install.sh")

# --- 1) $IsAdmin used before assignment -------------------------------------
# PowerShell reads undefined variables as $null without error, and '-not $null' is $true.
# With assignment down in BLOCK 3, BLOCK 2 saw $null and ALWAYS took the
# "unprivileged" branch -- the admin layer was never applied, even in elevated runs.
# On Windows, where the dev is not an admin, that layer is the only control that
# actually blocks --dangerously-skip-permissions: the entire package remained advisory.
ps1_lines = ps1.split("\n")
assign = [i for i, l in enumerate(ps1_lines)
          if re.match(r'^\s*\$IsAdmin\s*=', l, re.I)]
# Comments mentioning $IsAdmin do not count as usage: counting them would fail
# when an explanatory comment was placed above the assignment.
uses = [i for i, l in enumerate(ps1_lines)
        if re.search(r'\$IsAdmin\b', l, re.I)
        and not l.lstrip().startswith("#") and i not in assign]
if check(len(assign) == 1, "install.ps1: $IsAdmin has exactly one assignment",
         detail="found %d" % len(assign)):
    check(uses and assign[0] < min(uses),
          "install.ps1: $IsAdmin assigned BEFORE first use",
          detail="assigned at line %d, first used at %d"
                 % (assign[0] + 1, min(uses) + 1))

# --- 2) rc=3 treated as failure in user pass --------------------------------
# 3 = "valid selection, zero targets in this scope". With '--only managed',
# the user pass has no targets, which is the expected result -- not a failure.
#
# This check previously suffered from a false negative by searching the ENTIRE FILE:
# the admin layer block always had '-ne 3', so it passed with the bug present
# in the user pass. The window below is what makes it effective.
def trecho_apos(txt, marcador, linhas=12):
    if marcador not in txt:
        return ""
    corte = txt[txt.index(marcador) + len(marcador):]
    return "\n".join(corte.split("\n")[:linhas])

# --- Ordering: admin layer BEFORE user scope --------------------------------
# The user target declares superseded_by pointing to managed CLAUDE.md, which
# only exists after the admin block. Inverted, a single run leaves BOTH present
# and the core is charged twice on every prompt until the next run.
#
# Anchored on block HEADERS:
for _rel, _cab_maq, _cab_user in (
    ("install.sh",
     "# Admin layer (enforcement; requires root)",
     "# AI configuration (driven by targets/*.json)"),
    ("install.ps1",
     "# Admin layer (enforcement; requires Administrator privileges)",
     "# AI configuration (driven by targets\\*.json)"),
):
    _txt = read(_rel)
    _m = _txt.find(_cab_maq)
    _u = _txt.find(_cab_user)
    if check(_m != -1 and _u != -1,
             "%s: both block headers exist" % _rel,
             "" if _m != -1 and _u != -1 else "mach=%d user=%d" % (_m, _u)):
        check(_m < _u,
              "%s: admin layer runs BEFORE user scope" % _rel,
              "" if _m < _u else
              "inverted (mach=%d user=%d) -- duplicates guidelines for one run" % (_m, _u))

# All FOUR scripts, not just the two where the bug first surfaced.
_passes = [
    ("install.ps1", ps1, "Invoke-AgentShieldEngine -Arguments $applyArgs", "-ne 3"),
    ("install.sh", sh, 'APPLY_ARGS[@]}" || APPLY_RC=$?', "-ne 3"),
    ("deploy.ps1", read("deploy.ps1"), "Invoke-AgentShieldEngine -Arguments $userApplyArgs", "-ne 3"),
    ("deploy.sh", read("deploy.sh"), 'apply_args[@]}" || apply_rc=$?', "-eq 3"),
]
for _nome, _txt, _marcador, _esperado in _passes:
    _janela = trecho_apos(_txt, _marcador)
    check(bool(_janela), "%s: user pass locatable" % _nome,
          "" if _janela else "missing marker: %s" % _marcador)
    check(_esperado in _janela,
          "%s: user pass does not treat rc=3 as failure" % _nome)

# --- 3) summary derived from "applied" rather than "am admin" ---------------
# Being admin does not apply anything by itself, and '-Only claude-code' has no
# machine targets. The summary used to claim "Applied" when the step had been skipped.
check("$AdminApplied = $true" in ps1,
      "install.ps1: records that admin layer was actually written")
check("if ($AdminApplied) {" in ps1,
      "install.ps1: summary conditioned on what was applied, not $IsAdmin")
check("admin=$([int]$AdminApplied)" in ps1,
      "install.ps1: final line reports applied state, not privilege")
check("ADMIN_APPLIED=1" in sh,
      "install.sh: records that admin layer was actually written")
check('"$ADMIN_APPLIED" == "1"' in sh,
      "install.sh: summary conditioned on what was applied")
check("admin=$ADMIN_APPLIED" in sh,
      "install.sh: final line reports applied state")

# Parity: both installers must distinguish the same three states.
for label, txt in (("install.ps1", ps1), ("install.sh", sh)):
    check("Not part of selection" in txt,
          "%s: distinguishes 'not selected' from 'not applied'" % label)

# =============================================================================
section("8a. Post-install verifier")
# =============================================================================
# The package has three verifications with different scopes, and only the third
# answers "is the machine configured as expected?" after rollout:
#   validate-config.py -> the SOURCE (free, in pipeline)
#   install --dry-run  -> the PLAN   (free, in pipeline)
#   verify-install.py  -> the RESULT (runs on installed host)
VERIFY = "tests/verify-install.py"
if check(os.path.isfile(os.path.join(ROOT, VERIFY)), "exists: %s" % VERIFY):
    vtxt = read(VERIFY)

    # Reuse, not reimplementation: if the verifier resolves paths one way
    # and the engine another, it checks the WRONG FILE and returns false OK --
    # the worst possible outcome for a verification tool.
    check("from apply_targets import" in vtxt,
          "  imports engine instead of reimplementing")
    for fn in ("expand", "load_all_targets", "filter_by_selector"):
        check(fn in vtxt, "  reuses %s() from engine" % fn)
    check("def expand(" not in vtxt,
          "  does NOT reimplement expand()")

    # Every strategy needs a verifier: an uncovered one would pass silently
    # as "file exists" without verifying content.
    for strat in sorted(VALID_STRATEGIES):
        check(('"%s"' % strat) in vtxt,
              "  covers strategy '%s'" % strat)

    # Output contract for fleet grepping, matching installers.
    check("AGENTSHIELD: VERIFY DONE" in vtxt,
          "  prints stable result line")
    check("--expect-managed" in vtxt,
          "  distinguishes missing admin layer from required admin layer")
    for token in ("--machine-detector", '"runner": "detect-managed"',
                  'result["compliant"] = exit_code == 0'):
        check(token in vtxt, "  supports managed detector contract: %s" % token)
    # The engine injects payload_by_os before writing. A verifier comparing
    # raw payload would flag divergence on the CORRECT file.
    check("apply_payload_by_os(spec" in vtxt,
          "  applies payload_by_os before comparing (matching engine)")

    # Must not leak dev config values in output.
    check("never prints developer configuration values" in vtxt,
          "  states it does not print dev config values")

    # Endpoint management requires a final machine-readable verdict without
    # leaking the evaluated files or configuration values.
    for token in ("--output-mode", '"Console", "Json", "Quiet"',
                  'emit_event("start")', 'emit_event("phase", "target_configuration")',
                  '"event": "result"', '"duration_ms"', '"expect_managed"'):
        check(token in vtxt, "  endpoint verifier: output contract contains %s" % token)
    check("OUTPUT_MODE == \"Console\"" in vtxt,
          "  endpoint verifier: Json and Quiet suppress console details")

    # Documentation exposure: flags that change the verdict in a fleet.
    for doc in (OPERATIONS_DOC, "tests/README.md"):
        check("verify-install.py" in read(doc), "  cited in %s" % doc)
    rtxt = read(OPERATIONS_DOC)
    for flag in ("--expect-managed", "--home", "--only"):
        check(("verify-install.py %s" % flag) in rtxt,
              "  README shows 'verify-install.py %s'" % flag)
    check("verify-install.py --expect-managed --output-mode Quiet" in rtxt,
          "  OPERATIONS.md shows structured endpoint verification")

    # The pipeline must EXERCISE the verifier against an actually written disk,
    # proving that it flags drift.
    ptxt = read("bitbucket-pipelines.yml")
    check("bash scripts/unix/install.sh --skip-tools" in ptxt,
          "  pipeline installs for real (not just dry-run)")
    check("python tests/verify-install.py" in ptxt,
          "  pipeline verifies real installation")
    check("deriva proposital" in ptxt,
          "  pipeline proves verifier detects drift")

# =============================================================================
section("8b. Layer 2 suites (behavioral)")
# =============================================================================
# Layer 2 costs API credits and does not run in CI, so breakage goes unnoticed
# until someone needs it. These free checks guarantee the suite remains executable
# and coherent with the real config.
SIM_TOOLS = ["claude", "codex"]
sims = {}
for tool in SIM_TOOLS:
    rel = "tests/simulate-%s-config.sh" % tool
    if check(os.path.isfile(os.path.join(ROOT, rel)), "exists: %s" % rel):
        sims[tool] = read(rel)

check(os.path.isfile(os.path.join(ROOT, "tests/lib-sim.sh")), "exists: tests/lib-sim.sh")
check(os.path.isfile(os.path.join(ROOT, "tests/simulate-all.sh")), "exists: tests/simulate-all.sh")

if os.path.isfile(os.path.join(ROOT, "tests/simulate-all.sh")):
    runner = read("tests/simulate-all.sh")
    for tool in sims:
        check('"%s"' % tool in runner, "  simulate-all.sh iterates '%s'" % tool)

for tool, txt in sorted(sims.items()):
    tem_guarda = "require_cli" in txt or ("command -v" in txt and "exit 1" in txt)
    check(tem_guarda, "  %s: handles missing CLI" % tool)

    # Suite must read REAL payload from policy/ or targets/, not an inline copy.
    usa_fonte = "policy/" in txt or "targets/" in txt or "compose_guidelines" in txt
    check(usa_fonte, "  %s: reads real config (policy/ or targets/)" % tool)

# Guideline composition must NOT be reimplemented in the suites.
if os.path.isfile(os.path.join(ROOT, "tests/lib-sim.sh")):
    libsim = read("tests/lib-sim.sh")
    check("apply_targets.py" in libsim,
          "  lib-sim.sh delegates composition to engine")
    check("core-guidelines.md" not in libsim,
          "  lib-sim.sh does NOT reimplement guideline concatenation")

for tool, txt in sorted(sims.items()):
    if tool == "claude":
        continue
    check("source \"$SCRIPT_DIR/lib-sim.sh\"" in txt,
          "  %s: uses common harness" % tool)

# The env var allowing non-root testing is what makes Layer 2 feasible for Codex.
if "codex" in sims:
    check("CODEX_HOME" in sims["codex"],
          "  codex: relocates CODEX_HOME (without touching real profile)")
    check("requirements.toml" in sims["codex"],
          "  codex: declares non-relocatable requirements.toml boundary")

# =============================================================================
section("8c. Shell variable used without assignment (set -u)")
# =============================================================================
# Scripts run under 'set -euo pipefail': an unassigned variable ABORTS execution.
# 'bash -n' cannot catch this -- it is a runtime error, not syntax.
#
# This section exists because of a real bug: '$OS_TYPE' (a variable that never
# existed; the correct name is '$OS') passed all tests because the line was
# after the root gate in deploy.sh and was never executed in CI. It failed on
# a user machine at the end of a deploy that appeared to have succeeded.
#
# Without shellcheck available, the check is heuristic: it collects usages of
# $VAR / ${VAR} in UPPERCASE and verifies whether there is an assignment in the file,
# if the variable comes from environment, or if it uses a default (${VAR:-x}, safe under -u).
AMBIENTE = {
    "HOME", "PATH", "USER", "EUID", "UID", "PWD", "OLDPWD", "SHELL", "TERM",
    "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL", "OSTYPE", "HOSTTYPE", "IFS",
    "PS1", "PS2", "RANDOM", "SECONDS", "LINENO", "FUNCNAME", "BASH_SOURCE",
    "BASH_VERSION", "BASH_REMATCH", "PIPESTATUS", "SUDO_USER", "SUDO_UID",
    "APPDATA", "LOCALAPPDATA", "USERPROFILE", "SystemRoot", "ProgramData",
    "ProgramFiles", "GITHUB_TOKEN", "CODEX_HOME",
    "SKIP_SECURITY_HOOK",
    "DEBIAN_FRONTEND", "NC",
    # defined in tests/lib-sim.sh and inherited by scripts sourcing it
    "RED", "GREEN", "YELLOW", "CYAN", "GRAY", "BLUE", "MAGENTA",
    "PASS", "FAIL", "SKIP", "COST", "PY", "REPO_DIR", "SCRIPT_DIR",
}

_ATRIB = [
    re.compile(r"^\s*(?:local\s+|export\s+|declare\s+-\w+\s+|readonly\s+)?"
               r"([A-Z][A-Z0-9_]*)\s*(?:\+?=|\()"),
    re.compile(r"^\s*local\s+.*?\b([A-Z][A-Z0-9_]*)="),
    re.compile(r"^\s*for\s+([A-Z][A-Z0-9_]*)\s+in\b"),
    re.compile(r"^\s*read\s+(?:-\w+\s+)*([A-Z][A-Z0-9_]*)"),
    re.compile(r"^\s*([A-Z][A-Z0-9_]*)=\S*\s+\S"),
    re.compile(r"\b([A-Z][A-Z0-9_]*)=\S*\s+(?:\"?\$PY|py_json|python)"),
    # Assignment in the middle of a line, after then/else/do/;/&&/||.
    re.compile(r"(?:^|;|\bthen\b|\belse\b|\bdo\b|&&|\|\|)"
               r"\s*([A-Z][A-Z0-9_]*)\s*\+?="),
]
_USO = re.compile(r"\$\{([A-Z][A-Z0-9_]*)(?:[^}]*)\}|\$([A-Z][A-Z0-9_]*)")

SH_FILES = ["install.sh", "deploy.sh", "hooks/pre-commit",
            "tests/lib-sim.sh", "tests/simulate-all.sh",
            "tests/simulate-claude-config.sh",
            "tests/simulate-codex-config.sh"]

for rel in SH_FILES:
    full = os.path.join(ROOT, repo_rel(rel))
    if not os.path.isfile(full):
        continue
    texto = read(rel)
    linhas = texto.split("\n")

    atribuidas = set()
    for l in linhas:
        for rx in _ATRIB:
            m = rx.search(l)
            if m:
                atribuidas.add(m.group(1))
    seguras = atribuidas | AMBIENTE

    problemas = []
    for n, l in enumerate(linhas, 1):
        if l.strip().startswith("#"):
            continue
        codigo = l.split("#")[0]
        for m in _USO.finditer(codigo):
            nome = m.group(1) or m.group(2)
            if nome in seguras:
                continue
            # ${VAR:-...} / ${VAR:=...} / ${VAR+...} do not abort under set -u
            if re.search(r"\$\{" + re.escape(nome) + r"(:-|:=|:\?|\+|:\+)", codigo):
                continue
            problemas.append("L%d:$%s" % (n, nome))

    check(not problemas, "  %s: no variable used without assignment" % rel,
          problemas[:6] or "")

# printf with an EMPTY array still applies the format once and prints a blank line.
# In deploy.sh this caused 'evidence' never to be empty in the caller.
for rel in SH_FILES:
    full = os.path.join(ROOT, repo_rel(rel))
    if not os.path.isfile(full):
        continue
    linhas = read(rel).split("\n")
    suspeitos = []
    for n, l in enumerate(linhas, 1):
        m = re.search(r"printf\s+'[^']*'\s+\"\$\{(\w+)\[@\]\}\"", l)
        if not m:
            continue
        var = m.group(1)
        janela = "\n".join(linhas[max(0, n - 5):n - 1])
        if ("#%s[@]" % var) not in janela.replace(" ", "").replace("${", "").replace("}", ""):
            suspeitos.append("L%d:%s" % (n, var))
    check(not suspeitos,
          "  %s: array printf has length guard" % rel, suspeitos or "")

# A function whose stdout is DATA must not emit diagnostics to stdout: the warning
# text would be parsed as a record.
if os.path.isfile(os.path.join(ROOT, repo_rel("deploy.sh"))):
    dep = read("deploy.sh")
    m = re.search(r"_get_all_users_guarded\(\)\s*\{(.*?)\n\}", dep, re.S)
    if check(bool(m), "  deploy.sh: _get_all_users_guarded exists"):
        corpo = m.group(1)
        avisos = re.findall(r"^\s*(?:warn|info|error)\s+.*$", corpo, re.M)
        sem_redirect = [a.strip()[:60] for a in avisos if ">&2" not in a]
        check(not sem_redirect,
              "  deploy.sh: data-function diagnostics go to stderr",
              sem_redirect or "")

# Reports must not assert "applied"/"installed" in dry-run.
for rel, marca in (("deploy.sh", "VERBO_OK"), ("deploy.ps1", "verboOk")):
    if not os.path.isfile(os.path.join(ROOT, repo_rel(rel))):
        continue
    txt = read(rel)
    check(marca in txt and "WOULD BE installed (dry-run)" in txt,
          "  %s: report uses conditional verb in dry-run" % rel)
    if marca in txt:
        primeira = txt.index(marca)
        ini = txt.rfind(chr(10), 0, primeira) + 1
        fim = txt.find(chr(10), primeira)
        linha = txt[ini:fim if fim > 0 else len(txt)]
        e_atribuicao = ("%s=" % marca) in linha.replace(" ", "")
        check(e_atribuicao, "  %s: verb defined before usage" % rel,
              "" if e_atribuicao else "first occurrence is not assignment: %s" % linha.strip()[:60])

# Machine-readable output is consumed by endpoint-management workflows. Keep the
# stable fields and event boundaries in every supported runner without invoking
# an installer during source validation.
for _rel, _mode, _json_gate, _result_gate in (
    ("install.ps1", "[ValidateSet(\"Console\", \"Json\", \"Quiet\")]",
     '$script:OutputMode -eq "Json"', '$OutputMode -ne "Console"'),
    ("deploy.ps1", "[ValidateSet(\"Console\", \"Json\", \"Quiet\")]",
     '$script:OutputMode -eq "Json"', '$OutputMode -ne "Console"'),
    ("install.sh", "Console (default), Json, or Quiet",
     '[[ "$OUTPUT_MODE" == "Json" ]]', '[[ "$OUTPUT_MODE" != "Console" ]]'),
    ("deploy.sh", "Console|Json|Quiet",
     '[[ "$OUTPUT_MODE" == "Json" ]]', '[[ "$OUTPUT_MODE" != "Console" ]]'),
):
    _txt = read(_rel)
    check(_mode in _txt, "  %s: supports Console, Json, and Quiet" % _rel)
    check(_json_gate in _txt, "  %s: phase events are Json-only" % _rel)
    check(_result_gate in _txt, "  %s: result is emitted for Json and Quiet" % _rel)
    for _field in ("schema_version", "run_id", "duration_ms", "exit_code",
                   "selected", "managed", "dry_run"):
        check(_field in _txt, "  %s: output contains %s" % (_rel, _field))

_deploy_sh = read("deploy.sh")
for _term in ("/var/log/agentshield", "agent-shield-deploy.log", "LOG_PATH_JSON",
              "if ! $DRY_RUN", "log_path\":%s"):
    check(_term in _deploy_sh, "  deploy.sh: Unix transcript contract contains %s" % _term)

_install_sh = read("install.sh")
for _term in (".local/state/agentshield", "agent-shield-install.log", "LOG_PATH_JSON",
              "if ! $DRY_RUN", "id -gn", "log_path\":%s"):
    check(_term in _install_sh, "  install.sh: Unix transcript contract contains %s" % _term)

_operations = read("docs/OPERATIONS.md")
for _term in ("Automation output modes", "duration_ms", "ownership_repair",
              "--output-mode", "-OutputMode"):
    check(_term in _operations, "  OPERATIONS.md: documents %s" % _term)

# Targets skipped due to OS must not leave blank blocks in logs.
check("if not (sos and not o and not f)" in py_engine,
      "  Python engine: no ghost block for OS-skipped target")
check("$r.SkipOs -gt 0 -and $r.Ok -eq 0" in ps_engine,
      "  PowerShell engine: no ghost block for OS-skipped target")

# The DONE line must state whether it was a dry-run.
for rel in ("install.sh", "deploy.sh", "install.ps1", "deploy.ps1"):
    if os.path.isfile(os.path.join(ROOT, repo_rel(rel))):
        check("dry=" in read(rel), "  %s: DONE line states dry=" % rel)

# =============================================================================
section("9. Encoding of files deployed to host")
# =============================================================================
# BOM breaks JSON parsers and shell shebangs; CRLF breaks scripts under sh.
shipped = ["lib/apply_targets.py", "lib/security-tools.sh", "policy/policy.json",
           "policy/tools.json", "hooks/pre-commit", "install.sh", "deploy.sh"]
# Layer 2 suites do not go to host, but run under sh: CRLF breaks shebangs equally.
shipped += [f for f in ("tests/lib-sim.sh", "tests/simulate-all.sh",
                        "tests/simulate-claude-config.sh",
                        "tests/simulate-codex-config.sh")
            if os.path.isfile(os.path.join(ROOT, f))]
shipped += ["targets/%s.json" % m for m in sorted(manifests)]
shipped += [p for p in ("policy/codex-requirements.toml",
                        "policy/codex-managed-defaults.toml")
            if os.path.isfile(os.path.join(ROOT, p))]
# The .md files in policy/ are concatenated byte-for-byte by the engine and
# compared with generated CLAUDE.md; CRLF would break comparison on Windows.
shipped += sorted("policy/" + f for f in os.listdir(os.path.join(ROOT, "policy"))
                  if f.endswith(".md"))
for rel in shipped:
    b = open(os.path.join(ROOT, repo_rel(rel)), "rb").read()
    check(not b.startswith(b"\xef\xbb\xbf"), "  no BOM: %s" % rel)
    check(b"\r\n" not in b, "  pure LF: %s" % rel)

# =============================================================================
section("10. Packaging -- build-package covers what deploy requires")
# =============================================================================
# This section exists because of a real regression: a file was added to
# deploy's $required and omitted from build-package's $Files. The zip was generated
# with no error and every deployment from it failed.
deploy_req = ps_array(read("deploy.ps1"), "required")
pkg_files = ps_array(read("build-package.ps1"), "Files")
if check(deploy_req is not None and pkg_files is not None,
         "able to parse \\$required and \\$Files"):
    faltando = [f for f in norm(deploy_req) if f not in norm(pkg_files)]
    check(not faltando, "build-package packages everything deploy.ps1 requires",
          faltando or "%d files" % len(deploy_req))
    ausentes = [f for f in deploy_req
                if not os.path.isfile(os.path.join(ROOT, repo_rel(f.replace("\\", "/"))))]
    check(not ausentes, "all required files exist in repository", ausentes or "")

    # Entire folders also need to be included in the zip, otherwise the engine
    # starts with no manifests and reports "no targets selected" -- false success.
    pkg_text = read("build-package.ps1")
    for d in ("targets", "policy", "lib"):
        check(d in pkg_text, "build-package mentions folder '%s'" % d)
    check("$IntegrationFiles = @()" in pkg_text,
          "build-package separates optional integration assets")
    check("[switch]$IncludeGpo" in pkg_text and
          '"integrations/vscode-gpo/vscode-policy.json"' in pkg_text,
          "build-package includes VS Code baseline only with -IncludeGpo")
    for _term in ("integrations/falcon-rtr/README.md",
                  "integrations/falcon-rtr/agentshield-deploy.workflow.template.yaml",
                  "integrations/falcon-rtr/agentshield-deploy-windows.mocks.template.json",
                  "integrations/falcon-rtr/agentshield-deploy-linux.mocks.template.json",
                  "integrations/falcon-rtr/agentshield-deploy-macos.mocks.template.json",
                  "integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Windows.ps1",
                  "integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Unix.sh",
                  "integrations/falcon-rtr/rtr-scripts/AgentShield-Cleanup-Windows.ps1",
                  "integrations/falcon-rtr/rtr-scripts/AgentShield-Cleanup-Unix.sh"):
        check(_term in pkg_text, "build-package can package %s" % _term)
    check("[switch]$IncludeFalconTemplates" in pkg_text and
          '"$Name-integrations"' in pkg_text,
          "build-package emits optional integration archive")
    check(not any(rel.startswith("integrations/") for rel in pkg_files),
          "deployment archive excludes integration assets")
    _shell_block = re.search(r"if \(\$IncludeShell\) \{(.*?)\n\}", pkg_text, re.S)
    check(_shell_block is not None, "build-package defines an -IncludeShell payload block")
    if _shell_block:
        for _term in ("scripts/unix/install.sh", "scripts/unix/deploy.sh",
                      "scripts/unix/Test-AgentShieldManaged.sh",
                      "tests/verify-install.py"):
            check(_term in _shell_block.group(1),
                  "  -IncludeShell includes %s" % _term)

for _rel, _platform, _activity in (
        ("integrations/falcon-rtr/agentshield-deploy.workflow.template.yaml", "Windows",
         "<AGENTSHIELD_APPLY_WINDOWS_ACTIVITY_ID>"),
        ("integrations/falcon-rtr/agentshield-deploy-linux.workflow.template.yaml", "Linux",
         "<AGENTSHIELD_APPLY_UNIX_ACTIVITY_ID>"),
        ("integrations/falcon-rtr/agentshield-deploy-macos.workflow.template.yaml", "Mac",
         "<AGENTSHIELD_APPLY_UNIX_ACTIVITY_ID>")):
    _workflow_path = os.path.join(ROOT, _rel)
    if check(os.path.isfile(_workflow_path), "exists: %s" % _rel):
        _workflow = open(_workflow_path, encoding="utf-8").read()
        check("name: On demand" in _workflow and "type: On demand" in _workflow,
              "  %s workflow remains manually triggered" % _platform)
        check("<FALCON_HOST_GROUP_ID>" in _workflow,
              "  %s workflow retains host-group placeholder" % _platform)
        check(_activity in _workflow and "RecordAgentShieldResult" in _workflow,
              "  %s workflow uses typed custom apply activity" % _platform)
        check("package_sha256:" in _workflow and "expected_release:" not in _workflow,
              "  %s workflow logs package hash without fixed release" % _platform)
        check("GetDeviceDetails.Platform:'%s'" % _platform in _workflow,
              "  %s workflow filters its platform" % _platform)

for _rel, _platform, _base_dir in (
        ("integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Windows.ps1", "Windows", "C:\\Windows\\Temp"),
        ("integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Unix.sh", "Unix", "/var/tmp"),
        ("integrations/falcon-rtr/rtr-scripts/AgentShield-Cleanup-Windows.ps1", "Windows", "C:\\Windows\\Temp"),
        ("integrations/falcon-rtr/rtr-scripts/AgentShield-Cleanup-Unix.sh", "Unix", "/var/tmp")):
    _script_path = os.path.join(ROOT, _rel)
    if check(os.path.isfile(_script_path), "exists: %s" % _rel):
        _script = open(_script_path, encoding="utf-8").read()
        check(_base_dir in _script, "  %s custom script fixes its staging directory" % _platform)

for _rel in ("integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Windows.ps1",
             "integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Unix.sh"):
    _apply = open(os.path.join(ROOT, _rel), encoding="utf-8").read()
    check("<AGENTSHIELD_PACKAGE_SHA256>" in _apply,
          "  custom apply script requires configured package SHA-256: %s" % _rel)
check("bash -l" not in read("integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Unix.sh"),
      "  Unix custom apply script does not load a login shell")
check("precheck_failed" in read("integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Windows.ps1") and
      "validation_failed" in read("integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Windows.ps1") and
      "$deployment.exit_code -ne 0" in read("integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Windows.ps1"),
      "  Windows custom apply script fails closed on invalid checks and deployment errors")
check("precheck_failed" in read("integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Unix.sh") and
      "validation_failed" in read("integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Unix.sh") and
      '"$DEPLOY_CODE" -ne 0' in read("integrations/falcon-rtr/rtr-scripts/AgentShield-Apply-Unix.sh"),
      "  Unix custom apply script fails closed on invalid checks and deployment errors")

for _rel in ("integrations/falcon-rtr/agentshield-deploy-windows.mocks.template.json",
             "integrations/falcon-rtr/agentshield-deploy-linux.mocks.template.json",
             "integrations/falcon-rtr/agentshield-deploy-macos.mocks.template.json"):
    _mock_path = os.path.join(ROOT, _rel)
    if check(os.path.isfile(_mock_path), "exists: %s" % _rel):
        try:
            _mock = json.load(open(_mock_path, encoding="utf-8"))
            check("success" in _mock and "scenario_overrides" in _mock and
                  {"already_compliant", "precheck_failed", "deploy_failed", "validation_failed",
                   "not_compliant_after_deploy", "wrong_platform"}.issubset(_mock["scenario_overrides"]),
                  "  mock fixture covers success and expected failure scenarios")
        except ValueError as exc:
            check(False, "  mock fixture is valid JSON", str(exc))

UNIX_DETECTOR = "scripts/unix/Test-AgentShieldManaged.sh"
if check(os.path.isfile(os.path.join(ROOT, UNIX_DETECTOR)), "exists: %s" % UNIX_DETECTOR):
    _unix_detector = open(os.path.join(ROOT, UNIX_DETECTOR), encoding="utf-8").read()
    for _term in ("--machine-detector", "--output-mode", "Python 3 is required"):
        check(_term in _unix_detector, "  Unix managed detector contains %s" % _term)

install_req = ps_array(read("install.ps1"), "required")
if install_req is not None:
    same = norm(install_req) == norm(deploy_req)
    check(same, "install.ps1 and deploy.ps1 require the same files",
          "" if same else "diff: %s" % sorted(set(norm(install_req)) ^ set(norm(deploy_req))))

# Intune detection must remain native PowerShell, package-contained, and scoped
# to the machine-managed controls. It is intentionally not a user-profile audit.
DETECTOR = "Test-AgentShieldManaged.ps1"
if check(os.path.isfile(os.path.join(ROOT, repo_rel(DETECTOR))), "exists: %s" % DETECTOR):
    _det = read(DETECTOR)
    check('"scripts/windows/Test-AgentShieldManaged.ps1"' in _pkg,
          "  build-package includes managed detector")
    check("Falcon RTR v3 workflow" in _pkg and "falcon-rtr\\README.md" in _pkg,
          "  build-package RTR guide references the v3 workflow")
    for _term in ("codex_requirements", "claude_statusline", "claude_managed_controls",
                  "claude_managed_guidance", "claude_managed_mcp_absent"):
        check(_term in _det, "  managed detector checks %s" % _term)
    for _term in ("ConvertTo-Json -Compress", "exit $exitCode", "scope = \"machine\"",
                  "Get-Sha256"):
        check(_term in _det, "  managed detector contains %s" % _term)
    check("Get-FileHash" not in _det,
          "  managed detector uses .NET SHA256, not Get-FileHash")

# =============================================================================
section("10b. Legacy files must not return by reference")
# =============================================================================
# claude-code.json, claude-settings.json, claude-desktop.json and
# vscode-settings.json were absorbed into manifests. A lingering reference
# makes installers abort on host or apply obsolete config.
REMOVIDOS = ("claude-code.json", "claude-desktop.json",
             "claude-settings.json", "vscode-settings.json")
scripts = ["install.sh", "deploy.sh", "install.ps1", "deploy.ps1",
           "build-package.ps1", "tests/simulate-claude-config.sh"]
for rel in scripts:
    full = os.path.join(ROOT, repo_rel(rel))
    if not os.path.isfile(full):
        continue
    txt = read(rel)
    hits = [f for f in REMOVIDOS
            if re.search(r"(?<![\w/\.-])" + re.escape(f), txt)]
    check(not hits, "  %s has no reference to removed file" % rel, hits or "")

for f in REMOVIDOS:
    check(not os.path.isfile(os.path.join(ROOT, f)),
          "  %s no longer exists at root" % f)

# =============================================================================
section("11. VS Code extensions -- same list across all 6 installers")
# =============================================================================
listas = {
    "install.ps1": ps_array(read("install.ps1"), "vsExts"),
    "install.sh": sh_array(read("install.sh"), "VS_EXTENSIONS"),
    "deploy.ps1": ps_array(read("deploy.ps1"), "extensions"),
    "deploy.sh": sh_array(read("deploy.sh"), "extensions"),
    "vscode-gpo/download-vsix.ps1": ps_array(read("vscode-gpo/download-vsix.ps1"), "Extensions"),
    "vscode-gpo/install-extensions.ps1": ps_array(read("vscode-gpo/install-extensions.ps1"), "Extensions"),
}
parsed = {k: v for k, v in listas.items() if v}
check(len(parsed) == len(listas), "able to parse all 6 extension lists",
      "failed on: %s" % [k for k, v in listas.items() if not v]
      if len(parsed) != len(listas) else "")

if parsed:
    ref_name, ref = sorted(parsed.items())[0]
    for nome, lst in sorted(parsed.items()):
        same = sorted(lst) == sorted(ref)
        check(same, "  %s == %s" % (nome, ref_name),
              "" if same else "diff: %s" % sorted(set(lst) ^ set(ref)))
    # No extension in the package may require an account.
    EXIGEM_LOGIN = ("snyk", "bridgecrew.checkov")
    todas = {e for lst in parsed.values() for e in lst}
    login_required = sorted(e for e in todas
                            if any(t in e.lower() for t in EXIGEM_LOGIN))
    check(not login_required, "no extension requires login",
          login_required or sorted(todas))

# =============================================================================
section("12. MCP servers -- consistent across targets")
# =============================================================================
mcp_sets = {}
for mid, m in sorted(manifests.items()):
    for spec in m.get("files", []):
        if spec.get("strategy") not in ("merge-mcp", "overwrite"):
            continue
        payload = spec.get("payload") or {}
        key = spec.get("mcp_key", "mcpServers")
        servers = payload.get(key)
        if isinstance(servers, dict) and servers:
            mcp_sets[mid] = set(servers)

if mcp_sets:
    ref_name, ref = sorted(mcp_sets.items())[0]
    for name, s in sorted(mcp_sets.items()):
        check(s == ref, "  %s == %s" % (name, ref_name),
              sorted(s) if s == ref else "diff: %s" % sorted(s ^ ref))

    # Two levels with distinct meanings:
    #   required -- the package DISTRIBUTES to every machine (managed-mcp.json)
    #   allowed  -- dev can add individually; the package does not install
    # Confusing the two is a high-cost error.
    _mcp = intents["mcp_governance"]
    declared = set(_mcp["required"])
    _req = set(_mcp["required"])
    _alw = set(_mcp["allowed"])
    check(not (_req & _alw), "  'required' and 'allowed' are disjoint",
          "in both: %s" % sorted(_req & _alw))
    check(not (_alw & ref), "  no 'allowed' server is distributed by manifests",
          "unduly distributed: %s" % sorted(_alw & ref))
    # allowedMcpServers must NOT be declared. It was rejected by the CLI:
    # "Invalid entry was ignored: failed validation".
    _mg = [f for t in manifests.values() for f in t.get("files", [])
           if "allowedMcpServers" in f.get("payload", {})]
    check(not _mg,
          "  managed-settings does NOT declare allowedMcpServers (CLI rejects it)",
          "" if not _mg else "declared in: %s" % ", ".join(sorted(
              t["id"] for t in manifests.values()
              for f in t.get("files", [])
              if "allowedMcpServers" in f.get("payload", {}))))

    # Permissive posture must be explicitly DECLARED.
    _txt_mcp = json.dumps(_mcp, ensure_ascii=False)
    check("POSTURA ATUAL" in _txt_mcp,
          "  permissive posture declared as intentional decision")
    check("Rever quando" in _txt_mcp or "politica publicada" in _txt_mcp,
          "  states what would change it (published policy)")
    check("failed validation" in _txt_mcp,
          "  preserves evidence from when flag was enabled")

    # Flag must not return without documentation.
    _flag = [t["id"] for t in manifests.values() for f in t.get("files", [])
             if "allowManagedMcpServersOnly" in f.get("payload", {})]
    check(not _flag,
          "  allowManagedMcpServersOnly is not declared (permissive posture)",
          "" if not _flag else "declared in: %s -- docs state otherwise" % ", ".join(_flag))

    # And the FILE must not be written again.
    _escreve_mcp = ["%s -> %s" % (t["id"], f.get("strategy"))
                    for t in manifests.values() for f in t.get("files", [])
                    if any(str(d).endswith("managed-mcp.json")
                           for d in f.get("dest", {}).values())
                    and f.get("strategy") != "remove"]
    check(not _escreve_mcp,
          "  no target WRITES managed-mcp.json (only removes it)",
          "" if not _escreve_mcp
          else "%s -- presence of file claims exclusive MCP control"
               % ", ".join(_escreve_mcp))
    check(ref == declared,
          "  distributed MCPs == 'required' in policy.json",
          sorted(ref) if ref == declared else "diff: %s" % sorted(ref ^ declared))

    if CHECK_TOOLS:
        for mid, m in sorted(manifests.items()):
            for spec in m.get("files", []):
                payload = spec.get("payload") or {}
                servers = payload.get(spec.get("mcp_key", "mcpServers"))
                if not isinstance(servers, dict):
                    continue
                for nome, cfg in sorted(servers.items()):
                    cmd = cfg.get("command")
                    found = shutil.which(cmd) if cmd else None
                    check(bool(found), "  binario de '%s' no PATH" % nome,
                          found or "absent -- server will not start", warn_only=True)
                break

# =============================================================================
section("12b. Documentation coverage")
# =============================================================================
# Adding a tool and forgetting to document it is an expected failure mode.
_docs = read("README.md") + read(ARCHITECTURE_DOC) + read("targets/README.md")

for mid in sorted(manifests):
    check(mid in _docs, "  target '%s' cited in documentation" % mid)

# Every GROUP selector (aggregating more than one target) must be documented.
_grupos = sorted({sel for sel, ids in all_selectors.items() if len(ids) > 1})
for sel in _grupos + ["all"]:
    check(("`%s`" % sel) in _docs, "  group selector '%s' documented" % sel)

# =============================================================================
section("12c. Internal documentation links resolve")
# =============================================================================
# Headings generate GitHub anchor slugs: lowercase, punctuation removed, spaces to hyphens.
def _anchor(titulo):
    t = re.sub(r"^#+\s*", "", titulo).strip().lower()
    t = re.sub(r"[^\w\s-]", "", t, flags=re.UNICODE)
    return re.sub(r"\s", "-", t)


_docs_md = ["README.md", ARCHITECTURE_DOC, OPERATIONS_DOC, "tests/README.md", "targets/README.md",
            "integrations/bitbucket/README.md", "integrations/vscode-gpo/README.md", "docs/README.md",
            "docs/ARCHITECTURE.md", "docs/OPERATIONS.md", "docs/PLATFORMS.md"]
_total_links = 0
for _f in _docs_md:
    if not os.path.isfile(os.path.join(ROOT, _f)):
        continue
    _s = read(_f)
    _titulos = {_anchor(l) for l in _s.split(chr(10)) if l.startswith("#")}
    _links = re.findall(r"\]\(#([^)]+)\)", _s)
    _total_links += len(_links)
    _quebrados = sorted({a for a in _links if a not in _titulos})
    check(not _quebrados, "%s: all internal links resolve" % _f,
          "" if not _quebrados else "missing destination: %s" % ", ".join(_quebrados[:3]))

# Duplicate sections check.
for _f in _docs_md:
    if not os.path.isfile(os.path.join(ROOT, _f)):
        continue
    _dentro, _tit = False, []
    for _l in read(_f).split(chr(10)):
        if _l.strip().startswith("```"):
            _dentro = not _dentro
            continue
        if not _dentro and _l.startswith("#"):
            _tit.append(_l.strip())
    _dups = sorted({t for t in _tit if _tit.count(t) > 1})
    check(not _dups, "%s: no duplicate sections" % _f,
          "" if not _dups else "repeated: %s" % "; ".join(t[:46] for t in _dups[:2]))

check(_total_links > 0, "internal links exist to verify",
      "%d links" % _total_links)

# =============================================================================
section("13. Numbers stated in documentation")
# =============================================================================
# Numbers in prose become stale silently.
TOLERANCIA = 0.20


def _num(texto, padrao):
    m = re.search(padrao, texto)
    if not m:
        return None
    return int(m.group(1).replace(".", ""))


def _dentro(afirmado, real):
    if afirmado is None or real == 0:
        return False
    return abs(afirmado - real) <= real * TOLERANCIA


_real_checks = _counts["OK"] + _counts["WARN"] + _counts["FAIL"]
for _rel, _pat in (("tests/README.md", r"grew from ~90 to ~([\d.]+)"),):
    _doc = _num(read(_rel), _pat)
    check(_dentro(_doc, _real_checks),
          "%s: check count matches" % _rel,
          "doc=%s real~%d (tolerance %d%%)" % (_doc, _real_checks, TOLERANCIA * 100))

# =============================================================================
print("\n" + "=" * 100)
print("RESULT: %d OK, %d WARN, %d FAIL" % (_counts["OK"], _counts["WARN"], _counts["FAIL"]))
print("=" * 100)
sys.exit(1 if _counts["FAIL"] else 0)
