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
  push (or re-run the workflow), and `docker compose pull && docker compose up -d` on the VM.
- With Cloudflare **Flexible** SSL, the hop from Cloudflare to the VM is plain HTTP, so the token
  crosses that hop unencrypted. Fine for a hobby playlist; use Full SSL if that matters.

## Run locally

```sh
export PLAYLIST_TOKEN_MD5=$(tr -d '\r\n' < ~/.config/radio/token | md5sum | cut -d' ' -f1)
docker compose up -d --build                       # http://localhost/
python playlist.py push http://localhost acdc.json --name acdc
```

## Deploy on Oracle Cloud (Always Free, Ampere A1 / Ubuntu)

1. Create the VM ([Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)).
   Image is multi-arch, so arm64 is fine.
2. Install Docker: [docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/).
3. Open port 80 in **both** places:
   - VCN security list / NSG: ingress TCP 80 ([docs](https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securitylists.htm)).
     Tighten the source to [Cloudflare's IP ranges](https://www.cloudflare.com/ips/) once it works.
   - The VM's own iptables (Oracle's Ubuntu image blocks it by default):
     ```sh
     sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
     sudo netfilter-persistent save
     ```
4. Copy `docker-compose.yml` to the VM, then `docker compose pull && docker compose up -d`,
   then from your machine `python playlist.py push https://radio.<yourdomain> acdc.json --name acdc`. Image: `ghcr.io/areaewhy/radio` (amd64 + arm64,
   built by `.github/workflows/image.yml` on every push to `main`).
5. Idle reclaim: Oracle may reclaim an Always Free VM that stays mostly idle for 7 days; upgrading the
   account to Pay-As-You-Go avoids it (still free within limits; set a budget alert).

## Cloudflare

- DNS: `A radio.<yourdomain>` -> VM public IP, **proxied** (orange cloud).
- SSL: set **Flexible** for this hostname only via a
  [Configuration Rule](https://developers.cloudflare.com/rules/configuration-rules/)
  ([Flexible mode](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/flexible/)).
- Caveat: Cloudflare's [CDN terms](https://www.cloudflare.com/service-specific-terms-application-services/)
  restrict serving large non-HTML media on non-Enterprise plans. If they object, grey-cloud the record
  (you then need TLS on the VM, e.g. Caddy).
