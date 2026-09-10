#!/bin/bash
# One-time bootstrap for a fresh machine.
# Run this BEFORE `docker compose up -d`.
set -euo pipefail

cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "No .env found. Copy .env.example to .env and fill it in first."
  exit 1
fi

# Read .env instead of `source`-ing it. Sourcing executes the file as bash,
# so a value containing a space (e.g. TV_PATH=/home/jordan/Videos/Tv Shows)
# is parsed as a command and kills the script before it does anything.
# This loader accepts quoted and unquoted values alike, matching how Docker
# Compose reads the same file, so both stay in agreement about the paths.
load_env() {
  local line key value
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z ${line//[[:space:]]/} ]] && continue
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue

    key=${BASH_REMATCH[2]}
    value=${BASH_REMATCH[3]}

    if [[ ${#value} -ge 2 && ( ( ${value:0:1} == '"' && ${value: -1} == '"' ) \
                            || ( ${value:0:1} == "'" && ${value: -1} == "'" ) ) ]]; then
      value=${value:1:${#value}-2}
    else
      # Unquoted: drop an inline ` # comment` and trailing space, as Compose does.
      value=${value%%[[:space:]]#*}
      value=${value%"${value##*[![:space:]]}"}
    fi

    export "$key=$value"
  done < .env
}

load_env

# --- Validate everything up front, before creating anything -----------------
missing=()
for var in DATA_ROOT DOWNLOADS_PATH TV_PATH MOVIES_PATH ARRSTACK_SUBNET WIREGUARD_PRIVATE_KEY; do
  [[ -z ${!var:-} ]] && missing+=("$var")
done

if (( ${#missing[@]} )); then
  echo "!! These required values are missing or empty in .env:"
  printf '     %s\n' "${missing[@]}"
  echo
  echo "   Fill them in and re-run. See README.md — WIREGUARD_PRIVATE_KEY comes"
  echo "   from your NordVPN account, not your login password."
  exit 1
fi

PUID=${PUID:-1000}
PGID=${PGID:-1000}

# Prefer group-based docker access; escalate to sudo only for a genuine
# permission problem, not for a daemon that simply isn't running.
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  docker_err=$(docker info 2>&1 || true)
  if printf '%s' "$docker_err" | grep -qi 'permission denied'; then
    DOCKER=(sudo docker)
  else
    echo "!! Docker daemon not reachable:"
    printf '%s\n' "$docker_err" | head -3 | sed 's/^/     /'
    echo "   Start Docker and re-run this script."
    exit 1
  fi
fi

# Set ownership to PUID:PGID, but only when it isn't already correct, and
# never fatally — a bad chown shouldn't abort the rest of the bootstrap.
ensure_owner() {
  local path=$1 recursive=${2:-} owner
  owner=$(stat -c '%u:%g' "$path" 2>/dev/null || stat -f '%u:%g' "$path" 2>/dev/null || echo "")
  [ "$owner" = "${PUID}:${PGID}" ] && return 0

  if chown ${recursive} "${PUID}:${PGID}" "$path" 2>/dev/null; then
    return 0
  fi
  if sudo chown ${recursive} "${PUID}:${PGID}" "$path" 2>/dev/null; then
    return 0
  fi

  echo "    !! could not set ownership on ${path} (currently ${owner:-unknown})."
  echo "       Run: sudo chown ${recursive} ${PUID}:${PGID} \"${path}\""
  return 0
}

echo "==> Creating data directories under ${DATA_ROOT}"
for svc in qbittorrent prowlarr sonarr radarr seerr plex homepage; do
  mkdir -p "${DATA_ROOT}/${svc}/config"
done

# Seed the dashboard config from the examples in this repo. Per-file, and
# only when absent — re-running never clobbers edits you've made, and the
# repo keeps a clean copy to diff against.
if [ -d homepage/config.example ]; then
  echo "==> Seeding homepage config (existing files left alone)"
  for f in homepage/config.example/*.yaml; do
    target="${DATA_ROOT}/homepage/config/$(basename "$f")"
    if [ -e "$target" ]; then
      echo "    kept    $(basename "$f")"
    else
      cp "$f" "$target"
      echo "    seeded  $(basename "$f")"
    fi
  done
fi

# Only touch ownership on media dirs we create ourselves — never recursively
# rewrite an existing library.
for path in "${DOWNLOADS_PATH}" "${TV_PATH}" "${MOVIES_PATH}"; do
  if [ ! -d "${path}" ]; then
    mkdir -p "${path}"
    ensure_owner "${path}"
  fi
done

# qBittorrent silently resets its config (new temp password on every start)
# when /config ownership doesn't match PUID/PGID. Set it here so that never
# becomes a thing you have to debug.
echo "==> Ensuring ${DATA_ROOT} is owned by ${PUID}:${PGID}"
ensure_owner "${DATA_ROOT}" -R

echo "==> Creating shared 'arrstack' docker network (${ARRSTACK_SUBNET})"
if ! "${DOCKER[@]}" network inspect arrstack >/dev/null 2>&1; then
  "${DOCKER[@]}" network create --subnet="${ARRSTACK_SUBNET}" arrstack
else
  echo "    network already exists, skipping"
fi

# The systemd unit reads the subnet from here, so it stays in sync with .env
# instead of being hardcoded in the unit file.
if [ -d /run/systemd/system ]; then
  echo "==> Recording ARRSTACK_SUBNET in /etc/default/arrstack"
  if ! printf 'ARRSTACK_SUBNET=%s\n' "${ARRSTACK_SUBNET}" \
       | sudo tee /etc/default/arrstack >/dev/null; then
    echo "    !! could not write /etc/default/arrstack."
    echo "       The systemd unit will fall back to 172.20.0.0/16."
  fi
fi

if command -v nordvpn >/dev/null 2>&1; then
  echo "==> Applying NordVPN allowlist + settings"
  # via bash, so a missing exec bit isn't a failure mode
  ARRSTACK_SUBNET="${ARRSTACK_SUBNET}" bash ./systemd/arrstack-vpn-apply.sh || true
  echo "    Install the systemd unit so this survives reboots — see README.md."
else
  echo "==> nordvpn CLI not found — skipping allowlist step."
  echo "    If you use NordVPN's Linux firewall, allowlist ${ARRSTACK_SUBNET}"
  echo "    (subnet) and 32400 (port) manually."
fi

echo ""
echo "==> Done. Next: docker compose up -d"
