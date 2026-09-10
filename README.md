# Arr Stack

Prowlarr + Sonarr + Radarr + qBittorrent (behind a Gluetun/NordVPN kill
switch) + Seerr, all on one shared Docker network so NordVPN only ever
needs one allowlisted subnet.

## Fresh machine setup

1. **Install Docker**
   ```
   sudo apt update
   sudo apt install docker.io docker-compose-plugin -y
   ```

2. **Clone this repo, then create your `.env`**
   ```
   cp .env.example .env
   nano .env
   ```
   Fill in `DATA_ROOT`, `DOWNLOADS_PATH`, `TV_PATH`, `MOVIES_PATH` for
   this machine, and `WIREGUARD_PRIVATE_KEY` (see below).

   **Quote any path containing a space** — `TV_PATH="/home/jordan/Videos/Tv Shows"`.
   Compose and `setup.sh` both strip the quotes.

3. **Get a NordVPN WireGuard private key**
   Gluetun needs a WireGuard key, not your regular NordVPN login.
   Log into your NordVPN account dashboard and generate a manual
   WireGuard/NordLynx config, or run `nordvpn account` on a machine
   with the NordVPN CLI installed and follow the link there. Paste
   the private key into `.env`.

4. **Run the bootstrap script**
   ```
   chmod +x setup.sh
   ./setup.sh
   ```
   It validates `.env` up front (and stops without creating anything if
   something's missing), creates the data/media folders, sets their
   ownership to `PUID:PGID`, creates the shared `arrstack` Docker network
   with a fixed subnet, records that subnet in `/etc/default/arrstack` for
   the systemd unit, and applies the NordVPN allowlist if the CLI is
   installed. It's safe to re-run.

5. **Start everything**
   ```
   docker compose up -d
   ```
   (Prefix with `sudo` unless your user is in the `docker` group.)

6. **Verify the VPN tunnel is up before trusting qBittorrent**
   ```
   docker logs gluetun --tail 30
   docker exec -it qbittorrent curl ifconfig.me
   ```
   The second command should return a NordVPN IP, not your home IP.
   Then confirm the kill switch actually kills: `docker stop gluetun` and
   re-run the `curl` — it must **fail**, not fall back to your real IP.

## First-login / one-time UI config

- **qBittorrent** (`http://localhost:8080`) — grab the temp password with
  `docker logs qbittorrent | grep -i "temporary password"`, log in,
  then set a permanent one under Tools > Options > Web UI.
- **Prowlarr** (`http://localhost:9696`) — add your indexers, then
  Settings > Apps > add Sonarr (`http://sonarr:8989`) and Radarr
  (`http://radarr:7878`) using their API keys from Settings > General
  > Security in each app. Indexers sync automatically after that.
- **Sonarr / Radarr** — Settings > Download Clients > add qBittorrent.
  Host is `gluetun` (not `qbittorrent` — gluetun owns the network stack),
  port `8080`. Settings > Media Management > enable hardlinks (downloads
  and media live on the same drive, so hardlinking avoids double storage).
  Settings > Connect > add Plex (host = your LAN IP, not `localhost` —
  Plex isn't on this network — port `32400`, plus your Plex auth token).
  Enable "On Import" and "On Upgrade" so Plex refreshes automatically.
- **Plex** (`http://localhost:32400/web`) — Plex runs on `network_mode: host`
  (not the `arrstack` bridge network) since it needs LAN discovery and
  remote access to work properly. First run: get a claim token from
  https://plex.tv/claim (expires in ~4 minutes), paste it into `.env` as
  `PLEX_CLAIM`, then `docker compose up -d plex`. Once it shows up
  linked to your account in the Plex web UI, you can clear `PLEX_CLAIM`
  from `.env` — it's not needed on subsequent starts. Add your TV and
  Movie libraries pointing at `/tv` and `/movies` inside the container.
  For remote access, either forward port 32400 on your router to this
  machine, or skip that entirely and use Tailscale.
- **Seerr** (`http://localhost:5055`) — connect Plex first (Settings >
  Plex), then Settings > Services > add Radarr and Sonarr the same way
  (container name + port + API key), marking each as the default server.

## Known gotchas (learned the hard way)

- **NordVPN's allowlist can reset on reboot** if the daemon comes up
  fresh. The included `systemd/arrstack-vpn-settings.service` re-applies
  it on every boot — see below to install it.
- **qBittorrent config can silently reset** if its config folder's
  ownership doesn't match `PUID`/`PGID` (e.g. after a container
  recreate). If you see a fresh temp password appear, run:
  `sudo chown -R ${PUID}:${PGID} $DATA_ROOT/qbittorrent/config`
  `setup.sh` now sets this on every run, so it should stop recurring.
- **Folder names with spaces** (e.g. `Tv Shows`) break `setup.sh` if you
  leave them unquoted in `.env` — bash *executes* that file when reading
  it, so `TV_PATH=/home/jordan/Videos/Tv Shows` runs `Shows` as a command
  and the script dies before doing anything. Quote them in `.env`.
  (The YAML volume mounts are fine either way; Compose interpolates after
  parsing, so the space never confuses it. It's purely a shell problem —
  which is where to look if this bites you again.)
- **qBittorrent's WebUI returns a bare "Unauthorized"** when you reach it
  by anything other than `localhost` — 4.6+ validates the Host header.
  Hitting `http://<lan-ip>:8080` from another machine trips this even
  with correct credentials. Fix under Tools > Options > Web UI: either
  add the host/IP to "Server domains", or untick "Enable Host header
  validation" on a trusted LAN.
- **Publishing `6881` does not get you inbound peers.** NordVPN via
  gluetun does no port forwarding, so nothing arrives on it regardless of
  the port mapping. Expect leech-only ratios; don't spend an evening
  debugging the port mapping.
- **Recreating gluetun breaks qBittorrent** until qBittorrent is also
  recreated. It has no network stack of its own
  (`network_mode: "service:gluetun"`), so it stays attached to a
  namespace that no longer exists:
  `docker compose up -d --force-recreate qbittorrent`
- **linuxserver.io images use `/config`; Seerr's image uses
  `/app/config`.** Check the error message / image docs before
  assuming the Sonarr/Radarr convention applies everywhere.
- **Plex needs `network_mode: host`, not the `arrstack` bridge.**
  Remote access and local network discovery don't work reliably behind
  a Docker bridge network. Because of this, Sonarr/Radarr's Plex
  Connect settings need your machine's real LAN IP (not `localhost`
  or a container name) — same network-boundary reason.
- **NordVPN's firewall blocks Plex the same way it blocked qBittorrent
  and Sonarr** — since Plex is on host networking, it needs its own
  **port** allowlist entry (`32400`), separate from the `arrstack`
  **subnet** rule the other containers use. `setup.sh` and the systemd unit
  both handle this, but it's easy to forget if you add Plex later by
  hand.
- **NordVPN's `LAN Discovery` setting blocks other devices on your
  network from reaching this machine at all**, independent of the
  firewall/allowlist. If a device on the same subnet gets "server
  unreachable" while `curl` from the server itself works fine, check
  `nordvpn settings | grep -i lan` — it needs to say `enabled`.
  `nordvpn set lan-discovery enabled`.
- **Some NordVPN settings changes don't reliably apply live** — if a
  `nordvpn set ...` command reports success but behavior doesn't
  actually change, a full reboot has fixed it every time this has come
  up. The `arrstack-vpn-settings.service` systemd unit re-applies the
  important ones on every boot so you don't have to chase this by hand.

## Installing the reboot-safe NordVPN settings service (optional but recommended)

NordVPN has been observed to silently reset a few settings on reboot —
the `arrstack` subnet/port allowlist, `lan-discovery`, and `firewall`
state have all reverted unexpectedly at least once each in practice,
breaking LAN access to Plex or the Docker services until re-applied by
hand. This unit re-applies all of them automatically on every boot:

```
sudo cp systemd/arrstack-vpn-apply.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/arrstack-vpn-apply.sh
sudo cp systemd/arrstack-vpn-settings.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now arrstack-vpn-settings.service
```

Check it worked — and run it **twice**. The second run is the real test:
with every rule already applied, it must still reach the `lan-discovery`
and `firewall` steps.

```
sudo systemctl start arrstack-vpn-settings.service
journalctl -u arrstack-vpn-settings.service -n 20
```

Why a script rather than a list of `ExecStart=` lines: `nordvpn` exits
non-zero when a rule is *already* applied, which is the normal case on
most boots. systemd abandons the remaining `ExecStart=` lines at the
first failure, so a plain list would stop at the allowlist and never
re-apply `lan-discovery` or `firewall` — the settings most likely to
have actually reset. The script also waits for `nordvpnd` to become
reachable (`After=` only orders startup, it doesn't mean the daemon is
answering yet) and handles the `whitelist` → `allowlist` rename in
NordVPN 3.16+.

The subnet comes from `/etc/default/arrstack`, which `setup.sh` writes
from `.env`, so it stays in sync automatically.

## Backups

Nothing here backs up `${DATA_ROOT}`, and that's where every app's
database lives — indexers, quality profiles, history, request history.
Losing it means rebuilding the stack by hand.

- Sonarr/Radarr/Prowlarr each have Settings > General > Backups; turn
  them on. They write into `/config/Backups`.
- Then get `${DATA_ROOT}` off the machine on a timer, e.g.
  `tar czf arrstack-$(date +%F).tar.gz "${DATA_ROOT}"` to external or
  network storage. Stop the stack first for a clean copy of the SQLite
  databases, or accept a small risk of a torn snapshot.

## Access and exposure

Every service publishes on `0.0.0.0`, and Sonarr/Radarr/Prowlarr ship
with no authentication until you set some. That's fine on a trusted LAN,
which is what this is set up for — but it means **anything that can
route to this host can drive the stack**. Before forwarding any port
other than Plex's `32400`, or moving this box to a less trusted network,
either set authentication in each app or bind the ports to a specific
interface instead of all of them.

## Updating

Image tags default to `latest` but each is overridable in `.env`
(`SONARR_TAG=`, `PLEX_TAG=`, …). Pin them once the stack is working —
otherwise a routine `pull` can carry you across a breaking major with
no record of what you were on.

```
docker compose images       # what you're running now — paste into .env
docker compose pull
docker compose up -d
```

To roll one back, put the previous tag in `.env` and re-run `up -d`.

## TODO

### Apply on the host

The repo is ahead of the running machine — these close the gap.

- [ ] **Uninstall the old `arrstack-vpn-whitelist.service`.** It was removed
      from the repo, but that doesn't uninstall it. If it was ever enabled it
      still runs on every boot, duplicating the new unit's work:

      systemctl is-enabled arrstack-vpn-whitelist.service   # check first
      sudo systemctl disable --now arrstack-vpn-whitelist.service
      sudo rm -f /etc/systemd/system/arrstack-vpn-whitelist.service
      sudo systemctl daemon-reload

- [ ] **Install the replacement** — `arrstack-vpn-apply.sh` plus the updated
      unit. See "Installing the reboot-safe NordVPN settings service" above.
- [ ] **Re-run `./setup.sh`.** Idempotent. Writes `/etc/default/arrstack`
      (the unit reads the subnet from there) and fixes `${DATA_ROOT}`
      ownership.
- [ ] **Quote spaced paths in the host's `.env`** to match `.env.example`.
      Optional — the loader handles unquoted values — but it removes the
      ambiguity that broke `setup.sh` in the first place.
- [ ] **Pin the image tags.** `docker compose images`, then paste them into
      `.env`. Until this is done, every `pull` can cross a breaking major.
- [ ] **Re-verify after the above:** gluetun reaches `healthy` before
      qbittorrent starts; the kill switch still kills (`docker stop gluetun`,
      then `docker exec qbittorrent curl ifconfig.me` must fail); the VPN unit
      run **twice** still reaches `lan-discovery` and `firewall` on the second
      pass; and a real reboot leaves Plex and the *arr UIs reachable on the LAN
      with no manual `nordvpn` commands.

### Verify (claims not checked from a dev machine)

One command each. Each has a real failure mode behind it.

- [ ] **`ghcr.io/seerr-team/seerr:latest` resolves.** The only
      non-linuxserver image here, and the one most likely to have moved.
      `docker compose pull seerr`
- [ ] **gluetun actually ships a HEALTHCHECK.** The `service_healthy`
      condition never becomes satisfied without one, so qbittorrent would
      hang at startup rather than merely starting early.
      `docker inspect --format '{{json .Config.Healthcheck}}' gluetun`
- [ ] **Which of `allowlist` / `whitelist` this NordVPN CLI has.** The script
      detects it at runtime, so this is confirmation rather than a fix.
      `nordvpn allowlist --help || nordvpn whitelist --help`

### Deferred — considered and consciously not done

Not bugs. Recorded so the reasoning doesn't have to be re-derived later.

- [ ] **Single `/data` mount (TRaSH layout).** Separate `/downloads`, `/tv`
      and `/movies` mounts are the usual cause of hardlinks silently
      degrading to full copies. Here they're all on one filesystem so it
      works today; the restructure is insurance, plus one consistent path
      scheme. Cost: re-mapping paths in Sonarr, Radarr and qBittorrent.
- [ ] **Compose-managed network instead of `external: true`.** Would remove
      the "must run `setup.sh` before `up -d`" ordering trap. Cost: Compose
      won't adopt a network it didn't create, so the existing `arrstack`
      network has to be recreated with the stack down.
- [ ] **Authentication / interface-bound ports.** Only matters if this box
      stops being LAN-only. See "Access and exposure" above.
