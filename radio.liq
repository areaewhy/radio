# Radio: any number of named stations, each playing its playlist in order on
# its own live timeline. One HTTP port serves streams, pages and the POST API.
# Docs: https://www.liquidsoap.info/doc-2.4.6/

settings.log.stdout := true
settings.log.file := false

port = int_of_string(environment.get(default="8000", "PORT"))
bitrate = int_of_string(environment.get(default="128", "BITRATE"))
prefetch = int_of_string(environment.get(default="3", "PREFETCH"))# MD5 of the POST token, baked in at build time from a GitHub secret.
# Empty = POST /playlist disabled.
token_md5 = string.case(lower=true,
  string.trim(environment.get(default="", "PLAYLIST_TOKEN_MD5")))
www_dir = "/radio/www"
stations_dir = "/data/stations"   # <name>.json (playlist) + <name>.pos

if not file.exists(stations_dir) then
  try file.mkdir(stations_dir) catch _ do () end
end
if not file.exists(stations_dir) then
  print("FATAL: cannot create #{stations_dir}. /data must be writable by uid 100 " ^
        "(the container's liquidsoap user). Use a named volume (radio-data:/data) " ^
        "or, for a host folder: sudo chown -R 100:101 <folder>")
  exit(1)
end

# Used when a POST gives no color. Bright enough to read on black.
palette = ["#8AFB17", "#FF5E5B", "#00CECB", "#FFD23F", "#C77DFF", "#FF8C42",
           "#3DDC97", "#4EA8DE", "#F15BB5", "#FEE440", "#00F5D4", "#FF70A6"]
def random_color() =
  list.nth(palette, random.int(min=0, max=list.length(palette)))
end

# --- parsing --------------------------------------------------------------
def parse_tracks(s) =
  let json.parse (t :
    [{url: string, title: string?, artist: string?, album: string?}]) = s
  t
end

# {name, color?, tracks}; a bare array means the station "main".
def parse_post(s) =
  try
    let json.parse (p : {name: string, color: string?,
      tracks: [{url: string, title: string?, artist: string?, album: string?}]}) = s
    (string.case(lower=true, string.trim(p.name)), p.color ?? "", p.tracks)
  catch _ do
    ("main", "", parse_tracks(s))
  end
end

def valid_name(n) = r/^[a-z0-9][a-z0-9-]{0,39}$/.test(n) end
def valid_color(c) = r/^#[0-9a-fA-F]{6}$/.test(c) end

# --- stations -------------------------------------------------------------
stations = ref([])

def read_int(f) =
  if file.exists(f) then
    int_of_string(default=0, string.trim(file.contents(f)))
  else 0 end
end

def make_station(name, color, initial) =
  tracks = ref(initial)
  color = ref(color)
  pos_file = "#{stations_dir}/#{name}.pos"
  pos = ref(read_int(pos_file))
  listeners = ref(0)
  now = ref([])

  def set_pos(p) =
    pos := p
    file.write(data=string(p), pos_file)
  end

  # Position counts tracks queued, so a restart skips the few prefetched tracks.
  def next() =
    n = list.length(tracks())
    if n == 0 then null else
      t = list.nth(tracks(), pos() mod n)
      set_pos((pos() + 1) mod n)
      meta = [("title", t.title ?? ""), ("artist", t.artist ?? ""), ("album", t.album ?? "")]
      meta = list.filter(fun (kv) -> snd(kv) != "", meta)
      ann = string.concat(separator=",",
        list.map(fun (kv) -> "#{fst(kv)}=\"#{string.escape(snd(kv))}\"", meta))
      request.create(if ann == "" then t.url else "annotate:#{ann}:#{t.url}" end)
    end
  end

  # Only fetch new tracks while someone is listening: an idle station finishes
  # what it already downloaded, then plays silence. Keeps source-site load low.
  queue = request.dynamic(prefetch=prefetch, retry_delay=1.,
    available={listeners() > 0}, next)
  src = mksafe(queue)
  src.on_metadata(synchronous=false, fun (m) -> now := m)
  out = output.harbor(
    %ffmpeg(format="mp3", %audio(codec="libmp3lame", b="#{bitrate}k")),
    port=port, mount="stream/#{name}", format="audio/mpeg", src)
  out.on_connect(synchronous=false, fun (_) -> listeners := listeners() + 1)
  out.on_disconnect(synchronous=false,
    fun (_) -> listeners := if listeners() > 0 then listeners() - 1 else 0 end)

  def replace(t) =
    tracks := t
    set_pos(0)
    queue.set_queue([])   # drop prefetched tracks; current song finishes
  end
  log.important("Station #{name}: #{list.length(initial)} tracks")
  {name=name, color=color, tracks=tracks, listeners=listeners, now=now,
   replace=replace}
end

# [] or [station]
def find(name) =
  list.map(snd, list.filter(fun (kv) -> fst(kv) == name, stations()))
end

def save(name, color, tracks) =
  file.write(data=json.stringify({name=name, color=color, tracks=tracks}),
    "#{stations_dir}/#{name}.json")
end

# Load saved stations.
list.iter(fun (f) -> begin
    if string.contains(suffix=".json", f) then
      try
        let (name, color, t) = parse_post(file.contents("#{stations_dir}/#{f}"))
        color = if valid_color(color) then color else random_color() end
        stations := list.add((name, make_station(name, color, t)), stations())
      catch err do
        log.severe("Skipping #{f}: #{err.message}")
      end
    end
  end,
  file.ls(sorted=true, stations_dir))

# --- HTTP -----------------------------------------------------------------
def send_json(res, code, v) =
  res.status_code(code)
  res.content_type("application/json")
  res.header("Cache-Control", "no-store")
  res.data(v)
end
def message(res, code, msg) = send_json(res, code, json.stringify({message = msg})) end

def info(s) =
  m = s.now()
  {name = s.name, color = s.color(), tracks = list.length(s.tracks()),
   listeners = s.listeners(), title = m["title"], artist = m["artist"],
   album = m["album"]}
end

harbor.http.register(port=port, method="GET", "/stations", fun (_, res) ->
  send_json(res, 200, json.stringify(
    list.sort(fun (a, b) -> if a.name < b.name then -1 else 1 end,
      list.map(fun (kv) -> info(snd(kv)), stations())))))

harbor.http.register(port=port, method="GET", "/nowplaying/:name", fun (req, res) -> begin
  s = find(list.assoc(default="", "name", req.query))
  if list.length(s) > 0 then send_json(res, 200, json.stringify(info(list.hd(s))))
  else message(res, 404, "no such station") end
end)

harbor.http.register(port=port, method="GET", "/", fun (_, res) ->
  res.html(file.contents("#{www_dir}/index.html")))
harbor.http.register(port=port, method="GET", "/listen/:name", fun (_, res) ->
  res.html(file.contents("#{www_dir}/player.html")))

# POST /playlist  Authorization: Bearer <token>
# Body: {"name": "acdc", "color": "#8AFB17" (optional), "tracks": [...]}
# Same name overwrites. A bare array means the station "main".
def set_playlist(req, res) =
  auth = list.assoc(default="", "authorization",
    list.map(fun (h) -> (string.case(lower=true, fst(h)), snd(h)), req.headers))
  given = string.trim(string.residual(prefix="Bearer ", auth) ?? "")
  if token_md5 == "" then
    message(res, 403, "updates disabled (no token configured)")
  elsif given == "" or string.digest(given) != token_md5 then
    message(res, 401, "bad token")
  else
    try
      let (name, color, t) = parse_post(req.body())
      if not valid_name(name) then
        error.raise(error.invalid, "name must be 1-40 of a-z, 0-9, - (got \"#{name}\")")
      end
      if color != "" and not valid_color(color) then
        error.raise(error.invalid, "color must be #RRGGBB (got \"#{color}\")")
      end
      if list.length(t) == 0 then error.raise(error.invalid, "no tracks") end
      # Only web URLs: no file://, no other protocols or local paths.
      bad = list.filter(fun (x) -> not r/^https?:\/\/[^\s]+$/i.test(x.url), t)
      if list.length(bad) > 0 then
        error.raise(error.invalid,
          "#{list.length(bad)} track url(s) not http(s), e.g. \"#{list.hd(bad).url}\"")
      end
      s = find(name)
      if list.length(s) > 0 then
        s = list.hd(s)
        if color != "" then s.color := color end
        s.replace(t)
        save(name, s.color(), t)
        message(res, 200, "#{name}: replaced, #{list.length(t)} tracks, #{s.color()}; starts after the current song")
      else
        c = if color != "" then color else random_color() end
        stations := list.add((name, make_station(name, c, t)), stations())
        save(name, c, t)
        message(res, 201, "#{name}: created, #{list.length(t)} tracks, #{c}")
      end
    catch err do
      message(res, 400, "bad playlist: #{err.message}")
    end
  end
end
harbor.http.register(port=port, method="POST", "/playlist", set_playlist)

# Keeps the process alive (and the HTTP API up) when no station exists yet.
output.dummy(blank())
