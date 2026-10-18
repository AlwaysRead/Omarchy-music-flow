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
- Player cards with individual play/pause controls and hover scrolling for long track names.
- Elapsed/total track time and seeking for players that support position and duration. Non-seekable tracks show read-only progress; unknown-duration streams omit it.
- Widget visible while playing or paused; hidden when playback stops or the player closes.

Playback controls depend on the capabilities exposed by each app through MPRIS. Website names are detected from available media metadata; a browser wrapper may therefore appear as Chrome or Firefox.

## Requirements

- Omarchy with its Quickshell shell and Hyprland session.
- PipeWire/WirePlumber and a PulseAudio-compatible server such as `pipewire-pulse`.
- `cava`, `curl`, Python 3, and Bash.
- An MPRIS-compatible media player or browser session.
- Optional: `mpv-mpris` for MPV playback integration.
- Development checks: Node.js and `qmllint`.

CAVA analyzes the **default playback output**, so other applications playing through that output also affect the visualization. It does not record audio to disk or read the microphone. Artwork is fetched from the player-provided URL and cached locally.

## Install from this checkout

```bash
git clone https://github.com/AlwaysRead/Omarchy-music-flow.git
cd Omarchy-music-flow
./install.sh
```

The installer copies the runtime files into `~/.config/omarchy/plugins/custom.media/`, adds the widget to the bar, disables the stock `omarchy.media` widget, validates the plugin, and restarts the shell. If MPV and a supported MPRIS module are installed, it also links that module into the user’s MPV scripts directory.

The plugin ID remains `custom.media` for compatibility. Do not install upstream and this fork under that same ID at the same time.

## Work directly from a checkout

The local development setup uses a symlink:

```text
~/.config/omarchy/plugins/custom.media -> ~/Projects/Omarchy-music-flow
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
  "id": "custom.media",
  "showBarThumbnail": true,
  "showAppLogo": false,
  "showText": true,
  "visualizerMode": "wave"
}
```

Valid animation values are `wave`, `bars`, `dots`, `particles`, `equalizer`, and `ribbon`. Settings can be changed in the popup or with `omarchy bar set custom.media <setting> <value> --json`.

## Update or remove

After pulling changes from this fork into your checkout, synchronize it with:

```bash
./update.sh
```

To remove the installed widget and restore the stock media widget:

```bash
./uninstall.sh
```

Uninstall backs up the plugin directory or symlink instead of deleting it. These scripts change bar configuration and restart the shell. Automatic upstream updates can replace fork changes; use your own fork as the update source.

## Repository layout

```text
BarWidget.qml                  Bar widget and floating player
Service.qml                    MPRIS, PipeWire, artwork, and CAVA service
MediaModel.js                  Player matching and metadata helpers
AudioSpectrum.js               Audio attack/release envelope
manifest.json                  Omarchy plugin metadata
config/visualizer.conf         CAVA configuration
local-i18n/en.json              Interface strings
scripts/configure_bar.py       Shared bar configuration editor
scripts/install_files.sh       Shared runtime file deployment
install.sh / update.sh          Installation and synchronization
uninstall.sh                   Backup and restore stock media widget
tests/customizations.test.cjs   Preference and audio-envelope tests
tests/deployment.test.py        Clean runtime-deployment test
tests/playback-integration.py   Isolated MPRIS transition/seek test
.github/workflows/checks.yml    Automated tests and syntax checks
README.md / CREDITS.md / LICENSE
```

QML entry points stay at the repository root because the shell loads them from the plugin manifest. Configuration, translations, maintenance helpers, and tests have their own directories. Screenshots and preview assets are intentionally omitted.

## Check changes

```bash
node --test tests/*.test.cjs
python3 tests/deployment.test.py
qmllint BarWidget.qml Service.qml
bash -n install.sh update.sh uninstall.sh scripts/install_files.sh
omarchy plugin validate .
```

The GitHub workflow runs unit/deployment tests and syntax checks on pushes and pull requests. On an Omarchy development machine with PyGObject installed, run the isolated playback integration test:

```bash
dbus-run-session -- /usr/bin/python tests/playback-integration.py
```

This starts fake MPRIS players on a private session bus and checks playing, paused, stopped, player switching, closing, visibility, play/pause delivery, and seeking without controlling your desktop’s players. The UI updates position only while its popup is open, following [Quickshell’s position API](https://quickshell.org/docs/v0.2.1/types/Quickshell.Services.Mpris/MprisPlayer/#position).

## License

MIT, with the original copyright notice retained. See [LICENSE](LICENSE) and [CREDITS.md](CREDITS.md).
