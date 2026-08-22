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
- **linuxserver.io images use `/config`; Seerr's image uses
  `/app/config`.** Check the error message / image docs before
  assuming the Sonarr/Radarr convention applies everywhere.

## Installing the reboot-safe whitelist service (optional but recommended)

```
sudo cp systemd/arrstack-vpn-whitelist.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now arrstack-vpn-whitelist.service
```

## Updating

```
sudo docker compose pull
sudo docker compose up -d
```
