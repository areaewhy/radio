# radio

One container: plays `playlist.json` top to bottom (looping), downloading a few
tracks ahead, and serves the stream + a player page on one port.
Built on [Liquidsoap 2.4](https://www.liquidsoap.info/doc-2.4.6/) (`request.dynamic`, `output.harbor`, `harbor.http.register`).

| Path | What |
|---|---|
| `/` | player page (`www/index.html`) |
| `/stream` | 128 kbps MP3 stream |
| `/nowplaying` | `{title, artist, album}` JSON |

## Playlist

```sh
python playlist.py scrape https://the-site/page-with-mp3-links   # -> playlist.json (url + title)
python playlist.py shuffle                                         # randomize order in place
```

Format: see `playlist.example.json` (`url` required; `title`, `artist`, `album` optional).
Order = play order. Position is saved in the `radio-data` volume, so restarts resume
(skipping the few tracks that were prefetched but not played). Edit the JSON, then
`docker compose up -d --build` (it is baked into the image). Broken URLs are skipped.

Source-server load: each track is fetched once per play (one HEAD + one GET), never per listener.

## Run locally

```sh
docker compose up -d --build     # http://localhost/
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
4. `git clone` this repo, copy your `playlist.json` next to `docker-compose.yml` (or commit it), `docker compose up -d --build`.
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
