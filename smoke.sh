#!/usr/bin/env bash
#
# ci-runner-smoke: checks the image inside the same hardened container a host runs it in.
# Typical command (the build workflow runs exactly this before and after a push):
#
#   docker run --rm --read-only --network none --user 1001:1001 --cap-drop ALL \
#     --security-opt no-new-privileges:true --tmpfs /tmp:size=1g --tmpfs /home/runner/_diag:size=64m \
#     --shm-size 512m \
#     --memory 4g --memory-swap 4g --cpus 4 --pids-limit 2048 \
#     -v <dir>:/work -e HOME=/work/home -e XDG_CACHE_HOME=/work/.cache -e COREPACK_HOME=/work/.corepack \
#     -e npm_config_cache=/work/.npm \
#     --entrypoint ci-runner-smoke <image>
#
# Prints one `ok:` line per passed check; the first failure prints `FAIL:` and exits 1.
set -euo pipefail

work_dir="${WORK_DIR:-/work}"
install_dir="${RUNNER_INSTALL:-/home/runner}"

fail() { echo "ci-runner-smoke: FAIL: $*" >&2; exit 1; }
ok() { echo "ci-runner-smoke: ok: $*"; }

# 1. User and filesystem.
[ "$(id -u)" = "1001" ] || fail "uid is $(id -u), expected 1001"
# Read-only root, two independent ways. /home/runner belongs to uid 1001 and lives on the
# root filesystem, so a write there succeeds on a writable root and fails only under
# --read-only. And the kernel's own view: the mount at / must carry the ro option.
if touch /home/runner/.rw-probe 2>/dev/null; then
  rm -f /home/runner/.rw-probe
  fail "root filesystem is writable (uid 1001 could write /home/runner); start the container with --read-only"
fi
root_opts="$(awk '$5 == "/" { print $6 }' /proc/self/mountinfo | tail -1)"
case ",${root_opts}," in
  *,ro,*) ;;
  *) fail "mountinfo shows / with options '${root_opts}', not ro" ;;
esac
for d in "${work_dir}" "${HOME:?HOME must point to a writable directory}" "${XDG_CACHE_HOME:?XDG_CACHE_HOME must be set}" "${COREPACK_HOME:?COREPACK_HOME must be set}" "${npm_config_cache:?npm_config_cache must be set}"; do
  mkdir -p "$d" 2>/dev/null && touch "$d/.rw-probe" 2>/dev/null && rm -f "$d/.rw-probe" || fail "$d is not writable"
done
t="$(mktemp)" || fail "no writable temp directory (TMPDIR=${TMPDIR:-/tmp})"
rm -f "$t"
if command -v sudo >/dev/null; then fail "sudo is installed ($(command -v sudo))"; fi
[ "$(uname -m)" = "x86_64" ] || fail "architecture $(uname -m), expected x86_64"
ok "x86_64, uid 1001, read-only root; work, HOME, caches and temp writable; no sudo"

# 2. Tools.
major="$(node -p 'process.versions.node.split(".")[0]')" || fail "node does not start"
[ "${major}" = "${NODE_MAJOR:?image must set NODE_MAJOR}" ] || fail "node major ${major}, image declares ${NODE_MAJOR}"
for tool in npm npx python3 curl git ffmpeg zip unzip file ps gawk tar gzip xz tmux jq sqlite3 timeout sha256sum mktemp; do
  command -v "${tool}" >/dev/null || fail "missing tool: ${tool}"
done
python3 -c 'import sqlite3, json, fcntl, http.server, unittest' || fail "python3 standard library incomplete"
ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=blue:s=1024x1024 -frames:v 1 "${work_dir}/probe.jpg" \
  || fail "ffmpeg cannot encode a JPEG"
rm -f "${work_dir}/probe.jpg"
echo "ci-runner-smoke: versions: node $(node --version), npm $(npm --version), $(python3 --version 2>&1), $(git --version), $(ffmpeg -version | head -1)"
ok "tools present"

# 3. The runner starts from a copy on the work volume and can write its own files there.
#    A syntactically valid config that cannot register is enough to reach those writes.
copy="${work_dir}/runner"
rm -rf "${copy}"
cp -a "${install_dir}/." "${copy}"
out="$("${copy}/bin/Runner.Listener" --version 2>&1)" || fail "Runner.Listener --version failed: ${out}"
ver="$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"${out}" | tail -1 || true)"
[ -n "${ver}" ] || fail "no version line from Runner.Listener: ${out}"
settings="$(printf '{"agentName":"smoke","workFolder":"%s/_work"}' "${work_dir}" | base64 -w0)"
fake_config="$(printf '{".runner":"%s"}' "${settings}" | base64 -w0)"
(cd "${copy}" && timeout 120 ./run.sh --jitconfig "${fake_config}" >"${work_dir}/runner-smoke.log" 2>&1) || true
[ -f "${copy}/.runner" ] || { cat "${work_dir}/runner-smoke.log"; fail "runner wrote no .runner file in ${copy}"; }
[ -f "${copy}/run-helper.sh" ] || fail "runner wrote no run-helper.sh in ${copy}"
ls "${copy}/_diag"/Runner_*.log >/dev/null 2>&1 || { cat "${work_dir}/runner-smoke.log"; fail "runner wrote no diagnostic log in ${copy}/_diag"; }
ok "runner ${ver} starts from ${copy}"

# 4. The real entrypoint, end to end, on a scratch jit/work pair inside the work volume:
#    it must consume (delete) the config and start the runner from its own copy.
#    HOME and the caches point into the scratch work dir, the way a host points them into
#    /work: the entrypoint's wipe empties that dir, so afterwards they exist only if the
#    entrypoint created them again.
ep="${work_dir}/entrypoint-check"
rm -rf "${ep}"
mkdir -p "${ep}/jit" "${ep}/work"
printf '%s' "${fake_config}" > "${ep}/jit/jitconfig"
ep_dirs=("${ep}/work/home" "${ep}/work/.cache" "${ep}/work/.corepack" "${ep}/work/.npm")
HOME="${ep_dirs[0]}" XDG_CACHE_HOME="${ep_dirs[1]}" COREPACK_HOME="${ep_dirs[2]}" npm_config_cache="${ep_dirs[3]}" \
  JIT_DIR="${ep}/jit" WORK_DIR="${ep}/work" timeout 150 /usr/local/bin/ci-runner-entrypoint >"${ep}/entrypoint.log" 2>&1 || true
[ ! -e "${ep}/jit/jitconfig" ] || { cat "${ep}/entrypoint.log"; fail "entrypoint did not delete the consumed jitconfig"; }
[ -f "${ep}/work/runner/.runner" ] || { cat "${ep}/entrypoint.log"; fail "entrypoint's runner wrote no .runner in ${ep}/work/runner"; }
for d in "${ep_dirs[@]}"; do
  [ -d "${d}" ] || { cat "${ep}/entrypoint.log"; fail "entrypoint did not create ${d} again after its wipe"; }
done
ok "entrypoint consumed the config, created HOME and the caches again, and started the runner from its copy"

# 5. Native addons that ship a prebuilt binary install without a compiler. npm runs an
#    implicit `node-gyp rebuild` for every package with a binding.gyp; when an addon uses its
#    prebuilt binary (better-sqlite3 does), its binding.gyp builds nothing (a target of type
#    none), but node-gyp still configures against the Node headers and runs make. This section runs the same
#    configure and build on such a target, offline (the smoke container has no network), so
#    the headers must come from npm_config_nodedir, never from a download.
command -v make >/dev/null || fail "missing tool: make"
make_ver="$(make --version 2>&1)" || fail "make --version failed: ${make_ver}"
for compiler in cc c++ gcc g++; do
  if command -v "${compiler}" >/dev/null; then fail "a C/C++ compiler is on PATH: ${compiler} ($(command -v "${compiler}"))"; fi
done
# better-sqlite3's prebuilt linux-x64 binary (the addon tools/addon-check installs) needs GLIBC_2.34.
ldd_out="$(ldd --version 2>&1)" || fail "ldd --version failed: ${ldd_out}"
glibc="$(awk 'NR == 1 { print $NF }' <<<"${ldd_out}")"
[[ "${glibc}" =~ ^[0-9]+\.[0-9]+$ ]] || fail "no glibc version in the first line of ldd --version: ${ldd_out%%$'\n'*}"
[ "$(printf '%s\n' 2.34 "${glibc}" | sort -V | head -1)" = "2.34" ] || fail "glibc ${glibc} is older than 2.34"
nodedir="${npm_config_nodedir:?image must set npm_config_nodedir}"
hdr="${nodedir}/include/node"
[ -f "${hdr}/common.gypi" ] && [ -f "${hdr}/node_version.h" ] && [ -f "${hdr}/node_api.h" ] \
  || fail "no Node headers in ${hdr} (common.gypi, node_version.h, node_api.h)"
hdr_ver="$(awk '$1 == "#define" && $2 ~ /^NODE_(MAJOR|MINOR|PATCH)_VERSION$/ { v = v (v == "" ? "" : ".") $3 } END { print v }' "${hdr}/node_version.h")"
[ "v${hdr_ver}" = "$(node --version)" ] || fail "headers in ${hdr} are ${hdr_ver}, node is $(node --version)"
node_gyp="${NODE_GYP:-/usr/local/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js}"
[ -f "${node_gyp}" ] || fail "npm's node-gyp not found at ${node_gyp}"
gyp_dir="${work_dir}/node-gyp-check"
rm -rf "${gyp_dir}"
mkdir -p "${gyp_dir}"
echo "{ 'targets': [ { 'target_name': 'prebuilt_only', 'type': 'none' } ] }" > "${gyp_dir}/binding.gyp"
(cd "${gyp_dir}" && node "${node_gyp}" configure >"${gyp_dir}/configure.log" 2>&1) \
  || { cat "${gyp_dir}/configure.log"; fail "offline node-gyp configure against ${nodedir} failed"; }
[ -f "${gyp_dir}/build/Makefile" ] || { cat "${gyp_dir}/configure.log"; fail "node-gyp configure wrote no build/Makefile"; }
(cd "${gyp_dir}" && node "${node_gyp}" build >"${gyp_dir}/build.log" 2>&1) \
  || { cat "${gyp_dir}/build.log"; fail "node-gyp build (make) of a target that compiles nothing failed"; }
ok "${make_ver%%$'\n'*}, glibc ${glibc}, Node ${hdr_ver} headers in ${hdr}; offline node-gyp configure and build of a no-compile target; no C/C++ compiler"

echo "ci-runner-smoke: all checks passed"
