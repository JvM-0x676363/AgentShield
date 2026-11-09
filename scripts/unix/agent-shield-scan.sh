#!/usr/bin/env bash
set -euo pipefail

SCRIPT_LOCATION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "$SCRIPT_LOCATION/policy" && -d "$SCRIPT_LOCATION/targets" ]]; then
    ROOT="$SCRIPT_LOCATION"
else
    ROOT="$(cd "$SCRIPT_LOCATION/../.." && pwd)"
fi
OUTPUT_MODE="Console"
for ((index = 1; index <= $#; index++)); do
    if [[ "${!index}" == "--output-mode" ]]; then
        next=$((index + 1))
        OUTPUT_MODE="${!next:-Console}"
    elif [[ "${!index}" == --output-mode=* ]]; then
        value="${!index}"
        OUTPUT_MODE="${value#*=}"
    fi
done

blocked() {
    local detail="$1"
    if [[ "$OUTPUT_MODE" == "Console" ]]; then
        echo "[AGENTSHIELD SCAN] result: environment_blocked ($detail)" >&2
    else
        printf '{"schema_version":1,"event":"result","status":"environment_blocked","exit_code":2,"runner":"agent-shield-scan","detail":"%s","scanners":[]}\n' "$detail"
    fi
    exit 2
}

PYTHON=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
        PYTHON="$candidate"
        break
    fi
done
if [[ -z "$PYTHON" ]]; then
    blocked "python3_not_found"
fi

exec "$PYTHON" "$ROOT/scripts/scan/agent_shield_scan.py" \
    --rules-dir "$ROOT/rules/semgrep" "$@"
