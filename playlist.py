"""Build or shuffle playlist.json. Standard library only.

  python playlist.py scrape <page-url> [-o playlist.json] [--shuffle]
  python playlist.py shows <artist-page-url> [--color "#8AFB17"] [--artist NAME] [-o playlist.json]
  python playlist.py shuffle [playlist.json]
  python playlist.py push <station-url> [playlist.json]

push sends the file to POST /playlist. Token: RADIO_TOKEN env var, else
~/.config/radio/token (keep it out of the repo).

playlist.json is a list of {"url", "title"?, "artist"?, "album"?}.
Scrape fills url + title (link text, else file name); edit the rest by hand.
"""
import argparse
import html
import json
import os
import pathlib
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser


class LinkParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self._href, self._text = [], None, []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self._href, self._text = dict(attrs).get("href"), []

    def handle_data(self, data):
        if self._href is not None:
            self._text.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._href is not None:
            self.links.append((self._href, " ".join("".join(self._text).split())))
            self._href = None


def scrape(page_url):
    req = urllib.request.Request(page_url, headers={"User-Agent": "playlist-scraper/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        html = r.read().decode(r.headers.get_content_charset() or "utf-8", "replace")
    p = LinkParser()
    p.feed(html)
    seen, tracks = set(), []
    for href, text in p.links:
        url = urllib.parse.urljoin(page_url, href)
        path = urllib.parse.urlparse(url).path
        if not path.lower().endswith(".mp3") or url in seen:
            continue
        seen.add(url)
        name = urllib.parse.unquote(path.rsplit("/", 1)[-1])[:-4]
        tracks.append({"url": url, "title": text or name})
    return tracks


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "playlist-scraper/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode(r.headers.get_content_charset() or "utf-8", "replace")


def clean_title(name):
    """'02-Shot Down', '02 rock or bust', 'd1t03. Sin City' -> the song name."""
    return re.sub(r"^(?:d\d+)?t?\d{1,3}[\s\-._]+", "", name, flags=re.I).strip() or name


def scrape_shows(artist_url, color, artist=None, delay=1.0):
    """andymp3-style artist page: shows whose name is in <FONT color=...>,
    each linking to a show page that lists the track mp3s."""
    page = fetch(artist_url)
    show_re = re.compile(
        r'<a href="([^"]+)"[^>]*>(?:&nbsp;|\s)*<font color=#?' + re.escape(color.lstrip("#"))
        + r'>([^<]+)</font>', re.I)
    shows = show_re.findall(page)
    print(f"{len(shows)} shows marked {color}", file=sys.stderr)
    tracks = []
    for i, (href, show) in enumerate(shows, 1):
        show_url = urllib.parse.urljoin(artist_url, html.unescape(href))
        time.sleep(delay)  # be gentle with the source site
        try:
            sp = fetch(show_url)
        except Exception as e:
            print(f"  skip {show}: {e}", file=sys.stderr)
            continue
        head = re.search(r'PID=\d+">/([^/<]+)/([^<]+)</a>', sp)
        album = html.unescape(head.group(2) if head else show).strip()
        who = artist or (html.unescape(head.group(1)) if head else "")
        found = re.findall(r'<a href="([^"]+\.mp3)">([^<]+)</a>', sp, re.I)
        for t_href, t_name in found:
            name = html.unescape(t_name).strip()
            name = re.sub(r"\.mp3$", "", name, flags=re.I)
            name = clean_title(name)
            url = urllib.parse.urljoin(show_url, html.unescape(t_href))
            url = urllib.parse.quote(url, safe=":/?&=%#'")
            tracks.append({"url": url, "title": name, "artist": who, "album": album})
        print(f"  [{i}/{len(shows)}] {album}: {len(found)} tracks", file=sys.stderr)
    return tracks


def write(tracks, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(tracks, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"{len(tracks)} tracks -> {path}", file=sys.stderr)


def push(station, path):
    token_file = pathlib.Path.home() / ".config" / "radio" / "token"
    token = os.environ.get("RADIO_TOKEN") or token_file.read_text().strip()
    with open(path, "rb") as f:
        body = f.read()
    json.loads(body)  # fail locally on bad JSON
    req = urllib.request.Request(
        station.rstrip("/") + "/playlist", data=body, method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json",
                 "User-Agent": "playlist-push/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print(r.status, r.read().decode())
    except urllib.error.HTTPError as e:
        print(e.code, e.read().decode(), file=sys.stderr)
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scrape")
    s.add_argument("url")
    s.add_argument("-o", "--out", default="playlist.json")
    s.add_argument("--shuffle", action="store_true")
    sh = sub.add_parser("shuffle")
    sh.add_argument("file", nargs="?", default="playlist.json")
    sw = sub.add_parser("shows")
    sw.add_argument("url")
    sw.add_argument("--color", default="#8AFB17", help="font color marking the shows to take")
    sw.add_argument("--artist", help="display name (default: folder name from the show page)")
    sw.add_argument("-o", "--out", default="playlist.json")
    sw.add_argument("--shuffle", action="store_true")
    pu = sub.add_parser("push")
    pu.add_argument("station")
    pu.add_argument("file", nargs="?", default="playlist.json")
    a = ap.parse_args()

    if a.cmd == "scrape":
        tracks = scrape(a.url)
        if a.shuffle:
            random.shuffle(tracks)
        write(tracks, a.out)
    elif a.cmd == "shows":
        tracks = scrape_shows(a.url, a.color, a.artist)
        if a.shuffle:
            random.shuffle(tracks)
        write(tracks, a.out)
    elif a.cmd == "push":
        push(a.station, a.file)
    else:
        with open(a.file, encoding="utf-8") as f:
            tracks = json.load(f)
        random.shuffle(tracks)
        write(tracks, a.file)


if __name__ == "__main__":
    main()
