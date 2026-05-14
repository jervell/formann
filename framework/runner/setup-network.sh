#!/usr/bin/env bash
# Create the AFK runner sandbox Docker bridge network and apply the
# RFC1918-deny outbound policy. Idempotent: safe to invoke when the
# network and rules already exist.
#
# Network shape:
# - Custom bridge driver, fixed subnet, fixed Linux bridge interface name
#   (so iptables can target it).
# - Public internet stays reachable (Anthropic API, Maven Central, GitHub,
#   javadoc, etc.).
# - RFC1918 destinations (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) are
#   dropped, except for the bridge's own subnet — intra-bridge traffic is
#   allowed via an explicit RETURN before the deny rules.
#
# iptables rules live in a dedicated chain (RUNNER_FW_CHAIN) that
# DOCKER-USER jumps to for packets entering on the sandbox bridge. Rules
# are applied via a privileged sidecar container that joins the Docker VM's
# host network namespace.
#
# Prints the network name on stdout on success so callers can capture it
# (e.g. NET="$(framework/runner/setup-network.sh)").

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

# 1. Create the bridge network if absent.
if ! docker network inspect "$RUNNER_NETWORK_NAME" >/dev/null 2>&1; then
  docker network create "$RUNNER_NETWORK_NAME" \
    --driver bridge \
    --subnet "$RUNNER_SUBNET" \
    --opt "com.docker.network.bridge.name=$RUNNER_BRIDGE_NAME" \
    >&2
fi

# 2. Apply the iptables policy via a privileged sidecar.
#
# DOCKER-USER is consulted before Docker's own forwarding chain, so a jump
# inserted here intercepts packets from sandbox containers before they
# reach the masquerade path. The chain is flushed before re-population so
# repeat invocations don't accumulate duplicate rules.
FW_SCRIPT=$(cat <<EOF
set -e
apk add --no-cache iptables >/dev/null

iptables -N ${RUNNER_FW_CHAIN} 2>/dev/null || iptables -F ${RUNNER_FW_CHAIN}

# Allow intra-bridge traffic before any RFC1918 deny.
iptables -A ${RUNNER_FW_CHAIN} -d ${RUNNER_SUBNET} -j RETURN

# Deny RFC1918 destinations.
iptables -A ${RUNNER_FW_CHAIN} -d 10.0.0.0/8     -j DROP
iptables -A ${RUNNER_FW_CHAIN} -d 172.16.0.0/12  -j DROP
iptables -A ${RUNNER_FW_CHAIN} -d 192.168.0.0/16 -j DROP

# Hook DOCKER-USER -> our chain for packets entering the sandbox bridge.
if ! iptables -C DOCKER-USER -i ${RUNNER_BRIDGE_NAME} -j ${RUNNER_FW_CHAIN} 2>/dev/null; then
  iptables -I DOCKER-USER -i ${RUNNER_BRIDGE_NAME} -j ${RUNNER_FW_CHAIN}
fi
EOF
)

docker run --rm \
  --network host \
  --privileged \
  --cap-add NET_ADMIN \
  alpine:latest \
  sh -ec "$FW_SCRIPT" >&2

echo "$RUNNER_NETWORK_NAME"
