# Music Flow — customized fork

A media widget for the Omarchy top bar, with a floating player and a live CAVA audio visualizer.

Maintained fork: [AlwaysRead/Omarchy-music-flow](https://github.com/AlwaysRead/Omarchy-music-flow).

Forked from [Clifford Baidoo’s Omarchy Music Flow](https://github.com/Clifford-Baidoo/Omarchy-music-flow). Credit for the original plugin belongs to Clifford Baidoo and the upstream contributors. See [CREDITS.md](CREDITS.md) for provenance and [LICENSE](LICENSE) for the preserved upstream MIT license.

## Features in this fork

- Six audio-reactive styles: **Wave, Mirror bars, Dots, Sparks, Equalizer, Filled wave**.
- Real 16-band CAVA spectrum at 30 frames per second, with quick attack and gentler release.
- Theme accent colors and consistent corners; stronger animation contrast when all bar display options are off.
- Independent bar controls for artwork, app logo, and track text. Animation and display choices survive shell restarts.
- Artwork at the left of the bar, separate from the animation, with a player-icon fallback when artwork is loading or unavailable.
- Floating player with artwork, metadata, previous/next controls, play/pause, and per-app volume when a matching PipeWire stream is available.
- Long title, artist, and album text scrolls automatically in the floating player. Player cards retain hover-only scrolling, with a pause at each end.
- Detected live streams show a LIVE indicator. Seeking and timestamps are intentionally omitted.
- Widget visible while playing or paused; hidden when playback stops or the player closes.

Playback controls depend on the capabilities exposed by each app through MPRIS. Website names are detected from available media metadata; a browser wrapper may therefore appear as Chrome or Firefox.

## Requirements

- Omarchy with its Quickshell shell and Hyprland session.
- PipeWire/WirePlumber and a PulseAudio-compatible server such as `pipewire-pulse`.
- `cava`, `curl`, and Python 3.
- An MPRIS-compatible media player or browser session.
- Optional: `mpv-mpris` for MPV playback integration.

CAVA analyzes the **default playback output**, so other applications playing through that output also affect the visualization. It does not record audio to disk or read the microphone. Artwork is fetched from the player-provided URL and cached locally. Firefox’s dedicated MPRIS artwork cache is supported. For Twitch live channels, the plugin tries the public Twitch CDN preview for the stream, then browser artwork if the preview is unavailable; the player icon remains the final fallback. This does not require Twitch credentials or API tokens. Live detection depends on the URL and duration exposed by the browser; missing metadata can limit detection.

## Install

Use Omarchy’s plugin manager:

```bash
omarchy plugin add https://github.com/AlwaysRead/Omarchy-music-flow.git --enable
```

The plugin ID is `io.github.alwaysread.music-flow`. It replaces the stock `omarchy.media` widget. The fork has its own marketplace ID; upstream retains `custom.media`. MPV requires an existing MPRIS integration such as `mpv-mpris`.

## Work directly from a checkout

The local development setup uses a symlink:

```text
~/.config/omarchy/plugins/io.github.alwaysread.music-flow -> ~/Projects/Omarchy-music-flow
```

Edit the checkout and run `omarchy restart shell` if the running widget retains cached code. Keep an existing plugin directory backed up before replacing it with a symlink.

## Controls

| Location | Action | Result |
| --- | --- | --- |
| Bar | Left-click | Open or close the player |
| Bar | Middle-click | Play or pause |
| Bar | Right-click | Toggle track text and save the choice |
| Bar | Scroll up / down | Previous / next track |
| Floating player | Settings gear | Animation and bar display options |
| Player card | Click card | Select that player |
| Player card | Play/pause icon | Control that specific player |
| Player card | Hover | Scroll overflowing track text |

The app-logo setting affects only the bar. Logos remain visible in the floating player. The thumbnail setting controls the bar thumbnail slot, including its fallback icon.

## Preferences

Preferences live in the widget’s entry under `bar.layout` in `~/.config/omarchy/shell.json`:

```json
{
  "id": "io.github.alwaysread.music-flow",
  "showBarThumbnail": true,
  "showAppLogo": false,
  "showText": true,
  "visualizerMode": "wave"
}
```

Valid animation values are `wave`, `bars`, `dots`, `particles`, `equalizer`, and `ribbon`. Settings can be changed in the popup or with `omarchy bar set io.github.alwaysread.music-flow <setting> <value> --json`.

## Update or remove

For a plugin installed through Omarchy:

```bash
omarchy plugin update io.github.alwaysread.music-flow
omarchy plugin remove io.github.alwaysread.music-flow
```

For a development checkout linked into the plugin directory, pull changes in that checkout and restart the shell. Keep local edits committed before pulling. This repository uses Omarchy’s plugin manager rather than custom installation scripts.

## Repository layout

```text
BarWidget.qml                  Bar widget and floating player
MarqueeText.qml                Scrolling metadata component
Artwork.qml                    Shared, cancellable artwork requests
artwork.py                     Bounded artwork fetcher and private cache
Service.qml                    MPRIS, PipeWire, artwork, and CAVA service
MediaModel.js                  Player matching and metadata helpers
AudioSpectrum.js               Audio attack/release envelope
manifest.json                  Omarchy plugin metadata
config/visualizer.conf         CAVA configuration
local-i18n/en.json              Interface strings
README.md / CREDITS.md / LICENSE
```

QML entry points stay at the repository root because the shell loads them from the plugin manifest. Only runtime code, configuration, translations, documentation, and attribution are included. Screenshots, preview assets, tests, CI workflows, and custom maintenance scripts are omitted.

## Validation

This checkout is maintained for local use; no marketplace submission is required. Validation uses Omarchy’s manifest checker, syntax checks, malformed-input checks, and isolated playback fixtures. Temporary audit tests are kept outside the plugin repository.

```bash
omarchy plugin validate .
qmllint BarWidget.qml Service.qml Artwork.qml MarqueeText.qml
node --check MediaModel.js
node --check AudioSpectrum.js
python3 -c 'import ast; ast.parse(open("artwork.py").read())'
omarchy-shell io.github.alwaysread.music-flow status
```

## Artwork boundaries

Artwork accepts supported raster formats only, with a 2 MiB download limit, dimensions up to 4096 per side and 4 megapixels total. HTTPS requests use an exact CDN allowlist, public DNS addresses pinned for each request, timeouts, and no redirects or proxy settings. Local files are restricted to artwork/cache locations, checked for ownership, and opened without following symlinks. Unsupported or unavailable artwork falls back to the player icon.

The private cache stores up to 32 completed, content-addressed images. Requests are serialized and cancelled when the track changes, so an old request cannot replace the current thumbnail. Image headers are checked before Qt decodes them; this does not replace keeping Qt and system image libraries updated. Playback commands retain the selected MPRIS session, and an expired explicit target cannot control a different player. Display preference writes are serialized and restored from saved configuration after completion or failure.

## License

MIT, with the original copyright notice retained. See [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md).
