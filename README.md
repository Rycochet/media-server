# Media Server with Docker Compose

> [!IMPORTANT]
> This uses Cloudflare for incoming connections, NordVPN for outgoing, and Google Auth for logging in. If you cannot figure those out with help from google then this might not be the setup for you!

> [!NOTE]
> This is the barebones setup for a media server, it does not include any config (although over time I may add more document and templates explaining what to do).

## Components

> This is a partial list, the individual folders have every service, and I'll maybe add information for each over time.

### Media Server

* **AudioBookShelf**: Audiobook media server.
* **Kapowarr**: Comic Books.
* **Manyfold**: 3d model server.
* **Overseerr**: Requests for Sonarr / Radarr.
* **Plex Media Server**: Main media server.

### Content Management

* **Bazarr**: Subtitle Management (for Movies and TV Shows).
* **Kometa**: Add overlays to posters for tv and movies in Plex.
* **Imagemaid**: Delete unused posters in Plex.
* **Lidarr**: Music Management.
* **Plex-Find-Mismatch**: Find incorrect matches in Plex.
* **Prowlarr**: Usenet and Torrent Search.
* **qBittorrent**: Torrent downloads.
* **Radarr**: Movie Management.
* **SABnzbd**: Usenet downloads.
* **Sonarr**: TV Show Management.
* **Tdarr**: Transcode media for cnosistency and size.
* **Titlecardmaker**: Add consistent posters to episodes in Plex.

### System / Networking

* **Cloudflared**: Cloudflare Tunnel (incoming web requests).
* **DeUnhealth**: Restart unhealthy services.
* **Error-Pages**: Better looking error pages.
* **NordLynx** + **Socks5-Proxy**: VPN (outgoing connections).
* **OpenSpeedTest**: Speed test app to server.
* **SyncThing**: Synchronise libraries between multiple computers.
* **TinyAuth**: Google OAuth login security.
* **Traefik**: Webapp Routing.
* **Watchtower**: Automatic updating of services.

### Information

* **Glances**: (Hardware) Server Status.
* **Homer**: Dashboard
* **Tautulli**: Plex Server Status.

## Concept

Every service uses a similar folder layout, this inclues having a `config` folder inside the service folder for easier backup and configuration.

When one service depends on another it should only be started first (with a couple of exceptions that require them tobe healthy first).

## Installation

> [!IMPORTANT]
> The `install.sh` script is not usable yet, these other steps are always going to be manual!

It is advised to use VSCode or similar that does syntax highlighting (ie, colors) for the files you edit!

Duplicate the `.env.example` file as `.env`, all configuration needs to go in here.

The easiest way to disable services is to edit the root `compose.yaml` file and comment out the services you don't want by placing a `#` at the beginning of the line.

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
    1. Copy the "Run the following command" suggestion, paste it as `CLOUDFLARED_TOKEN` in `.env` then remove the `cloudflared.exe service install ` prefix (including space).
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
