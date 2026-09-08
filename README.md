# Arr Stack

Prowlarr + Sonarr + Radarr + qBittorrent (behind a Gluetun/NordVPN kill
switch) + Seerr, all on one shared Docker network so NordVPN only ever
needs one whitelisted subnet.

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
   This creates the data/media folders, creates the shared `arrstack`
   Docker network with a fixed subnet, and whitelists that subnet in
   NordVPN if the CLI is installed.

5. **Start everything**
   ```
   sudo docker compose up -d
   ```

6. **Verify the VPN tunnel is up before trusting qBittorrent**
   ```
   sudo docker logs gluetun --tail 30
   sudo docker exec -it qbittorrent curl ifconfig.me
   ```
   The second command should return a NordVPN IP, not your home IP.

## First-login / one-time UI config

- **qBittorrent** (`http://localhost:8080`) — grab the temp password with
  `sudo docker logs qbittorrent | grep -i "temporary password"`, log in,
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
  `PLEX_CLAIM`, then `sudo docker compose up -d plex`. Once it shows up
  linked to your account in the Plex web UI, you can clear `PLEX_CLAIM`
  from `.env` — it's not needed on subsequent starts. Add your TV and
  Movie libraries pointing at `/tv` and `/movies` inside the container.
  For remote access, either forward port 32400 on your router to this
  machine, or skip that entirely and use Tailscale.
- **Seerr** (`http://localhost:5055`) — connect Plex first (Settings >
  Plex), then Settings > Services > add Radarr and Sonarr the same way
  (container name + port + API key), marking each as the default server.

## Known gotchas (learned the hard way)

- **NordVPN's whitelist can reset on reboot** if the daemon comes up
  fresh. The included `systemd/arrstack-vpn-whitelist.service` re-applies
  it on every boot — see below to install it.
- **qBittorrent config can silently reset** if its config folder's
  ownership doesn't match `PUID`/`PGID` (e.g. after a container
  recreate). If you see a fresh temp password appear, run:
  `sudo chown -R ${PUID}:${PGID} $DATA_ROOT/qbittorrent/config`
- **Folder names with spaces** (e.g. `Tv Shows`) must be quoted in
  YAML volume mounts, or the mount silently fails/misparses.
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
  **port** whitelist (`32400`), separate from the `arrstack` **subnet**
  whitelist the other containers use. `setup.sh` and the systemd unit
  both handle this, but it's easy to forget if you add Plex later by
  hand.
- **NordVPN's `LAN Discovery` setting blocks other devices on your
  network from reaching this machine at all**, independent of the
  firewall/whitelist. If a device on the same subnet gets "server
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
the `arrstack` subnet/port whitelist, `lan-discovery`, and `firewall`
state have all reverted unexpectedly at least once each in practice,
breaking LAN access to Plex or the Docker services until re-applied by
hand. This unit re-applies all of them automatically on every boot:

```
sudo cp systemd/arrstack-vpn-settings.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now arrstack-vpn-settings.service
```

## Updating

```
sudo docker compose pull
sudo docker compose up -d
```
