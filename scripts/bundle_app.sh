#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
#
# Builds and bundles TTZip.app for macOS with Multi-Channel support (Direct, MAS, Steam, Community).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SIGN_IDENTITY="-"
CHANNEL="direct"
ENTITLEMENTS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel|-c) CHANNEL="$2"; shift 2 ;;
        --identity|-i) SIGN_IDENTITY="$2"; shift 2 ;;
        --entitlements|-e) ENTITLEMENTS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Resolve default channel-specific entitlements
if [ -z "${ENTITLEMENTS}" ]; then
    if [ "${CHANNEL}" = "mas" ]; then
        ENTITLEMENTS="${REPO_ROOT}/Sources/TTZipApp/TTZip.entitlements"
    else
        ENTITLEMENTS="${REPO_ROOT}/Sources/TTZipApp/TTZip-Direct.entitlements"
    fi
fi

SWIFT_FLAGS=()
case "${CHANNEL}" in
    mas)
        SWIFT_FLAGS+=("-Xswiftc" "-DMAS_BUILD")
        ;;
    steam)
        SWIFT_FLAGS+=("-Xswiftc" "-DSTEAM_BUILD")
        ;;
    community)
        SWIFT_FLAGS+=("-Xswiftc" "-DCOMMUNITY_BUILD")
        ;;
    direct|*)
        SWIFT_FLAGS+=("-Xswiftc" "-DDIRECT_BUILD")
        ;;
esac

echo "======================================================================"
echo "🍎 Building and Bundling TTZip.app Native Desktop Application"
echo "   Target Channel  : ${CHANNEL}"
echo "   Signing Identity: ${SIGN_IDENTITY}"
echo "   Entitlements    : ${ENTITLEMENTS}"
echo "======================================================================"

cd "${REPO_ROOT}"

echo "--> [1/4] Compiling TTZipApp via Swift Package Manager in release mode..."
swift build -c release --product TTZipApp "${SWIFT_FLAGS[@]}"

BIN_PATH="$(swift build -c release --show-bin-path)/TTZipApp"
DIST_DIR="${REPO_ROOT}/dist"
APP_DIR="${DIST_DIR}/TTZip.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "--> [2/4] Assembling .app bundle directory structure..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}"

# Copy Binary
cp "${BIN_PATH}" "${MACOS_DIR}/TTZip"
chmod +x "${MACOS_DIR}/TTZip"

# Copy Info.plist
cp "${REPO_ROOT}/Sources/TTZipApp/Info.plist" "${CONTENTS_DIR}/Info.plist"

# Copy AppIcon.icns
if [ -f "${REPO_ROOT}/Resources/AppIcon.icns" ]; then
    cp "${REPO_ROOT}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Copy PrivacyInfo.xcprivacy
if [ -f "${REPO_ROOT}/Sources/TTZipApp/PrivacyInfo.xcprivacy" ]; then
    cp "${REPO_ROOT}/Sources/TTZipApp/PrivacyInfo.xcprivacy" "${RESOURCES_DIR}/PrivacyInfo.xcprivacy"
fi

# Copy PkgInfo
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# Copy Sparkle Framework only for Direct channel
if [ "${CHANNEL}" = "direct" ]; then
    SPARKLE_SRC="$(find "${REPO_ROOT}/.build" -name "Sparkle.framework" -type d 2>/dev/null | grep -E "xcframework.*macos|release/Sparkle.framework" | head -n 1 || true)"
    if [ -n "${SPARKLE_SRC}" ] && [ -d "${SPARKLE_SRC}" ]; then
        cp -R "${SPARKLE_SRC}" "${FRAMEWORKS_DIR}/"
        codesign --force --deep --sign "${SIGN_IDENTITY}" "${FRAMEWORKS_DIR}/Sparkle.framework" 2>/dev/null || true
    fi
fi

# If Frameworks is empty, remove it
rmdir "${FRAMEWORKS_DIR}" 2>/dev/null || true

echo "--> [3/4] Performing code signing with Hardened Runtime..."
SIGN_ARGS=(--force --deep --sign "${SIGN_IDENTITY}")
if [ "${SIGN_IDENTITY}" != "-" ]; then
    SIGN_ARGS+=(--options runtime --timestamp)
    if [ -f "${ENTITLEMENTS}" ]; then
        SIGN_ARGS+=(--entitlements "${ENTITLEMENTS}")
    fi
fi

codesign "${SIGN_ARGS[@]}" "${APP_DIR}"

echo "--> [4/4] Verifying .app bundle integrity..."
codesign --verify --deep --strict "${APP_DIR}"

echo "======================================================================"
echo "✅ Successfully bundled and signed [${CHANNEL}]: ${APP_DIR}"
echo "======================================================================"
