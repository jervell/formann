# Formann runner image. Edit for your project's JDK version, build tools, dependencies.
#
# Builds from <consumer>/runner/ — no framework files needed in the build context.
# Extend this file as your project requires; the installer will not overwrite edits.

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Dispatches run without a TTY, leaving TERM unset; tools that shell out to
# tput (e.g. `bats -p`) hard-fail without it.
ENV TERM=dumb

# UTF-8 locale — without it the JVM (and other filename-sensitive tooling)
# decodes paths as ASCII and chokes on non-ASCII file names. C.UTF-8 is built
# into Debian; no locales package needed.
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      gnupg \
      jq \
      wget \
 && rm -rf /var/lib/apt/lists/*

# Eclipse Temurin JDK 25 from the Adoptium apt repo.
RUN wget -qO- https://packages.adoptium.net/artifactory/api/gpg/key/public \
      | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" \
      > /etc/apt/sources.list.d/adoptium.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends temurin-25-jdk \
 && rm -rf /var/lib/apt/lists/*

# Apache Maven, pinned from the Apache archive. Debian's apt package is frozen
# at 3.8.x, which silently ignores maven.repo.local.tail (see MAVEN_ARGS
# below) — the local-artifact read-through needs 3.9+. A repo that ships its
# own mvnw takes precedence simply by being invoked as ./mvnw.
ARG MAVEN_VERSION=3.9.16
RUN curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
      | tar -xz -C /opt \
 && ln -s "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn

# The runner bind-mounts the host's ~/.m2/repository read-only at
# /home/runner/.m2-host. The tail setting makes every Maven build read
# through to it for artifacts that only exist locally (e.g. locally-built
# snapshots of personal libraries), while downloads still land in the
# writable per-feature cache volume.
ENV MAVEN_ARGS="-Dmaven.repo.local.tail=/home/runner/.m2-host -Dmaven.repo.local.tail.ignoreAvailability=true"

# GitHub CLI (github-issues binding) and bats (framework test suite).
RUN wget -qO /usr/share/keyrings/githubcli-archive-keyring.gpg \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg \
 && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      bats \
      gh \
 && rm -rf /var/lib/apt/lists/*

# Node.js 20 from NodeSource, then the Claude CLI.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force

ARG RUNNER_UID=1000
ARG RUNNER_GID=1000
RUN groupadd --gid ${RUNNER_GID} runner \
 && useradd --create-home --uid ${RUNNER_UID} --gid ${RUNNER_GID} --shell /bin/bash runner \
 && mkdir -p /repo \
 && chown ${RUNNER_UID}:${RUNNER_GID} /repo

# Inline entrypoint — suppresses kernel core dumps so a container crash can't
# drop a `core` file into the bind-mounted runner-checkout, and logs the
# actual limit state and core_pattern so each dispatch log carries direct
# evidence of whether the prevention is in force.
RUN printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -e' \
      'ulimit -c 0' \
      'echo "runner: entrypoint: ulimit -c soft=$(ulimit -c)" >&2' \
      'echo "runner: entrypoint: ulimit -c hard=$(ulimit -Hc)" >&2' \
      'echo "runner: entrypoint: core_pattern=$(cat /proc/sys/kernel/core_pattern)" >&2' \
      'exec "$@"' \
    > /usr/local/bin/entrypoint.sh \
 && chmod +x /usr/local/bin/entrypoint.sh

USER runner
RUN git config --global --add safe.directory /repo
WORKDIR /repo

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
