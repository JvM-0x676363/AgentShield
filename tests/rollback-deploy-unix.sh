#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_deploy="$repo/scripts/unix/deploy.sh"
rollback="$repo/scripts/unix/rollback.sh"

if [[ $EUID -ne 0 ]]; then
    echo 'Run this isolated deploy test as root.' >&2
    exit 1
fi
test_user="${SUDO_USER:-}"
if [[ -z "$test_user" || "$test_user" == root ]] || ! id "$test_user" >/dev/null 2>&1; then
    echo 'Run with sudo from a normal user account.' >&2
    exit 1
fi
test_root="$(mktemp -d /tmp/agentshield-rollback-deploy.XXXXXXXX)"

make_fixture_copy() {
    local copy="$1"
    python3 - "$source_deploy" "$copy" "$repo" <<'PY'
import pathlib
import shlex
import sys

source, output, repo = map(pathlib.Path, sys.argv[1:4])
text = source.read_text(encoding="utf-8")
changes = (
    ('MARKER="<!-- security-team-block -->"',
     f'SCRIPT_DIR={shlex.quote(str(repo))}\nMARKER="<!-- security-team-block -->"'),
    ('if ! $DRY_RUN && [[ $EUID -eq 0 ]]; then',
     'if false; then # fixture keeps the host deployment log untouched'),
    ('ensure_codex_sandbox_prereqs_unix || warn "  Codex may use fallback, but Linux sandbox is not ready."',
     ': # fixture skips the machine package prerequisite'),
    ('done < <(_get_all_users_guarded)', 'done < "$AGENTSHIELD_FIXTURE_PROFILES"'),
)
for old, new in changes:
    if text.count(old) != 1:
        raise SystemExit("deploy_fixture_anchor_changed")
    text = text.replace(old, new, 1)
with output.open("w", encoding="utf-8", newline="\n") as target:
    target.write(text)
PY
    bash -n "$copy"
}

check_deploy_result() {
    python3 -c 'import json,sys
records=[json.loads(line) for line in sys.stdin if line.startswith("{")]
results=[record for record in records if record.get("event")=="result"]
if len(results)!=1 or results[0].get("status")!="success" or results[0].get("exit_code")!=0 or results[0]["targets"]!={"ok":2,"failed":0} or results[0].get("managed") or results[0].get("dry_run"):
    raise SystemExit("fixture_deploy_failed")'
}

check_receipts() {
    python3 - "$1" "$2" "$3" <<'PY'
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
homes = [pathlib.Path(value) for value in sys.argv[2:]]
seen = set()
for receipt_file in directory.glob("*.json"):
    operation = json.loads(receipt_file.read_text(encoding="utf-8"))["operations"][0]
    destination = pathlib.Path(operation["destination"])
    matches = [home for home in homes if home in destination.parents]
    if len(matches) != 1:
        raise SystemExit("receipt_outside_fixture_profiles")
    seen.add(matches[0])
if len(seen) != len(homes):
    raise SystemExit("missing_profile_receipts")
PY
}

for scenario in ready review; do
    scenario_root="$test_root/$scenario"
    home_a="$scenario_root/profile-a"
    home_b="$scenario_root/profile-b"
    receipts="$scenario_root/receipts"
    mkdir -p "$home_a" "$home_b" "$receipts"
    chmod 700 "$receipts"
    profile_file="$scenario_root/profiles.txt"
    printf '%s:%s\n%s:%s\n' "$test_user" "$home_a" "$test_user" "$home_b" > "$profile_file"
    if [[ "$scenario" == review ]]; then
        mkdir -p "$home_b/.claude"
        printf 'user-owned fixture\n' > "$home_b/.claude/vendor-claude-code.md"
    fi
    fixture="$scenario_root/deploy.fixture.sh"
    make_fixture_copy "$fixture"
    deploy_output="$scenario_root/deploy-result.jsonl"
    AGENTSHIELD_FIXTURE_PROFILES="$profile_file" \
        bash "$fixture" --force --only claude-code --skip-tools --skip-vscode \
        --experimental-receipt-dir "$receipts" --output-mode Json > "$deploy_output"
    check_deploy_result < "$deploy_output"
    check_receipts "$receipts" "$home_a" "$home_b"
    preview="$(bash "$rollback" --receipt-dir "$receipts")" || preview_code=$?
    preview_code="${preview_code:-0}"
    if [[ "$scenario" == ready ]]; then
        [[ "$preview_code" -eq 0 ]] || { echo 'multi_profile_preview_not_ready' >&2; exit 1; }
        receipt_count="$(python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="ready" and r["receipts"]>=2; print(r["receipts"])' <<< "$preview")"
        result="$(bash "$rollback" --receipt-dir "$receipts" --apply)"
        python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="restored" and r["applied"]==int(sys.argv[1])' "$receipt_count" <<< "$result"
        for home in "$home_a" "$home_b"; do
            [[ ! -e "$home/.git-hooks/pre-commit" && ! -e "$home/.claude/vendor-claude-code.md" ]] || {
                echo 'fixture_file_survived_rollback' >&2; exit 1;
            }
        done
        echo "RESULT: Unix isolated two-profile deploy and rollback passed (receipts=$receipt_count)"
    else
        [[ "$preview_code" -eq 2 ]] || { echo 'multi_profile_review_not_blocked' >&2; exit 1; }
        python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="blocked" and any(i.get("kind")=="manual_review" and i.get("reason")=="existing_target_has_no_inverse" for i in r["items"])' <<< "$preview"
        blocked="$(bash "$rollback" --receipt-dir "$receipts" --apply)" || blocked_code=$?
        [[ "${blocked_code:-0}" -eq 2 && -e "$home_a/.git-hooks/pre-commit" ]] || {
            echo 'multi_profile_partial_rollback_occurred' >&2; exit 1;
        }
        python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["status"]=="blocked" and r["applied"]==0' <<< "$blocked"
        echo 'RESULT: Unix existing file in second profile blocked batch rollback for both profiles'
    fi
    unset preview_code blocked_code
done
echo "Evidence directory: $test_root"
