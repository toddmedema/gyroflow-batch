#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="GyroflowBatch"
BUNDLE="${SCRIPT_DIR}/${APP_NAME}.app"
CONTENTS="${BUNDLE}/Contents"

echo "==> Cleaning previous build…"
rm -rf "$BUNDLE"

if [[ -f "${REPO_ROOT}/icon.png" ]]; then
    echo "==> Normalizing icon.png → 1024×1024 + AppIcon.icns…"
    NORM="${SCRIPT_DIR}/.icon-1024.png"
    /usr/bin/python3 "${SCRIPT_DIR}/normalize_icon.py" "${REPO_ROOT}/icon.png" "${NORM}"
    ICONSET="${SCRIPT_DIR}/AppIcon.iconset"
    rm -rf "${ICONSET}"
    mkdir -p "${ICONSET}"
    sips -z 16 16 "${NORM}" --out "${ICONSET}/icon_16x16.png" >/dev/null
    sips -z 32 32 "${NORM}" --out "${ICONSET}/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "${NORM}" --out "${ICONSET}/icon_32x32.png" >/dev/null
    sips -z 64 64 "${NORM}" --out "${ICONSET}/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "${NORM}" --out "${ICONSET}/icon_128x128.png" >/dev/null
    sips -z 256 256 "${NORM}" --out "${ICONSET}/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "${NORM}" --out "${ICONSET}/icon_256x256.png" >/dev/null
    sips -z 512 512 "${NORM}" --out "${ICONSET}/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "${NORM}" --out "${ICONSET}/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "${NORM}" --out "${ICONSET}/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "${ICONSET}" -o "${SCRIPT_DIR}/AppIcon.icns"
    rm -rf "${ICONSET}"
else
    echo "==> Warning: ${REPO_ROOT}/icon.png not found; using existing AppIcon.icns"
fi

echo "==> Compiling main.swift…"
swiftc \
    -O \
    -whole-module-optimization \
    -framework SwiftUI \
    -framework AppKit \
    -o "${SCRIPT_DIR}/${APP_NAME}" \
    "${SCRIPT_DIR}/main.swift"

echo "==> Assembling ${APP_NAME}.app bundle…"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Resources"

mv "${SCRIPT_DIR}/${APP_NAME}" "${CONTENTS}/MacOS/${APP_NAME}"
cp "${SCRIPT_DIR}/Info.plist" "${CONTENTS}/Info.plist"
cp "${SCRIPT_DIR}/AppIcon.icns" "${CONTENTS}/Resources/AppIcon.icns"
cp "${REPO_ROOT}/gyroflow_export_projects.sh" "${CONTENTS}/Resources/gyroflow_export_projects.sh"
chmod +x "${CONTENTS}/Resources/gyroflow_export_projects.sh"

echo "==> Code signing (ad-hoc)…"
codesign -s - --force --deep "$BUNDLE"

echo ""
echo "Build complete: ${BUNDLE}"
echo ""
echo "Next steps:"
echo "  1. Move ${APP_NAME}.app to /Applications (optional)"
echo "  2. System Settings → Privacy & Security → Full Disk Access → add ${APP_NAME}"
echo "  3. Launch the app and select your folders"
