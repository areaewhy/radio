"""Build, shuffle or push playlist.json. Standard library only.

  python playlist.py scrape <page-url> [-o playlist.json] [--shuffle]
  python playlist.py shuffle [playlist.json]
  python playlist.py push <station-url> [playlist.json] --name acdc [--color "#8AFB17"]

push sends the file to POST /playlist. Token: RADIO_TOKEN env var, else
~/.config/radio/token (keep it out of the repo).

playlist.json is a list of {"url", "title"?, "artist"?, "album"?}.
Scrape fills url + title (link text, else file name); edit the rest by hand.
"""
import argparse
import json
import os
import pathlib
import random
import sys
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


def write(tracks, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(tracks, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"{len(tracks)} tracks -> {path}", file=sys.stderr)


def push(station, path, name, color=None):
    token_file = pathlib.Path.home() / ".config" / "radio" / "token"
    token = os.environ.get("RADIO_TOKEN") or token_file.read_text().strip()
    with open(path, encoding="utf-8") as f:
        tracks = json.load(f)
    payload = {"name": name, "tracks": tracks}
    if color:
        payload["color"] = color
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
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
    pu = sub.add_parser("push")
    pu.add_argument("station")
    pu.add_argument("file", nargs="?", default="playlist.json")
    pu.add_argument("--name", required=True, help="station name: a-z, 0-9, - (same name overwrites)")
    pu.add_argument("--color", help="#RRGGBB accent (default: kept, or random for a new station)")
    a = ap.parse_args()

    if a.cmd == "scrape":
        tracks = scrape(a.url)
        if a.shuffle:
            random.shuffle(tracks)
        write(tracks, a.out)
    elif a.cmd == "push":
        push(a.station, a.file, a.name, a.color)
    else:
        with open(a.file, encoding="utf-8") as f:
            tracks = json.load(f)
        random.shuffle(tracks)
        write(tracks, a.file)


if __name__ == "__main__":
    main()
