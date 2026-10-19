import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import "MediaModel.js" as MediaModel
import "AudioSpectrum.js" as AudioSpectrum

Item {
  id: root

  property var shell: null
  property string preferredPlayerKey: ""
  property string lastActivePlayerKey: ""
  property var playerStartedAt: ({})
  property var pendingTrackOsd: null
  property int playSerial: 0
  // Bumped by signal connections whenever any player's playback state changes.
  // This forces activePlayer (which reads this) to re-evaluate reactively.
  property int playbackVersion: 0

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []

  readonly property var playbackStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isStream && isPlaybackStream(n) && n.audio) list.push(n)
    }
    return list
  }

  // Per-app volume: the PipeWire stream node correlated to the active player, if any.
  readonly property var activePlayerStream: activePlayer ? MediaModel.findPlayerStream(activePlayer, playbackStreams) : null
  readonly property bool hasVolumeControl: activePlayerStream !== null && activePlayerStream.audio !== null
  readonly property real volume: hasVolumeControl ? activePlayerStream.audio.volume : 1.0
  readonly property bool muted: hasVolumeControl ? activePlayerStream.audio.muted : false

  function setVolume(value) {
    if (!hasVolumeControl) return false
    if (typeof value !== "number" || !isFinite(value)) return false
    activePlayerStream.audio.volume = Math.max(0, Math.min(1, value))
    return true
  }

  function adjustVolume(delta) {
    if (!hasVolumeControl) return false
    return setVolume(activePlayerStream.audio.volume + delta)
  }

  function toggleMute() {
    if (!hasVolumeControl) return false
    activePlayerStream.audio.muted = !activePlayerStream.audio.muted
    return true
  }

  property var spectrum: []
  property real spectrumEnergy: 0
  property bool spectrumReady: false
  readonly property real audioLevel: spectrumEnergy
  property int spectrumFailures: 0

  function clearSpectrum() {
    root.spectrum = []
    root.spectrumEnergy = 0
    root.spectrumReady = false
  }

  function syncSpectrumProcess() {
    spectrumRetry.stop()
    root.spectrumFailures = 0
    spectrumProcess.running = root.isPlaying
    if (!root.isPlaying) clearSpectrum()
  }

  onIsPlayingChanged: Qt.callLater(syncSpectrumProcess)

  Timer {
    id: spectrumRetry
    interval: Math.min(8000, 1000 * Math.pow(2, Math.max(0, root.spectrumFailures - 1)))
    onTriggered: if (root.isPlaying) spectrumProcess.running = true
  }

  Process {
    id: spectrumProcess
    command: ["cava", "-p", decodeURIComponent(Qt.resolvedUrl("config/visualizer.conf").toString().replace(/^file:\/\//, ""))]
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(line) {
        var bands = AudioSpectrum.parse(line)
        if (!bands) return
        root.spectrumFailures = 0
        bands = AudioSpectrum.smooth(root.spectrum, bands)
        var sum = 0
        for (var b = 0; b < bands.length; b++) sum += bands[b] * bands[b]
        root.spectrumEnergy = Math.sqrt(sum / 16)
        root.spectrum = bands
        root.spectrumReady = true
        spectrumTimeout.restart()
      }
    }
    onExited: {
      root.clearSpectrum()
      if (root.isPlaying && root.spectrumFailures < 3) {
        root.spectrumFailures++
        spectrumRetry.restart()
      }
    }
  }
  Timer {
    id: spectrumTimeout
    interval: 500
    onTriggered: root.clearSpectrum()
  }

  readonly property var sourcePlayers: orderedSourcePlayers()
  readonly property var sourceCyclePlayers: orderedCycleSourcePlayers()
  // playerStartedAt changes every time syncPlayingOrder() runs (it writes playerStartedAt = next).
  // syncPlayingOrder() is called on every onIsPlayingChanged (via Instantiator below) and on
  // onPlayersChanged. So activePlayer re-evaluates automatically on every pause/resume/switch.
  // playbackVersion, preferredPlayerKey, and lastActivePlayerKey are also read.
  readonly property var activePlayer: {
    var _ps = playerStartedAt  // re-evaluate when any player's playing state changes
    var _pv = playbackVersion
    var _pk = preferredPlayerKey
    var _lk = lastActivePlayerKey
    return selectActivePlayer()
  }

  // isPlaying reads activePlayer.isPlaying directly — a real QML property access.
  // When activePlayer switches (e.g. Spotify→YouTube), this re-evaluates immediately.
  // When the current player pauses/resumes, activePlayer.isPlaying notifies this binding.
  // Falls back to isPlayerActive's PipeWire-stream check for players whose MPRIS
  // PlaybackStatus is stale (see isPlayerActive above).
  readonly property bool isPlaying: isPlayerActive(activePlayer)

  onActivePlayerChanged: Qt.callLater(function() {
    var key = root.playerCanonicalKey(root.activePlayer)
    if (key) root.lastActivePlayerKey = key
    if (root.preferredPlayerKey && key !== root.preferredPlayerKey && root.isPlaying)
      root.preferredPlayerKey = ""
  })

  // Per-player signal connections — use Mpris.players (UntypedObjectModel) directly
  // as the Instantiator model so Qt creates one Connections delegate per player.
  // Wire all relevant MprisPlayer notify signals so any change in state, track, or
  // metadata causes immediate UI updates.
  Instantiator {
    model: Mpris.players
    delegate: Connections {
      required property var modelData
      target: modelData
      function onIsPlayingChanged() {
        Qt.callLater(root.syncPlayingOrder)
        root.playbackVersion++
      }
      function onPlaybackStateChanged() {
        Qt.callLater(root.syncPlayingOrder)
        root.playbackVersion++
      }
      function onMetadataChanged() {
        root.playbackVersion++
      }
      function onTrackTitleChanged() {
        root.playbackVersion++
      }
      function onTrackArtistChanged() {
        root.playbackVersion++
      }
      function onTrackAlbumChanged() {
        root.playbackVersion++
      }
      function onTrackArtUrlChanged() {
        root.playbackVersion++
      }
    }
  }

  readonly property bool hasMedia: activePlayer !== null && (Boolean(title) || Boolean(artist) || isPlaying)
  
  readonly property string title: {
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    var cleaned = MediaModel.cleanTitle(t, a)
    if (cleaned) return cleaned
    return MediaModel.sanitizeText(activePlayer.identity || activePlayer.desktopEntry || "Media Playing")
  }

  readonly property string artist: {
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    return MediaModel.cleanArtist(a, t, activePlayer)
  }

  readonly property string album: activePlayer && activePlayer.trackAlbum ? MediaModel.cleanAlbum(activePlayer.trackAlbum) : (activePlayer && activePlayer.metadata && activePlayer.metadata["xesam:album"] ? MediaModel.cleanAlbum(activePlayer.metadata["xesam:album"]) : "")
  readonly property string rawCandidateArtUrl: activePlayer ? MediaModel.extractArtUrl(activePlayer) : ""
  readonly property string artUrl: artwork.url
  Artwork {
    id: artwork
    source: root.rawCandidateArtUrl
    fallbackSource: root.activePlayer ? MediaModel.extractArtUrl(root.activePlayer, true) : ""
  }

  readonly property string identity: activePlayer ? MediaModel.sanitizeText(activePlayer.identity || activePlayer.desktopEntry || "") : ""

  function isProxyPlayer(player) {
    return MediaModel.isProxyPlayer(player)
  }

  function hasMetadata(player) {
    return MediaModel.hasMetadata(player)
  }

  function canHandleAction(player, action) {
    return MediaModel.canHandleAction(player, action)
  }

  function canCycleSource(player) {
    return MediaModel.canCycleSource(player)
  }

  function isPlaybackStream(node) {
    return MediaModel.isPlaybackStream(node)
  }

  function playerHasActiveStream(player) {
    return MediaModel.playerHasActiveStream(player, playbackStreams)
  }

  // Explicit playback wins over the stream fallback. A paused MPRIS session
  // stays paused even if a browser leaves a PipeWire stream uncorked.
  function playerActivityRank(player) {
    if (!player) return 0
    if (player.isPlaying) return 2
    if (player.playbackState === MprisPlaybackState.Paused) return 0
    if (playerHasActiveStream(player)) return 1
    return 0
  }

  function isPlayerActive(player) {
    return playerActivityRank(player) > 0
  }

  function playerKey(player) {
    return MediaModel.playerKey(player)
  }

  function playerCanonicalKey(player) {
    return MediaModel.playerCanonicalKey(player)
  }

  function playerForKey(key) {
    if (typeof key !== "string" || !key || key.length > 512) return null
    var cKey = key.toLowerCase()
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (playerKey(p) === key || playerCanonicalKey(p) === cKey) return p
    }
    return null
  }

  function playerOrder(player, fallback) {
    var key = playerCanonicalKey(player)
    var value = key ? playerStartedAt[key] : undefined
    return value === undefined ? fallback : value
  }

  function syncPlayingOrder() {
    var next = Object.create(null)
    var alive = Object.create(null)
    var serial = playSerial

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxyPlayer(p)) continue
      var key = playerCanonicalKey(p)
      if (!key) continue

      alive[key] = true
      if (!isPlayerActive(p)) continue

      if (playerStartedAt[key] === undefined) {
        serial += 1
        next[key] = serial
      } else {
        next[key] = playerStartedAt[key]
      }
    }

    if (preferredPlayerKey && !alive[preferredPlayerKey]) preferredPlayerKey = ""
    if (lastActivePlayerKey && !alive[lastActivePlayerKey]) lastActivePlayerKey = ""

    playSerial = serial
    playerStartedAt = next
  }

  function orderedSourcePlayers() {
    var list = []
    var seen = Object.create(null)

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxyPlayer(p)) continue
      var cKey = playerCanonicalKey(p)
      if (!cKey || seen[cKey]) continue
      seen[cKey] = true
      if (hasMetadata(p)) {
        list.push(p)
      }
    }

    list.sort(function(a, b) {
      var aRank = playerActivityRank(a)
      var bRank = playerActivityRank(b)
      if (aRank !== bRank) return bRank - aRank
      if (aRank > 0) {
        var orderDelta = playerOrder(b, 0) - playerOrder(a, 0)
        if (orderDelta !== 0) return orderDelta
      }
      return labelFor(a).localeCompare(labelFor(b))
    })

    return list
  }

  function orderedCycleSourcePlayers() {
    var list = []
    var seen = Object.create(null)

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxyPlayer(p)) continue
      var cKey = playerCanonicalKey(p)
      if (!cKey || seen[cKey]) continue
      seen[cKey] = true
      if (canCycleSource(p)) {
        list.push(p)
      }
    }

    return list
  }

  function mostRecentPlayingPlayer() {
    var newest = null
    var newestRank = 0
    var newestOrder = -1

    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxyPlayer(p)) continue

      var rank = playerActivityRank(p)
      if (rank === 0) continue

      var order = playerOrder(p, i + 1)
      if (!newest || rank > newestRank || (rank === newestRank && order > newestOrder)) {
        newest = p
        newestRank = rank
        newestOrder = order
      }
    }

    return newest || null
  }

  function selectActivePlayer() {
    // 1. User explicitly selected a preferred player
    if (preferredPlayerKey) {
      var preferred = playerForKey(preferredPlayerKey)
      if (preferred && hasMetadata(preferred)) {
        if (isPlayerActive(preferred)) {
          return preferred
        }
        // Preferred player is paused — check if any OTHER player is actively playing
        var otherPlaying = mostRecentPlayingPlayer()
        if (otherPlaying) {
          // A different player is actively playing — switch to the actively playing player
          return otherPlaying
        }
        // Keep a paused selection, but let another paused session replace a stopped one.
        if (preferred.playbackState === MprisPlaybackState.Paused) return preferred
      }
    }

    // 2. Currently playing player (picks most recently started)
    var playingPlayer = mostRecentPlayingPlayer()
    if (playingPlayer) {
      return playingPlayer
    }

    // 3. Nothing is currently playing: stick to last active player if still available
    if (lastActivePlayerKey) {
      var last = playerForKey(lastActivePlayerKey)
      if (last && hasMetadata(last) && last.playbackState === MprisPlaybackState.Paused) return last
    }
    for (var pausedIndex = 0; pausedIndex < players.length; pausedIndex++) {
      var paused = players[pausedIndex]
      if (paused && !isProxyPlayer(paused) && hasMetadata(paused)
          && paused.playbackState === MprisPlaybackState.Paused) return paused
    }

    // 4. Fallback: first available non-proxy player with metadata
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (p && !isProxyPlayer(p) && hasMetadata(p)) {
        return p
      }
    }

    return null
  }

  function labelFor(player) {
    return MediaModel.labelFor(player)
  }

  function osdMessage(player, fallback) {
    return MediaModel.osdMessage(player, fallback)
  }

  function trackSignature(player) {
    return MediaModel.trackSignature(player)
  }

  function showOsd(actionLabel, iconName, player) {
    if (!shell) return
    shell.summon("omarchy.osd", JSON.stringify({
      icon: iconName || "media",
      message: MediaModel.safeSharedText(osdMessage(player || activePlayer, actionLabel))
    }))
  }

  function scheduleOsd(actionLabel, iconName, player, waitForTrackChange, beforeTrackSignature) {
    if (waitForTrackChange) {
      pendingTrackOsd = {
        actionLabel: actionLabel,
        iconName: iconName,
        player: player,
        playerKey: playerKey(player),
        before: beforeTrackSignature,
        attempts: 0
      }
      trackOsdTimer.restart()
    } else {
      Qt.callLater(function() { root.showOsd(actionLabel, iconName, player) })
    }
  }

  function flushPendingTrackOsd(force) {
    var pending = pendingTrackOsd
    if (!pending) return

    var player = playerForKey(pending.playerKey) || pending.player
    if (force || MediaModel.trackChanged(pending.before, player) || pending.attempts >= 10) {
      pendingTrackOsd = null
      trackOsdTimer.stop()
      root.showOsd(pending.actionLabel, pending.iconName, player)
      return
    }

    pending.attempts = pending.attempts + 1
    pendingTrackOsd = pending
    trackOsdTimer.restart()
  }

  function selectPlayer(key) {
    var player = playerForKey(key)
    if (!player || !hasMetadata(player)) return false
    preferredPlayerKey = playerCanonicalKey(player)
    if (!player.isPlaying && (player.canPlay || player.canTogglePlaying)) {
      playPlayer(player)
    }
    return true
  }

  function playPlayer(player) {
    if (!player || player.canControl === false) return false
    if (player.canPlay) {
      player.play()
      return true
    }
    if (player.canTogglePlaying && !player.isPlaying) {
      player.togglePlaying()
      return true
    }
    return false
  }

  function pausePlayer(player) {
    if (!player || player.canControl === false) return false
    if (player.canPause) {
      player.pause()
      return true
    }
    if (player.canTogglePlaying && player.isPlaying) {
      player.togglePlaying()
      return true
    }
    return false
  }

  function switchSource(delta, transferPlayback, showFeedback) {
    var list = sourceCyclePlayers
    if (!list || list.length === 0) return false

    var activeKey = playerCanonicalKey(activePlayer)
    var index = 0
    for (var i = 0; i < list.length; i++) {
      if (playerCanonicalKey(list[i]) === activeKey) {
        index = i
        break
      }
    }

    index = (index + delta + list.length) % list.length
    var current = activePlayer
    var next = list[index]
    var currentWasPlaying = current && Boolean(current.isPlaying)
    var currentKey = playerCanonicalKey(current)
    var nextKey = playerCanonicalKey(next)

    preferredPlayerKey = nextKey
    lastActivePlayerKey = nextKey

    if (transferPlayback && currentWasPlaying && next && nextKey !== currentKey) {
      var nextWasPlaying = Boolean(next.isPlaying)
      var nextStarted = nextWasPlaying || playPlayer(next)
      if (nextStarted) pausePlayer(current)
    }

    if (showFeedback !== false) Qt.callLater(function() {
      root.showOsd("Source", "media-source", next)
    })

    return true
  }

  function playerForAction(action, targetKey) {
    if (targetKey) return playerForKey(targetKey)

    if (canHandleAction(activePlayer, action)) return activePlayer

    var list = sourcePlayers
    for (var i = 0; i < list.length; i++) {
      if (canHandleAction(list[i], action)) return list[i]
    }

    return activePlayer
  }

  function runAction(action, showFeedback, targetKey) {
    var player = playerForAction(action, targetKey)
    if (!player || !canHandleAction(player, action)) return false
    var key = playerKey(player)
    var actionLabel = "Play/pause"
    var iconName = "media"
    var beforeTrackSignature = trackSignature(player)
    var handled = false

    if (action === "next") {
      actionLabel = "Next"
      iconName = "media-next"
      if (player && player.canGoNext) {
        player.next()
        handled = true
      }
    } else if (action === "previous") {
      actionLabel = "Previous"
      iconName = "media-previous"
      if (player && player.canGoPrevious) {
        player.previous()
        handled = true
      }
    } else if (action === "play") {
      actionLabel = "Play"
      iconName = "media-play"
      if (player && player.canPlay) {
        player.play()
        handled = true
      } else if (player && player.canTogglePlaying && !player.isPlaying) {
        player.togglePlaying()
        handled = true
      }
    } else if (action === "pause") {
      actionLabel = "Pause"
      iconName = "media-pause"
      if (player && player.canPause) {
        player.pause()
        handled = true
      } else if (player && player.canTogglePlaying && player.isPlaying) {
        player.togglePlaying()
        handled = true
      }
    } else if (action === "playPause") {
      var isCurrentlyPlaying = player && Boolean(player.isPlaying)
      actionLabel = isCurrentlyPlaying ? "Pause" : "Play"
      iconName = isCurrentlyPlaying ? "media-pause" : "media-play"
      if (player && player.canTogglePlaying && typeof player.togglePlaying === "function") {
        player.togglePlaying()
        handled = true
      } else if (player && player.isPlaying && player.canPause) {
        player.pause()
        handled = true
      } else if (player && !player.isPlaying && player.canPlay) {
        player.play()
        handled = true
      }
    }

    if (handled && key) {
      var cKey = playerCanonicalKey(player)
      preferredPlayerKey = cKey
      lastActivePlayerKey = cKey
    }
    if (showFeedback !== false)
      scheduleOsd(actionLabel, iconName, player, handled && (action === "next" || action === "previous"), beforeTrackSignature)
    return handled
  }

  Component.onCompleted: {
    Qt.callLater(root.syncPlayingOrder)
    Qt.callLater(root.syncSpectrumProcess)
  }
  onPlayersChanged: Qt.callLater(root.syncPlayingOrder)

  Timer {
    id: trackOsdTimer
    interval: 120
    repeat: false
    onTriggered: root.flushPendingTrackOsd(false)
  }

  PwObjectTracker { objects: root.playbackStreams }

  function statusJson() {
    var p = selectActivePlayer()
    var playing = p ? (p.isPlaying === true) : false
    var playingViaStream = isPlayerActive(p)
    var t = p ? (p.trackTitle || (p.metadata && p.metadata["xesam:title"]) || "") : ""
    var a = p ? (p.trackArtist || (p.metadata && p.metadata["xesam:artist"]) || "") : ""
    var cleanedTitle = MediaModel.cleanTitle(t, a)
    var finalTitle = cleanedTitle || (p ? MediaModel.sanitizeText(p.identity || p.desktopEntry || "Media Playing") : "")
    var finalArtist = p ? MediaModel.cleanArtist(a, t, p) : ""
    var finalAlbum = p ? (p.trackAlbum ? MediaModel.cleanAlbum(p.trackAlbum) : (p.metadata && p.metadata["xesam:album"] ? MediaModel.cleanAlbum(p.metadata["xesam:album"]) : "")) : ""
    var finalIdentity = p ? MediaModel.sanitizeText(p.identity || "") : ""
    var finalDesktop = p ? MediaModel.sanitizeText(p.desktopEntry || "") : ""

    return JSON.stringify({
      hasPlayer: p !== null,
      hasMedia: p !== null && (Boolean(finalTitle) || Boolean(finalArtist) || playing),
      playing: playing,
      playingViaStream: playingViaStream,
      serviceIsPlaying: root.isPlaying,
      isLiveStream: MediaModel.isLiveStream(p),
      audioLevel: root.audioLevel,
      activePlayerStreamFound: root.activePlayerStream !== null,
      spectrumReady: root.spectrumReady,
      spectrumBandCount: root.spectrum.length,
      identity: finalIdentity,
      desktopEntry: finalDesktop,
      title: finalTitle,
      artist: finalArtist,
      album: finalAlbum,
      artUrl: root.artUrl,
      hasVolumeControl: root.hasVolumeControl,
      volume: root.volume,
      muted: root.muted,
      canGoNext: p ? !!p.canGoNext : false,
      canGoPrevious: p ? !!p.canGoPrevious : false,
      canTogglePlaying: p ? (!!p.canTogglePlaying || !!p.canPlay || !!p.canPause) : false
    })
  }


  IpcHandler {
    target: "io.github.alwaysread.music-flow"

    function status(): string {
      return root.statusJson()
    }

    function playPause(): string {
      return root.runAction("playPause", true) ? "ok" : "unhandled"
    }

    function next(): string {
      return root.runAction("next", true) ? "ok" : "unhandled"
    }

    function previous(): string {
      return root.runAction("previous", true) ? "ok" : "unhandled"
    }

    function play(): string {
      return root.runAction("play", true) ? "ok" : "unhandled"
    }

    function pause(): string {
      return root.runAction("pause", true) ? "ok" : "unhandled"
    }

    function sourceNext(): string {
      return root.switchSource(1, false, true) ? "ok" : "unhandled"
    }

    function sourcePrevious(): string {
      return root.switchSource(-1, false, true) ? "ok" : "unhandled"
    }

    function sourceSwitch(): string {
      return root.switchSource(1, true, true) ? "ok" : "unhandled"
    }

    function sourceSwitchPrevious(): string {
      return root.switchSource(-1, true, true) ? "ok" : "unhandled"
    }

    function volumeUp(): string {
      return root.adjustVolume(0.05) ? "ok" : "unhandled"
    }

    function volumeDown(): string {
      return root.adjustVolume(-0.05) ? "ok" : "unhandled"
    }

    function setVolume(value: real): string {
      return root.setVolume(value) ? "ok" : "unhandled"
    }

    function toggleMute(): string {
      return root.toggleMute() ? "ok" : "unhandled"
    }

    function ping(): string {
      return "ok"
    }
  }
}
