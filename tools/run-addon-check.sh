#!/usr/bin/env bash
# usage: run-addon-check.sh <image ref>
# Runs tools/addon-check/check.sh in the hardened container (the flags run-smoke.sh uses), on a
# fresh work dir, but WITH network access: npm ci needs the package registry. Everything else
# about the image is checked offline by run-smoke.sh.
set -euo pipefail
image="${1:?image ref}"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
chmod 0777 "${work}"
docker run --rm --platform linux/amd64 --read-only --user 1001:1001 --cap-drop ALL \
  --security-opt no-new-privileges:true --tmpfs /tmp:size=1g --shm-size 512m \
  --memory 4g --memory-swap 4g --cpus 4 --pids-limit 2048 \
  -v "${work}:/work" -v "${here}/addon-check:/addon-check:ro" \
  -e HOME=/work/home -e XDG_CACHE_HOME=/work/.cache -e COREPACK_HOME=/work/.corepack -e npm_config_cache=/work/.npm \
  --entrypoint bash "${image}" /addon-check/check.sh /addon-check
