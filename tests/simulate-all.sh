#!/usr/bin/env bash
# =============================================================================
# Layer 2 runner: executes behavioral simulations for each installed CLI.
#
# A missing CLI is marked as SKIP, not failure -- config is applied even
# without the AI tool installed (by design: if the developer installs it later,
# the gate is already in place), so there is nothing to measure without the CLI.
#
# WARNING: consumes provider API credits for each installed CLI.
# NOT executed in CI/CD pipelines. Run on demand.
#
# Usage:  bash tests/simulate-all.sh
#         bash tests/simulate-all.sh codex         # single suite
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'

SUITES=("claude" "codex")
if [[ $# -gt 0 ]]; then SUITES=("$@"); fi

declare -a RESULTADO
FALHOU=0

for suite in "${SUITES[@]}"; do
    script="$SCRIPT_DIR/simulate-${suite}-config.sh"
    if [[ ! -f "$script" ]]; then
        echo -e "${RED}unknown suite: $suite${NC} ($script does not exist)"
        FALHOU=1
        continue
    fi

    echo
    echo "==================================================================="
    bash "$script"
    rc=$?
    echo "==================================================================="

    # Distinguish three outcomes so the runner does not report all green on an empty machine.
    if [[ $rc -eq 0 ]]; then
        if command -v "$suite" >/dev/null 2>&1; then
            RESULTADO+=("${GREEN}OK${NC}    $suite")
        else
            RESULTADO+=("${GRAY}SKIP${NC}  $suite (CLI missing)")
        fi
    else
        RESULTADO+=("${RED}FAIL${NC}  $suite (rc=$rc)")
        FALHOU=1
    fi
done

echo
echo -e "${CYAN}== Layer 2 summary ==${NC}"
for l in "${RESULTADO[@]}"; do echo -e "  $l"; done
echo

if [[ "$FALHOU" -eq 0 ]]; then
    echo -e "${YELLOW}Reminder:${NC} SKIP is not approval. Before a broad rollout, run"
    echo "this suite on a machine with actual CLIs installed --"
    echo "layer 1 (validate-config.py) proves the FILE conforms to vendor schema,"
    echo "not that the RULE successfully blocks actions."
fi

exit $FALHOU
