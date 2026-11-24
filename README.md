# radio

One container, any number of **stations**. Each station plays its JSON playlist top to
bottom (looping) on its own live timeline: every listener of a station hears the same
moment. Built on [Liquidsoap 2.4](https://www.liquidsoap.info/doc-2.4.6/)
(`request.dynamic`, `output.harbor`, `harbor.http.register`).

| Path | What |
|---|---|
| `/` | station list (links, colors, now playing) |
| `/listen/<name>` | player page for one station, in its color |
| `/stream/<name>` | 128 kbps MP3 stream |
| `/nowplaying/<name>` | `{name, color, tracks, listeners, title, artist, album}` |
| `/stations` | the same for every station, as a list |
| `POST /playlist` | create or replace a station (`Authorization: Bearer <token>`) |

## Building playlists

```sh
python playlist.py scrape https://any-site/page-with-mp3-links -o mix.json   # generic: url + title
python playlist.py shuffle acdc.json                                           # randomize in place
```

Playlist format: see `playlist.example.json` (`url` required; `title`, `artist`, `album` optional).
Order = play order.

## Stations

```sh
python playlist.py push https://radio.example.com acdc.json --name acdc --color "#8AFB17"
```

- `--name`: 1-40 of `a-z 0-9 -`. Pushing an existing name **replaces** its playlist (no warning);
  the current song finishes, then the new list starts from the top.
- `--color`: `#RRGGBB`. Optional: a new station gets a random one from a bright palette; a
  replaced station keeps its color unless you pass one.
- No rebuild or redeploy. Stations, playlists and play positions live in the `radio-data` volume
  (`/data/stations/<name>.json`), so restarts resume (skipping the few prefetched tracks).
- A bare JSON array POSTed without a name goes to the station `main`.
- Broken URLs are skipped. There is no delete endpoint: remove `/data/stations/<name>.*` and restart.

### Live stations (jellytune)

`"live": true, "start": <i>` in the POST makes a **live** station: hidden from `/` and
`/stations` (reachable only by its name), no looping, and `start` is the song playing right now.
A POST whose `start` song is already playing just swaps the queue; any other jumps to it.
Optional `fallback: [...]` loops when the queue runs out; an empty `tracks` switches to it at
once (jellytune's "Radio: off"). Omit `fallback` to keep the last one sent.
[jellytune](https://github.com/areaewhy/jellytune) uses this to mirror each user's queue.

Source-server load: a station **only fetches tracks while someone is listening**. Idle, it
finishes what it already downloaded and plays silence; the first listener starts it again
(about 2 s). Each played track is one HEAD + one GET to the source, never one per listener.

### Token

- The token lives only on your machine: `~/.config/radio/token` (or the `RADIO_TOKEN` env var).
- Its **MD5** is the repo secret `PLAYLIST_TOKEN_MD5`, baked into the image at build time.
  The image is public, so only the hash goes in it. MD5 is what Liquidsoap has built in;
  recovering a 256-bit random token from its MD5 hash is not practical.
- No secret in the image = `POST /playlist` returns 403.
- Rotate: write a new token to the file, then
  `tr -d '\r\n' < ~/.config/radio/token | md5sum | cut -d' ' -f1 | gh secret set PLAYLIST_TOKEN_MD5`,
  push (or re-run the workflow), and `docker compose pull && docker compose up -d` on the server.

## Security notes

- Port 80 binds to `127.0.0.1` only: reachable from the server itself (and cloudflared), not the
  LAN or the internet. `BIND=0.0.0.0` in `.env` opens it up if you really need that.
- Track URLs must be `http://` or `https://` (no `file://`, no local paths).
- `LOCAL_POST_ONLY=true`: `POST /playlist` is refused (403) for any request that came through
  Cloudflare (it carries `CF-Connecting-IP` / `CF-Ray`, which outside callers cannot strip), so only
  things on the box or LAN (jellytune, ssh) can change stations. Pushes from elsewhere then go
  through ssh: `python playlist.py push http://127.0.0.1:8688 ...` on the server.
- Station names are `a-z 0-9 -`, colors `#RRGGBB`; pages insert text with `textContent`.
- The container runs as the non-root `liquidsoap` user and only writes to its `/data` volume.
- **No listener cap.** Liquidsoap's built-in server cannot limit or kick listeners. Each listener
  costs 128 kbps of upload; if that matters, cap the server's upload with your router's QoS, or
  put Icecast (which has `<max-listeners>`) in front.

## Run locally

```sh
export PLAYLIST_TOKEN_MD5=$(tr -d '\r\n' < ~/.config/radio/token | md5sum | cut -d' ' -f1)
docker compose up -d --build                       # http://localhost/
python playlist.py push http://localhost acdc.json --name acdc
```

## Host at home with a Cloudflare Tunnel (recommended)

No open ports on your router, your home IP stays hidden, and HTTPS is handled by Cloudflare.
[Cloudflare Tunnel docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/create-remote-tunnel/)

1. Cloudflare dashboard > Zero Trust > Networks > Tunnels > **Create a tunnel** (Cloudflared).
   Copy the token into `.env` next to `docker-compose.yml`: `TUNNEL_TOKEN=...` (`.env` is gitignored).
2. In the tunnel, add a **public hostname**: `radio.<yourdomain>` -> service `HTTP` `radio:8000`.
3. On the server: `docker compose --profile tunnel pull && docker compose --profile tunnel up -d`.
4. From your machine: `python playlist.py push https://radio.<yourdomain> acdc.json --name acdc`.

Image: `ghcr.io/areaewhy/radio` (amd64 + arm64), built by `.github/workflows/image.yml` on every
push to `main`. Quick test without an account: `cloudflared tunnel --url http://localhost:80`
gives a random `trycloudflare.com` URL.

Caveat: Cloudflare's [CDN terms](https://www.cloudflare.com/service-specific-terms-application-services/)
restrict serving large non-HTML media on non-Enterprise plans; a small hobby stream is a gray area.
