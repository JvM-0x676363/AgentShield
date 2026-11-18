#!/usr/bin/env bash
set -euo pipefail

for tool in bash python3 git useradd id chown chmod mktemp; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "container_tool_missing: $tool" >&2
        exit 2
    }
done

[[ $EUID -eq 0 ]] || { echo 'container_root_required' >&2; exit 2; }
useradd --uid 50001 --user-group --no-create-home --shell /bin/sh agentshield_a
useradd --uid 50002 --user-group --no-create-home --shell /bin/sh agentshield_b

AGENTSHIELD_TEST_USER_A=agentshield_a \
AGENTSHIELD_TEST_USER_B=agentshield_b \
    bash tests/rollback-deploy-unix.sh
