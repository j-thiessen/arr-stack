#!/bin/bash
# Re-apply the NordVPN rules the arr stack depends on.
#
# Safe to run repeatedly. Every step runs independently: NordVPN exits
# non-zero when a rule is *already* applied, which is the normal case on
# most boots, so a shared failure path would skip the later settings —
# exactly the ones most likely to have reset.
#
# Deliberately no `set -e`.
set -uo pipefail

PLEX_PORT=32400

# Subnet comes from systemd's EnvironmentFile, or the file directly when run
# by hand, or a default matching .env.example.
if [ -z "${ARRSTACK_SUBNET:-}" ] && [ -r /etc/default/arrstack ]; then
  # shellcheck disable=SC1091
  . /etc/default/arrstack
fi
ARRSTACK_SUBNET=${ARRSTACK_SUBNET:-172.20.0.0/16}

NORDVPN=$(command -v nordvpn || echo /usr/bin/nordvpn)
if [ ! -x "$NORDVPN" ]; then
  echo "nordvpn CLI not found — nothing to do." >&2
  exit 0
fi

# `After=nordvpnd.service` only orders startup; it does not mean the daemon is
# ready to answer. Right after boot the CLI reports "daemon not reachable" for
# a few seconds. Exit non-zero if it never comes up so systemd retries.
ready=0
for _ in $(seq 1 30); do
  if "$NORDVPN" status >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done

if [ "$ready" -ne 1 ]; then
  echo "nordvpnd did not become ready after 60s — will retry." >&2
  exit 1
fi

# `whitelist` was renamed `allowlist` in NordVPN 3.16 and the alias was later
# dropped. Pick whichever this install actually has.
if "$NORDVPN" allowlist --help >/dev/null 2>&1; then
  LIST=allowlist
elif "$NORDVPN" whitelist --help >/dev/null 2>&1; then
  LIST=whitelist
else
  echo "nordvpn CLI has neither 'allowlist' nor 'whitelist'." >&2
  exit 1
fi

apply() {
  echo "+ nordvpn $*"
  "$NORDVPN" "$@" || echo "    (non-zero: already applied or unsupported — continuing)"
}

# Containers on the arrstack bridge.
apply "$LIST" add subnet "$ARRSTACK_SUBNET"
# Plex uses host networking, so the subnet rule above doesn't cover it.
apply "$LIST" add port "$PLEX_PORT"
# Both have been observed to silently revert across reboots, breaking LAN
# access to Plex and the *arr UIs.
apply set lan-discovery enabled
apply set firewall enabled

echo "arrstack VPN rules applied (subnet ${ARRSTACK_SUBNET}, port ${PLEX_PORT})."
exit 0
