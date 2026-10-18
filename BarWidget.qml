import qs.Commons as PluginCommons
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Ui
import qs.Commons
import "MediaModel.js" as MediaModel

BarWidget {
  id: root
  moduleName: "custom.media"

  property var service: null
  property string visualizerMode: {
    var mode = setting("visualizerMode", "wave")
    return ["wave", "bars", "dots", "particles", "equalizer", "ribbon"].indexOf(mode) >= 0 ? mode : "wave"
  }
  property bool showBarThumbnail: setting("showBarThumbnail", true) === true
  property bool showAppLogo: setting("showAppLogo", true) === true
  Process { id: appLogoPreference }
  Process { id: thumbnailPreference }
  Process { id: textPreference }
  Process { id: animationPreference }
  property bool showText: setting("showText", true) === true

  function toggleTrackText() {
    if (textPreference.running) return
    root.showText = !root.showText
    textPreference.command = ["omarchy", "bar", "set", "custom.media", "showText", root.showText ? "true" : "false", "--json"]
    textPreference.running = true
  }

  function selectAnimation(mode) {
    if (animationPreference.running) return
    root.visualizerMode = mode
    animationPreference.command = ["omarchy", "bar", "set", "custom.media", "visualizerMode", mode, "--json"]
    animationPreference.running = true
    waveCanvas.requestPaint()
  }

  // The original repo registered this plugin under a per-user id
  // (${USER_NAME}.media) before this fork switched to the fixed
  // "custom.media" id above. Derive that legacy id from the account
  // actually running the shell instead of a hardcoded name - a literal
  // like "nek0.media" only ever matched one specific developer's own
  // machine and was a no-op fallback for everyone else.
  readonly property string legacyUserPluginId: {
    var u = Quickshell.env("USER") || Quickshell.env("LOGNAME") || ""
    return u ? (u + ".media") : ""
  }

  readonly property var mediaService: {
    if (service) return service
    if (!root.bar || !root.bar.shell) return null
    if (root.moduleName && root.bar.shell.serviceFor(root.moduleName))
      return root.bar.shell.serviceFor(root.moduleName)
    if (root.bar.shell.serviceFor("custom.media"))
      return root.bar.shell.serviceFor("custom.media")
    if (root.legacyUserPluginId && root.bar.shell.serviceFor(root.legacyUserPluginId))
      return root.bar.shell.serviceFor(root.legacyUserPluginId)
    if (root.bar.shell.serviceFor("omarchy.media"))
      return root.bar.shell.serviceFor("omarchy.media")
    if (root.bar.shell.firstPartyServiceFor("omarchy.media"))
      return root.bar.shell.firstPartyServiceFor("omarchy.media")
    return null
  }

  function deduplicatePlayers(players) {
    var list = []
    var seen = {}
    var raw = players || []
    for (var i = 0; i < raw.length; i++) {
      var p = raw[i]
      if (!p || MediaModel.isProxyPlayer(p)) continue
      var cKey = MediaModel.playerCanonicalKey(p)
      if (!cKey || seen[cKey]) continue
      seen[cKey] = true
      if (MediaModel.hasMetadata(p)) list.push(p)
    }
    return list
  }

  readonly property var fallbackPlayers: deduplicatePlayers(Mpris.players ? Mpris.players.values : [])

  function findFallbackActivePlayer() {
    var list = fallbackPlayers || []
    var fallback = null
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!p) continue
      if (p.isPlaying) return p
      if (!fallback && (p.trackTitle || p.trackArtist || p.canPlay)) fallback = p
    }
    return fallback
  }

  // Reading mediaService.activePlayer is a direct QML property access — QML tracks
  // it as a dependency and re-evaluates when the service's activePlayer changes.
  // The fallback reads Mpris.players.values directly so isPlaying changes still propagate.
  readonly property var activePlayer: {
    if (mediaService && mediaService.activePlayer) return mediaService.activePlayer
    return findFallbackActivePlayer()
  }
  readonly property var sourcePlayers: mediaService && mediaService.sourcePlayers && mediaService.sourcePlayers.length > 0 ? mediaService.sourcePlayers : fallbackPlayers
  // Prefer mediaService.isPlaying when the service backs the current activePlayer: it
  // also treats a player as playing when its PipeWire stream is actively flowing even
  // if MPRIS's own PlaybackStatus is stale (e.g. Chromium reporting "Stopped" while a
  // tab still has an unmuted, uncorked audio stream). The no-service fallback path has
  // no PipeWire correlation available, so it stays on raw MPRIS state.
  readonly property bool isPlaying: {
    if (mediaService && mediaService.activePlayer) return Boolean(mediaService.isPlaying)
    return (activePlayer && activePlayer.isPlaying) || false
  }

  // Per-app volume mirrors mediaService only — the standalone fallback path (no service)
  // has no PipeWire stream correlation available, so volume control is simply unavailable then.
  readonly property bool hasVolumeControl: Boolean(mediaService && mediaService.hasVolumeControl)
  readonly property real volume: hasVolumeControl ? mediaService.volume : 1.0
  readonly property bool muted: Boolean(mediaService && mediaService.muted)

  function setVolume(value) {
    if (mediaService && typeof mediaService.setVolume === "function") mediaService.setVolume(value)
  }

  function toggleMute() {
    if (mediaService && typeof mediaService.toggleMute === "function") mediaService.toggleMute()
  }

  readonly property var spectrum: mediaService && mediaService.spectrum ? mediaService.spectrum : []
  readonly property real currentEnergy: mediaService ? mediaService.audioLevel : 0
  property int positionTick: 0
  readonly property real trackLength: activePlayer && activePlayer.lengthSupported ? Math.max(0, activePlayer.length) : 0
  readonly property real trackPosition: {
    var tick = positionTick
    return activePlayer && activePlayer.positionSupported ? Math.max(0, Math.min(trackLength, activePlayer.position)) : 0
  }
  readonly property bool hasTrackProgress: Boolean(activePlayer && activePlayer.positionSupported && trackLength > 0)

  function formatTime(seconds) {
    var total = Math.max(0, Math.floor(seconds || 0))
    var minutes = Math.floor(total / 60)
    var remainder = total % 60
    return minutes + ":" + (remainder < 10 ? "0" : "") + remainder
  }

  Timer {
    interval: 500
    repeat: true
    running: root.popupOpen && root.hasTrackProgress && Boolean(root.activePlayer && root.activePlayer.isPlaying)
    onTriggered: root.positionTick++
  }
  onSpectrumChanged: { if (waveCanvas.visible) waveCanvas.requestPaint() }
  onIsPlayingChanged: waveCanvas.requestPaint()

  readonly property bool hasMedia: activePlayer !== null && (Boolean(title) || Boolean(isPlaying) || Boolean(activePlayer.trackTitle || activePlayer.trackArtist))
  readonly property string playIcon: isPlaying ? "󰏤" : "󰐊"
  
  readonly property string title: {
    if (mediaService && mediaService.title) return MediaModel.sanitizeText(mediaService.title)
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    if (t) return MediaModel.cleanTitle(t, a)
    if (activePlayer.identity) return MediaModel.sanitizeText(activePlayer.identity)
    if (activePlayer.desktopEntry) return MediaModel.sanitizeText(activePlayer.desktopEntry)
    return "Playing"
  }

  readonly property string artist: {
    if (mediaService && mediaService.artist) return MediaModel.sanitizeText(mediaService.artist)
    if (!activePlayer) return ""
    var t = activePlayer.trackTitle || (activePlayer.metadata && activePlayer.metadata["xesam:title"]) || ""
    var a = activePlayer.trackArtist || (activePlayer.metadata && activePlayer.metadata["xesam:artist"]) || ""
    return MediaModel.cleanArtist(a, t, activePlayer)
  }

  readonly property string album: {
    if (mediaService && mediaService.album) return MediaModel.cleanAlbum(mediaService.album)
    if (!activePlayer) return ""
    if (activePlayer.trackAlbum) return MediaModel.cleanAlbum(activePlayer.trackAlbum)
    if (activePlayer.metadata && activePlayer.metadata["xesam:album"]) return MediaModel.cleanAlbum(activePlayer.metadata["xesam:album"])
    return ""
  }

  property string verifiedArtUrl: ""
  readonly property string rawCandidateArtUrl: {
    if (mediaService) return ""
    if (!activePlayer) return ""
    return MediaModel.extractArtUrl(activePlayer)
  }

  readonly property string artUrl: {
    var cached = mediaService ? String(mediaService.artUrl || "") : ""
    // The service has validated raster bytes before writing this exact cache.
    // Keep its timestamp query so Qt reloads the image when the track changes.
    var expected = "file://" + artworkCachePath
    if (cached === expected || (cached.indexOf(expected + "?t=") === 0 && /^\d+$/.test(cached.slice(expected.length + 3)))) return cached
    if (MediaModel.isRasterDataUri(cached)) return cached
    return verifiedArtUrl
  }
  readonly property string artworkCachePath: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy/music-flow/artwork.cache"

  onRawCandidateArtUrlChanged: {
    var raw = root.rawCandidateArtUrl
    if (!raw) {
      artFetchProc.running = false
      root.verifiedArtUrl = ""
      return
    }

    if (MediaModel.isRasterDataUri(raw)) {
      artFetchProc.running = false
      root.verifiedArtUrl = raw
      return
    }

    // Remote HTTPS or local file: validate & cache with strict byte limits, no redirects, secure mktemp, and magic byte check
    root.verifiedArtUrl = ""
    artFetchProc.running = false
    artFetchProc.command = [
      "bash", "-c",
      "set -euo pipefail; URL=\"$1\"; CACHE_FILE=\"$2\"; CACHE_DIR=\"$(dirname \"$CACHE_FILE\")\"; mkdir -p -m 0700 \"$CACHE_DIR\"; TMP_FILE=$(mktemp -p \"$CACHE_DIR\" artwork.XXXXXX); trap 'rm -f \"${TMP_FILE:-}\"' EXIT; if [[ \"$URL\" =~ ^https:// ]]; then HTTP_CODE=$(curl -sS --connect-timeout 3 --max-time 10 --retry 2 --retry-delay 1 --retry-max-time 25 --max-filesize 2097152 --proto \"=https\" -w \"%{http_code}\" \"$URL\" -o \"$TMP_FILE\" 2>/dev/null || echo \"000\"); if [[ \"$HTTP_CODE\" != \"200\" ]]; then exit 1; fi; elif [[ \"$URL\" =~ ^file://(/.*) ]] || [[ \"$URL\" =~ ^(/.*) ]]; then FILE_PATH=\"${BASH_REMATCH[1]}\"; python3 -c '\nimport os,stat,sys\nfrom urllib.parse import unquote, urlsplit\np=unquote(urlsplit(sys.argv[1]).path)\nfd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK|os.O_CLOEXEC)\nst=os.fstat(fd)\nif not(stat.S_ISREG(st.st_mode) and 4<=st.st_size<=2097152):\n os.close(fd)\n sys.exit(1)\nd=os.read(fd,2097152)\nos.close(fd)\nsys.stdout.buffer.write(d)\n' \"$FILE_PATH\" > \"$TMP_FILE\" 2>/dev/null; else exit 1; fi; MAGIC=$(od -N 12 -A n -t x1 \"$TMP_FILE\" 2>/dev/null | tr -d \" \\n\"); if [[ \"$MAGIC\" =~ ^89504e470d0a1a0a ]] || [[ \"$MAGIC\" =~ ^ffd8 ]] || [[ \"$MAGIC\" =~ ^47494638 ]] || [[ \"$MAGIC\" =~ ^424d ]] || [[ \"$MAGIC\" =~ ^52494646.{8}57454250 ]]; then mv -f \"$TMP_FILE\" \"$CACHE_FILE\"; exit 0; else exit 1; fi",
      "--",
      raw,
      root.artworkCachePath
    ]
    artFetchProc.running = true
  }

  Process {
    id: artFetchProc
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.verifiedArtUrl = "file://" + root.artworkCachePath + "?t=" + Date.now()
      } else {
        root.verifiedArtUrl = ""
      }
    }
  }

  PluginCommons.Translations { id: localStrings; directory: Qt.resolvedUrl("local-i18n") }
  property bool settingsOpen: false
  property bool popupOpen: false
  property bool isMinimized: false

  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }
  property real maxLabelWidth: 220

  function playerKey(player) {
    if (!player) return ""
    if (mediaService && typeof mediaService.playerKey === "function") return mediaService.playerKey(player)
    return MediaModel.playerKey(player)
  }

  function playerCanonicalKey(player) {
    if (!player) return ""
    return MediaModel.playerCanonicalKey(player)
  }

  function runAction(action, targetPlayer) {
    var p = targetPlayer || activePlayer
    if (!p) return
    if (mediaService && typeof mediaService.runAction === "function") {
      mediaService.runAction(action, false, playerKey(p))
      return
    }
    if (action === "playPause") {
      if (typeof p.togglePlaying === "function") p.togglePlaying()
      else if (typeof p.playPause === "function") p.playPause()
      else if (p.isPlaying && typeof p.pause === "function") p.pause()
      else if (typeof p.play === "function") p.play()
    } else if (action === "next" && typeof p.next === "function") {
      p.next()
    } else if (action === "previous" && typeof p.previous === "function") {
      p.previous()
    }
  }

  function selectPlayer(targetPlayer) {
    if (!targetPlayer) return
    var key = playerKey(targetPlayer)
    if (mediaService && typeof mediaService.selectPlayer === "function") {
      mediaService.selectPlayer(key)
    } else {
      if (typeof targetPlayer.play === "function") {
        targetPlayer.play()
      } else if (typeof targetPlayer.togglePlaying === "function") {
        targetPlayer.togglePlaying()
      }
    }
  }

  function sourceName(player) {
    return MediaModel.sourceName(player)
  }

  function sourceIcon(player) {
    return MediaModel.sourceIcon(player)
  }

  visible: Boolean(root.activePlayer && (root.isPlaying || root.activePlayer.playbackState === MprisPlaybackState.Paused))
  onVisibleChanged: {
    if (!visible) {
      root.popupOpen = false
      if (root.bar) root.bar.hideTooltip(root)
    }
  }
  implicitWidth: pill.width + Style.space(8)
  implicitHeight: barSize

  Behavior on implicitWidth {
    NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
  }

  // Bar Pill Capsule - Dynamic Continuous Flow Audio Visualizer
  BorderSurface {
    id: pill
    anchors.centerIn: parent
    height: Math.min(parent.height - Style.space(6), Style.space(28))
    width: root.isMinimized
      ? height
      : (root.showText ? (flowRow.implicitWidth + Style.space(16)) : Math.max(Style.space(110), flowRow.implicitWidth + Style.space(16)))
    radius: Style.cornerRadius
    clip: true
    color: clickArea.containsMouse ? Util.alpha(root.bar ? root.bar.barForeground : Color.foreground, 0.05) : "transparent"
    borderSpec: Border.none()

    Behavior on width {
      NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
    }
    Behavior on color {
      ColorAnimation { duration: 180 }
    }

    // Subtle live audio animation behind the media content.
    Canvas {
      id: waveCanvas
      anchors.fill: parent
      anchors.margins: Style.space(2)
      anchors.leftMargin: barThumbnail.visible
        ? Style.space(8) + barThumbnail.width + Style.space(7)
        : Style.space(2)
      visible: !root.isMinimized
      readonly property bool highContrast: !root.showBarThumbnail && !root.showAppLogo && !root.showText
      opacity: highContrast ? 1.0 : 0.55
      onHighContrastChanged: requestPaint()
      onVisibleChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        if (!visible || !root.isPlaying || root.spectrum.length !== 16 || width <= 0 || height <= 0) return
        var bands = root.spectrum
        var sumSquares = 0
        for (var b = 0; b < bands.length; b++) sumSquares += bands[b] * bands[b]
        var energy = Math.sqrt(sumSquares / bands.length)
        if (energy <= 0.005) return
        var mid = height / 2
        var mode = root.visualizerMode
        ctx.strokeStyle = Util.alpha(Color.accent, 0.35 + energy * 0.65)
        ctx.fillStyle = Util.alpha(Color.accent, 0.25 + energy * 0.75)
        ctx.lineWidth = highContrast ? 2.5 : 1.5
        if (mode === "ribbon") {
          ctx.beginPath()
          for (var top = 0; top < 16; top++) {
            var ribbonX = top * width / 15
            var ribbonY = mid - bands[top] * height * 0.44
            if (top === 0) ctx.moveTo(ribbonX, ribbonY)
            else ctx.lineTo(ribbonX, ribbonY)
          }
          for (var bottom = 15; bottom >= 0; bottom--)
            ctx.lineTo(bottom * width / 15, mid + bands[bottom] * height * 0.44)
          ctx.closePath()
          ctx.fill()
        } else if (mode === "wave") {
          for (var side = -1; side <= 1; side += 2) {
            ctx.beginPath()
            for (var i = 0; i < 16; i++) {
              var x = i * width / 15
              var y = mid + side * bands[i] * height * 0.44
              if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
            }
            ctx.stroke()
          }
        } else {
          var step = width / 16
          for (var n = 0; n < 16; n++) {
            var value = bands[n]
            if (value <= 0.005) continue
            ctx.fillStyle = Util.alpha(Color.accent, value)
            var px = (n + 0.5) * step
            var h = value * height * 0.9
            if (mode === "equalizer") ctx.fillRect(px - step * 0.3, height - h, step * 0.6, h)
            else if (mode === "bars") ctx.fillRect(px - step * 0.25, mid - h / 2, step * 0.5, h)
            else if (mode === "dots") {
              ctx.beginPath(); ctx.arc(px, mid, value * Math.min(step * 0.4, height * 0.4), 0, Math.PI * 2); ctx.fill()
            } else if (mode === "particles") {
              // Frequency energy places paired sparks; no random or timed motion.
              for (var sign = -1; sign <= 1; sign += 2) {
                ctx.beginPath(); ctx.arc(px, mid + sign * h / 2, value * 2, 0, Math.PI * 2); ctx.fill()
              }
            }
          }
        }
      }
    }

    // Minimized Mode (Single icon)
    Item {
      anchors.fill: parent
      visible: root.isMinimized

      Text {
        anchors.centerIn: parent
        text: "󰝚"
        textFormat: Text.PlainText
        color: root.isPlaying ? Color.accent : (clickArea.containsMouse ? Color.accent : (root.bar ? root.bar.barForeground : Color.foreground))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
        Behavior on color { ColorAnimation { duration: 140 } }
      }
    }

    // Thumbnail, app logo, and track text each follow their own display toggle.
    Row {
      id: flowRow
      anchors.verticalCenter: parent.verticalCenter
      x: barThumbnail.visible ? Style.space(8) : (parent.width - width) / 2
      spacing: Style.space(7)
      visible: !root.isMinimized

      Item {
        id: barThumbnail
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(22)
        height: width
        visible: root.showBarThumbnail

        Image {
          id: barArtwork
          anchors.fill: parent
          source: root.artUrl
          sourceSize.width: Style.space(44)
          sourceSize.height: Style.space(44)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          autoTransform: true
          visible: status === Image.Ready
        }

        Text {
          anchors.centerIn: parent
          visible: barArtwork.status !== Image.Ready
          text: root.sourceIcon(root.activePlayer)
          textFormat: Text.PlainText
          color: Color.accent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      // Music Icon / Source Glyph
      Text {
        id: glyph
        visible: root.showAppLogo && (!root.showBarThumbnail || barArtwork.status === Image.Ready)
        anchors.verticalCenter: parent.verticalCenter
        text: root.hasMedia && root.showAppLogo ? root.sourceIcon(root.activePlayer) : "󰝚"
        textFormat: Text.PlainText
        color: root.isPlaying ? Color.accent : (root.hasMedia ? (root.bar ? root.bar.barForeground : Color.foreground) : Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.4))
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }
      }

      // Track Title & Artist with smooth marquee scroll, or idle placeholder
      Item {
        id: scrollClip
        width: root.hasMedia ? Math.min(root.maxLabelWidth, titleRow.implicitWidth) : idleLabel.implicitWidth
        height: Math.max(glyph.implicitHeight, Style.space(16))
        clip: true
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showText && (!root.bar || !root.bar.vertical)

        Text {
          id: idleLabel
          visible: !root.hasMedia
          text: "Music"
          textFormat: Text.PlainText
          color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Row {
          id: titleRow
          visible: root.hasMedia
          spacing: Style.space(5)
          anchors.verticalCenter: parent.verticalCenter

          property bool needsScroll: titleRow.implicitWidth > root.maxLabelWidth

          Text {
            id: titleText
            text: root.title
            textFormat: Text.PlainText
            color: root.bar ? root.bar.barForeground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: sepText
            visible: root.artist !== ""
            text: "·"
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: artistText
            visible: root.artist !== ""
            text: root.artist
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          SequentialAnimation on x {
            id: scrollAnim
            running: titleRow.needsScroll && !root.popupOpen && (!root.bar || !root.bar.vertical) && root.hasMedia && !root.isMinimized && root.showText
            loops: Animation.Infinite

            PauseAnimation { duration: 2500 }
            NumberAnimation {
              to: -(titleRow.implicitWidth - scrollClip.width)
              duration: Math.max(3000, (titleRow.implicitWidth - scrollClip.width) * 35)
              easing.type: Easing.Linear
            }
            PauseAnimation { duration: 2000 }
            NumberAnimation {
              to: 0
              duration: Math.max(1500, (titleRow.implicitWidth - scrollClip.width) * 15)
              easing.type: Easing.InOutQuad
            }
          }
        }
      }
    }
  }

  // Interactive Bar Click Area
  MouseArea {
    id: clickArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) {
        root.runAction("playPause", root.activePlayer)
      } else if (mouse.button === Qt.RightButton) {
        root.toggleTrackText()
      } else {
        root.popupOpen = !root.popupOpen
      }
    }
    onWheel: function(wheel) {
      if (!root.activePlayer) return
      if (wheel.angleDelta.y > 0) {
        root.runAction("previous", root.activePlayer)
      } else if (wheel.angleDelta.y < 0) {
        root.runAction("next", root.activePlayer)
      }
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasMedia ? MediaModel.sanitizeText(root.title + (root.artist ? " — " + root.artist : "")) : "Music Player (Right-click: Toggle Text)")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // Dedicated Floating Player & Source Selection Window
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(12)

      // Top Row: Album Cover Art & Song Info
      Row {
        spacing: Style.space(12)
        width: parent.width

        BorderSurface {
          width: Style.space(72)
          height: Style.space(72)
          radius: Style.cornerRadius
          color: Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.08)
          borderSpec: Border.controlSpec("normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)

          Image {
            id: popupThumbnail
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            autoTransform: true
            sourceSize.width: Style.space(144)
            sourceSize.height: Style.space(144)
            source: root.artUrl
            visible: status === Image.Ready
          }

          Text {
            anchors.centerIn: parent
            visible: popupThumbnail.status !== Image.Ready
            text: root.hasMedia ? root.sourceIcon(root.activePlayer) : "󰝚"
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          spacing: Style.space(3)
          width: parent.width - Style.space(72) - settingsGear.width - parent.spacing * 2
          anchors.verticalCenter: parent.verticalCenter

          // Active Source Badge
          Row {
            spacing: Style.space(4)
            Text {
              text: root.sourceIcon(root.activePlayer)
              textFormat: Text.PlainText
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: root.sourceName(root.activePlayer).toUpperCase()
              textFormat: Text.PlainText
              color: Color.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            text: root.title || "Nothing playing"
            textFormat: Text.PlainText
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            text: root.artist
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          Text {
            text: root.album
            textFormat: Text.PlainText
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }
        Button {
          id: settingsGear
          bordered: true
          iconText: "󰒓"
          tooltipText: localStrings.t("settings.title")
          foreground: root.bar ? root.bar.foreground : Color.foreground
          selected: root.settingsOpen
          focusable: true
          onClicked: root.settingsOpen = !root.settingsOpen
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(2)
        visible: root.hasTrackProgress

        PanelSlider {
          id: progressSlider
          width: parent.width
          bar: root.bar
          minimum: 0
          maximum: Math.max(1, root.trackLength)
          step: 5
          value: root.trackPosition
          enabled: Boolean(root.activePlayer && root.activePlayer.canSeek)
          opacity: enabled ? 1 : 0.6
          fillColor: Color.accent
          knobColor: Color.accent
          property var targetPlayer: null
          property string targetTrack: ""
          onDraggingChanged: {
            if (dragging) {
              targetPlayer = root.activePlayer
              targetTrack = MediaModel.trackSignature(targetPlayer)
            }
          }
          onMoved: function(value) {
            if (!dragging) {
              targetPlayer = root.activePlayer
              targetTrack = MediaModel.trackSignature(targetPlayer)
            }
          }
          onReleased: function(value) {
            if (targetPlayer && targetPlayer === root.activePlayer
                && targetTrack === MediaModel.trackSignature(targetPlayer)
                && targetPlayer.canSeek && targetPlayer.positionSupported) {
              targetPlayer.position = Math.max(0, Math.min(root.trackLength, value))
              root.positionTick++
            }
            targetPlayer = null
          }
        }

        Row {
          width: parent.width
          Text {
            width: parent.width / 2
            text: root.formatTime(progressSlider.dragging ? progressSlider.liveValue : root.trackPosition)
            textFormat: Text.PlainText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.65)
          }
          Text {
            width: parent.width / 2
            horizontalAlignment: Text.AlignRight
            text: root.formatTime(root.trackLength)
            textFormat: Text.PlainText
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.65)
          }
        }
      }

      // Playback Controls
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(12)

        Button {
          iconText: "󰒮"
          width: Style.space(40)
          height: Style.space(40)
          foreground: root.bar ? root.bar.foreground : Color.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: Boolean(root.activePlayer && root.activePlayer.canGoPrevious)
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.runAction("previous", root.activePlayer)
        }

        Button {
          iconText: root.isPlaying ? "󰏤" : "󰐊"
          width: Style.space(40)
          height: Style.space(40)
          foreground: Color.accent
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: Boolean(root.activePlayer && (root.activePlayer.canTogglePlaying || root.activePlayer.canPlay || root.activePlayer.canPause || root.isPlaying))
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.runAction("playPause", root.activePlayer)
        }

        Button {
          iconText: "󰒭"
          width: Style.space(40)
          height: Style.space(40)
          foreground: root.bar ? root.bar.foreground : Color.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: Boolean(root.activePlayer && root.activePlayer.canGoNext)
          opacity: enabled ? 1.0 : 0.4
          onClicked: root.runAction("next", root.activePlayer)
        }
      }

      // Per-Source Volume (the PipeWire stream correlated to the active player)
      Row {
        width: parent.width
        spacing: Style.space(8)
        visible: root.hasVolumeControl

        Text {
          id: volumeIcon
          text: root.muted ? "󰝟" : (root.volume > 0.5 ? "󰕾" : (root.volume > 0 ? "󰖀" : "󰕿"))
          textFormat: Text.PlainText
          color: volumeIconMouse.containsMouse ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          anchors.verticalCenter: parent.verticalCenter

          Behavior on color { ColorAnimation { duration: 140 } }

          MouseArea {
            id: volumeIconMouse
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleMute()
          }
        }

        PanelSlider {
          id: volumeSlider
          bar: root.bar
          width: parent.width - volumeIcon.width - Style.space(8)
          minimum: 0
          maximum: 1
          step: 0.05
          value: root.muted ? 0 : root.volume
          anchors.verticalCenter: parent.verticalCenter
          onMoved: function(v) { root.setVolume(v) }
          onReleased: function(v) { root.setVolume(v) }
          onRightClicked: root.toggleMute()
        }
      }

      Column {
        visible: root.settingsOpen
        width: parent.width
        spacing: Style.space(10)

        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        Text {
          text: localStrings.t("settings.animation")
          textFormat: Text.PlainText
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        GridLayout {
          width: parent.width
          columns: 2
          columnSpacing: Style.space(6)
          rowSpacing: Style.space(6)
          Repeater {
            model: [
              { id: "wave", key: "wave" },
              { id: "bars", key: "bars" },
              { id: "dots", key: "dots" },
              { id: "particles", key: "sparks" },
              { id: "equalizer", key: "equalizer" },
              { id: "ribbon", key: "ribbon" }
            ]
            Button {
              required property var modelData
              required property int index
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              Layout.columnSpan: 1
              Layout.preferredHeight: Style.space(36)
              text: localStrings.t("animation." + modelData.key)
              fontSize: Style.font.bodySmall
              foreground: root.bar ? root.bar.foreground : Color.foreground
              selected: root.visualizerMode === modelData.id
              bordered: true
              focusable: true

              onClicked: {
                root.selectAnimation(modelData.id)
              }
            }
          }
        }

        Text {
          text: localStrings.t("settings.display")
          textFormat: Text.PlainText
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Button {
          width: parent.width
          height: Style.space(38)
          leftAlign: true
          text: localStrings.t("settings.thumbnail")
          iconText: root.showBarThumbnail ? "󰄬" : "󰄱"
          fontSize: Style.font.bodySmall
          selected: root.showBarThumbnail
          bordered: true
          foreground: root.bar ? root.bar.foreground : Color.foreground
          focusable: true
          enabled: !thumbnailPreference.running
          onClicked: {
            root.showBarThumbnail = !root.showBarThumbnail
            thumbnailPreference.command = ["omarchy", "bar", "set", "custom.media", "showBarThumbnail", root.showBarThumbnail ? "true" : "false", "--json"]
            thumbnailPreference.running = true
          }
        }

        Button {
          width: parent.width
          height: Style.space(38)
          leftAlign: true
          text: localStrings.t("settings.appLogo")
          iconText: root.showAppLogo ? "󰄬" : "󰄱"
          fontSize: Style.font.bodySmall
          selected: root.showAppLogo
          bordered: true
          foreground: root.bar ? root.bar.foreground : Color.foreground
          focusable: true
          enabled: !appLogoPreference.running
          onClicked: {
            root.showAppLogo = !root.showAppLogo
            appLogoPreference.command = ["omarchy", "bar", "set", "custom.media", "showAppLogo", root.showAppLogo ? "true" : "false", "--json"]
            appLogoPreference.running = true
          }
        }

        Button {
          width: parent.width
          height: Style.space(38)
          leftAlign: true
          text: localStrings.t("settings.words")
          iconText: root.showText ? "󰄬" : "󰄱"
          fontSize: Style.font.bodySmall
          selected: root.showText
          bordered: true
          foreground: root.bar ? root.bar.foreground : Color.foreground
          focusable: true
          enabled: !textPreference.running
          onClicked: root.toggleTrackText()
        }
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      // Source / Player Switcher Section
      Column {
        width: parent.width
        spacing: Style.space(6)

        Row {
          spacing: Style.space(6)
          Text {
            text: "󱘖"
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: localStrings.t("players.title")
            textFormat: Text.PlainText
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          visible: root.sourcePlayers.length > 1
          text: localStrings.t("players.hint")
          textFormat: Text.PlainText
          color: Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.6)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        // Empty state when no players are active
        Text {
          visible: root.sourcePlayers.length === 0
          text: localStrings.t("players.empty")
          textFormat: Text.PlainText
          color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.6)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          anchors.horizontalCenter: parent.horizontalCenter
          topPadding: Style.space(6)
          bottomPadding: Style.space(6)
        }

        // Player Source Cards
        Repeater {
          model: root.sourcePlayers

          BorderSurface {
            id: sourceRow
            required property var modelData

            readonly property var player: modelData
            readonly property bool selected: root.activePlayer && player
              && root.playerCanonicalKey(root.activePlayer) === root.playerCanonicalKey(player)
            readonly property string name: root.sourceName(player)
            readonly property string icon: root.sourceIcon(player)
            readonly property string track: {
              if (!player) return "Active Player"
              var t = player.trackTitle || (player.metadata && player.metadata["xesam:title"]) || ""
              var a = player.trackArtist || (player.metadata && player.metadata["xesam:artist"]) || ""
              if (t) return MediaModel.cleanTitle(t, a)
              return MediaModel.sanitizeText(player.identity || "Active Player")
            }
            readonly property string artistName: {
              if (!player) return ""
              var t = player.trackTitle || (player.metadata && player.metadata["xesam:title"]) || ""
              var a = player.trackArtist || (player.metadata && player.metadata["xesam:artist"]) || ""
              return MediaModel.cleanArtist(a, t, player)
            }
            // Same Repeater-delegate stale-hover issue as the flow-mode buttons above.
            property bool hovered: false

            width: parent.width
            height: Style.space(54)
            radius: Style.cornerRadius
            color: selected
              ? Style.selectedFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
              : (sourceRow.hovered ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.04))
            borderSpec: selected
              ? Border.controlSpec("selected", root.bar ? root.bar.foreground : Color.foreground, Color.accent)
              : Border.controlSpec(sourceRow.hovered ? "hover-cursor" : "normal", root.bar ? root.bar.foreground : Color.foreground, Color.accent)

            Row {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              z: 1
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              Text {
                id: sourceGlyph
                text: sourceRow.icon
                textFormat: Text.PlainText
                color: sourceRow.selected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.subtitle
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - sourceStatus.width - parent.spacing - (sourceGlyph.visible ? sourceGlyph.width + parent.spacing : 0)
                spacing: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  text: sourceRow.name
                  textFormat: Text.PlainText
                  color: sourceRow.selected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Item {
                  id: sourceTrackClip
                  width: parent.width
                  height: sourceTrack.implicitHeight
                  clip: true
                  readonly property real overflow: Math.max(0, sourceTrack.implicitWidth - width)

                  Text {
                    id: sourceTrack
                    text: sourceRow.track + (sourceRow.artistName && sourceRow.artistName !== sourceRow.name ? " — " + sourceRow.artistName : "")
                    textFormat: Text.PlainText
                    color: Util.alpha(root.bar ? root.bar.foreground : Color.foreground, 0.65)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    onTextChanged: {
                      x = 0
                      if (sourceTrackScroll.running) sourceTrackScroll.restart()
                    }
                  }

                  SequentialAnimation {
                    id: sourceTrackScroll
                    running: root.popupOpen && (sourceRow.hovered || sourceStatus.hot) && sourceTrackClip.overflow > 0 && !Style.reduceMotion
                    loops: Animation.Infinite
                    onStopped: sourceTrack.x = 0
                    PauseAnimation { duration: 1800 }
                    NumberAnimation {
                      target: sourceTrack
                      property: "x"
                      from: 0
                      to: -sourceTrackClip.overflow
                      duration: Math.max(1800, sourceTrackClip.overflow * 35)
                      easing.type: Easing.Linear
                    }
                    PauseAnimation { duration: 1800 }
                    NumberAnimation {
                      target: sourceTrack
                      property: "x"
                      from: -sourceTrackClip.overflow
                      to: 0
                      duration: Math.max(1800, sourceTrackClip.overflow * 35)
                      easing.type: Easing.Linear
                    }
                  }
                }
              }

              Button {
                id: sourceStatus
                readonly property bool playing: Boolean(sourceRow.player && sourceRow.player.isPlaying)
                iconText: playing ? "󰏤" : "󰐊"
                tooltipText: localStrings.t(playing ? "players.pause" : "players.play")
                foreground: sourceRow.selected ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
                enabled: MediaModel.canHandleAction(sourceRow.player, playing ? "pause" : "play")
                opacity: enabled ? 1.0 : 0.4
                focusable: true
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.runAction(playing ? "pause" : "play", sourceRow.player)
              }
            }

            MouseArea {
              id: sourceCardMouse
              anchors.fill: parent
              anchors.rightMargin: sourceStatus.width + Style.space(10)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: sourceRow.hovered = true
              onExited: sourceRow.hovered = false
              onClicked: root.selectPlayer(sourceRow.player)
            }
          }
        }
      }
    }
  }
}
