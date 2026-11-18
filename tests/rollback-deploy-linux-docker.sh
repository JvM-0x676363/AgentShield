#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 2 || "$1" != --image || -z "$2" ]]; then
    echo 'Usage: bash tests/rollback-deploy-linux-docker.sh --image <local-image>' >&2
    exit 2
fi
image="$2"

command -v docker >/dev/null 2>&1 || { echo 'docker_not_found' >&2; exit 2; }
docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 || {
    echo 'docker_daemon_unavailable' >&2
    exit 2
}
docker image inspect "$image" >/dev/null 2>&1 || {
    echo 'image_not_cached: choose a local image with bash, Python 3, Git, useradd, and coreutils; no image will be pulled' >&2
    exit 2
}

docker run --rm --pull=never --network none \
    --security-opt no-new-privileges \
    --pids-limit 128 --memory 512m \
    --mount "type=bind,src=$repo,dst=/agent-shield,readonly" \
    --tmpfs /tmp:rw,exec,nosuid,size=256m \
    --workdir /agent-shield --user 0:0 --entrypoint bash \
    "$image" tests/rollback-deploy-linux-docker-inner.sh

echo 'RESULT: Docker container removed; fixture evidence was disposable.'
