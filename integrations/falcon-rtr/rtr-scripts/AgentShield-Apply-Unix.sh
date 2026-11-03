#!/usr/bin/env bash

# Replace this placeholder with the SHA-256 of the reviewed agent-shield.zip
# before uploading the script to Falcon. Do not leave the placeholder in place.
EXPECTED_PACKAGE_SHA256='<AGENTSHIELD_PACKAGE_SHA256>'
set -u

PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'
export PATH
BASE_DIR='/var/tmp'
ZIP="$BASE_DIR/agent-shield.zip"
PACKAGE_DIR="$BASE_DIR/agent-shield"

case "$(uname -s)" in
    Darwin) PLATFORM='mac' ;;
    Linux) PLATFORM='linux' ;;
    *) PLATFORM='unknown' ;;
esac

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}; value=${value//\"/\\\"}; value=${value//$'\n'/\\n}; value=${value//$'\r'/\\r}; value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

json_bool() { [[ "$1" == 'true' ]] && printf 'true' || printf 'false'; }

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
    else return 1; fi
}

OUTCOME='error'; PACKAGE_SHA256=''; EXTRACT_OK='false'; ERROR=''
PRECHECK_COMPLIANT='false'; PRECHECK_CODE=-1; DEPLOY_RAN='false'; DEPLOY_STATUS=''; DEPLOY_CODE=-1
VALIDATE_COMPLIANT='false'; VALIDATE_CODE=-1; CLEANUP_OK='false'; CLEANUP_ERROR=''

emit() {
    printf '{"outcome":"%s","platform":"%s","package_sha256":"%s","extract_ok":%s,"precheck_compliant":%s,"precheck_exit_code":%d,"deploy_ran":%s,"deploy_status":"%s","deploy_exit_code":%d,"validate_compliant":%s,"validate_exit_code":%d,"deploy_log_path":"/var/log/agentshield/agent-shield-deploy.log","error":"%s","cleanup_ok":%s,"cleanup_error":"%s"}\n' \
        "$OUTCOME" "$PLATFORM" "$(json_escape "$PACKAGE_SHA256")" "$(json_bool "$EXTRACT_OK")" \
        "$(json_bool "$PRECHECK_COMPLIANT")" "$PRECHECK_CODE" "$(json_bool "$DEPLOY_RAN")" \
        "$(json_escape "$DEPLOY_STATUS")" "$DEPLOY_CODE" "$(json_bool "$VALIDATE_COMPLIANT")" "$VALIDATE_CODE" \
        "$(json_escape "$ERROR")" "$(json_bool "$CLEANUP_OK")" "$(json_escape "$CLEANUP_ERROR")"
}

run_package_script() {
    local output
    output="$(/bin/bash "$@" 2>&1)"
    RUN_CODE=$?
    RUN_JSON="$(printf '%s\n' "$output" | grep -E '^[[:space:]]*\{' | tail -n 1)"
}

has_compliance_result() { [[ "$1" =~ \"compliant\"[[:space:]]*:[[:space:]]*(true|false) ]]; }
is_compliant() { [[ "$1" =~ \"compliant\"[[:space:]]*:[[:space:]]*true ]]; }

cleanup() {
    if [[ "$BASE_DIR" != '/var/tmp' ]]; then CLEANUP_ERROR='Unexpected staging directory.'; return; fi
    if rm -rf -- "$PACKAGE_DIR" && rm -f -- "$ZIP"; then CLEANUP_OK='true'; else CLEANUP_ERROR='Could not remove AgentShield staging.'; fi
}

main() {
    if [[ "$EXPECTED_PACKAGE_SHA256" == '<AGENTSHIELD_PACKAGE_SHA256>' || ! "$EXPECTED_PACKAGE_SHA256" =~ ^[a-fA-F0-9]{64}$ ]]; then ERROR='Expected package SHA-256 is not configured.'; return; fi
    if [[ ! -f "$ZIP" ]]; then ERROR='AgentShield package was not found in the approved staging directory.'; return; fi
    PACKAGE_SHA256="$(sha256_file "$ZIP")" || { ERROR='No SHA-256 utility is available.'; return; }
    local actual_hash expected_hash
    actual_hash="$(printf '%s' "$PACKAGE_SHA256" | tr '[:upper:]' '[:lower:]')"
    expected_hash="$(printf '%s' "$EXPECTED_PACKAGE_SHA256" | tr '[:upper:]' '[:lower:]')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then ERROR='AgentShield package SHA-256 did not match the configured value.'; return; fi
    mkdir -p "$PACKAGE_DIR" || { ERROR='Could not create extraction directory.'; return; }
    if command -v unzip >/dev/null 2>&1; then unzip -oq "$ZIP" -d "$PACKAGE_DIR" || { ERROR='Package extraction failed.'; return; }
    elif command -v python3 >/dev/null 2>&1; then python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$ZIP" "$PACKAGE_DIR" || { ERROR='Package extraction failed.'; return; }
    else ERROR='Neither unzip nor Python 3 is available for package extraction.'; return; fi
    EXTRACT_OK='true'

    run_package_script "$PACKAGE_DIR/Test-AgentShieldManaged.sh" --output-mode Quiet
    PRECHECK_CODE=$RUN_CODE
    if ! has_compliance_result "$RUN_JSON"; then OUTCOME='precheck_failed'; return; fi
    if is_compliant "$RUN_JSON"; then PRECHECK_COMPLIANT='true'; OUTCOME='already_compliant'; return; fi

    run_package_script "$PACKAGE_DIR/deploy.sh" --force --skip-tools --skip-vscode --output-mode Quiet
    DEPLOY_RAN='true'; DEPLOY_CODE=$RUN_CODE
    if [[ "$RUN_JSON" =~ \"status\"[[:space:]]*:[[:space:]]*\"([a-z]+)\" ]]; then DEPLOY_STATUS="${BASH_REMATCH[1]}"; else DEPLOY_STATUS='unparsed'; fi
    if [[ "$DEPLOY_CODE" -ne 0 || "$DEPLOY_STATUS" != 'success' ]]; then OUTCOME='deploy_failed'; return; fi

    run_package_script "$PACKAGE_DIR/Test-AgentShieldManaged.sh" --output-mode Quiet
    VALIDATE_CODE=$RUN_CODE
    if ! has_compliance_result "$RUN_JSON"; then OUTCOME='validation_failed'; return; fi
    if is_compliant "$RUN_JSON"; then VALIDATE_COMPLIANT='true'; OUTCOME='compliant_after_deploy'; else OUTCOME='not_compliant_after_deploy'; fi
}

main
cleanup
emit
