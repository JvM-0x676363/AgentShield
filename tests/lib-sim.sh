#!/usr/bin/env bash
# =============================================================================
# Common harness for layer 2 simulations (behavioral).
#
# Sourced by simulate-<tool>-config.sh. Each CLI has its own output format,
# so only truly shared logic stays here: colors, Python detection,
# skip when the CLI is not installed, counting, and reporting.
#
# Do not attempt to abstract the assertion itself: the three CLIs report
# blocking differently (structured permission_denials in Claude, text in
# Codex, missing tool in Antigravity). A generic "case()" would obscure
# this difference, which is precisely what these tests exist to measure.
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'

PASS=0; FAIL=0; SKIP=0; COST=0

command -v python3 >/dev/null 2>&1 && PY=python3 || PY=python

# -----------------------------------------------------------------------------
# require_cli <binary> <friendly name>
#
# Exits with 0 -- not 1 -- when the CLI is not installed. Missing tooling
# is not a configuration failure: if this failed, the runner could not execute
# available tests on a machine having only a subset of CLIs.
# -----------------------------------------------------------------------------
require_cli() {
    local bin="$1" nome="$2"
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo -e "${GRAY}== $nome: SKIP -- '$bin' is not in PATH ==${NC}"
        echo -e "${GRAY}   (config is applied even without the CLI installed; this test"
        echo -e "    only verifies BEHAVIOR, so without the CLI there is nothing to measure)${NC}"
        exit 0
    fi
}

ok()   { echo -e "  [${GREEN}PASS${NC}] $1  ${GRAY}$2${NC}"; PASS=$((PASS + 1)); }
bad()  { echo -e "  [${RED}FAIL${NC}] $1  ${GRAY}$2${NC}"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  [${GRAY}SKIP${NC}] $1  ${GRAY}$2${NC}"; SKIP=$((SKIP + 1)); }

add_cost() {
    COST=$("$PY" -c "print(round($COST + ${1:-0}, 4))")
}

# -----------------------------------------------------------------------------
# Disposable sandbox with dummy .env, git repo, and a readable file.
# -----------------------------------------------------------------------------
make_sandbox() {
    local sb="$1"
    mkdir -p "$sb"
    printf 'DB_PASSWORD=DummyTestPassword\nAPI_TOKEN=dummy_token_for_tests\n' > "$sb/.env"
    echo "print('ok')" > "$sb/app.py"
    printf 'READ_MARKER_OK\n' > "$sb/readme.txt"
    git -C "$sb" init -q . 2>/dev/null || true
    git -C "$sb" add -A >/dev/null 2>&1 || true
    SKIP_SECURITY_HOOK=1 git -C "$sb" -c user.email=t@local -c user.name=test \
        commit -qm "sandbox" >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# compose_guidelines <target-id> <destination>
#
# DELEGATES composition to the engine instead of reimplementing it. An earlier
# version of this function concatenated policy files by hand and ended up 1 byte
# different from the engine: cat preserves the trailing newline of core, whereas
# the engine rstrips. One byte does not alter model behavior, but duplicating
# composition logic only to test against it produces self-approving tests.
#
# Applies to a disposable HOME, strips marker lines, and produces the payload.
# -----------------------------------------------------------------------------
compose_guidelines() {
    local target_id="$1" dst="$2"
    local tmp_home gerado
    tmp_home="$(mktemp -d)"

    if ! "$PY" "$REPO_DIR/lib/apply_targets.py" --root "$REPO_DIR" \
            --scope user --only "$target_id" --home "$tmp_home" >/dev/null 2>&1; then
        echo "compose_guidelines: engine failed for '$target_id'" >&2
        rm -rf "$tmp_home"
        return 1
    fi

    gerado="$(find "$tmp_home" -name '*.md' -type f | head -1)"
    if [[ -z "$gerado" ]]; then
        echo "compose_guidelines: no .md generated for '$target_id'" >&2
        rm -rf "$tmp_home"
        return 1
    fi

    grep -vF '<!-- security-team-block -->' "$gerado" > "$dst"
    rm -rf "$tmp_home"
    [[ -s "$dst" ]]
}

report() {
    local nome="$1"
    echo
    echo "-------------------------------------------------------------------"
    echo -e "$nome: ${GREEN}$PASS PASS${NC}, ${RED}$FAIL FAIL${NC}, ${GRAY}$SKIP SKIP${NC}  |  cost: ${YELLOW}US\$ $COST${NC}"
}
