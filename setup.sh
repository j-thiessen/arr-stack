#!/bin/bash
# One-time bootstrap for a fresh machine.
# Run this BEFORE `docker compose up -d`.
set -euo pipefail

if [ ! -f .env ]; then
  echo "No .env found. Copy .env.example to .env and fill it in first."
  exit 1
fi

# shellcheck disable=SC1091
source .env

echo "==> Creating data directories under ${DATA_ROOT}"
mkdir -p "${DATA_ROOT}/qbittorrent/config"
mkdir -p "${DATA_ROOT}/prowlarr/config"
mkdir -p "${DATA_ROOT}/sonarr/config"
mkdir -p "${DATA_ROOT}/radarr/config"
mkdir -p "${DATA_ROOT}/seerr/config"
mkdir -p "${DATA_ROOT}/plex/config"
mkdir -p "${DOWNLOADS_PATH}"
mkdir -p "${TV_PATH}"
mkdir -p "${MOVIES_PATH}"

echo "==> Creating shared 'arrstack' docker network (${ARRSTACK_SUBNET})"
if ! sudo docker network inspect arrstack >/dev/null 2>&1; then
  sudo docker network create --subnet="${ARRSTACK_SUBNET}" arrstack
else
  echo "    network already exists, skipping"
fi

if command -v nordvpn >/dev/null 2>&1; then
  echo "==> Whitelisting ${ARRSTACK_SUBNET} in NordVPN"
  nordvpn whitelist add subnet "${ARRSTACK_SUBNET}" || true

  echo "==> Whitelisting Plex port 32400 in NordVPN"
  # Plex runs on host networking (not the arrstack bridge), so it needs
  # its own port whitelist rather than the subnet rule above.
  nordvpn whitelist add port 32400 || true

  echo "    NOTE: whitelist rules can be lost if the NordVPN daemon"
  echo "    resets. If containers or Plex lose connectivity after a"
  echo "    reboot, re-run:"
  echo "      nordvpn whitelist add subnet ${ARRSTACK_SUBNET}"
  echo "      nordvpn whitelist add port 32400"
else
  echo "==> nordvpn CLI not found — skipping whitelist step."
  echo "    If you use NordVPN's Linux firewall, whitelist ${ARRSTACK_SUBNET}"
  echo "    (subnet) and 32400 (port) manually."
fi

if [ -z "${WIREGUARD_PRIVATE_KEY:-}" ]; then
  echo ""
  echo "!! WIREGUARD_PRIVATE_KEY is empty in .env — gluetun will fail to start."
  echo "   See README.md for how to generate one from your NordVPN account."
fi

echo ""
echo "==> Done. Next: sudo docker compose up -d"
