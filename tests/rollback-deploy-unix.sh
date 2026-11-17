#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_deploy="$repo/scripts/unix/deploy.sh"
rollback="$repo/scripts/unix/rollback.sh"

if [[ $EUID -ne 0 ]]; then
    echo 'Run this isolated deploy test as root.' >&2
    exit 1
fi
test_user_a="${AGENTSHIELD_TEST_USER_A:-${SUDO_USER:-}}"
test_user_b="${AGENTSHIELD_TEST_USER_B:-$test_user_a}"
for test_user in "$test_user_a" "$test_user_b"; do
    if [[ -z "$test_user" || "$test_user" == root ]] || ! id "$test_user" >/dev/null 2>&1; then
        echo 'Run with sudo from a normal user account, or supply two existing test users.' >&2
        exit 1
    fi
done
if [[ "$test_user_a" != "$test_user_b" && "$(id -u "$test_user_a")" == "$(id -u "$test_user_b")" ]]; then
    echo 'Distinct test users must have distinct UIDs.' >&2
    exit 1
fi
test_root="$(mktemp -d /tmp/agentshield-rollback-deploy.XXXXXXXX)"
chmod 711 "$test_root"

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

check_account_isolation() {
    [[ "$test_user_a" != "$test_user_b" ]] || return 0
    python3 - "$home_a" "$home_b" "$receipts" "$test_user_a" "$test_user_b" <<'PY'
import os
import pathlib
import pwd
import sys

home_a, home_b, receipts = map(pathlib.Path, sys.argv[1:4])
users = [pwd.getpwnam(name) for name in sys.argv[4:6]]
homes = [home_a, home_b]
files = [
    [home / ".git-hooks" / "pre-commit", home / ".gitconfig",
     home / ".claude" / "vendor-claude-code.md"]
    for home in homes
]
for account, home, paths in zip(users, homes, files):
    if home.stat().st_uid != account.pw_uid or any(
        path.stat().st_uid != account.pw_uid for path in paths
    ):
        raise SystemExit("fixture_ownership_incorrect")

def can_access(account, path):
    pid = os.fork()
    if pid == 0:
        try:
            os.setgroups([])
            os.setgid(account.pw_gid)
            os.setuid(account.pw_uid)
            if path.is_dir():
                os.listdir(path)
            else:
                with open(path, "rb"):
                    pass
        except OSError:
            os._exit(1)
        os._exit(0)
    _, status = os.waitpid(pid, 0)
    return os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0

for index, account in enumerate(users):
    for path in files[index]:
        if not can_access(account, path):
            raise SystemExit("own_profile_unreadable")
    for path in files[1 - index]:
        if can_access(account, path):
            raise SystemExit("cross_profile_read_allowed")
    if can_access(account, receipts):
        raise SystemExit("receipt_directory_read_allowed")
print("RESULT: Unix distinct-UID ownership and access checks passed")
PY
}

for scenario in ready review; do
    scenario_root="$test_root/$scenario"
    home_a="$scenario_root/profile-a"
    home_b="$scenario_root/profile-b"
    receipts="$scenario_root/receipts"
    mkdir -p "$home_a" "$home_b" "$receipts"
    chmod 711 "$scenario_root"
    chmod 700 "$home_a" "$home_b"
    chown "$test_user_a" "$home_a"
    chown "$test_user_b" "$home_b"
    chmod 700 "$receipts"
    profile_file="$scenario_root/profiles.txt"
    printf '%s:%s\n%s:%s\n' "$test_user_a" "$home_a" "$test_user_b" "$home_b" > "$profile_file"
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
    check_account_isolation
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
