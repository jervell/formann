# Formann runner image. Edit for your project's JDK version, build tools, dependencies.
#
# Builds from <consumer>/runner/ — no framework files needed in the build context.
# Extend this file as your project requires; the installer will not overwrite edits.

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      gnupg \
      jq \
      maven \
      wget \
 && rm -rf /var/lib/apt/lists/*

# Eclipse Temurin JDK 21 from the Adoptium apt repo.
RUN wget -qO- https://packages.adoptium.net/artifactory/api/gpg/key/public \
      | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" \
      > /etc/apt/sources.list.d/adoptium.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends temurin-21-jdk \
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
