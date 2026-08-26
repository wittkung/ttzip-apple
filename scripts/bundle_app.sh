#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: High-performance native archiving and compression engine.

# Builds and bundles TTZip.app for macOS with Multi-Channel support (Direct, MAS, Steam, Community).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SIGN_IDENTITY="-"
CHANNEL="direct"
ENTITLEMENTS=""
OPEN_APP=false
BUILD_CONFIG="release"
FAST_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel|-c) CHANNEL="$2"; shift 2 ;;
        --identity|-i) SIGN_IDENTITY="$2"; shift 2 ;;
        --entitlements|-e) ENTITLEMENTS="$2"; shift 2 ;;
        --release|-r) BUILD_CONFIG="release"; shift ;;
        --debug|-d) BUILD_CONFIG="debug"; shift ;;
        --fast|-f) FAST_MODE=true; BUILD_CONFIG="debug"; shift ;;
        --open|-o) OPEN_APP=true; shift ;;
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
echo "🍎 Building and Bundling TTZip.app [${BUILD_CONFIG} mode]"
echo "   Target Channel  : ${CHANNEL}"
echo "   Signing Identity: ${SIGN_IDENTITY}"
echo "   Entitlements    : ${ENTITLEMENTS}"
echo "======================================================================"

cd "${REPO_ROOT}"

echo "--> [1/4] Compiling TTZipApp via Swift Package Manager in ${BUILD_CONFIG} mode..."
swift build -c "${BUILD_CONFIG}" --product TTZipApp -Xlinker -rpath -Xlinker @executable_path/../Frameworks -Xswiftc -warnings-as-errors "${SWIFT_FLAGS[@]}"

DIST_DIR="${REPO_ROOT}/dist"
APP_DIR="${DIST_DIR}/TTZip.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# Find compiled binary dynamically
BIN_PATH="$(swift build -c "${BUILD_CONFIG}" --show-bin-path)/TTZipApp"

if [ "${FAST_MODE}" = true ] && [ -d "${APP_DIR}" ]; then
    echo "--> [Fast Mode] In-place updating TTZip binary..."
    cp -f "${BIN_PATH}" "${MACOS_DIR}/TTZip"
    if [ "${BUILD_CONFIG}" = "release" ]; then
        strip -x "${MACOS_DIR}/TTZip" 2>/dev/null || true
    fi
    install_name_tool -add_rpath @executable_path/../Frameworks "${MACOS_DIR}/TTZip" 2>/dev/null || true
    chmod +x "${MACOS_DIR}/TTZip"
    codesign --force --sign "${SIGN_IDENTITY}" "${MACOS_DIR}/TTZip" 2>/dev/null || true
    codesign --force --sign "${SIGN_IDENTITY}" "${APP_DIR}" 2>/dev/null || true
else
    echo "--> [2/4] Assembling .app bundle directory structure..."
    rm -rf "${APP_DIR}"
    mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}"

    # Copy Binary and ensure Frameworks rpath
    cp "${BIN_PATH}" "${MACOS_DIR}/TTZip"
    if [ "${BUILD_CONFIG}" = "release" ]; then
        strip -x "${MACOS_DIR}/TTZip" 2>/dev/null || true
    fi
    install_name_tool -add_rpath @executable_path/../Frameworks "${MACOS_DIR}/TTZip" 2>/dev/null || true
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

    # Copy all .lproj localization directories
    find "${REPO_ROOT}/Sources/TTZipApp/Resources" -name "*.lproj" -type d 2>/dev/null | while read -r lproj_dir; do
        lproj_name="$(basename "${lproj_dir}")"
        mkdir -p "${RESOURCES_DIR}/${lproj_name}"
        cp -R "${lproj_dir}/"* "${RESOURCES_DIR}/${lproj_name}/"
    done

    # Copy PkgInfo
    echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

    # Copy Sparkle Framework only for Direct channel
    if [ "${CHANNEL}" = "direct" ]; then
        SPARKLE_SRC="$(find "${REPO_ROOT}/.build" -name "Sparkle.framework" -type d 2>/dev/null | grep -E "xcframework.*macos|release/Sparkle.framework|debug/Sparkle.framework" | head -n 1 || true)"
        if [ -n "${SPARKLE_SRC}" ] && [ -d "${SPARKLE_SRC}" ]; then
            cp -R "${SPARKLE_SRC}" "${FRAMEWORKS_DIR}/"
            if [ "${SIGN_IDENTITY}" != "-" ]; then
                codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${FRAMEWORKS_DIR}/Sparkle.framework" 2>/dev/null || true
            else
                codesign --force --sign "-" "${FRAMEWORKS_DIR}/Sparkle.framework" 2>/dev/null || true
            fi
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

    if [ "${BUILD_CONFIG}" = "release" ]; then
        echo "--> [4/4] Verifying .app bundle integrity..."
        codesign --verify --deep --strict "${APP_DIR}"
    fi
fi

echo "======================================================================"
echo "✅ Successfully bundled [${CHANNEL} - ${BUILD_CONFIG}]: ${APP_DIR}"
echo "======================================================================"

if [ "${OPEN_APP}" = true ]; then
    echo "--> Launching freshly built TTZip.app..."
    killall TTZip 2>/dev/null || true
    pkill -9 -x TTZip 2>/dev/null || true
    pkill -9 -f "TTZip.app" 2>/dev/null || true
    sleep 0.2
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "${APP_DIR}" 2>/dev/null || true
    open "${APP_DIR}"
    echo "🎉 TTZip.app 已成功在桌面启动！"
    echo "   产物路径: ${APP_DIR}"
    echo "======================================================================"
fi

