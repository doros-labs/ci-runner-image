#!/usr/bin/env bash
#
# Runs exactly one GitHub Actions job, then exits.
#
# Contract with the host:
#   - the host drops a one-shot JIT runner config into $JIT_DIR/jitconfig (default /jit);
#   - $WORK_DIR (default /work) is a writable volume that belongs to this container only;
#   - the container is restarted by the host after it exits, for the next job.
#
# Why the runner is copied: the image's root filesystem is mounted read-only, but the
# runner writes files next to its own binaries while it starts (its decoded settings, a
# helper script, its diagnostic logs). So every job starts from a fresh copy of the
# pristine install, placed on the work volume.
set -euo pipefail

jit_dir="${JIT_DIR:-/jit}"
work_dir="${WORK_DIR:-/work}"
install_dir="${RUNNER_INSTALL:-/home/runner}"
job_runner="${work_dir}/runner"

echo "ci-runner: waiting for a runner config in ${jit_dir}/jitconfig"
while [ ! -s "${jit_dir}/jitconfig" ]; do
  sleep 5
done

# Clean slate first, config second: if preparing the work volume fails (for example the
# disk is full), the config is still there for the next attempt.
find "${work_dir}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
mkdir -p "${work_dir}/_work"
cp -a "${install_dir}/." "${job_runner}"

# The host usually points HOME and the cache directories into the work volume, which the
# wipe above just emptied: create whichever of them are set.
for dir in "${HOME:-}" "${XDG_CACHE_HOME:-}" "${COREPACK_HOME:-}" "${npm_config_cache:-}"; do
  if [ -n "${dir}" ]; then mkdir -p "${dir}"; fi
done

# Read the config once and delete it, so it can never start a second job.
jit_config="$(cat "${jit_dir}/jitconfig")"
rm -f "${jit_dir}/jitconfig"

echo "ci-runner: starting one job from ${job_runner}"
cd "${job_runner}"
exec ./run.sh --jitconfig "${jit_config}"
