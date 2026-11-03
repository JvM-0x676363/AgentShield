#!/usr/bin/env bash

set -u

BASE_DIR='/var/tmp'
ZIP="$BASE_DIR/agent-shield.zip"
PACKAGE_DIR="$BASE_DIR/agent-shield"

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}; value=${value//\"/\\\"}; value=${value//$'\n'/\\n}; value=${value//$'\r'/\\r}; value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

cleanup_ok=false
removed_zip=false
removed_dir=false
cleanup_error=''

if [[ "$BASE_DIR" != '/var/tmp' ]]; then
    cleanup_error='Unexpected staging directory.'
else
    cleanup_ok=true
    if [[ -e "$ZIP" ]]; then
        if rm -f -- "$ZIP"; then removed_zip=true; else cleanup_ok=false; cleanup_error='Could not remove staged package.'; fi
    fi
    if [[ -e "$PACKAGE_DIR" ]]; then
        if rm -rf -- "$PACKAGE_DIR"; then removed_dir=true; else cleanup_ok=false; cleanup_error='Could not remove extracted package.'; fi
    fi
fi

printf '{"cleanup_ok":%s,"removed_zip":%s,"removed_dir":%s,"base_dir":"%s","cleanup_error":"%s"}\n' \
    "$cleanup_ok" "$removed_zip" "$removed_dir" "$BASE_DIR" "$(json_escape "$cleanup_error")"
