#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Omarchy Music Flow Plugin Installer
# ==============================================================================

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Single source of truth for every id this script and the config-writer below
# touch, so the plugin id never has to be duplicated (and drift) across files.
PLUGIN_ID="custom.media"
STOCK_PLUGIN_ID="omarchy.media"
BAR_SECTION="left"
BAR_ANCHOR_ID="omarchy.workspaces"
TARGET_DIR="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"

MPV_MPRIS_CANDIDATES=(
    "/usr/lib/mpv-mpris/mpris.so"
    "/etc/mpv/scripts/mpris.so"
)

echo -e "${BLUE}==>${NC} Installing ${GREEN}Omarchy Music Flow${NC} [${PLUGIN_ID}]..."

# 1. Ensure target plugin directory exists
mkdir -p "${TARGET_DIR}"

# 2. Copy all required plugin files
#
# Shared deployment includes every runtime dependency and preserves attribution.
source "${SCRIPT_DIR}/scripts/install_files.sh"

echo -e "${BLUE}==>${NC} Plugin files installed to: ${TARGET_DIR}"

# 3. Catch manifest/schema problems before they get wired into the bar
if command -v omarchy >/dev/null 2>&1; then
    if ! omarchy plugin validate "${TARGET_DIR}"; then
        echo -e "${RED}==> Error:${NC} plugin failed validation, aborting before touching your bar config." >&2
        exit 1
    fi
fi

# 4. Enable MPV MPRIS script if mpv is installed (enables Seanime, MPV, and anime video player support)
if command -v mpv >/dev/null 2>&1; then
    mkdir -p "${HOME}/.config/mpv/scripts"
    for candidate in "${MPV_MPRIS_CANDIDATES[@]}"; do
        if [ -f "${candidate}" ]; then
            ln -sf "${candidate}" "${HOME}/.config/mpv/scripts/mpris.so"
            echo -e "${BLUE}==>${NC} Enabled MPV MPRIS integration for video & Seanime playback."
            break
        fi
    done
fi

# 5. Safely configure Omarchy shell.json layout
echo -e "${BLUE}==>${NC} Configuring status bar layout in ~/.config/omarchy/shell.json..."
PLUGIN_ID="${PLUGIN_ID}" STOCK_PLUGIN_ID="${STOCK_PLUGIN_ID}" \
BAR_SECTION="${BAR_SECTION}" BAR_ANCHOR_ID="${BAR_ANCHOR_ID}" \
python3 "${SCRIPT_DIR}/scripts/configure_bar.py" --action enable --bootstrap

# 6. Restart Omarchy Shell
if command -v omarchy >/dev/null 2>&1; then
    echo -e "${BLUE}==>${NC} Reloading Omarchy shell..."
    omarchy restart shell
    echo -e "${GREEN}✔ Installation successful! Music Flow is now active on your bar.${NC}"
else
    echo -e "${YELLOW}==> Note: Please restart omarchy-shell manually to apply changes.${NC}"
fi
