#!/usr/bin/env bash
# Verifies machine-managed AgentShield controls on Linux and macOS.

set -euo pipefail

SCRIPT_LOCATION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_LOCATION/policy" && -d "$SCRIPT_LOCATION/targets" ]]; then
    ROOT="$SCRIPT_LOCATION"
else
    ROOT="$(cd "$SCRIPT_LOCATION/../.." && pwd)"
fi

OUTPUT_MODE="Quiet"

usage() {
    cat <<'USAGE'
Usage: Test-AgentShieldManaged.sh [--output-mode Console|Json|Quiet]

Verifies only the machine-managed AgentShield controls. Exit codes:
  0  compliant
  1  one or more managed controls are missing or different
  2  usage error or Python 3 is unavailable
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-mode)
            shift
            OUTPUT_MODE="${1:-}"
            [[ "$OUTPUT_MODE" =~ ^(Console|Json|Quiet)$ ]] || {
                echo "[ERROR] --output-mode must be Console, Json, or Quiet" >&2
                exit 2
            }
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 \
        && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PYTHON="$candidate"
        break
    fi
done

if [[ -z "$PYTHON" ]]; then
    echo "[ERROR] Python 3 is required for managed-control verification" >&2
    exit 2
fi

exec "$PYTHON" "$ROOT/tests/verify-install.py" \
    --machine-detector \
    --output-mode "$OUTPUT_MODE"
