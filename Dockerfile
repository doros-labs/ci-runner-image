# syntax=docker/dockerfile:1
#
# A general-purpose, ephemeral self-hosted GitHub Actions runner image.
#
# Intended runtime: one container per job, started with a just-in-time (JIT) runner config,
# a read-only root filesystem, a non-root user and two writable volumes (/work for the job,
# /jit for the one-shot config). The container never needs a Docker socket.
#
# Contents: the GitHub runner (from GitHub's own runner image), Node.js from the official
# Node image (with its headers), Python 3, make and a set of common command-line tools. No
# compiler is added, and the runner user gets no sudo. Nothing host-specific (addresses,
# tokens, names) is baked in; a host passes its own values at run time.

# Node major line this image ships; the smoke check asserts it. The Node stage is pinned by
# digest (the node:22-slim index, as the build summary's "Base image digests" printed it);
# a bump changes NODE_MAJOR and the digest together.
ARG NODE_MAJOR=22
FROM node:${NODE_MAJOR}-slim@sha256:e9f565d32859f0cbfb52125eafe8be39390f24dac302dc3cdf566e8ba3ab21ee AS node

# GitHub's runner image: Ubuntu, a `runner` user with uid 1001, the runner in /home/runner.
FROM ghcr.io/actions/actions-runner:2.337.0@sha256:e5496277be5d09bc968b3d64911b74e219ac4a3f2edce956a3ecf9271bea1ef4

ARG NODE_MAJOR=22
ENV NODE_MAJOR=${NODE_MAJOR}
LABEL org.opencontainers.image.source="https://github.com/doros-labs/ci-runner-image"
LABEL org.opencontainers.image.description="Ephemeral self-hosted GitHub Actions runner (JIT, read-only root, uid 1001)"
USER root
ENV DEBIAN_FRONTEND=noninteractive

# Command-line tools for typical Node/Python test suites. ffmpeg without recommends.
# make (no compiler): npm runs an implicit `node-gyp rebuild` for every package with a
# binding.gyp, also when the package ships a prebuilt binary and its binding.gyp then builds
# nothing; that rebuild still calls make. The smoke check asserts make is there and no C/C++
# compiler is.
# iproute2 for ss: test suites probe listening ports with it.
# python3-venv (venv + ensurepip) so suites can build a throwaway virtual environment; it follows
# the base image's default python3, so a base upgrade does not leave a stale version-pinned package.
# sudo is purged with its configuration: the runner user gets no privilege escalation.
# The smoke check asserts that sudo is absent.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl git python3 ffmpeg zip unzip file procps gawk tar gzip xz-utils \
       tmux jq sqlite3 make iproute2 python3-venv \
  && SUDO_FORCE_REMOVE=yes apt-get purge -y sudo \
  && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
# The headers of this exact Node build, for node-gyp: with npm_config_nodedir set, node-gyp
# configures against them and never downloads a header tarball.
COPY --from=node /usr/local/include/node /usr/local/include/node
ENV npm_config_nodedir=/usr/local
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

COPY --chmod=0755 entrypoint.sh /usr/local/bin/ci-runner-entrypoint
COPY --chmod=0755 smoke.sh /usr/local/bin/ci-runner-smoke
USER 1001:1001
WORKDIR /home/runner
ENTRYPOINT ["/usr/local/bin/ci-runner-entrypoint"]
