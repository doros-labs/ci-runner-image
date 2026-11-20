# syntax=docker/dockerfile:1
#
# A general-purpose, ephemeral self-hosted GitHub Actions runner image.
#
# Intended runtime: one container per job, started with a just-in-time (JIT) runner config,
# a read-only root filesystem, a non-root user and two writable volumes (/work for the job,
# /jit for the one-shot config). The container never needs a Docker socket.
#
# Contents: the GitHub runner (from GitHub's own runner image), Node.js from the official
# Node image, Python 3 and a set of common command-line tools. No compiler is added, and
# the runner user gets no sudo. Nothing host-specific (addresses, tokens, names) is baked in;
# a host passes its own values at run time.

# Node major line this image ships; the smoke check asserts it. The first build runs from
# the tag, and its summary prints the digest to pin here in a follow-up commit.
ARG NODE_MAJOR=22
FROM node:${NODE_MAJOR}-slim AS node

# GitHub's runner image: Ubuntu, a `runner` user with uid 1001, the runner in /home/runner.
FROM ghcr.io/actions/actions-runner:2.337.0@sha256:e5496277be5d09bc968b3d64911b74e219ac4a3f2edce956a3ecf9271bea1ef4

ARG NODE_MAJOR=22
ENV NODE_MAJOR=${NODE_MAJOR}
LABEL org.opencontainers.image.source="https://github.com/doros-labs/ci-runner-image"
LABEL org.opencontainers.image.description="Ephemeral self-hosted GitHub Actions runner (JIT, read-only root, uid 1001)"
USER root
ENV DEBIAN_FRONTEND=noninteractive

# Command-line tools for typical Node/Python test suites. ffmpeg without recommends.
# sudo is purged with its configuration: the runner user gets no privilege escalation.
# The smoke check asserts that sudo is absent.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates curl git python3 ffmpeg zip unzip file procps gawk tar gzip xz-utils \
       tmux jq sqlite3 \
  && SUDO_FORCE_REMOVE=yes apt-get purge -y sudo \
  && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

COPY --chmod=0755 entrypoint.sh /usr/local/bin/ci-runner-entrypoint
COPY --chmod=0755 smoke.sh /usr/local/bin/ci-runner-smoke
USER 1001:1001
WORKDIR /home/runner
ENTRYPOINT ["/usr/local/bin/ci-runner-entrypoint"]
