# Media Server with Docker Compose

> [!IMPORTANT]
> This uses Cloudflare for incoming connections, NordVPN for outgoing, and Google Auth for logging in. If you cannot figure those out with help from google then this might not be the setup for you!

> [!WARNING]
> I do not use all of these services, so not everything is guaranteed to work.

> [!NOTE]
> This is the barebones setup for a media server, it does not include any config (although over time I may add more document and templates explaining what to do).

<img width="1304" height="715" alt="image" src="https://github.com/user-attachments/assets/4bf99c07-ac29-4233-863e-af6cd92f10aa" />

## Concept

Every service uses a similar folder layout, this includes having a `config` folder inside the service folder for easier backup and configuration.

When one service depends on another it should only be started first (with a couple of exceptions that require them to be healthy first).

There are some included scripts for use within various services directly - you do not need to install python or have anything more than `bash` available on the server.

### Services

This is a list of all services, and the profiles they are started with. Note that only the `core` profiles are included in the `compose.yaml` file, everything else needs to be manually added.

| NAME                   | PROFILE     | DESCRIPTION |
| ---------------------- | ----------- | ----------- |
| cloudflared            | core        | Cloudflare tunnel |
| deunhealth             | core        | Bring unhealthy containers back up |
| error-pages            | core        | Error pages |
| socket-proxy           | core        | Secure access to the docker socket |
| tinyauth               | core        | OAuth via Google |
| traefik                | core        | HTTP routing |
| vpn                    | core        | VPN + HTTP Proxy + Socks5 Proxy |
| watchtower             | core        | Auto-update containers |
| adguardhome            | network     | Ads & trackers blocking DNS server |
| audiobookshelf         | library     | Audiobooks library |
| bazarr                 | media       | Subtitles |
| beszel                 | information | System information |
| chaptarr               | media       | Books / Audiobooks |
| cleanuparr             | download    | Bad download handling |
| docker-discord-alerts  | tools       | Notify Discord when docker containers change |
| dozzle                 | information | Docker status |
| duc                    | tools       | Disk usage |
| emby                   | library     | Media library |
| flaresolverr           | network     | Cloudflare captcha bypasss |
| glances                | information | Operating system status |
| homepage               | information | Dashboard |
| i2p                    | network     | I2P Client |
| imagemaid              | quality     | Cleanup Plex image cache |
| jellyfin               | library     | Open source media library |
| kapowarr               | library     | Comics |
| kometa                 | quality     | Poster overlays, collections, playlists for Plex |
| komga                  | library     | Comic library |
| libretranslate         | tools       | Translation |
| lidarr                 | media       | Music |
| lingarr                | quality     | Subtitle translation |
| manyfold               | library     | 3d models library |
| minecraft              | games       | Minecraft |
| mylar                  | media       | Comics |
| neutarr                | download    | Missing media search |
| notifiarr              | tools       | System notifications |
| onlyfans               | download    | Download all subscriptions |
| openspeedtest          | network     | Bandwidth test to server |
| pgadmin                | tools       | Database admin |
| plex                   | library     | Media library |
| plex-find-mismatch     | quality     | Finds mismatches between tvdb/tmdb/imdb and Plex |
| portainer              | information | Container management |
| postgres               | tools       | Database |
| prowlarr               | download    | Torrent / NNTP search proxy |
| qbittorrent            | download    | Torrent downloader |
| radarr                 | media       | Movies |
| sabnzbd                | download    | NNTP downloader |
| scrutiny               | information | S.M.A.R.T. information |
| seerr                  | information | Media requests and issue tracking |
| sonarr                 | media       | TV Shows |
| sonarr_youtubedl       | disabled    | Download from Youtube |
| speedtest-tracker      | information | Speedtest with history |
| stash                  | tools       | Porn database |
| subgen                 | quality     | Audio transription |
| syncthing              | download    | Remote data synchronisation |
| tautulli               | information | Plex stats |
| tdarr                  | quality     | Transcoding / format shifting / audio normalisation |
| tdarr_inform           | quality     | Notifications from sonarr / radarr / etc to tdarr |
| tdarr-node             | quality     | Transcoding node for tdarr |
| titlecardmaker         | quality     | Episode thumbnails for Plex |
| tracearr               | library     | Plex & Emby monitoring |
| ubooquity              | media       | Comics |
| watchstate             | tools       | Sync media library watch state |
| webtop                 | desktop     | Linux desktop |
| whisparr               | media       | Porn |
| whoami                 | network     | Who... Am... I...? |
| windows                | desktop     | Windows desktop |
| zfdash                 | information | ZFS administration |
| zfs-discord-alerts     | tools       | Notify Discord when there are zfs problems |

> [!NOTE]
> The `core` PROFILE services are enabled in the `compose.yaml` file, you must add any others you wish to a `compose.override.yaml` file instead:
> ```yaml
> include:
>   - whoami/compose.yaml
> ```

## Network

This has two networks defined in `compose.yaml`.

* The `internal` network does not have internet access, and is used for inter-service communication. All routing into the stack should come through `traefik` which acts as a bridge between the two.
* The `external` network allows for a service to contact the internet directly. (Ideally services should be using the `http://vpn:8888` service as an http(s) proxy instead.)

## Installation

> [!IMPORTANT]
> The `install.sh` script is not usable yet, these other steps are always going to be manual!

It is advised to use VSCode or similar that does syntax highlighting (ie, colors) for the files you edit!

Duplicate the `.env.example` file as `.env`, all configuration needs to go in here.

Create an empty `compose.override.yaml` file, and copy the commented block of `include:` services into it, then to enable a service you can simply uncomment that line. For some services have a look for included template files that want copying into theit `config/` folders and renaming.

### Google

1. Add your email address as the `EMAIL` and `WHITELIST` in `.env`
1. Follow these instructions: <https://developers.google.com/identity/protocols/oauth2>
1. Add the `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` in `.env`
1. Place a long random hexadecimal value in `OAUTH_SECRET` in .env`
    * The best way is to use the output of `openssl rand -hex 16`

### Cloudflare

#### Domain name

1. Make an account if you haven't already.
1. Buy a domain, or if you already have one you can transfer the domain servers accross.
    * Set this as the `DOMAIN` in `.env`
    * Replace the `$DOMAIN` in `PLEX_URL` with this.

#### Tunnel (incoming security)

1. Sign up for Zero Trust - you can choose the personal 0-cost.
1. Go to Networks -> Tunnels
    1. Create a Tunnel, name it for your domain
    1. Copy the "Run the following command" suggestion, paste it as `CLOUDFLARED_TOKEN` in `.env` then remove the `cloudflared.exe service install` prefix (including space).
    1. Create 2 public hostnames, one to your domain, and one to `*` at your domain
        * Both have a service of `https://traefik`
        * Both have Advanced -> TLS -> Origin Server Name as your domain
        * Both have Advanced -> TLS -> HTTP2 connection turned on

#### Make subdomains accessible

1. Go back to Account Home, then click on your domain name.
1. Under the Domain (Zone) settings go to SSL/TLS -> Overview, and enable Full encryption.
1. Under DNS -> Records, create a CNAME entry for `*` pointing at your domain.
1. Under DNS -> Settings, enable DNSSEC.

#### Allow ssl certificates to be created

1. Click on your Profile in the top right, go to your profile, then click on API Tokens on the left.
1. Create a Token using the Edit zone DNS template
1. Allow it access to your domain under Zone Resources
1. Copy the token to `CLOUDFLARE_API` in `.env`

### NordVPN

1. Make an account, click on NordVPN on the left, scroll down to API Key, create one and copy to `VPN_PRIVATE_KEY` in `.env`

### Media Paths

1. Make sure you set `PATH_DOWNLOADS` to a good download folder, this will be used by multiple services as a consistent location.
1. Place all of your media paths in the `PATH_XYZ` variables in `.env` - add more as needed.

### Plex

1. Use these instructions to get `PLEX_TOKEN` in `.env` - <https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/>
1. Ensure you have all the correct paths for Plex from the Media Paths section above. Internally we're going to map them all under the `/data/` folder.
1. In your current Plex server go to Settings -> Library, and disable (and save) the "Empty trash automatically after every scan" option!
1. Stop Plex Media Server!
1. Copy (move is risky, but it's your library) the Plex Config folder starting at `Library` into `plex/config/` - so there is a folder in there called `Library`.

## Bootstrap

> [!IMPORTANT]
> The Plex library must have finished copying before you do this, and you must not run the old one again (unless you decide not to go ahead with this).

1. Run `docker compose pull` - disable any services that you don't have permission for.
1. Just before running go to <https://account.plex.tv/claim> and copy the token to `PLEX_CLAIM` in `.env`
1. Run `docker compose up -d` and wait for everything to come up.
1. Go to `https://dozzle.<domain>` and wait for all the red dots to turn green.
1. Optional: Run `docker compose down` followed by `docker compose up -d dozzle plex` - this reduces load and lets you setup things one at a time.
1. Go to Plex and tell it to rescan everything - every entry should get re-found as Plex uses file hashes for identification.
