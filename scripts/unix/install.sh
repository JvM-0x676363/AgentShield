#!/usr/bin/env bash
# Security AI Config Installer — Linux/Mac
# Covers: Claude Code CLI + global Git hooks (audit mode)
# Usage: bash install.sh [--dry-run]

set -euo pipefail

SCRIPT_LOCATION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source checkout: scripts/unix/. Distribution ZIP: package root.
if [[ -d "$SCRIPT_LOCATION/policy" && -d "$SCRIPT_LOCATION/targets" ]]; then
    SCRIPT_DIR="$SCRIPT_LOCATION"
else
    SCRIPT_DIR="$(cd "$SCRIPT_LOCATION/../.." && pwd)"
fi
DRY_RUN=false
OUTPUT_MODE="Console"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
sep()   { echo -e "  -----------------------------------------------"; }

# `sudo bash install.sh` changes $HOME to /root, but this is a SINGLE developer's
# installer. Derive caller profile so we don't install guidelines, hooks, and global
# Git configuration into root. deploy.sh remains the path for multi-profile rollouts.
TARGET_USER="${SUDO_USER:-${USER:-root}}"
TARGET_HOME="$HOME"
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        TARGET_HOME="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    elif command -v getent > /dev/null 2>&1; then
        TARGET_HOME="$(getent passwd "$SUDO_USER" | awk -F: '{print $6}')"
    fi
    if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
        error "Could not resolve HOME for $SUDO_USER; no user profile will be modified."
        error "Use deploy.sh for multi-user rollouts or fix the user's system entry."
        exit 1
    fi
fi
GIT_HOOKS_DIR="$TARGET_HOME/.git-hooks"
GIT_TEMPLATE="$TARGET_HOME/.git-template"

# --- Python 3: used only to MERGE JSON preserving existing configurations ---
# Clean installation does not need it (direct copy). On macOS without Xcode CLT,
# /usr/bin/python3 is a stub that exists in PATH but fails on execution, so
# `command -v` is not enough: we must run a check to verify it works.
PY=""
for _c in python3 python; do
    if command -v "$_c" > /dev/null 2>&1 \
       && "$_c" -c 'import sys, json; sys.exit(0 if sys.version_info[0] == 3 else 1)' > /dev/null 2>&1; then
        PY="$_c"; break
    fi
done
MERGES_SKIPPED=0
FAILED_TARGETS=0
# "Running as root" != "applied": --only claude has no machine target.
ADMIN_APPLIED=0

# JSON merge wrapper. Without valid python3: consume heredoc and PRESERVE existing
# file. Overwriting developer config would be worse than not applying right now.
py_json() {
    if [[ -z "$PY" ]]; then
        MERGES_SKIPPED=1
        warn "  python3 not found -- merge skipped; existing file preserved"
        cat > /dev/null
        return 0
    fi
    "$PY" -
}

ONLY="all"

usage() {
    cat <<'USAGE'
Usage: bash install.sh [options]

  --dry-run              Show what would be done without making changes
  --only <selectors>     Which configs to apply (default: all)
                         E.g.: --only codex
                               --only claude,antigravity
                               --only managed          (enforcement layers only)
                               --only claude-managed   (specific target)
  --list-targets         List available targets and selectors and exit
  --skip-tools           Do not download gitleaks/semgrep/trivy
  --skip-vscode          Do not install VS Code extensions
  --output-mode <mode>   Console (default), Json, or Quiet
  -h, --help             Show this help

Note: --only filters ONLY AI CONFIGURATIONS. Scanner tools,
VS Code extensions, and git hooks have their own flags (--skip-tools,
--skip-vscode) -- they are orthogonal layers, not selectable targets.
USAGE
}

SKIP_TOOLS=false
SKIP_VSCODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY_RUN=true ;;
        --output-mode)  shift; OUTPUT_MODE="${1:-}"
                        [[ "$OUTPUT_MODE" =~ ^(Console|Json|Quiet)$ ]] || { error "--output-mode must be Console, Json, or Quiet"; exit 2; } ;;
        --only)         shift; ONLY="${1:-}"
                        [[ -n "$ONLY" ]] || { error "--only requires a value"; exit 2; } ;;
        --only=*)       ONLY="${1#*=}" ;;
        --list-targets) exec "${PY:-python3}" "$SCRIPT_DIR/lib/apply_targets.py" \
                             --root "$SCRIPT_DIR" --list-targets ;;
        --skip-tools)   SKIP_TOOLS=true ;;
        --skip-vscode)  SKIP_VSCODE=true ;;
        -h|--help)      usage; exit 0 ;;
        *)              error "unknown option: $1"; echo; usage; exit 2 ;;
    esac
    shift
done

RUN_ID="$(command -v uuidgen >/dev/null 2>&1 && uuidgen || printf '%s-%s' "$(date +%s)" "$$")"
STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STARTED_EPOCH="$(date +%s)"
LOG_PATH=""
if ! $DRY_RUN; then
    LOG_DIR="$TARGET_HOME/.local/state/agentshield"
    LOG_CANDIDATE="$LOG_DIR/agent-shield-install.log"
    if mkdir -p "$LOG_DIR" 2>/dev/null \
       && chmod 0700 "$LOG_DIR" 2>/dev/null \
       && touch "$LOG_CANDIDATE" 2>/dev/null \
       && chmod 0600 "$LOG_CANDIDATE" 2>/dev/null; then
        if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
            TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || true)"
            if [[ -n "$TARGET_GROUP" ]]; then
                chown "$TARGET_USER:$TARGET_GROUP" "$LOG_DIR" "$LOG_CANDIDATE" 2>/dev/null || true
            else
                chown "$TARGET_USER" "$LOG_DIR" "$LOG_CANDIDATE" 2>/dev/null || true
            fi
        fi
        LOG_PATH="$LOG_CANDIDATE"
    else
        echo "[WARN] unable to initialize installation log; continuing without a transcript" >&2
    fi
fi
ORIGINAL_STDOUT=1
if [[ -n "$LOG_PATH" ]]; then
    exec 3>&1
    if [[ "$OUTPUT_MODE" == "Console" ]]; then
        exec > >(tee -a "$LOG_PATH") 2>&1
    else
        exec >>"$LOG_PATH" 2>&1
    fi
    ORIGINAL_STDOUT=3
elif [[ "$OUTPUT_MODE" != "Console" ]]; then
    exec 3>&1
    exec 1>/dev/null
    ORIGINAL_STDOUT=3
fi
json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}
json_selected() {
    local value item first=true
    local IFS=','
    read -r -a values <<< "$1"
    printf '['
    for value in "${values[@]}"; do
        item="${value#"${value%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        $first || printf ','
        printf '"%s"' "$(json_escape "$item")"
        first=false
    done
    printf ']'
}
SELECTED_JSON="$(json_selected "$ONLY")"
LOG_PATH_JSON="null"
if [[ -n "$LOG_PATH" ]]; then
    LOG_PATH_JSON="\"$(json_escape "$LOG_PATH")\""
fi
emit_event() {
    [[ "$OUTPUT_MODE" == "Json" ]] || return 0
    printf '{"schema_version":1,"event":"%s","phase":"%s","run_id":"%s","timestamp_utc":"%s","runner":"install","scope":"user","dry_run":%s,"selected":%s}\n' \
        "$1" "${2:-}" "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DRY_RUN" "$SELECTED_JSON" >&$ORIGINAL_STDOUT
}
emit_event start

$DRY_RUN && info "Dry-run mode -- no changes will be made\n"
MODE="apply"; $DRY_RUN && MODE="dry-run"
echo -e "\n${CYAN}=== AgentShield | workstation install ===${NC}"
info "Execution mode: $MODE; runner=install; scope=user; selected=$ONLY"

# Linux requires Bubblewrap for Codex sandbox to be predictable. The
# client may attempt a built-in helper without it, but that depends on user
# namespaces/AppArmor; not installing packages automatically prevents surprises.
OS="linux"
[[ "$(uname)" == "Darwin" ]] && OS="mac"
if [[ "$OS" == "linux" ]]; then
    if command -v bwrap > /dev/null 2>&1; then
        info "Codex sandbox: bubblewrap found."
    else
        warn "Codex sandbox: bubblewrap (bwrap) not found."
        warn "  Install via distribution package manager before using Codex (e.g.: sudo apt install bubblewrap)."
        warn "  Without it the built-in helper depends on user namespaces/AppArmor and may fail to start."
    fi
else
    info "Codex sandbox: macOS uses native Seatbelt; no additional setup needed."
fi

run() { if $DRY_RUN; then echo "  [dry-run] $*"; else eval "$@"; fi; }

# --- Source file validation ---
# Per-tool configuration lives in targets/*.json + policy/*; installers
# no longer carry per-tool blocks. Only check roots: the engine validates
# each manifest and each referenced payload_file/compose.
for f in "lib/apply_targets.py" "lib/security-tools.sh" "policy/core-guidelines.md" "policy/policy.json" "policy/tools.json" "hooks/pre-commit"; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { error "File not found: $SCRIPT_DIR/$f"; exit 1; }
done
[[ -d "$SCRIPT_DIR/targets" ]] || { error "Directory not found: $SCRIPT_DIR/targets"; exit 1; }

# Sandbox prerequisite is not part of --skip-tools: scanners are optional,
# but without Bubblewrap Codex Linux may fail to start.
# shellcheck source=lib/security-tools.sh
source "$SCRIPT_DIR/lib/security-tools.sh"
ensure_codex_sandbox_prereqs_unix || warn "  Codex may use fallback, but Linux sandbox is not ready."

# --- Validate selector BEFORE touching anything ---------------------
# Invalid selectors must abort as usage error (exit 2) and not midway:
# without this, a typo in --only caused the script to iterate tools and
# hooks only to exit with 1 at the end, giving the false impression that
# something was applied. The engine validates and returns 2; do not swallow it.
if [[ -n "$PY" ]]; then
    SEL_RC=0
    "$PY" "$SCRIPT_DIR/lib/apply_targets.py" --root "$SCRIPT_DIR" \
        --scope machine --only "$ONLY" --dry-run >/dev/null 2>&1 || SEL_RC=$?
    if [[ "$SEL_RC" -eq 2 ]]; then
        # Re-run WITHOUT redirection: engine prints valid vocabulary to stdout.
        "$PY" "$SCRIPT_DIR/lib/apply_targets.py" --root "$SCRIPT_DIR" \
            --scope machine --only "$ONLY" --dry-run || true
        exit 2
    fi
fi

# The admin layer comes BEFORE user scope, and the order is mandatory:
# the user target declares superseded_by pointing to the managed CLAUDE.md,
# which only exists after this block. Inverted, the user block is written,
# the admin layer creates the managed one immediately after, and both remain
# present -- charging the core guidelines twice per prompt until the next run.
# Admin layer (enforcement; requires root)
# Admin layer (enforcement; requires root)
# This is where controls developers cannot revert reside: Claude Code
# managed-settings.json and Codex requirements.toml. Antigravity has no
# admin layer: all of its configuration lives in the user profile.
#
# Honest note on real strength: on Linux/Mac developers typically HAVE root on
# their machine, so this represents friction and auditability, not containment.
# On corporate Windows (dev without admin) this is true enforcement.
echo -e "\n${CYAN}[Admin Layer - Enforcement]${NC}"

# Check if selection includes machine target before requiring root: demanding
# privilege for something no one requested creates misleading reports.
# Probe by exit code (3 = valid selection, zero targets), not stdout parsing.
# Under 'set -e', '|| VAR=$?' is required: probe intentionally returns 3 and would abort.
MACHINE_SELECTED=1
if [[ -n "$PY" ]]; then
    PROBE_RC=0
    "$PY" "$SCRIPT_DIR/lib/apply_targets.py" --root "$SCRIPT_DIR" --scope machine --only "$ONLY" --dry-run >/dev/null 2>&1 || PROBE_RC=$?
    if [[ "$PROBE_RC" -eq 3 ]]; then MACHINE_SELECTED=0; fi
fi

# We also need to know whether user-scoped targets remain: this separates
# "partially installed" from "nothing installed".
USER_SELECTED=1
if [[ -n "$PY" ]]; then
    USER_PROBE_RC=0
    "$PY" "$SCRIPT_DIR/lib/apply_targets.py" --root "$SCRIPT_DIR" --scope user --only "$ONLY" --home "$TARGET_HOME" --dry-run >/dev/null 2>&1 || USER_PROBE_RC=$?
    if [[ "$USER_PROBE_RC" -eq 3 ]]; then USER_SELECTED=0; fi
fi

if [[ "$MACHINE_SELECTED" == "0" ]]; then
    info "no enforcement targets in --only '$ONLY' -- step not applicable"
elif [[ $EUID -ne 0 ]] && ! $DRY_RUN; then
    warn "running without root -- enforcement layer SKIPPED"
    warn "  Run with sudo to apply managed-settings/requirements/system settings."
    # Self-service script: skip what requires root and warn, rather than failing
    # with an error that a developer without sudo cannot fix. deploy.sh requires privilege.
    # Exception: selection containing only machine scope delivered nothing, which is a failure.
    if [[ "$USER_SELECTED" == "0" ]]; then
        error "  selection contained only machine scope: NOTHING applied in this run"
        FAILED_TARGETS=1
    fi
elif [[ -z "$PY" ]]; then
    MERGES_SKIPPED=1
    warn "python3 not found -- enforcement layer SKIPPED"
else
    if [[ $EUID -ne 0 ]]; then
        # Dry-run without root: engine ignores privilege check, showing full plan.
        warn "DRY-RUN without root: the plan below is what WOULD BE written."
        warn "  In a real run this step would be SKIPPED until run with sudo."
    fi
    MACHINE_ARGS=(--root "$SCRIPT_DIR" --scope machine --only "$ONLY")
    $DRY_RUN && MACHINE_ARGS+=(--dry-run)
    if "$PY" "$SCRIPT_DIR/lib/apply_targets.py" "${MACHINE_ARGS[@]}"; then
        if $DRY_RUN; then
            # Do not claim enforcement when nothing was written.
            info "  (dry-run: nothing written -- rules above are NOT active)"
        else
            ADMIN_APPLIED=1
            warn "On this platform developers typically have root: treat as friction, not containment."
        fi
    else
        APPLY_RC=$?
        error "admin layer failed (rc=$APPLY_RC)"
        FAILED_TARGETS=1
    fi
fi

sep

# AI Configuration (driven by targets/*.json)
# AI configuration (driven by targets/*.json)
# Previously: a handwritten block per tool, duplicated across 4 installers.
# Now: target manifests in targets/ describe destination, format, and merge
# strategy, and the engine applies them. Adding a new AI is 1 manifest, not 4 edits.
#
# lib/ApplyTargets.ps1 is the PowerShell counterpart for Windows installers, reading
# the SAME manifests. tests/validate-config.py checks parity between the two.
echo -e "\n${CYAN}[AI Configuration - User Scope]${NC}"
emit_event phase user_configuration

APPLY_ARGS=(--root "$SCRIPT_DIR" --scope user --home "$TARGET_HOME" --only "$ONLY")
$DRY_RUN && APPLY_ARGS+=(--dry-run)

if [[ -z "$PY" ]]; then
    MERGES_SKIPPED=1
    warn "python3 not found -- AI configuration NOT applied"
    warn "  Existing files remain intact."
else
    APPLY_RC=0
    "$PY" "$SCRIPT_DIR/lib/apply_targets.py" "${APPLY_ARGS[@]}" || APPLY_RC=$?
    # rc=3 is "valid selection, zero targets in this scope" -- not a failure.
    # With '--only managed' there are no user-scope targets; treating that as
    # an error would exit with failed=1 and 'config is NOT complete' when everything succeeded.
    if [[ "$APPLY_RC" -ne 0 && "$APPLY_RC" -ne 3 ]]; then
        error "configuration application failed (rc=$APPLY_RC)"
        FAILED_TARGETS=1
    fi
fi

sep

# Security tools installation (machine level, requires sudo/root)
echo -e "\n${CYAN}[Security Tools - Installation]${NC}"
emit_event phase security_tools

if $SKIP_TOOLS; then
    info "--skip-tools -- tool downloads skipped"
else

if [[ $EUID -ne 0 ]]; then
    warn "  Script running without root/sudo privileges."
    warn "  Machine-level installation (/usr/local/bin) requires sudo -- skipping this step."
    warn "  Run: sudo bash install.sh   -- to install gitleaks/trivy/semgrep automatically."
    warn "  Or install manually:"
    warn "    pip3 install semgrep==1.175.0"
else
    # Shared source: pinned releases and verified SHA-256. Do not use
    # remote scripts or mutable release endpoints on developer machines.
    install_security_tools_unix || warn "  One or more tools were not installed"
fi

sep

fi   # end of --skip-tools gate

# VS Code security extensions
echo -e "\n${CYAN}[VS Code Extensions]${NC}"

VS_EXTENSIONS=(
    "semgrep.semgrep"
    "sonarsource.sonarlint-vscode"
    "usernamehw.errorlens"
    # Snyk removed: requires account (snyk.login/snyk.setToken). Trivy substituted
    # -- runs locally, Aqua Platform connection is optional.
    "AquaSecurityOfficial.trivy-vulnerability-scanner"
)

CODE_BIN=""
VS_CANDIDATES=(
    "/usr/bin/code"
    "/usr/local/bin/code"
    "/snap/bin/code"
    "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    "$TARGET_HOME/.local/bin/code"
)
for c in "${VS_CANDIDATES[@]}"; do
    [[ -x "$c" ]] && { CODE_BIN="$c"; break; }
done
[[ -z "$CODE_BIN" ]] && CODE_BIN="$(command -v code 2>/dev/null || true)"

if $SKIP_VSCODE; then
    info "--skip-vscode -- VS Code extensions skipped"
elif [[ -n "$CODE_BIN" ]]; then
    for ext in "${VS_EXTENSIONS[@]}"; do
        if $DRY_RUN; then
            echo "  [dry-run] code --install-extension $ext --force"
        else
            # Under sudo, 'code' must run as session owner, otherwise extensions
            # end up in root profile.
            if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
                sudo -H -u "$SUDO_USER" "$CODE_BIN" --install-extension "$ext" --force &>/dev/null \
                    && info "  ✔ $ext" || warn "  ✘ $ext (failed)"
            else
                "$CODE_BIN" --install-extension "$ext" --force &>/dev/null \
                    && info "  ✔ $ext" || warn "  ✘ $ext (failed)"
            fi
        fi
    done
else
    warn "  VS Code not found -- skipping extensions"
    warn "  Install manually: code --install-extension <extension>"
fi

# VS Code settings are applied by the engine (targets/vscode.json), covering
# deb/rpm, snap, and flatpak. Only extension installation remains here, which
# engine does not handle (depends on 'code' binary).

sep

# Git global hooks (AUDIT ONLY — no block)
echo -e "\n${CYAN}[Git Global Hooks - Audit Mode]${NC}"
emit_event phase git_hooks

run "mkdir -p '$GIT_HOOKS_DIR'"
run "git config --file '$TARGET_HOME/.gitconfig' core.hooksPath '$GIT_HOOKS_DIR'"

PRE_COMMIT="$GIT_HOOKS_DIR/pre-commit"

# Single source in hooks/pre-commit -- previously duplicated (and divergent) across 4 installers.
# Byte-by-byte comparison against what WOULD BE written (source with CRLF stripped),
# not between two normalized sides: an existing hook in CRLF -- which breaks under sh
# with "\r: command not found" -- counts as divergent and is rewritten in LF.
if [[ -f "$PRE_COMMIT" ]] && diff -q \
        <(tr -d '\r' < "$SCRIPT_DIR/hooks/pre-commit") \
        "$PRE_COMMIT" > /dev/null 2>&1; then
    info "pre-commit hook is already up to date -- nothing to do"
elif $DRY_RUN; then
    echo "  [dry-run] Would install/update $PRE_COMMIT"
else
    if [[ -f "$PRE_COMMIT" ]]; then
        # Previous version skipped ANY existing hook, leaving old hooks
        # (with 'exit 1', which BLOCKS commits) in place forever.
        PRE_COMMIT_BAK="$PRE_COMMIT.bak-$(date +%Y%m%d-%H%M%S)"
        cp -p "$PRE_COMMIT" "$PRE_COMMIT_BAK"
        warn "pre-commit hook outdated -- replacing (backup in $PRE_COMMIT_BAK)"
    else
        info "Installing pre-commit hook from hooks/pre-commit (audit only)..."
    fi
    tr -d '\r' < "$SCRIPT_DIR/hooks/pre-commit" > "$PRE_COMMIT"
    chmod +x "$PRE_COMMIT"
    info "  ✔ $PRE_COMMIT (audit mode: gitleaks + semgrep + trivy)"
fi

# Git init template
run "mkdir -p '$GIT_TEMPLATE/hooks'"
# The template is COPIED into every new repository (git init/clone), so
# whatever lingers here becomes trash in every repository on the machine.
run "find '$GIT_TEMPLATE/hooks' -maxdepth 1 -name 'pre-commit.bak*' -delete 2>/dev/null || true"
run "cp '$PRE_COMMIT' '$GIT_TEMPLATE/hooks/pre-commit' 2>/dev/null || true"
run "chmod +x '$GIT_TEMPLATE/hooks/pre-commit' 2>/dev/null || true"
run "git config --file '$TARGET_HOME/.gitconfig' init.templateDir '$GIT_TEMPLATE'"

# Admin pass wrote files inside another user's profile. Return ownership,
# including the directly modified .gitconfig above.
if [[ $EUID -eq 0 && "$TARGET_USER" != "root" && ! $DRY_RUN ]]; then
    for user_path in "$TARGET_HOME/.claude" "$TARGET_HOME/.codex" \
                     "$TARGET_HOME/.gemini" "$GIT_HOOKS_DIR" "$GIT_TEMPLATE" \
                     "$TARGET_HOME/.gitconfig" "$TARGET_HOME/.config/Code/User" \
                     "$TARGET_HOME/Library/Application Support/Code/User" \
                     "$TARGET_HOME/snap/code/current/.config/Code/User"; do
        [[ -e "$user_path" ]] && chown -R "$TARGET_USER" "$user_path"
    done
fi

sep

# Summary
echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo -e "  ${CYAN}AI Configuration${NC}"
if [[ "$ONLY" == "all" ]]; then
    echo "    Claude Code / Claude Desktop / Codex CLI / Antigravity"
else
    echo "    PARTIAL INSTALLATION -- selection: $ONLY"
    echo "    Unselected targets were NOT applied or modified."
fi
echo "    Applied targets: see [INFO] OK lines above."
echo "    Source: targets/*.json + policy/  (inventory in targets/README.md)"
echo ""
if [[ "$ADMIN_APPLIED" == "1" ]]; then
    echo -e "  ${CYAN}Admin Layer (enforcement)${NC}"
    echo "    Applied. On this platform developers typically have root: friction, not containment."
elif [[ "$MACHINE_SELECTED" == "0" ]]; then
    echo -e "  ${YELLOW}Admin Layer (enforcement)${NC}"
    echo "    Not part of selection '$ONLY' -- nothing to apply."
elif [[ $EUID -ne 0 ]]; then
    echo -e "  ${YELLOW}Admin Layer (enforcement)${NC}"
    echo "    NOT applied -- ran without root."
    echo "    Entire configuration is in user profile and editable by developer."
else
    echo -e "  ${YELLOW}Admin Layer (enforcement)${NC}"
    echo "    NOT applied -- see [ERROR]/[WARN] lines above."
fi
echo ""
echo -e "  ${CYAN}Git (audit mode -- does not block commits)${NC}"
echo "    $PRE_COMMIT"
echo ""
echo ""
echo -e "  ${YELLOW}VS Code -- MANUAL ACTION REQUIRED (once per machine)${NC}"
echo "    Security extensions DO NOT declare support for Restricted Mode:"
echo "    until the project folder is trusted, all extensions remain disabled."
echo "    Trust ONCE the parent folder of your repositories -- all subfolders"
echo "    inherit trust, including ones created in the future:"
echo ""
echo "      Ctrl+Shift+P -> 'Workspace Trust' -> Trusted Folders & Workspaces"
echo "      -> Add Folder -> select parent folder (e.g.: ~/repos)"
echo ""
echo -e "  ${YELLOW}Restart Claude Code to apply changes.${NC}"
echo ""

if [[ "$FAILED_TARGETS" == "1" ]]; then
    echo ""
    error "WARNING: one or more targets failed -- configuration is NOT complete."
    error "  Review [ERROR] lines above before considering the workstation ready."
fi

if [[ "$MERGES_SKIPPED" == "1" ]]; then
    echo ""
    warn "WARNING: python3 was not found -- one or more JSON merges were skipped."
    warn "  Existing files remained INTACT: security configurations were NOT"
    warn "  applied to them. Install python3 and re-run this script."
    warn "  macOS: xcode-select --install   |   Debian/Ubuntu: apt install python3"
fi

# Stable final line for grep in fleet rollouts.
DRY_FLAG=0; $DRY_RUN && DRY_FLAG=1
echo "AGENTSHIELD: INSTALL DONE failed=$FAILED_TARGETS admin=$ADMIN_APPLIED merges_skipped=$MERGES_SKIPPED only=$ONLY dry=$DRY_FLAG"
RESULT_STATUS="success"; [[ "$FAILED_TARGETS" == "1" ]] && RESULT_STATUS="failed"
echo "AGENTSHIELD: RESULT status=$RESULT_STATUS runner=install scope=user managed=$ADMIN_APPLIED dry_run=$DRY_FLAG selected=$ONLY"
if [[ "$OUTPUT_MODE" != "Console" ]]; then
    DURATION_MS="$(( ($(date +%s) - STARTED_EPOCH) * 1000 ))"
    printf '{"schema_version":1,"event":"result","run_id":"%s","started_at_utc":"%s","duration_ms":%s,"status":"%s","exit_code":%s,"runner":"install","scope":"user","selected":%s,"managed":%s,"dry_run":%s,"targets":{"failed":%s},"log_path":%s}\n' \
        "$RUN_ID" "$STARTED_AT_UTC" "$DURATION_MS" "$RESULT_STATUS" "$([[ "$RESULT_STATUS" == success ]] && echo 0 || echo 1)" "$SELECTED_JSON" "$([[ "$ADMIN_APPLIED" == 1 ]] && echo true || echo false)" "$DRY_RUN" "$FAILED_TARGETS" "$LOG_PATH_JSON" >&$ORIGINAL_STDOUT
fi
[[ "$FAILED_TARGETS" == "1" ]] && exit 1
exit 0
