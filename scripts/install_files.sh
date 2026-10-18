#!/usr/bin/env bash
# Shared by install.sh and update.sh. SCRIPT_DIR and TARGET_DIR are set by caller.
# Copy all runtime dependencies, along with upstream license and attribution.
PLUGIN_FILES=(
    BarWidget.qml Service.qml MediaModel.js AudioSpectrum.js manifest.json
    config/visualizer.conf local-i18n/en.json LICENSE CREDITS.md
)

for plugin_file in "${PLUGIN_FILES[@]}"; do
    if [[ ! -f "${SCRIPT_DIR}/${plugin_file}" ]]; then
        echo "Missing required plugin file: ${plugin_file}" >&2
        exit 1
    fi
done

PLUGIN_TMP_FILES=()
cleanup_plugin_tmp_files() {
    local tmp
    for tmp in "${PLUGIN_TMP_FILES[@]}"; do
        rm -f -- "${tmp}"
    done
}
trap cleanup_plugin_tmp_files EXIT

install_plugin_file() {
    local name="$1" destination tmp
    destination="${TARGET_DIR}/$(dirname "${name}")"
    mkdir -p "${destination}"
    # Rename into place rather than following a destination file symlink.
    tmp=$(mktemp -p "${destination}" ".$(basename "${name}").XXXXXX")
    PLUGIN_TMP_FILES+=("${tmp}")
    cp -f -- "${SCRIPT_DIR}/${name}" "${tmp}"
    chmod --reference="${SCRIPT_DIR}/${name}" "${tmp}"
    mv -f -- "${tmp}" "${TARGET_DIR}/${name}"
}

for plugin_file in "${PLUGIN_FILES[@]}"; do
    install_plugin_file "${plugin_file}"
done
