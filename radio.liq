# Radio: plays playlist.json in order, a few tracks downloaded ahead,
# serves the stream and the player page from one HTTP port.
# Docs: https://www.liquidsoap.info/doc-2.4.6/

settings.log.stdout := true
settings.log.file := false

port = int_of_string(environment.get(default="8000", "PORT"))
bitrate = int_of_string(environment.get(default="128", "BITRATE"))
prefetch = int_of_string(environment.get(default="3", "PREFETCH"))
playlist_file = "/radio/playlist.json"
www_dir = "/radio/www"
pos_file = "/data/position"

# --- playlist -------------------------------------------------------------
let json.parse (tracks :
  [{url: string, title: string?, artist: string?, album: string?}]) =
  file.contents(playlist_file)

n = list.length(tracks)
if n == 0 then
  print("playlist.json has no tracks")
  shutdown()
end
log.important("Loaded #{n} tracks from #{playlist_file}")

# Position survives restarts. It counts tracks queued, so a restart skips
# the (prefetch) tracks that were downloaded but not yet played.
pos = ref(
  if file.exists(pos_file) then
    int_of_string(default=0, string.trim(file.contents(pos_file))) mod n
  else 0 end)

def quote(s) = string.escape(s) end

def next_track() =
  t = list.nth(tracks, pos())
  pos := (pos() + 1) mod n
  file.write(data=string(pos()), pos_file)
  meta = [
    ("title", t.title ?? ""), ("artist", t.artist ?? ""),
    ("album", t.album ?? "")
  ]
  meta = list.filter(fun (kv) -> snd(kv) != "", meta)
  ann = string.concat(separator=",",
    list.map(fun (kv) -> "#{fst(kv)}=\"#{quote(snd(kv))}\"", meta))
  uri = if ann == "" then t.url else "annotate:#{ann}:#{t.url}" end
  request.create(uri)
end

# Bad URLs fail to resolve and are skipped; the next one is fetched.
radio = request.dynamic(prefetch=prefetch, retry_delay=5., next_track)
radio = mksafe(radio)

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

# --- stream ---------------------------------------------------------------
output.harbor(
  %ffmpeg(format="mp3", %audio(codec="libmp3lame", b="#{bitrate}k")),
  port=port, mount="stream", format="audio/mpeg",
  radio)
