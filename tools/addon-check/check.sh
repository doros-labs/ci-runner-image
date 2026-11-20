#!/usr/bin/env bash
# usage (inside the image, see tools/run-addon-check.sh): check.sh <dir with package.json and package-lock.json>
#
# Installs the lockfile with npm ci, the way a project install does, then loads the addon and
# opens an in-memory database. better-sqlite3 ships prebuilt binaries; npm still runs its
# implicit `node-gyp rebuild`, which must succeed without a compiler, compile nothing and take
# the Node headers from npm_config_nodedir instead of downloading them.
#
# The lockfile pins version and integrity but carries no `resolved` URLs (one tarball name
# has the shape this repository's content denylist rejects): npm resolves name@version from
# the registry and verifies the integrity.
set -euo pipefail

fail() { echo "addon-check: FAIL: $*" >&2; exit 1; }
ok() { echo "addon-check: ok: $*"; }

src="${1:?source dir}"
dir="${WORK_DIR:-/work}/addon-check"
rm -rf "${dir}"
mkdir -p "${dir}"
cp "${src}/package.json" "${src}/package-lock.json" "${dir}/"
cd "${dir}"

npm ci --no-audit --no-fund >npm-ci.log 2>&1 || { cat npm-ci.log; fail "npm ci failed"; }
cat npm-ci.log
pkg="node_modules/better-sqlite3"
[ -d "${pkg}/build" ] || fail "npm's implicit node-gyp rebuild did not run (no ${pkg}/build)"
compiled="$(find "${pkg}/build" -name '*.node' -print)"
[ -z "${compiled}" ] || fail "node-gyp compiled the addon instead of using the prebuilt binary: ${compiled}"
gyp_cache="${XDG_CACHE_HOME:?XDG_CACHE_HOME must be set}/node-gyp"
[ ! -e "${gyp_cache}" ] || fail "node-gyp downloaded Node headers into ${gyp_cache}; npm_config_nodedir was not used"
node -e '
  const Database = require("better-sqlite3");
  const db = new Database(":memory:");
  const row = db.prepare("select sqlite_version() as version, 6 * 7 as answer").get();
  if (row.answer !== 42) throw new Error("unexpected query result " + JSON.stringify(row));
  db.close();
  console.log("SQLite " + row.version);
' >load.log 2>&1 || { cat load.log; fail "better-sqlite3 does not load or cannot open an in-memory database"; }
ok "npm ci with the implicit node-gyp rebuild (no compile, no header download); better-sqlite3 loads, $(cat load.log) in memory"
