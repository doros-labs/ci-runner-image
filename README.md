# ci-runner-image

A general-purpose, ephemeral self-hosted GitHub Actions runner image for linux/amd64, published at `ghcr.io/doros-labs/ci-runner`.

**Pin it by digest, never by tag.** Each main build prints the digest it pushed, and the smoke check has passed on that exact digest.

**Do not pin the bootstrap build.** The very first build runs its Node stage from a tag. Only builds whose Dockerfile pins every base image by digest are meant to be pinned.

## What is inside
- GitHub's runner image as the base (pinned release + digest). The runtime user is uid 1001.
- Node.js (major line in the Dockerfile's `NODE_MAJOR`) from the official Node image.
- Python 3 with its standard library and the venv module (python3-venv, with ensurepip).
- curl, git, ffmpeg, zip/unzip, file, procps, gawk, tar/gzip/xz, tmux, jq, sqlite3, make, iproute2 (ss).
- The headers of the shipped Node build in `/usr/local/include/node`, with `npm_config_nodedir=/usr/local`. Together with make this lets npm's implicit `node-gyp rebuild` finish for addons that ship a prebuilt binary (its binding.gyp then compiles nothing), without a header download.
- No compiler and no sudo: an addon without a prebuilt binary for this platform does not build here. No addresses, tokens or other host-specific values.

## How it runs
- The container runs one job and exits (`ci-runner-entrypoint`).
- It waits until `/jit/jitconfig` exists and is non-empty (the host writes it atomically, one file per container), reads it once and deletes it, so a config can never start a second job.
- It wipes `/work`, then runs the job from a fresh copy of the runner placed there. The runner writes next to its own files even in JIT mode (its settings, a helper script, its diagnostic logs); running from the copy keeps all of that on `/work`, so the root filesystem can stay read-only.
- Runner labels come from the JIT config, not from the image.

Recommended container flags. The smoke check uses exactly these. A host normally sets `HOME`, `XDG_CACHE_HOME` and `COREPACK_HOME`. `npm_config_cache` under `/work` is an extra the smoke adds, and it is recommended: without it, `npm ci` tries to write `~/.npm` on the read-only root. The entrypoint creates whichever of these directories are set, after it wipes `/work`.
```
--read-only --user 1001:1001 --cap-drop ALL --security-opt no-new-privileges:true
--tmpfs /tmp:size=1g --tmpfs /home/runner/_diag:size=64m --shm-size 512m
-v <work>:/work -v <jit>:/jit
-e HOME=/work/home -e XDG_CACHE_HOME=/work/.cache -e COREPACK_HOME=/work/.corepack
-e npm_config_cache=/work/.npm
```

## Network a job typically needs
- GitHub: the runner service and repository checkout.
- The npm registry, for `npm ci`.
- The Actions cache service, only for jobs that use a cache.

## Checks
- `tools/denylist-check.py`: fails the build on internal-looking or secret-looking content: private-style paths, IP addresses, local host names, e-mail addresses, issue keys, accented words, credential shapes.
- `ci-runner-smoke`: user, read-only root (a write probe plus the mount options), tools, runner start, the real entrypoint end to end, and the native-addon prerequisites (make, glibc 2.34 or newer, matching Node headers, an offline node-gyp configure and build of a target that compiles nothing, no C/C++ compiler on PATH), ss, and a `python3 -m venv` with a working pip. It runs in the hardened container before the push and again on the pushed digest; the tags move only after that.
- `tools/run-addon-check.sh`: the same container flags with network, `npm ci` of `tools/addon-check` (better-sqlite3, which ships prebuilt binaries), then loads it and opens an in-memory database. It runs next to the smoke check, on both images.
