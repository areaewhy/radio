# Radio: plays the playlist in order, a few tracks downloaded ahead, and
# serves the stream, the player page and a playlist-update endpoint on one port.
# Docs: https://www.liquidsoap.info/doc-2.4.6/

settings.log.stdout := true
settings.log.file := false

port = int_of_string(environment.get(default="8000", "PORT"))
bitrate = int_of_string(environment.get(default="128", "BITRATE"))
prefetch = int_of_string(environment.get(default="3", "PREFETCH"))
# MD5 of the POST token, baked in at build time from a GitHub secret.
# Empty = POST /playlist disabled.
token_md5 = string.case(lower=true,
  string.trim(environment.get(default="", "PLAYLIST_TOKEN_MD5")))
www_dir = "/radio/www"
playlist_file = "/data/playlist.json"   # written by POST /playlist
pos_file = "/data/position"

# --- playlist -------------------------------------------------------------
def parse_playlist(s) =
  let json.parse (t :
    [{url: string, title: string?, artist: string?, album: string?}]) = s
  t
end

tracks = ref(
  if file.exists(playlist_file) then
    try parse_playlist(file.contents(playlist_file))
    catch err do
      log.severe("Ignoring bad #{playlist_file}: #{err.message}")
      []
    end
  else [] end)
log.important("Loaded #{list.length(tracks())} tracks")

# Position survives restarts. It counts tracks queued, so a restart skips
# the (prefetch) tracks that were downloaded but not yet played.
pos = ref(
  if file.exists(pos_file) then
    int_of_string(default=0, string.trim(file.contents(pos_file)))
  else 0 end)

def set_pos(p) =
  pos := p
  file.write(data=string(p), pos_file)
end

def next_track() =
  n = list.length(tracks())
  if n == 0 then null else
    t = list.nth(tracks(), pos() mod n)
    set_pos((pos() + 1) mod n)
    meta = [
      ("title", t.title ?? ""), ("artist", t.artist ?? ""),
      ("album", t.album ?? "")
    ]
    meta = list.filter(fun (kv) -> snd(kv) != "", meta)
    ann = string.concat(separator=",",
      list.map(fun (kv) -> "#{fst(kv)}=\"#{string.escape(snd(kv))}\"", meta))
    request.create(if ann == "" then t.url else "annotate:#{ann}:#{t.url}" end)
  end
end

# Empty playlist = silence until one is POSTed. Bad URLs are skipped.
queue = request.dynamic(prefetch=prefetch, retry_delay=5., next_track)
radio = mksafe(queue)

# --- now playing ----------------------------------------------------------
now = ref([])
radio.on_metadata(synchronous=false, fun (m) -> now := m)

def nowplaying(_, res) =
  m = now()
  res.content_type("application/json")
  res.header("Cache-Control", "no-store")
  res.data(json.stringify({
    title = m["title"], artist = m["artist"], album = m["album"]
  }))
end
harbor.http.register(port=port, method="GET", "/nowplaying", nowplaying)

def page(_, res) =
  res.html(file.contents("#{www_dir}/index.html"))
end
harbor.http.register(port=port, method="GET", "/", page)

# --- POST /playlist  (Authorization: Bearer <token>, body = playlist JSON) --
def reply(res, code, msg) =
  res.status_code(code)
  res.content_type("application/json")
  res.data(json.stringify({message = msg}))
end

def set_playlist(req, res) =
  auth = list.assoc(default="",
    "authorization", list.map(fun (h) -> (string.case(lower=true, fst(h)), snd(h)),
                              req.headers))
  given = string.trim(string.residual(prefix="Bearer ", auth) ?? "")
  if token_md5 == "" then
    reply(res, 403, "updates disabled (no token configured)")
  elsif given == "" or string.digest(given) != token_md5 then
    reply(res, 401, "bad token")
  else
    body = req.body()
    try
      t = parse_playlist(body)
      if list.length(t) == 0 then error.raise(error.invalid, "empty list") end
      file.write(data=body, playlist_file)
      tracks := t
      set_pos(0)
      queue.set_queue([])   # drop prefetched tracks; current song finishes
      log.important("Playlist replaced: #{list.length(t)} tracks")
      reply(res, 200, "#{list.length(t)} tracks; starts after the current song")
    catch err do
      reply(res, 400, "bad playlist: #{err.message}")
    end
  end
end
harbor.http.register(port=port, method="POST", "/playlist", set_playlist)

# --- stream ---------------------------------------------------------------
output.harbor(
  %ffmpeg(format="mp3", %audio(codec="libmp3lame", b="#{bitrate}k")),
  port=port, mount="stream", format="audio/mpeg",
  radio)
