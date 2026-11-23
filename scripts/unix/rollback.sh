#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' '{"schema_version":1,"runner":"rollback","status":"blocked","reason":"python3_not_found","exit_code":2}'
  exit 2
fi
exec python3 "$root/scripts/rollback/rollback.py" "$@"
