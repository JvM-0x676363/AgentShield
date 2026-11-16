#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(id -u)" -eq 0 ]]; then
    echo 'Run this test without root privileges.' >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    echo 'Python 3 and Git are required for this test.' >&2
    exit 2
fi

test_root="$(mktemp -d "${TMPDIR:-/tmp}/agentshield-rollback-install.XXXXXXXX")"
chmod 0700 "$test_root"
test_home="$test_root/profile"
receipt_dir="$test_root/receipts"
mkdir -m 0700 "$test_home" "$receipt_dir"

export HOME="$test_home"
export USER="$(id -un)"
export XDG_CONFIG_HOME="$test_home/.config"
export GIT_CONFIG_GLOBAL="$test_home/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONNOUSERSITE=1
unset SUDO_USER SUDO_UID SUDO_GID

if ! install_output="$(bash "$repo/scripts/unix/install.sh" \
    --only claude-code --skip-tools --skip-vscode \
    --experimental-receipt-dir "$receipt_dir" 2>&1)"; then
    printf '%s\n' "$install_output" | tail -n 12 >&2
    printf 'Evidence directory: %s\n' "$test_root" >&2
    exit 1
fi
if [[ "$install_output" != *'INSTALL DONE failed=0'* ||
      "$install_output" != *'VS Code extensions skipped'* ]]; then
    echo 'Isolated install did not report success and skipped VS Code extensions.' >&2
    printf 'Evidence directory: %s\n' "$test_root" >&2
    exit 1
fi

for relative in .claude/vendor-claude-code.md .git-hooks/pre-commit \
    .git-hooks/agent-shield-scan.py .git-template/hooks/pre-commit; do
    if [[ ! -f "$test_home/$relative" ]]; then
        echo 'Expected installed file is missing.' >&2
        printf 'Evidence directory: %s\n' "$test_root" >&2
        exit 1
    fi
done

if ! preview="$(python3 "$repo/scripts/rollback/rollback.py" --receipt-dir "$receipt_dir")"; then
    echo 'Rollback preview was blocked.' >&2
    printf '%s\n' "$preview" >&2
    printf 'Evidence directory: %s\n' "$test_root" >&2
    exit 1
fi
receipt_count="$(printf '%s\n' "$preview" | python3 -c '
import json, sys
result = json.load(sys.stdin)
if (result.get("status") != "ready" or result.get("blocked") != 0 or
        result.get("receipts", 0) < 1 or result.get("ready") != result.get("receipts")):
    sys.exit(1)
print(result["receipts"])
')" || {
    echo 'Rollback preview did not mark every receipt ready.' >&2
    printf '%s\n' "$preview" >&2
    printf 'Evidence directory: %s\n' "$test_root" >&2
    exit 1
}

if ! result="$(python3 "$repo/scripts/rollback/rollback.py" --receipt-dir "$receipt_dir" --apply)"; then
    echo 'Rollback apply failed.' >&2
    printf '%s\n' "$result" >&2
    printf 'Evidence directory: %s\n' "$test_root" >&2
    exit 1
fi
printf '%s\n' "$result" | python3 -c '
import json, sys
result = json.load(sys.stdin)
expected = int(sys.argv[1])
if result.get("status") != "restored" or result.get("applied") != expected:
    sys.exit(1)
' "$receipt_count" || {
    echo 'Rollback did not apply every ready receipt.' >&2
    printf 'Evidence directory: %s\n' "$test_root" >&2
    exit 1
}

for relative in .claude/vendor-claude-code.md .git-hooks/pre-commit \
    .git-hooks/agent-shield-scan.py .git-template/hooks/pre-commit; do
    if [[ -e "$test_home/$relative" ]]; then
        echo 'A created file survived rollback.' >&2
        printf 'Evidence directory: %s\n' "$test_root" >&2
        exit 1
    fi
done
for key in core.hooksPath init.templateDir; do
    if git config --file "$test_home/.gitconfig" --get-all "$key" >/dev/null 2>&1; then
        echo 'An installed Git setting survived rollback.' >&2
        printf 'Evidence directory: %s\n' "$test_root" >&2
        exit 1
    fi
done

printf 'RESULT: Unix isolated install and rollback passed (receipts=%s)\n' "$receipt_count"
printf 'Evidence directory: %s\n' "$test_root"
