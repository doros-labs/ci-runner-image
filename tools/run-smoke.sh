#!/usr/bin/env bash
# usage: run-smoke.sh <image ref>
# Runs ci-runner-smoke in the hardened container (the flags a host uses), on a fresh work dir.
set -euo pipefail
image="${1:?image ref}"
work="$(mktemp -d)"
chmod 0777 "${work}"
docker run --rm --platform linux/amd64 --read-only --network none --user 1001:1001 --cap-drop ALL \
  --security-opt no-new-privileges:true --tmpfs /tmp:size=1g --tmpfs /home/runner/_diag:size=64m --shm-size 512m \
  --memory 4g --memory-swap 4g --cpus 4 --pids-limit 2048 \
  -v "${work}:/work" -e HOME=/work/home -e XDG_CACHE_HOME=/work/.cache -e COREPACK_HOME=/work/.corepack -e npm_config_cache=/work/.npm \
  --entrypoint ci-runner-smoke "${image}"
