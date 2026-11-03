#!/usr/bin/env bash
# Security AI Config — Multi-User Fleet Deployment (Linux / macOS)
# Discovers users with claude/git/vscode and installs security configurations.
# Usage: sudo bash deploy.sh [--dry-run] [--force]

set -euo pipefail

SCRIPT_LOCATION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source checkout: scripts/unix/. Distribution ZIP: package root.
if [[ -d "$SCRIPT_LOCATION/policy" && -d "$SCRIPT_LOCATION/targets" ]]; then
    SCRIPT_DIR="$SCRIPT_LOCATION"
else
    SCRIPT_DIR="$(cd "$SCRIPT_LOCATION/../.." && pwd)"
fi
MARKER="<!-- security-team-block -->"
DRY_RUN=false
FORCE=false
ONLY="all"   # default; overwritten by --only in parse below
OUTPUT_MODE="Console"
SKIP_TOOLS=false
SKIP_VSCODE=false

# while + shift, NOT 'for arg in "$@"'. In a for loop, 'shift' modifies
# positional parameters but does NOT advance the loop variable: '--only codex'
# picked up the wrong value and '--only=codex' read ${1#*=} (first argument,
# not the current one). Result: --only was silently ignored and the deployment
# applied EVERYTHING -- the opposite of what the operator requested, with no error.
#
# error() is not yet defined at this point in the file (log functions come later),
# so errors here use echo directly to stderr.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --force)   FORCE=true ;;
        --skip-tools) SKIP_TOOLS=true ;;
        --skip-vscode) SKIP_VSCODE=true ;;
        --output-mode) shift; OUTPUT_MODE="${1:-}"
                       [[ "$OUTPUT_MODE" =~ ^(Console|Json|Quiet)$ ]] || { echo "[ERROR] --output-mode must be Console, Json, or Quiet" >&2; exit 2; } ;;
        --only)    shift
                   ONLY="${1:-}"
                   [[ -n "$ONLY" ]] || { echo "[ERROR] --only requires a value" >&2; exit 2; } ;;
        --only=*)  ONLY="${1#*=}" ;;
        --list-targets) exec "${PY:-python3}" "$SCRIPT_DIR/lib/apply_targets.py" \
                            --root "$SCRIPT_DIR" --list-targets ;;
        -h|--help) echo "Usage: sudo bash deploy.sh [--dry-run] [--force] [--skip-tools] [--skip-vscode] [--output-mode Console|Json|Quiet] [--only <selectors>] [--list-targets]"; exit 0 ;;
        *)         echo "[ERROR] unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

RUN_ID="$(command -v uuidgen >/dev/null 2>&1 && uuidgen || printf '%s-%s' "$(date +%s)" "$$")"
STARTED_AT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STARTED_EPOCH="$(date +%s)"
LOG_PATH=""
# A dry-run must not create persistent files. Real fleet deployments retain a
# local transcript for responders whose console capture is truncated.
if ! $DRY_RUN && [[ $EUID -eq 0 ]]; then
    LOG_DIR="/var/log/agentshield"
    LOG_CANDIDATE="$LOG_DIR/agent-shield-deploy.log"
    if install -d -m 0750 "$LOG_DIR" 2>/dev/null \
       && touch "$LOG_CANDIDATE" 2>/dev/null \
       && chmod 0640 "$LOG_CANDIDATE" 2>/dev/null; then
        LOG_PATH="$LOG_CANDIDATE"
    else
        echo "[WARN] unable to initialize deployment log; continuing without a transcript" >&2
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
    printf '{"schema_version":1,"event":"%s","phase":"%s","run_id":"%s","timestamp_utc":"%s","runner":"deploy","scope":"fleet","dry_run":%s,"selected":%s}\n' \
        "$1" "${2:-}" "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DRY_RUN" "$SELECTED_JSON" >&$ORIGINAL_STDOUT
}
emit_event start

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${CYAN}========== $* ==========${NC}"; }
sep()     { echo -e "${GRAY}  -------------------------------------------${NC}"; }
run()     { if $DRY_RUN; then echo "  [dry-run] $*"; else eval "$@"; fi; }

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
MACHINE_OK=0

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

$DRY_RUN && info "Dry-run mode — no changes will be made\n"
MODE="apply"; $DRY_RUN && MODE="dry-run"
echo -e "\n${CYAN}=== AgentShield | fleet deployment ===${NC}"
info "Execution mode: $MODE; runner=deploy; selected=$ONLY"

# --- Requires root (except in dry-run) ---
# Dry-run writes nothing, so requiring root there protected nothing and prevented
# two useful things: (a) developers previewing the plan on their own machine and
# (b) the pipeline smoke-testing the full path of this script.
#
# This is NOT a convenience detail: the 'OS_TYPE: unbound variable' bug passed
# all tests precisely because the line was after this gate and never executed without root.
if [[ $EUID -ne 0 ]]; then
    if $DRY_RUN; then
        warn "No root -- dry-run continues (nothing will be written)."
        warn "  For a real run: sudo bash deploy.sh"
    else
        error "Run as root: sudo bash deploy.sh"
        exit 1
    fi
fi

# --- OS detection ---
OS="linux"
[[ "$(uname)" == "Darwin" ]] && OS="mac"
info "System: $OS"

# --- Source file validation ---
# Per-tool configuration lives in targets/*.json + policy/*. Only check roots:
# the engine validates each manifest and each referenced payload_file/compose.
for f in "lib/apply_targets.py" "lib/security-tools.sh" "policy/core-guidelines.md" "policy/policy.json" "policy/tools.json" "hooks/pre-commit"; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { error "File not found: $SCRIPT_DIR/$f"; exit 1; }
done
[[ -d "$SCRIPT_DIR/targets" ]] || { error "Directory not found: $SCRIPT_DIR/targets"; exit 1; }

# Detection functions

detect_user() {
    local username="$1"
    local home="$2"
    local score=0
    local evidence=()

    # Git
    [[ -f "$home/.gitconfig" ]] && { score=$((score+1)); evidence+=("git (.gitconfig)"); }

    # VS Code
    local vscode_paths=(
        "$home/.vscode"
        "$home/Library/Application Support/Code/User"          # mac
        "$home/.config/Code/User"                              # linux
        "$home/snap/code/current/.config/Code/User"           # linux snap
    )
    for p in "${vscode_paths[@]}"; do
        [[ -d "$p" ]] && { score=$((score+1)); evidence+=("vscode ($p)"); break; }
    done

    # Claude Code CLI
    local claude_paths=(
        "$home/.claude"
        "$home/.claude.json"
        "$home/.npm/bin/claude"
        "$home/.local/bin/claude"
        "/usr/local/bin/claude"
    )
    for p in "${claude_paths[@]}"; do
        [[ -e "$p" ]] && { score=$((score+1)); evidence+=("claude-code ($p)"); break; }
    done

    # Claude Desktop (mac)
    [[ -d "$home/Library/Application Support/Claude" ]] && {
        score=$((score+1)); evidence+=("claude-desktop (Library/Application Support/Claude)")
    }

    # Node/npm (indicates developer)
    [[ -d "$home/.npm" ]] || [[ -d "$home/.nvm" ]] || [[ -d "$home/.fnm" ]] && {
        score=$((score+1)); evidence+=("node/npm")
    }

    # Python (indicates developer)
    [[ -d "$home/.pyenv" ]] || [[ -d "$home/.venv" ]] || [[ -f "$home/.python-version" ]] && {
        score=$((score+1)); evidence+=("python")
    }

    echo "$score"
    # printf with an EMPTY array still applies the format once and prints a blank line.
    # That made 'evidence' never empty in the caller: a stray '+' marker appeared and
    # the useful message '(config prepared for future install)' never showed -- exactly
    # for profiles without AI, which are the ones that most need the explanation.
    if [[ "${#evidence[@]}" -gt 0 ]]; then
        printf '%s\n' "${evidence[@]}"
    fi
}

get_home_dir() {
    local username="$1"
    if [[ "$OS" == "mac" ]]; then
        dscl . -read "/Users/$username" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || echo "/Users/$username"
    else
        getent passwd "$username" 2>/dev/null | cut -d: -f6 || echo "/home/$username"
    fi
}

get_all_users() {
    local system_users=("root" "daemon" "bin" "sys" "sync" "games" "man" "lp" "mail"
                        "news" "uucp" "proxy" "www-data" "backup" "list" "irc" "gnats"
                        "nobody" "systemd-network" "systemd-resolve" "messagebus"
                        "syslog" "_apt" "tss" "uuidd" "tcpdump" "avahi-autoipd"
                        "usbmux" "rtkit" "cups-pk-helper" "dnsmasq" "avahi" "speech-dispatcher"
                        "pulse" "saned" "colord" "geoclue" "hplip" "gdm" "sssd"
                        "_mbsetupuser" "_spotlight" "_mdnsresponder" "_locationd")

    if [[ "$OS" == "mac" ]]; then
        dscl . list /Users | grep -v '^_' | while read -r u; do
            local skip=false
            for s in "${system_users[@]}"; do [[ "$u" == "$s" ]] && skip=true && break; done
            $skip && continue
            local home
            home=$(get_home_dir "$u")
            [[ -d "$home" ]] && echo "$u:$home"
        done
    else
        # Users with UID >= 1000 and a valid shell (excluding nologin/false)
        while IFS=: read -r user _ uid _ _ home shell; do
            [[ "$uid" -lt 1000 ]] && continue
            [[ "$shell" =~ (nologin|false|sync|shutdown|halt) ]] && continue
            [[ -d "$home" ]] || continue
            local skip=false
            for s in "${system_users[@]}"; do [[ "$user" == "$s" ]] && skip=true && break; done
            $skip && continue
            echo "$user:$home"
        done < /etc/passwd
    fi
}

# Wrapper: /etc/passwd may not exist where dry-run now runs (git-bash on
# Windows, minimal container). Without this guard, the smoke test leaks a
# redirect error that says nothing about the configuration.
# ATTENTION: stdout of this function is DATA -- consumed by 'done < <(...)'.
# Any diagnostics must go to stderr, otherwise warning text is parsed as a
# user record. That is exactly what happened in the first version: a warn on
# stdout became a "user" named "[WARN] /etc/passwd not readable..." and the
# deployment tried to install for it.
_get_all_users_guarded() {
    if [[ "$OS" != "mac" && ! -r /etc/passwd ]]; then
        warn "  /etc/passwd not readable in this environment -- user discovery skipped" >&2
        return 0
    fi
    get_all_users
}

install_vscode_extensions() {
    local username="$1"
    local home="$2"

    local extensions=(
        "semgrep.semgrep"
        "sonarsource.sonarlint-vscode"
        "usernamehw.errorlens"
        # Snyk removed: requires account. Trivy runs locally, no login required.
        "AquaSecurityOfficial.trivy-vulnerability-scanner"
    )

    # Locate the code binary in user context
    local code_bin=""
    local candidates=(
        "/usr/bin/code"
        "/usr/local/bin/code"
        "/snap/bin/code"
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        "$home/.local/bin/code"
    )
    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] && { code_bin="$c"; break; }
    done

    if [[ -z "$code_bin" ]]; then
        warn "    vscode: binary 'code' not found -- skipping extensions"
        return
    fi

    info "    vscode: installing extensions via $code_bin"
    for ext in "${extensions[@]}"; do
        if $DRY_RUN; then
            echo "      [dry-run] sudo -u $username $code_bin --install-extension $ext --force"
        else
            sudo -u "$username" "$code_bin" --install-extension "$ext" --force 2>/dev/null \
                && info "      ✔ $ext" \
                || warn "      ✘ $ext (failed)"
        fi
    done

    # VS Code settings are applied by the engine (targets/vscode.json),
    # covering the three packaging formats -- deb/rpm, snap, and flatpak -- via
    # only_if_parent_exists on the alternatives. This block keeps only extension
    # installation, which the engine does not handle (requires the 'code' binary).
    #
    # Ownership of files written as root is returned to the profile owner in
    # install_for_user, together with the other directories.
}

install_for_user() {
    local username="$1"
    local home="$2"

    local hooks_dir="$home/.git-hooks"
    local template_dir="$home/.git-template"

    # ---- AI Configuration (driven by targets/*.json) ----
    # Previously: CLAUDE.md, settings.json, claude.json, and Claude Desktop written
    # by hand here, each with its own merge. Now the engine reads targets/ and
    # applies the 5 user-scope targets -- Claude Code, Claude Desktop,
    # Codex CLI, Antigravity, and VS Code.
    #
    # --home is intentionally explicit: under SYSTEM the process environment points
    # to systemprofile, and configuration would go to a profile no dev uses.
    if [[ -z "$PY" ]]; then
        MERGES_SKIPPED=1
        warn "    python3 not found -- AI configuration NOT applied for $username"
    else
        local apply_args=(--root "$SCRIPT_DIR" --scope user --home "$home" --only "$ONLY")
        $DRY_RUN && apply_args+=(--dry-run)
        local apply_rc=0
        "$PY" "$SCRIPT_DIR/lib/apply_targets.py" "${apply_args[@]}" || apply_rc=$?
        # rc 3 = valid selection with no targets in this scope. With --only managed
        # there are no user targets; counting that as a failure marked every developer
        # in the fleet as broken. The machine pass already distinguished three states;
        # this one did not.
        if [[ "$apply_rc" -eq 0 || "$apply_rc" -eq 3 ]]; then
            # Files written as root need ownership returned to profile owner,
            # otherwise the developer cannot edit their own config -- and the CLI
            # may not even be able to read it.
            if ! $DRY_RUN; then
                emit_event phase ownership_repair
                # ~/.gemini remains on the list: Antigravity stores settings, MCP,
                # and GEMINI.md there -- the directory tree belongs to it now.
                for _d in "$home/.claude" "$home/.codex" "$home/.gemini"; do
                    [[ -d "$_d" ]] && chown -R "$username" "$_d" 2>/dev/null || true
                done
                [[ -f "$home/.claude.json" ]] && chown "$username" "$home/.claude.json" 2>/dev/null || true
            fi
        else
            warn "    AI configuration failed for $username"
            return 1
        fi
    fi

    # ---- VS Code extensions ----
    if $SKIP_VSCODE; then
        info "    vscode: skipped (--skip-vscode)"
    else
        install_vscode_extensions "$username" "$home"
    fi

    # ---- Git hooks (audit mode) ----
    $DRY_RUN || { mkdir -p "$hooks_dir"; chown "$username" "$hooks_dir"; }

    local pre_commit="$hooks_dir/pre-commit"
    # Single source in hooks/pre-commit -- previously duplicated (and divergent) across 4 installers.
    # Byte-by-byte comparison against what WOULD BE written, so an existing hook in CRLF
    # is rewritten in LF rather than reported as up to date.
    if [[ -f "$pre_commit" ]] && diff -q \
            <(tr -d '\r' < "$SCRIPT_DIR/hooks/pre-commit") \
            "$pre_commit" > /dev/null 2>&1; then
        info "    pre-commit hook: already up to date -- nothing to do"
    elif $DRY_RUN; then
        echo "  [dry-run] pre-commit hook: would install/update $pre_commit"
    else
        if [[ -f "$pre_commit" ]]; then
            # Previous version skipped ANY existing hook, leaving old hooks
            # (with 'exit 1', which BLOCKS commits) permanently installed.
            local bak="$pre_commit.bak-$(date +%Y%m%d-%H%M%S)"
            cp -p "$pre_commit" "$bak"
            chown "$username" "$bak"
            warn "    pre-commit hook: outdated -- replaced (backup in $bak)"
        else
            info "    pre-commit hook: creating (audit mode: gitleaks + semgrep + trivy)..."
        fi
        tr -d '\r' < "$SCRIPT_DIR/hooks/pre-commit" > "$pre_commit"
        chmod +x "$pre_commit"
        chown "$username" "$pre_commit"
    fi

    # Git configuration for user
    if ! $DRY_RUN; then
        # git config --file writes directly to target user's .gitconfig. Previously
        # "sudo -u X git config --global", which depended on HOME pointing to the
        # target user and could end up writing to root's gitconfig.
        git config --file "$home/.gitconfig" core.hooksPath "$hooks_dir" \
            || warn "    git config core.hooksPath: failed for $username"
        mkdir -p "$template_dir/hooks"
        cp "$pre_commit" "$template_dir/hooks/pre-commit" 2>/dev/null || true
        chmod +x "$template_dir/hooks/pre-commit" 2>/dev/null || true
        git config --file "$home/.gitconfig" init.templateDir "$template_dir" || true
        chown "$username" "$home/.gitconfig"
        chown -R "$username" "$template_dir"
    else
        echo "  [dry-run] git config --global core.hooksPath $hooks_dir (as $username)"
        echo "  [dry-run] git config --global init.templateDir $template_dir (as $username)"
    fi
}

# SECURITY TOOLS INSTALLATION (machine-level — once, not per user)
section "Security Tools - Installation (machine-level)"
emit_event phase security_tools
# shellcheck source=lib/security-tools.sh
source "$SCRIPT_DIR/lib/security-tools.sh"
# Sandbox prerequisite is independent of --skip-tools: scanners can be deferred,
# but Codex Linux depends on Bubblewrap for predictable isolation.
ensure_codex_sandbox_prereqs_unix || warn "  Codex may use fallback, but Linux sandbox is not ready."
if $SKIP_TOOLS; then
    info "  Skipped (--skip-tools) -- run a second pass without the flag to install tools."
else
    install_security_tools_unix || warn "  One or more tools were not installed"
fi
sep

# User Discovery
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

section "Admin Layer - Enforcement (machine-level)"
emit_event phase managed_enforcement

# This is where controls developers cannot revert reside: Claude Code
# managed-settings.json and Codex requirements.toml. Antigravity has no
# admin layer: all of its configuration lives in the user profile.
# Once per machine, not per user -- hence outside the loop.
#
# Real enforcement strength depends on platform and who has admin access. The
# deployment prints the warning rather than leaving it implicit: promising
# containment where it does not exist is worse than not having the layer.
# MACHINE_OK has THREE states, not two: 1 applied, 0 failed, na not requested.
# Without the third, '--only codex-user' would exit with 1 for not applying
# enforcement the operator never asked for -- and fleet rollout would read it
# as a broken host.
if [[ -z "$PY" ]]; then
    MERGES_SKIPPED=1
    warn "python3 not found -- enforcement layer SKIPPED"
else
    MACHINE_ARGS=(--root "$SCRIPT_DIR" --scope machine --only "$ONLY")
    $DRY_RUN && MACHINE_ARGS+=(--dry-run)
    # rc 3 = step not requested. Detect by exit code, not by output parsing --
    # same contract the PowerShell engine uses, where Write-Host cannot be
    # captured by 2>&1.
    # '|| MACHINE_RC=$?' is required under 'set -e': rc 3 is a legitimate state
    # (step not requested) and would abort the script if left unguarded.
    MACHINE_RC=0
    "$PY" "$SCRIPT_DIR/lib/apply_targets.py" "${MACHINE_ARGS[@]}" || MACHINE_RC=$?
    if [[ "$MACHINE_RC" -eq 3 ]]; then
        MACHINE_OK="na"
        info "no enforcement targets in --only '$ONLY' -- step not applicable"
    elif [[ "$MACHINE_RC" -eq 0 ]]; then
        MACHINE_OK=1
    else
        MACHINE_OK=0
        error "admin layer failed -- enforcement configuration NOT applied"
    fi
fi

if [[ "$OS" == "mac" || "$OS" == "linux" ]]; then
    warn "On this platform developers typically have root on their own machine."
    warn "  Treat this layer as friction + auditability, NOT containment."
    warn "  Reapply on schedule (Falcon RTR / cron) and monitor drift by SHA256."
fi

section "User Discovery"
emit_event phase user_discovery

declare -a TARGET_USERS=()
declare -a TARGET_HOMES=()
declare -a SKIP_USERS=()

while IFS=: read -r username home; do
    mapfile -t detection < <(detect_user "$username" "$home")
    local_score="${detection[0]}"
    evidence=("${detection[@]:1}")

    # All real (non-system) profiles are targeted, even without AI currently installed:
    # if installed in the future, the security gate will already be in place.
    TARGET_USERS+=("$username")
    TARGET_HOMES+=("$home")
    if [[ "$local_score" -gt 0 ]]; then
        echo -e "  ${GREEN}[TARGET]${NC} $username ($home)"
    else
        echo -e "  ${YELLOW}[TARGET (no AI yet)]${NC} $username ($home)"
    fi
    for e in "${evidence[@]}"; do
        echo -e "         ${GRAY}+ $e${NC}"
    done
    [[ "${#evidence[@]}" -eq 0 ]] && echo -e "         ${GRAY}(config prepared for future install)${NC}"
done < <(_get_all_users_guarded)

echo ""
info "Target users: ${#TARGET_USERS[@]}"

if [[ "${#TARGET_USERS[@]}" -eq 0 ]]; then
    warn "No eligible users found. Use --force to install for all."
    # The admin layer already ran above, so print the DONE line here too:
    # the docs state it is ALWAYS the last line, and a rollout grep cannot
    # find nothing on a host that did receive enforcement.
    DRY_FLAG=0; $DRY_RUN && DRY_FLAG=1
    echo "AGENTSHIELD: DONE ok=0 fail=0 machine=$MACHINE_OK only=$ONLY dry=$DRY_FLAG"
    [[ "$MACHINE_OK" == "0" ]] && exit 1
    exit 0
fi

# Confirmation
if ! $DRY_RUN && ! $FORCE; then
    echo ""
    echo -e "${YELLOW}Install for the following users?${NC}"
    for u in "${TARGET_USERS[@]}"; do echo "  - $u"; done
    echo ""
    # Without this guard, "read" without a TTY (Falcon RTR, cron, pipe) returns empty,
    # falls into "Cancelled" and deployment becomes a silent no-op with exit 0 --
    # the worst possible outcome in a remote rollout.
    if [[ ! -t 0 ]]; then
        error "Non-interactive execution detected and --force was not specified."
        error "Nothing was modified. Re-run with --force:"
        error "  sudo bash deploy.sh --force"
        exit 2
    fi
    read -rp "Confirm? (y/N): " confirm
    [[ "$confirm" =~ ^[yYsS]$ ]] || { info "Cancelled."; exit 0; }
fi

# Per-User Deploy
section "Deploy"
emit_event phase user_deployment

SUCCESS=()
FAILED=()

for i in "${!TARGET_USERS[@]}"; do
    username="${TARGET_USERS[$i]}"
    home="${TARGET_HOMES[$i]}"
    echo -e "\n  ${CYAN}-> $username${NC}"
    if install_for_user "$username" "$home"; then
        SUCCESS+=("$username")
    else
        error "    Failed to process $username"
        FAILED+=("$username")
    fi
done

# Report
section "Report"

echo ""
# In dry-run nothing was written: claiming "installed successfully" would be false, and
# the dry-run warning three lines below does not undo the impression given at a glance.
if $DRY_RUN; then
    VERBO_OK="WOULD BE installed (dry-run)"
    VERBO_ADMIN="WOULD BE applied (dry-run)"
else
    VERBO_OK="Installed successfully"
    VERBO_ADMIN="applied"
fi

[[ "${#SUCCESS[@]}" -gt 0 ]] && {
    echo -e "  ${GREEN}OK  ${VERBO_OK}:${NC}"
    for u in "${SUCCESS[@]}"; do echo "       - $u"; done
}
[[ "${#FAILED[@]}" -gt 0 ]] && {
    echo -e "  ${RED}ERR Failed:${NC}"
    for u in "${FAILED[@]}"; do echo "       - $u"; done
}
echo ""
if [[ "$MACHINE_OK" == "1" ]]; then
    echo -e "  ${GREEN}OK  Admin layer (enforcement) ${VERBO_ADMIN}${NC}"
    echo "       Claude managed-settings + Codex requirements"
elif [[ "$MACHINE_OK" == "na" ]]; then
    echo -e "  ${GRAY}--  Admin layer not selected (--only $ONLY)${NC}"
else
    echo -e "  ${RED}ERR Admin layer NOT applied${NC} -- only user layer is active,"
    echo "       and it is editable by the developer."
fi
if [[ "$ONLY" != "all" ]]; then
    echo ""
    warn "PARTIAL INSTALLATION -- selection: $ONLY"
    warn "  Unselected items were NEITHER applied NOR removed."
fi
echo ""
$DRY_RUN && warn "Dry-run completed -- no changes were made."
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

if [[ "$MERGES_SKIPPED" == "1" ]]; then
    echo ""
    warn "WARNING: python3 was not found -- one or more JSON merges were skipped."
    warn "  Existing files remained INTACT: security configurations were NOT"
    warn "  applied to them. Install python3 and re-run this script."
    warn "  macOS: xcode-select --install   |   Debian/Ubuntu: apt install python3"
fi

# Stable final line for grep in fleet rollouts. Aligns with deploy.ps1, which already
# printed this -- the .sh did not, and docs claimed both did.
# machine= indicates whether the enforcement layer succeeded: without it, only the
# developer-editable layer is active, and "ok=N fail=0" alone would misrepresent that.
DRY_FLAG=0; $DRY_RUN && DRY_FLAG=1
# dry= distinguishes dry-run from real execution: without it, a "machine=1" from
# dry-run would pass as applied enforcement when grepping a fleet rollout.
echo "AGENTSHIELD: DONE ok=${#SUCCESS[@]} fail=${#FAILED[@]} machine=$MACHINE_OK only=$ONLY dry=$DRY_FLAG"

RESULT_STATUS="success"
if [[ "${#FAILED[@]}" -gt 0 ]] || [[ "$MACHINE_OK" == "0" ]]; then
    RESULT_STATUS="failed"
fi
echo "AGENTSHIELD: RESULT status=$RESULT_STATUS runner=deploy scope=fleet managed=$MACHINE_OK dry_run=$DRY_FLAG selected=$ONLY"
if [[ "$OUTPUT_MODE" != "Console" ]]; then
    DURATION_MS="$(( ($(date +%s) - STARTED_EPOCH) * 1000 ))"
    printf '{"schema_version":1,"event":"result","run_id":"%s","started_at_utc":"%s","duration_ms":%s,"status":"%s","exit_code":%s,"runner":"deploy","scope":"fleet","selected":%s,"managed":%s,"dry_run":%s,"targets":{"ok":%s,"failed":%s},"log_path":%s}\n' \
        "$RUN_ID" "$STARTED_AT_UTC" "$DURATION_MS" "$RESULT_STATUS" "$([[ "$RESULT_STATUS" == success ]] && echo 0 || echo 1)" "$SELECTED_JSON" "$([[ "$MACHINE_OK" == 1 ]] && echo true || echo false)" "$DRY_RUN" "${#SUCCESS[@]}" "${#FAILED[@]}" "$LOG_PATH_JSON" >&$ORIGINAL_STDOUT
fi

if [[ "$RESULT_STATUS" == "failed" ]]; then
    exit 1
fi
exit 0
