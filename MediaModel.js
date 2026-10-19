// ==============================================================================
// MediaModel.js - Music Flow Intelligent Media & Metadata Resolver
// ==============================================================================

function isProxyPlayer(player) {
  var dbusName = String(player && player.dbusName || "").toLowerCase()
  var desktopEntry = String(player && player.desktopEntry || "").toLowerCase()
  return dbusName.indexOf("playerctld") !== -1 || desktopEntry === "playerctld"
}

function hasMetadata(player) {
  if (!player || isProxyPlayer(player)) return false
  if (player.trackTitle || player.trackArtist || player.identity || player.desktopEntry) return true
  if (player.metadata && (player.metadata["xesam:title"] || player.metadata["xesam:artist"])) return true
  return false
}

function hasTrackMetadata(player) {
  if (!player || isProxyPlayer(player)) return false
  if (player.trackTitle || player.trackArtist || player.trackAlbum || player.trackArtUrl) return true
  if (player.metadata && (player.metadata["xesam:title"] || player.metadata["xesam:artist"] || player.metadata["mpris:artUrl"])) return true
  return false
}

function playerCanControl(player) {
  return !!(player && (player.canTogglePlaying || player.canPlay || player.canPause || player.canGoNext || player.canGoPrevious))
}

function canHandleAction(player, action) {
  if (!player || player.canControl === false) return false
  if (action === "next") return !!player.canGoNext
  if (action === "previous") return !!player.canGoPrevious
  if (action === "play") return !!(player.canPlay || player.canTogglePlaying)
  if (action === "pause") return !!(player.canPause || player.canTogglePlaying)
  if (action === "playPause") return !!(player.canTogglePlaying || player.canPlay || player.canPause)
  return false
}

function canCycleSource(player) {
  return !!(player && hasMetadata(player) && (player.isPlaying || player.canPlay))
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : (node && node.properties ? node.properties : {})
}

function isBlacklistedStream(node) {
  if (!node) return true
  var p = nodeProps(node)
  // capText bounds this before the .indexOf() scans below: PipeWire node properties
  // are set by the client that registered the node (any same-user process), with no
  // protocol-enforced length limit, same trust model as the MPRIS text already
  // capped elsewhere in this file.
  var raw = capText([
    p["application.name"] || "",
    p["application.process.binary"] || "",
    p["node.name"] || "",
    node.name || "",
    node.description || ""
  ].join(" ")).toLowerCase()

  var blacklisted = [
    "speech-dispatcher",
    "speech-dispatcher-dummy",
    "sd_dummy",
    "speechd",
    "spdsend",
    "omarchy_speaker_tuning",
    "quickshell",
    "cava",
    "easyeffects",
    "pulseeffects",
    "rtkit-daemon"
  ]

  return blacklisted.some(function(b) {
    return raw.indexOf(b) !== -1
  })
}

function isPlaybackStream(node) {
  if (!node || !node.isStream || isBlacklistedStream(node)) return false
  var p = nodeProps(node)

  // 1. Filter out notification/event/alert/system sound effects
  var role = capText(String(p["media.role"] || p["node.role"] || "")).toLowerCase()
  if (role === "event" || role === "notification" || role === "alert" || role === "test" || role === "sound-effect") {
    return false
  }

  // 2. Filter out Discord & transient message notification sounds
  var mediaName = capText(String(p["media.name"] || "")).toLowerCase()
  if (mediaName.indexOf("notification") !== -1 || mediaName.indexOf("alert") !== -1 || mediaName.indexOf("message") !== -1 || mediaName.indexOf("ping") !== -1) {
    return false
  }

  var appName = capText(String(p["application.name"] || p["application.process.binary"] || "")).toLowerCase()
  if (appName.indexOf("discord") !== -1 && role !== "music" && mediaName.indexOf("music") === -1) {
    return false
  }

  if (node.isSink === true) return true

  var mediaClass = String(node.type || p["media.class"] || "")
  return mediaClass.indexOf("Stream/Output/Audio") !== -1
    || mediaClass.indexOf("AudioOutStream") !== -1
    || mediaClass.indexOf("Output") !== -1
}

function streamLabelKey(label) {
  // Every caller (rawStreamLabel's output, playerAppLabel's dbus fallback) routes
  // through here, so bounding the input here covers the whole matching pipeline.
  var key = capText(String(label || "")).toLowerCase()
  key = key.replace(/^pipewire alsa \[/, "")
  key = key.replace(/\]$/, "")
  key = key.replace(/^alsa playback \[/, "")
  key = key.replace(/[^a-z0-9]+/g, "")
  return key
}

function rawStreamLabel(node) {
  if (!node) return ""
  var p = nodeProps(node)
  return p["application.name"]
    || node.description
    || p["media.name"]
    || p["application.process.binary"]
    || p["node.name"]
    || node.name
    || ""
}

// Known browser & application families for cross-matching MPRIS & Pipewire
var APP_FAMILY_MAP = {
  "firefox": ["firefox", "zen", "zen-bin", "librewolf", "floorp", "waterfox", "tor-browser", "gecko"],
  "zen": ["zen", "zen-bin", "firefox", "gecko"],
  "librewolf": ["librewolf", "firefox", "gecko"],
  "chromium": ["chromium", "chrome", "google-chrome", "google-chrome-stable", "brave", "brave-browser", "edge", "microsoft-edge", "opera", "vivaldi"],
  "chrome": ["chrome", "google-chrome", "google-chrome-stable", "chromium"],
  "brave": ["brave", "brave-browser", "chromium"],
  "spotify": ["spotify", "spotify-launcher", "spotify-client"],
  "mpv": ["mpv", "mpv-mpris", "celluloid"],
  "vlc": ["vlc"]
}

function normalizeAppName(name) {
  // Bounds areAppsInSameFamily's inputs (MPRIS identity/desktopEntry/dbusName and
  // PipeWire application.name/etc.) before the regex chain below runs.
  var s = capText(String(name || "")).toLowerCase()
  s = s.replace(/^org\.mpris\.mediaplayer2\./, "")
  s = s.replace(/[\._]instance.*$/, "")
  s = s.replace(/[^a-z0-9]/g, "")
  return s
}

function areAppsInSameFamily(nameA, nameB) {
  var a = normalizeAppName(nameA)
  var b = normalizeAppName(nameB)
  if (!a || !b) return false
  if (a === b) return true

  for (var family in APP_FAMILY_MAP) {
    var members = APP_FAMILY_MAP[family]
    var aInFamily = members.some(function(m) { return a === normalizeAppName(m) || a.endsWith(normalizeAppName(m)) })
    var bInFamily = members.some(function(m) { return b === normalizeAppName(m) || b.endsWith(normalizeAppName(m)) })
    if (aInFamily && bInFamily) return true
  }

  return false
}

function playerAppLabel(player) {
  if (!player) return ""
  var dbus = String(player.dbusName || "")
  dbus = dbus.replace(/^org\.mpris\.MediaPlayer2\./, "")
  dbus = dbus.replace(/[\._]instance.*$/, "")
  return player.desktopEntry || player.identity || dbus
}

function playerHasPlaybackStream(player, playbackStreams) {
  if (!player) return false
  var pLabel = playerAppLabel(player)
  var pKey = streamLabelKey(pLabel)
  var pDbus = String(player.dbusName || "")

  var streams = Array.isArray(playbackStreams) ? playbackStreams : []
  for (var i = 0; i < streams.length; i++) {
    var sNode = streams[i]
    if (!sNode) continue
    var sLabel = rawStreamLabel(sNode)
    var sKey = streamLabelKey(sLabel)
    if (!sKey) continue

    if (pKey && sKey === pKey) return true
    if (areAppsInSameFamily(pLabel, sLabel) || areAppsInSameFamily(pDbus, sLabel)) return true

    var p = nodeProps(sNode)
    var binary = String(p["application.process.binary"] || "")
    if (binary && (areAppsInSameFamily(pLabel, binary) || areAppsInSameFamily(pDbus, binary))) return true
  }

  return false
}

// Resolves the single PipeWire stream node that corresponds to a player, for volume
// control. Reuses the same label/family matching heuristics as playerHasPlaybackStream,
// preferring an actively unmuted/uncorked match over a corked/muted one.
function streamMatchesPlayer(player, sNode) {
  if (!player || !sNode) return false
  var pLabel = playerAppLabel(player)
  var pKey = streamLabelKey(pLabel)
  var pDbus = String(player.dbusName || "")
  var sLabel = rawStreamLabel(sNode)
  var sKey = streamLabelKey(sLabel)
  var p = nodeProps(sNode)
  var binary = String(p["application.process.binary"] || "")

  return (sKey && pKey && sKey === pKey)
    || areAppsInSameFamily(pLabel, sLabel)
    || areAppsInSameFamily(pDbus, sLabel)
    || (binary && (areAppsInSameFamily(pLabel, binary) || areAppsInSameFamily(pDbus, binary)))
}

function findPlayerStream(player, playbackStreams) {
  if (!player) return null
  var streams = Array.isArray(playbackStreams) ? playbackStreams : []
  var fallback = null

  for (var i = 0; i < streams.length; i++) {
    var sNode = streams[i]
    if (!sNode || !streamMatchesPlayer(player, sNode)) continue

    var p = nodeProps(sNode)
    var isCorked = p["pulse.corked"] === "true" || p["pulse.corked"] === true
    var isMuted = sNode.audio && sNode.audio.muted
    if (!isCorked && !isMuted) return sNode
    if (!fallback) fallback = sNode
  }

  return fallback
}

function playerHasActiveStream(player, playbackStreams) {
  if (!player) return false
  var pLabel = playerAppLabel(player)
  var pDbus = String(player.dbusName || "")

  var streams = Array.isArray(playbackStreams) ? playbackStreams : []
  for (var i = 0; i < streams.length; i++) {
    var sNode = streams[i]
    if (!sNode) continue
    var p = nodeProps(sNode)
    var isCorked = p["pulse.corked"] === "true" || p["pulse.corked"] === true
    var isMuted = sNode.audio && sNode.audio.muted
    if (isCorked || isMuted) continue

    var sLabel = rawStreamLabel(sNode)
    if (areAppsInSameFamily(pLabel, sLabel) || areAppsInSameFamily(pDbus, sLabel)) return true
    var binary = String(p["application.process.binary"] || "")
    if (binary && (areAppsInSameFamily(pLabel, binary) || areAppsInSameFamily(pDbus, binary))) return true
  }

  return false
}

function playerKey(player) {
  if (!player) return ""
  return capText(player.dbusName || player.desktopEntry || player.identity || "", 512)
}

function playerCanonicalKey(player) {
  // A bus name identifies an MPRIS session. Do not collapse different browser
  // instances: playback controls must retain the exact player selected by the user.
  return capText(playerKey(player), 512).toLowerCase()
}

function trackSignature(player) {
  if (!player) return ""
  return [
    capText(player.trackTitle),
    capText(player.trackArtist),
    capText(player.trackAlbum),
    capText(player.trackArtUrl)
  ].join("\u001f")
}

function trackChanged(previousSignature, player) {
  return trackSignature(player) !== String(previousSignature || "")
}

// ------------------------------------------------------------------------------
// Text & Security Sanitization
// ------------------------------------------------------------------------------

var MAX_TEXT_LENGTH = 4096

// Bounds worst-case CPU/memory from attacker-controlled MPRIS metadata text
// (xesam:title, xesam:url, etc. have no length cap in the MPRIS/D-Bus spec,
// unlike bus names) before it's run through the regex cascades below and in
// cleanTitle/detectPlatform.
function capText(raw, maxLen) {
  if (Array.isArray(raw)) raw = raw.slice(0, 16).map(function(value) {
    return Array.isArray(value) ? "" : String(value === null || value === undefined ? "" : value).slice(0, 256)
  }).join(", ")
  var s = (raw === null || raw === undefined) ? "" : String(raw)
  var limit = maxLen || MAX_TEXT_LENGTH
  return s.length > limit ? s.slice(0, limit) : s
}

// Bound metadata and remove markup and control characters for plain-text labels.
// Shared AutoText sinks additionally require safeSharedText below.
function sanitizeText(raw) {
  if (raw === null || raw === undefined) return ""
  var text = capText(raw)
  if (!text) return ""

  // 1. Remove script, style, and iframe blocks including contents
  text = text.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
  text = text.replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, "")
  text = text.replace(/<iframe\b[^>]*>[\s\S]*?<\/iframe>/gi, "")

  // 2. Strip all remaining HTML/XML tags (e.g. <img ...>, <b>, etc.)
  text = text.replace(/<[^>]*>/g, "")

  // 3. Strip remaining isolated angle brackets, control characters, and non-printable characters
  text = text.replace(/[<>\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/g, "")

  // 4. Normalize multiple whitespace sequences
  text = text.replace(/\s{2,}/g, " ")

  return text.trim()
}

// Shared Omarchy tooltip/OSD sinks may use AutoText. Remove entity introducers
// as well as markup so encoded tags cannot change how those sinks render.
function safeSharedText(raw) {
  return sanitizeText(raw).replace(/&/g, "")
}

// Cleans up common ugly tags from media titles (e.g. YouTube, Animepahe, movie/music titles)
function cleanTitle(rawTitle, rawArtist) {
  var title = sanitizeText(rawTitle)
  var artist = sanitizeText(rawArtist)
  if (!title) return ""

  // 1. Remove browser suffixes
  title = title.replace(/\s*[-—|•]\s*(?:Zen Browser|Mozilla Firefox|Firefox|Google Chrome|Chromium|Brave|Microsoft Edge|Vivaldi|Opera)$/i, "")

  // 2. Remove site branding suffixes
  title = title.replace(/\s*(?:[-—|•]|on|::|\|)\s*(?:YouTube|Twitch|SoundCloud|Spotify|Netflix|Crunchyroll|Coursera|Bandcamp|Vimeo|Reddit|Bilibili|Animepahe|HiAnime|AniWave|Gogoanime|FMovies|Dulo TV|Dulo)(?:\.[a-z]{2,4})?$/i, "")
  title = title.replace(/\s*[-—|•]\s*Watch on [A-Za-z0-9 ]+$/i, "")
  title = title.replace(/\s*::\s*.*$/i, "")

  // 3. Remove streaming filler phrases
  title = title.replace(/\s*(?:Full Movie|Full Show|Full HD|HD Free|Online Free HD|Online Free|Watch Free Online|Watch Online Free|Watch Online|Free Online|Online HD|Free HD|HD Online|Free Stream|Streaming Online)\s*/gi, " ")
  title = title.replace(/^Watch\s+/i, "")

  // 4. Remove anime release group tags and video quality brackets
  title = title.replace(/^\[[^\]]+\]\s*/g, "")
  title = title.replace(/\s*\[[0-9a-fA-F]{8}\]/g, "") // CRC32 hashes
  title = title.replace(/\s*\[(?:1080p|720p|480p|2160p|4k|aac|hevc|x264|x265|dvd|bd|bluray|vostfr|sub)\]/gi, "")
  title = title.replace(/\s*\((?:1080p|720p|480p|2160p|4k|aac|hevc|x264|x265|dvd|bd|bluray|vostfr|sub)\)/gi, "")

  // 5. Remove file extensions
  title = title.replace(/\.(mkv|mp4|avi|webm|mp3|flac|wav|m4a|ogg|opus)$/i, "")

  // 6. Strip duplicate artist prefix if present
  if (artist && title.toLowerCase().indexOf(artist.toLowerCase() + " - ") === 0) {
    title = title.substring(artist.length + 3).trim()
  }

  // 7. Clean up multiple consecutive spaces
  title = title.replace(/\s{2,}/g, " ").trim()

  // 8. If title had "Artist - Title", split it unless right side is episode/season
  if (!artist && title.indexOf(" - ") !== -1) {
    var parts = title.split(" - ")
    if (parts.length === 2) {
      var left = parts[0].trim()
      var right = parts[1].trim()
      var isEpisode = /^(?:ep|episode|season|part|vol|v|s[0-9]+|e[0-9]+)?\s*[0-9]+(?:\.[0-9]+)?$/i.test(right)
      if (!isEpisode && left.length > 1 && right.length > 1 && !/^(?:Season|Episode|Chapter)/i.test(right)) {
        return sanitizeText(right)
      }
    }
  }

  return sanitizeText(title)
}

// Derives a clean artist or source badge
function cleanArtist(rawArtist, rawTitle, player) {
  var artist = ""
  if (rawArtist) {
    if (Array.isArray(rawArtist)) artist = rawArtist.slice(0, 16).map(sanitizeText).join(", ")
    else artist = sanitizeText(rawArtist)
  }

  if (artist && artist !== "Unknown" && artist !== "undefined") return sanitizeText(artist)

  // If artist is missing, check if title had "Artist - Title"
  var title = sanitizeText(rawTitle)
  title = title.replace(/\s*[-—|•]\s*(?:Zen Browser|Mozilla Firefox|Firefox|Google Chrome|Chromium|Brave|YouTube|Twitch|SoundCloud|Spotify|Netflix|Crunchyroll|Coursera|Bandcamp|Vimeo|Reddit|Bilibili)$/i, "")
  title = title.replace(/\s*[-—|•]\s*Watch on [A-Za-z0-9 ]+$/i, "")

  if (title.indexOf(" - ") !== -1) {
    var parts = title.split(" - ")
    if (parts.length === 2) {
      var left = parts[0].trim()
      var right = parts[1].trim()
      var isEpisode = /^(?:ep|episode|season|part|vol|v)?\s*[0-9]+(?:\.[0-9]+)?$/i.test(right)
      if (!isEpisode && left.length > 1 && right.length > 1) {
        return sanitizeText(left)
      }
    }
  }

  // Fallback to detected platform name
  var src = sourceName(player)
  if (src && src !== "Player" && src !== "Media" && src !== "Unknown") return sanitizeText(src)

  return ""
}

function cleanAlbum(rawAlbum) {
  return sanitizeText(rawAlbum)
}

// ------------------------------------------------------------------------------
// Artwork URL Validation & Resource Protection
// ------------------------------------------------------------------------------

var MAX_URL_LENGTH = 2048
var MAX_DATA_IMAGE_LENGTH = 256 * 1024 // 256 KB max for inline data URIs

// Whitelist of trusted media artwork CDN domains
var ALLOWED_HTTPS_CDN_DOMAINS = [
  // YouTube
  "i.ytimg.com",
  "img.youtube.com",
  // Twitch stream previews and browser-provided artwork
  "static-cdn.jtvnw.net",
  // Spotify
  "i.scdn.co",
  "image-cdn-ak.spotifycdn.com",
  "image-cdn-fa.spotifycdn.com",
  "mosaic.scdn.co",
  "lineup-images.scdn.co",
  // Apple Music / iTunes
  "is1-ssl.mzstatic.com",
  "is2-ssl.mzstatic.com",
  "is3-ssl.mzstatic.com",
  "is4-ssl.mzstatic.com",
  "is5-ssl.mzstatic.com",
  "is-ssl.mzstatic.com",
  // SoundCloud
  "i1.sndcdn.com",
  "a1.sndcdn.com",
  // Bandcamp
  "f4.bcbits.com",
  // Last.fm
  "lastfm.freetls.fastly.net",
  // Deezer
  "e-cdns-images.dzcdn.net",
  "cdns-images.dzcdn.net",
  // Tidal
  "resources.tidal.com",
  // Amazon Music
  "m.media-amazon.com",
  "images-na.ssl-images-amazon.com",
  // Genius
  "images.genius.com",
  "images.rapgenius.com"
]

function isAllowedLocalPath(path) {
  if (!path || typeof path !== "string") return false
  if (path.length > MAX_URL_LENGTH) return false

  // Reject control characters and directory traversal
  if (/[\x00-\x1f\x7f]/.test(path)) return false
  if (path.indexOf("..") !== -1) return false
  if (path.charAt(0) !== "/") return false

  // Explicitly disallow SVG files to prevent active XML / resource-referencing decoding
  if (/\.svg(?:z)?$/i.test(path)) return false

  // Disallow sensitive and special OS system paths
  var blockedPrefixes = [
    "/dev/", "/proc/", "/sys/", "/etc/", "/run/", "/var/run/",
    "/boot/", "/root/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/"
  ]
  for (var i = 0; i < blockedPrefixes.length; i++) {
    if (path.indexOf(blockedPrefixes[i]) === 0) return false
  }

  // Allowed directory roots: strictly dedicated cache, temp, and system icon paths.
  // Arbitrary user personal paths (/home/.../Pictures, /home/.../Documents, etc.) are blocked.
  var isCacheOrTemp = (
    path.indexOf("/tmp/") === 0 ||
    path.indexOf("/var/tmp/") === 0 ||
    /\/\.cache\//.test(path)
  )
  var isSystemIcon = (
    path.indexOf("/usr/share/icons/") === 0 ||
    path.indexOf("/usr/share/pixmaps/") === 0
  )
  var isFirefoxMpris = /\/(?:\.config\/mozilla\/firefox|\.mozilla\/firefox)\/firefox-mpris\/[a-zA-Z0-9_-]+\.png$/.test(path)

  if (!isCacheOrTemp && !isSystemIcon && !isFirefoxMpris) return false

  // Strictly raster image file extensions only (no SVG)
  var allowedRasterExtensions = /\.(png|jpe?g|webp|gif|bmp|ico)$/i
  if (allowedRasterExtensions.test(path)) return true

  // Allow cache files with alphanumeric filenames in tmp or cache directories (e.g. Spotify/Chromium cache hashes)
  if (isCacheOrTemp) {
    var basename = path.split("/").pop()
    if (/^[a-zA-Z0-9_\-\.]+$/.test(basename)) return true
  }

  return false
}

function isAllowedHttpsUrl(urlString) {
  if (typeof urlString !== "string" || urlString.length > MAX_URL_LENGTH
      || /[\x00-\x20\x7f\\]/.test(urlString)) return false
  if (/\.svg(?:z)?(?:[?#]|$)/i.test(urlString)) return false
  var match = urlString.match(/^https:\/\/([a-z0-9.-]+)(?::443)?(?=\/|[?#]|$)/i)
  return Boolean(match && ALLOWED_HTTPS_CDN_DOMAINS.indexOf(match[1].toLowerCase()) >= 0)
}

function isRasterDataUri(rawUrl) {
  if (!rawUrl || typeof rawUrl !== "string") return false
  if (rawUrl.length > MAX_DATA_IMAGE_LENGTH) return false

  var match = rawUrl.match(/^data:image\/(?:png|jpe?g|webp|gif|bmp);base64,((?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?)$/i)
  if (!match) return false

  var b64 = match[1]
  // Check raster image magic headers in base64:
  // PNG: iVBORw0KGgo (\x89PNG\r\n\x1a\n)
  // JPEG: /9j/ (\xff\xd8\xff)
  // GIF: R0lGOD (GIF87a / GIF89a)
  // WebP: UklGR (RIFF)
  // BMP: Qk (BM)
  if (b64.indexOf("iVBORw0KGgo") === 0 ||
      b64.indexOf("/9j/") === 0 ||
      b64.indexOf("R0lGOD") === 0 ||
      b64.indexOf("UklGR") === 0 ||
      b64.indexOf("Qk") === 0) {
    return true
  }

  return false
}

// Validates artwork URI against strictly permitted image schemes, safe CDN hosts, and byte limits
function sanitizeArtUrl(rawUrl) {
  if (!rawUrl) return ""
  var raw = String(rawUrl)
  if (raw.length > MAX_DATA_IMAGE_LENGTH) return ""
  var url = raw.trim()
  if (!url) return ""

  // Reject control characters and newlines
  if (/[\x00-\x1f\x7f]/.test(url)) return ""

  // 1. Data URIs: Strictly RASTER image MIME types only with valid base64 magic headers & bounded length
  if (url.indexOf("data:image/") === 0) {
    if (isRasterDataUri(url)) {
      return url
    }
    return ""
  }

  // 2. Local file URIs: file:///...
  if (url.indexOf("file://") === 0) {
    var path = url.slice(7)
    if (/[?#]/.test(path)) return ""
    try { path = decodeURIComponent(path) } catch (e) { return "" }
    if (isAllowedLocalPath(path)) {
      return "file://" + path.split("/").map(encodeURIComponent).join("/")
    }
    return ""
  }

  // 3. Absolute local filesystem paths: /...
  if (url.charAt(0) === "/") {
    if (isAllowedLocalPath(url)) {
      return "file://" + url.split("/").map(encodeURIComponent).join("/")
    }
    return ""
  }

  // 4. Remote HTTPS URLs strictly limited to trusted media CDN hosts
  if (url.indexOf("https://") === 0) {
    if (isAllowedHttpsUrl(url)) {
      return url
    }
    return ""
  }

  return ""
}

function twitchChannel(player) {
  if (!player) return ""
  var meta = player.metadata || {}
  var url = capText(meta["xesam:url"] || player.url, MAX_URL_LENGTH).toLowerCase()
  var match = url.match(/^https:\/\/(?:www\.|m\.)?twitch\.tv\/([a-z0-9_]{1,25})\/?(?:[?#].*)?$/)
  if (match) {
    var reserved = ["videos", "directory", "downloads", "search", "settings", "subscriptions", "inventory", "wallet", "turbo", "jobs", "p", "store", "dashboard", "clips", "collections", "following", "moderator", "login", "signup"]
    return reserved.indexOf(match[1]) < 0 ? match[1] : ""
  }
  if (/^https:\/\/player\.twitch\.tv\//.test(url)) {
    var channel = url.match(/[?&]channel=([a-z0-9_]{1,25})(?:&|$)/)
    return channel ? channel[1] : ""
  }
  return ""
}

function isLiveStream(player) {
  if (!player) return false
  if (twitchChannel(player)) return true
  var meta = player.metadata || {}
  var url = capText(meta["xesam:url"] || player.url, MAX_URL_LENGTH).toLowerCase()
  if (!/^https:\/\/(?:www\.|m\.)?youtube\.com\/(?:watch\?|live\/)/.test(url)) return false
  // Missing duration also occurs on ordinary videos. Only the browser's
  // explicit unbounded-duration sentinel is evidence of a live timeline.
  var metadataLength = Number(meta["mpris:length"])
  var length = Number(player.length)
  return metadataLength >= 1e18
    || (player.lengthSupported === true && (length >= 1e12 || length === Infinity))
}

// Twitch channel previews show the live video; player artwork is the fallback.
function extractArtUrl(player, playerArtworkOnly) {
  if (!player) return ""
  var liveChannel = twitchChannel(player)
  if (liveChannel && !playerArtworkOnly)
    return sanitizeArtUrl("https://static-cdn.jtvnw.net/previews-ttv/live_user_" + liveChannel + "-320x180.jpg")

  var candidate = ""
  if (player.trackArtUrl) {
    candidate = sanitizeArtUrl(player.trackArtUrl)
    if (candidate) return candidate
  }

  var meta = player.metadata || {}
  if (meta["mpris:artUrl"]) {
    candidate = sanitizeArtUrl(meta["mpris:artUrl"])
    if (candidate) return candidate
  }

  if (meta["xesam:artUrl"]) {
    candidate = sanitizeArtUrl(meta["xesam:artUrl"])
    if (candidate) return candidate
  }

  if (playerArtworkOnly) return ""
  var url = capText(meta["xesam:url"] || player.url, MAX_URL_LENGTH)
  if (url) {
    var ytMatch = url.match(/^https:\/\/(?:www\.|m\.)?youtube\.com\/watch\?(?:[^#]*&)?v=([a-zA-Z0-9_-]{11})(?:[&#]|$)/)
      || url.match(/^https:\/\/youtu\.be\/([a-zA-Z0-9_-]{11})(?:[?&#]|$)/)
      || url.match(/^https:\/\/(?:www\.|m\.)?youtube\.com\/(?:live|shorts)\/([a-zA-Z0-9_-]{11})(?:[?&#]|$)/)
    if (ytMatch && ytMatch[1]) {
      return sanitizeArtUrl("https://i.ytimg.com/vi/" + ytMatch[1] + "/hqdefault.jpg")
    }
  }

  return ""
}

// Identifies the exact playing website / streaming service or native desktop app
function detectPlatform(player) {
  if (!player) return { name: "Media", icon: "󰝚" }

  var meta = (player && player.metadata) ? player.metadata : {}
  var url = capText(meta["xesam:url"] || player.url, MAX_URL_LENGTH).toLowerCase()
  var rawTitle = capText(player.trackTitle || meta["xesam:title"]).toLowerCase()
  var artUrl = capText(player.trackArtUrl || meta["mpris:artUrl"] || meta["xesam:artUrl"], MAX_URL_LENGTH).toLowerCase()
  var id = capText(player.identity || player.desktopEntry || player.dbusName || player.appName).toLowerCase()

  // 1. Spotify
  if (id.indexOf("spotify") !== -1 || url.indexOf("spotify.com") !== -1) {
    return { name: "Spotify", icon: "󰓇" }
  }

  // 2. YouTube
  if (url.indexOf("youtube.com") !== -1 || url.indexOf("youtu.be") !== -1 || artUrl.indexOf("ytimg.com") !== -1 || rawTitle.indexOf("youtube") !== -1) {
    return { name: "YouTube", icon: "󰗃" }
  }

  // 3. Twitch
  if (url.indexOf("twitch.tv") !== -1 || rawTitle.indexOf("twitch") !== -1) {
    return { name: "Twitch", icon: "󰕃" }
  }

  // 4. SoundCloud & Bandcamp
  if (url.indexOf("soundcloud.com") !== -1 || rawTitle.indexOf("soundcloud") !== -1) {
    return { name: "SoundCloud", icon: "󰝚" }
  }
  if (url.indexOf("bandcamp.com") !== -1 || rawTitle.indexOf("bandcamp") !== -1) {
    return { name: "Bandcamp", icon: "󰝚" }
  }

  // 5. Anime streaming sites (Animepahe, HiAnime, 9anime, Gogoanime)
  if (rawTitle.indexOf("animepahe") !== -1 || url.indexOf("animepahe") !== -1) return { name: "Animepahe", icon: "󰚩" }
  if (rawTitle.indexOf("hianime") !== -1 || url.indexOf("hianime") !== -1) return { name: "HiAnime", icon: "󰚩" }
  if (rawTitle.indexOf("9anime") !== -1 || rawTitle.indexOf("aniwave") !== -1) return { name: "AniWave", icon: "󰚩" }
  if (rawTitle.indexOf("gogoanime") !== -1 || rawTitle.indexOf("anitaku") !== -1) return { name: "Gogoanime", icon: "󰚩" }

  // 6. Movie streaming sites (FMovies, Dulo TV, Netflix, Crunchyroll)
  if (rawTitle.indexOf("fmovies") !== -1 || url.indexOf("fmovies") !== -1) return { name: "FMovies", icon: "󰐹" }
  if (rawTitle.indexOf("dulo.gd") !== -1 || rawTitle.indexOf("dulo tv") !== -1 || rawTitle.indexOf("dulo") !== -1 || url.indexOf("dulo") !== -1) return { name: "Dulo TV", icon: "󰐹" }
  if (url.indexOf("crunchyroll.com") !== -1 || rawTitle.indexOf("crunchyroll") !== -1) return { name: "Crunchyroll", icon: "󰚩" }
  if (url.indexOf("netflix.com") !== -1 || rawTitle.indexOf("netflix") !== -1) return { name: "Netflix", icon: "󰝆" }

  // 7. Dedicated desktop media players
  if (id.indexOf("mpv") !== -1) return { name: "MPV", icon: "󰐹" }
  if (id.indexOf("vlc") !== -1) return { name: "VLC", icon: "󰕼" }
  if (id.indexOf("cliamp") !== -1) return { name: "cliamp", icon: "󰎆" }
  if (id.indexOf("stremio") !== -1) return { name: "Stremio", icon: "󰐹" }
  if (id.indexOf("celluloid") !== -1) return { name: "Celluloid", icon: "󰐹" }

  // 8. Fallback to browser application name
  if (id.indexOf("zen") !== -1) return { name: "Zen Browser", icon: "󰈹" }
  if (id.indexOf("firefox") !== -1) return { name: "Firefox", icon: "󰈹" }
  if (id.indexOf("brave") !== -1) return { name: "Brave", icon: "󰊯" }
  if (id.indexOf("chrome") !== -1 || id.indexOf("chromium") !== -1) return { name: "Chrome", icon: "󰊯" }
  if (id.indexOf("edge") !== -1) return { name: "Edge", icon: "󰊯" }

  var fallbackName = (player && (player.identity || player.desktopEntry)) || "Media"
  return { name: sanitizeText(fallbackName), icon: "󰝚" }
}

function sourceName(player) {
  return sanitizeText(detectPlatform(player).name)
}

function sourceIcon(player) {
  return detectPlatform(player).icon
}

function labelFor(player) {
  if (!player) return ""
  var raw = player.trackTitle || player.identity || player.desktopEntry || sourceName(player) || ""
  return sanitizeText(raw)
}

function osdMessage(player, fallback) {
  if (!player) return sanitizeText(fallback)
  var label = labelFor(player)
  var artist = player.trackArtist ? sanitizeText(player.trackArtist) : ""
  if (label && artist) return sanitizeText(label + " - " + artist)
  return sanitizeText(label || fallback)
}

if (typeof module !== "undefined") {
  module.exports = {
    isProxyPlayer: isProxyPlayer,
    hasMetadata: hasMetadata,
    hasTrackMetadata: hasTrackMetadata,
    playerCanControl: playerCanControl,
    canHandleAction: canHandleAction,
    canCycleSource: canCycleSource,
    nodeProps: nodeProps,
    isBlacklistedStream: isBlacklistedStream,
    isPlaybackStream: isPlaybackStream,
    streamLabelKey: streamLabelKey,
    rawStreamLabel: rawStreamLabel,
    normalizeAppName: normalizeAppName,
    areAppsInSameFamily: areAppsInSameFamily,
    playerAppLabel: playerAppLabel,
    playerHasPlaybackStream: playerHasPlaybackStream,
    playerHasActiveStream: playerHasActiveStream,
    findPlayerStream: findPlayerStream,
    playerKey: playerKey,
    playerCanonicalKey: playerCanonicalKey,
    trackSignature: trackSignature,
    trackChanged: trackChanged,
    sanitizeText: sanitizeText,
    safeSharedText: safeSharedText,
    cleanTitle: cleanTitle,
    cleanArtist: cleanArtist,
    cleanAlbum: cleanAlbum,
    isRasterDataUri: isRasterDataUri,
    sanitizeArtUrl: sanitizeArtUrl,
    extractArtUrl: extractArtUrl,
    twitchChannel: twitchChannel,
    isLiveStream: isLiveStream,
    detectPlatform: detectPlatform,
    sourceName: sourceName,
    sourceIcon: sourceIcon,
    labelFor: labelFor,
    osdMessage: osdMessage
  }
}
