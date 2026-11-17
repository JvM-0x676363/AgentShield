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

settings="$test_home/.config/Code/User/settings.json"
mkdir -p "$(dirname "$settings")"
printf '{\n  "user.setting": true\n}\n' > "$settings"
cp "$settings" "$test_root/prior-settings.json"
prior_mtime="$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$settings")"
json_receipts="$test_root/json-receipts"
mkdir -m 0700 "$json_receipts"
if ! json_install="$(bash "$repo/scripts/unix/install.sh" \
    --only vscode --skip-tools --skip-vscode \
    --experimental-receipt-dir "$json_receipts" 2>&1)"; then
    printf '%s\n' "$json_install" | tail -n 12 >&2
    printf 'Evidence directory: %s\n' "$test_root" >&2
    exit 1
fi
if [[ "$json_install" != *'INSTALL DONE failed=0'* ]]; then
    echo 'Isolated VS Code JSON merge did not report success.' >&2
    exit 1
fi
if ! json_preview="$(python3 "$repo/scripts/rollback/rollback.py" --receipt-dir "$json_receipts")"; then
    echo 'Canonical JSON rollback preview was blocked.' >&2
    printf '%s\n' "$json_preview" >&2
    exit 1
fi
printf '%s\n' "$json_preview" | python3 -c '
import json, sys
result = json.load(sys.stdin)
items = result.get("items", [])
if result.get("status") != "ready" or not any(
        item.get("kind") == "json_added_keys" and item.get("status") == "ready"
        for item in items):
    sys.exit(1)
' || { echo 'Canonical JSON receipt was not ready.' >&2; exit 1; }
if ! json_result="$(python3 "$repo/scripts/rollback/rollback.py" --receipt-dir "$json_receipts" --apply)"; then
    echo 'Canonical JSON rollback apply failed.' >&2
    printf '%s\n' "$json_result" >&2
    exit 1
fi
printf '%s\n' "$json_result" | python3 -c '
import json, sys
result = json.load(sys.stdin)
if result.get("status") != "restored" or result.get("applied") != result.get("receipts"):
    sys.exit(1)
' || { echo 'Canonical JSON batch rollback was incomplete.' >&2; exit 1; }
if ! cmp -s "$settings" "$test_root/prior-settings.json" ||
   [[ "$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$settings")" != "$prior_mtime" ]]; then
    echo 'Canonical JSON file or timestamp was not restored.' >&2
    exit 1
fi

existing_file="$test_home/.claude/vendor-claude-code.md"
printf 'pre-existing user file\n' > "$existing_file"
manual_receipt_dir="$test_root/manual-receipts"
mkdir -m 0700 "$manual_receipt_dir"
if ! manual_install_output="$(bash "$repo/scripts/unix/install.sh" \
    --only claude-code --skip-tools --skip-vscode \
    --experimental-receipt-dir "$manual_receipt_dir" 2>&1)"; then
    printf '%s\n' "$manual_install_output" | tail -n 12 >&2
    printf 'Evidence directory: %s\n' "$test_root" >&2
    exit 1
fi
if [[ "$manual_install_output" != *'INSTALL DONE failed=0'* ]]; then
    echo 'Existing-file install did not report success.' >&2
    exit 1
fi
cp "$existing_file" "$test_root/installed-existing.txt"

if manual_preview="$(python3 "$repo/scripts/rollback/rollback.py" --receipt-dir "$manual_receipt_dir")"; then
    echo 'Existing-file rollback preview should require manual review.' >&2
    exit 1
else
    preview_rc=$?
    [[ "$preview_rc" -eq 2 ]] || { printf '%s\n' "$manual_preview" >&2; exit 1; }
fi
printf '%s\n' "$manual_preview" | python3 -c '
import json, sys
result = json.load(sys.stdin)
if result.get("status") != "blocked" or not any(
        item.get("status") == "preview_only" for item in result.get("items", [])):
    sys.exit(1)
' || { echo 'Existing-file review was not reported.' >&2; exit 1; }

if manual_result="$(python3 "$repo/scripts/rollback/rollback.py" --receipt-dir "$manual_receipt_dir" --apply)"; then
    echo 'Existing-file batch rollback should have been blocked.' >&2
    exit 1
else
    apply_rc=$?
    [[ "$apply_rc" -eq 2 ]] || { printf '%s\n' "$manual_result" >&2; exit 1; }
fi
printf '%s\n' "$manual_result" | python3 -c '
import json, sys
result = json.load(sys.stdin)
if result.get("status") != "blocked" or result.get("applied") != 0:
    sys.exit(1)
' || { echo 'Existing-file batch rollback changed state.' >&2; exit 1; }
if ! cmp -s "$existing_file" "$test_root/installed-existing.txt" ||
   [[ ! -f "$test_home/.git-hooks/pre-commit" ]]; then
    echo 'Existing-file batch rollback changed the temporary profile.' >&2
    exit 1
fi

printf 'RESULT: Unix isolated install and rollback passed (receipts=%s)\n' "$receipt_count"
echo 'RESULT: Unix canonical VS Code JSON merge and rollback passed'
echo 'RESULT: Unix existing-file review blocked batch rollback'
printf 'Evidence directory: %s\n' "$test_root"
