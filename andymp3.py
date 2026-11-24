"""Build a playlist from andymp3.com artist pages. Standard library only.

  python andymp3.py <artist-page-url> [<artist-page-url> ...] [-o playlist.json]
                    [--color "#8AFB17"] [--artist NAME] [--shuffle] [--all]

Takes the shows on each artist page whose name is in <FONT color=...> (default:
the green "#8AFB17" picks), opens each show page and collects every track:
  url, title (track number stripped), artist (folder name, e.g. "ACDC"),
  album (show name, e.g. "Amsterdam-11-12-79").
--all takes every show instead of only the colored ones.
Waits --delay seconds (default 1) between requests to go easy on the site.

Then: python playlist.py push <station-url> playlist.json --name <station>
"""
import argparse
import html
import random
import re
import sys
import time
import urllib.parse
import urllib.request

import json

UA = "playlist-scraper/1.0"


def write(tracks, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(tracks, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"{len(tracks)} tracks -> {path}", file=sys.stderr)


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode(r.headers.get_content_charset() or "utf-8", "replace")


def clean_title(name):
    """'02-Shot Down', '02 rock or bust', 'd1t03. Sin City' -> the song name."""
    name = re.sub(r"\.mp3$", "", name.strip(), flags=re.I)
    return re.sub(r"^(?:d\d+)?t?\d{1,3}[\s\-._]+", "", name, flags=re.I).strip() or name


def find_shows(page, color=None):
    """[(href, show name)] from an artist page; color=None means every show."""
    if color:
        pat = (r'<a href="([^"]*MP3\.aspx\?[^"]+)"[^>]*>(?:&nbsp;|\s)*<font color=#?'
               + re.escape(color.lstrip("#")) + r'>([^<]+)</font>')
    else:
        pat = r'<a href="([^"]*MP3\.aspx\?AL=Y[^"]+)"[^>]*>(?:&nbsp;|\s)*(?:<font[^>]*>)?([^<]+)'
    return [(h, html.unescape(n).strip()) for h, n in re.findall(pat, page, re.I)]


def parse_show(page, show_url, fallback_album, artist=None):
    head = re.search(r'PID=\d+">/([^/<]+)/([^<]+)</a>', page)
    album = html.unescape(head.group(2)).strip() if head else fallback_album
    who = artist or (html.unescape(head.group(1)).strip() if head else "")
    tracks = []
    for href, name in re.findall(r'<a href="([^"]+\.mp3)">([^<]+)</a>', page, re.I):
        url = urllib.parse.urljoin(show_url, html.unescape(href))
        url = urllib.parse.quote(url, safe=":/?&=%#'")
        tracks.append({"url": url, "title": clean_title(html.unescape(name)),
                       "artist": who, "album": album})
    return tracks


def scrape(artist_url, color=None, artist=None, delay=1.0):
    shows = find_shows(fetch(artist_url), color)
    print(f"{artist_url}: {len(shows)} shows" + (f" marked {color}" if color else ""),
          file=sys.stderr)
    tracks = []
    for i, (href, show) in enumerate(shows, 1):
        show_url = urllib.parse.urljoin(artist_url, html.unescape(href))
        time.sleep(delay)
        try:
            found = parse_show(fetch(show_url), show_url, show, artist)
        except Exception as e:
            print(f"  skip {show}: {e}", file=sys.stderr)
            continue
        tracks += found
        print(f"  [{i}/{len(shows)}] {show}: {len(found)} tracks", file=sys.stderr)
    return tracks


def main():
    ap = argparse.ArgumentParser(description="Build a playlist from andymp3.com artist pages.")
    ap.add_argument("urls", nargs="+", metavar="artist-page-url")
    ap.add_argument("-o", "--out", default="playlist.json")
    ap.add_argument("--color", default="#8AFB17", help="font color marking the shows to take")
    ap.add_argument("--all", action="store_true", help="take every show, ignore --color")
    ap.add_argument("--artist", help="artist name override (default: folder name on the show page)")
    ap.add_argument("--shuffle", action="store_true")
    ap.add_argument("--delay", type=float, default=1.0, help="seconds between requests")
    a = ap.parse_args()

    tracks, seen = [], set()
    for u in a.urls:
        for t in scrape(u, None if a.all else a.color, a.artist, a.delay):
            if t["url"] not in seen:
                seen.add(t["url"])
                tracks.append(t)
    if a.shuffle:
        random.shuffle(tracks)
    write(tracks, a.out)


if __name__ == "__main__":
    main()
