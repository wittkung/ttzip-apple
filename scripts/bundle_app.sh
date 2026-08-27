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
DIST_DIR="${REPO_ROOT}/dist"
CUSTOM_BUILD_DIR=""
FORCE_CLEAN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel|-c) CHANNEL="$2"; shift 2 ;;
        --identity|-i) SIGN_IDENTITY="$2"; shift 2 ;;
        --entitlements|-e) ENTITLEMENTS="$2"; shift 2 ;;
        --out-dir) DIST_DIR="$2"; shift 2 ;;
        --build-path) CUSTOM_BUILD_DIR="$2"; shift 2 ;;
        --release|-r) BUILD_CONFIG="release"; shift ;;
        --debug|-d) BUILD_CONFIG="debug"; shift ;;
        --fast|-f) FAST_MODE=true; BUILD_CONFIG="debug"; shift ;;
        --clean) FORCE_CLEAN=true; shift ;;
        --open|-o) OPEN_APP=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

BUILD_DIR="${CUSTOM_BUILD_DIR:-${REPO_ROOT}/.build_${CHANNEL}}"
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)"

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

# Append Multi-Core Parallel LLVM CodeGen optimization for WMO
SWIFT_FLAGS+=("-Xswiftc" "-num-threads" "-Xswiftc" "${NCPU}")

echo "======================================================================"
echo "🍎 Building and Bundling TTZip.app [${BUILD_CONFIG} mode, ${NCPU} cores]"
echo "   Target Channel  : ${CHANNEL}"
echo "   Build Directory : ${BUILD_DIR}"
echo "   Output Directory: ${DIST_DIR}"
echo "   Signing Identity: ${SIGN_IDENTITY}"
echo "   Entitlements    : ${ENTITLEMENTS}"
echo "======================================================================"

cd "${REPO_ROOT}"

# Deterministic binary and build path resolution (0 SPM subprocess overhead)
BIN_DIR="${BUILD_DIR}/${BUILD_CONFIG}"
BIN_PATH="${BIN_DIR}/TTZipApp"

NEED_SWIFT_BUILD=true
if [ "${FORCE_CLEAN}" = false ] && [ -f "${BIN_PATH}" ]; then
    # 检查 Sources, Package.swift, Package.resolved, Vendor 是否有比现有可执行文件更新的文件
    NEWER_FILE="$(find "${REPO_ROOT}/Sources" "${REPO_ROOT}/Package.swift" "${REPO_ROOT}/Package.resolved" "${REPO_ROOT}/Vendor" -newer "${BIN_PATH}" 2>/dev/null | head -n 1 || true)"
    if [ -z "${NEWER_FILE}" ]; then
        NEED_SWIFT_BUILD=false
    fi
fi

if [ "${NEED_SWIFT_BUILD}" = true ]; then
    echo "--> [1/4] Compiling TTZipApp via Swift Package Manager in ${BUILD_CONFIG} mode (${NCPU} threads)..."
    swift build \
        --build-path "${BUILD_DIR}" \
        --jobs "${NCPU}" \
        -c "${BUILD_CONFIG}" \
        --product TTZipApp \
        -Xlinker -L"${REPO_ROOT}/Vendor" \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        -Xswiftc -warnings-as-errors \
        "${SWIFT_FLAGS[@]}"
else
    echo "--> [1/4] TTZipApp sources are up-to-date (Skipped SPM compilation in 0.01s)."
fi

APP_DIR="${DIST_DIR}/TTZip.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PLUGINS_DIR="${CONTENTS_DIR}/PlugIns"

if [ ! -f "${BIN_PATH}" ]; then
    BIN_PATH="$(swift build --build-path "${BUILD_DIR}" -c "${BUILD_CONFIG}" --show-bin-path)/TTZipApp"
    BIN_DIR="$(dirname "${BIN_PATH}")"
fi

if [ "${FORCE_CLEAN}" = true ]; then
    echo "--> [Clean Mode] Removing existing bundle: ${APP_DIR}"
    rm -rf "${APP_DIR}"
fi

STATE_DIR="${BUILD_DIR}/.bundle_state"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}" "${STATE_DIR}"

APP_UPDATED=false

get_file_stat() {
    stat -f "%m_%z" "$1" 2>/dev/null || echo "missing"
}

# Helper for atomic copy if modified
sync_file_if_changed() {
    local src="$1"
    local dst="$2"
    local mode="${3:-}"
    if [ ! -f "${dst}" ] || ! cmp -s "${src}" "${dst}"; then
        mkdir -p "$(dirname "${dst}")"
        cp -f "${src}" "${dst}"
        [ -n "${mode}" ] && chmod "${mode}" "${dst}"
        APP_UPDATED=true
        return 0
    fi
    return 1
}

# 1. Update Executable Binary (Stamp-based change detection to avoid strip diff bug)
BIN_STAT="$(get_file_stat "${BIN_PATH}")"
LAST_BIN_STAT="$(cat "${STATE_DIR}/TTZipApp.stamp" 2>/dev/null || true)"

if [ ! -f "${MACOS_DIR}/TTZip" ] || [ "${BIN_STAT}" != "${LAST_BIN_STAT}" ]; then
    echo "--> [2/4] Updating TTZip binary..."
    cp -f "${BIN_PATH}" "${MACOS_DIR}/TTZip"
    if [ "${BUILD_CONFIG}" = "release" ]; then
        strip -x "${MACOS_DIR}/TTZip" 2>/dev/null || true
    fi
    chmod +x "${MACOS_DIR}/TTZip"
    echo -n "${BIN_STAT}" > "${STATE_DIR}/TTZipApp.stamp"
    APP_UPDATED=true
else
    echo "--> [2/4] TTZip binary is up-to-date."
fi

# 2. Sync Info.plist, PrivacyInfo, AppIcon, PkgInfo
sync_file_if_changed "${REPO_ROOT}/Sources/TTZipApp/Info.plist" "${CONTENTS_DIR}/Info.plist" "" || true

if [ -f "${REPO_ROOT}/Resources/AppIcon.icns" ]; then
    sync_file_if_changed "${REPO_ROOT}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns" "" || true
fi

if [ -f "${REPO_ROOT}/Sources/TTZipApp/PrivacyInfo.xcprivacy" ]; then
    sync_file_if_changed "${REPO_ROOT}/Sources/TTZipApp/PrivacyInfo.xcprivacy" "${RESOURCES_DIR}/PrivacyInfo.xcprivacy" "" || true
fi

if [ ! -f "${CONTENTS_DIR}/PkgInfo" ] || [ "$(cat "${CONTENTS_DIR}/PkgInfo" 2>/dev/null)" != "APPL????" ]; then
    echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"
    APP_UPDATED=true
fi

# 3. Sync Localization (.lproj)
for lproj_dir in "${REPO_ROOT}"/Sources/TTZipApp/Resources/*.lproj; do
    if [ -d "${lproj_dir}" ]; then
        lproj_name="$(basename "${lproj_dir}")"
        target_lproj="${RESOURCES_DIR}/${lproj_name}"
        mkdir -p "${target_lproj}"
        for f in "${lproj_dir}"/*; do
            if [ -f "${f}" ]; then
                sync_file_if_changed "${f}" "${target_lproj}/$(basename "${f}")" "" || true
            fi
        done
    fi
done

# 4. Handle Sparkle Framework (Direct Channel only)
if [ "${CHANNEL}" = "direct" ]; then
    # Fast deterministic Sparkle path lookup
    SPARKLE_SRC=""
    for candidate in \
        "${BUILD_DIR}/artifacts/sparkle/Sparkle/Sparkle.framework" \
        "${BUILD_DIR}/artifacts/Sparkle/Sparkle.framework" \
        "${BUILD_DIR}/checkouts/Sparkle/Sparkle.framework" \
        "${REPO_ROOT}/.build/artifacts/sparkle/Sparkle/Sparkle.framework" \
        "${REPO_ROOT}/.build/artifacts/Sparkle/Sparkle.framework"; do
        if [ -d "${candidate}" ]; then
            SPARKLE_SRC="${candidate}"
            break
        fi
    done

    if [ -z "${SPARKLE_SRC}" ]; then
        SPARKLE_SRC="$(find "${BUILD_DIR}" "${REPO_ROOT}/.build" -maxdepth 4 -name "Sparkle.framework" -type d 2>/dev/null | grep -E "xcframework.*macos|release/Sparkle.framework|debug/Sparkle.framework" | head -n 1 || true)"
    fi

    if [ -n "${SPARKLE_SRC}" ] && [ -d "${SPARKLE_SRC}" ]; then
        TARGET_SPARKLE="${FRAMEWORKS_DIR}/Sparkle.framework"
        if [ ! -d "${TARGET_SPARKLE}" ]; then
            echo "--> Embedding Sparkle.framework..."
            cp -R "${SPARKLE_SRC}" "${FRAMEWORKS_DIR}/"
            if [ "${SIGN_IDENTITY}" != "-" ]; then
                codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${TARGET_SPARKLE}" 2>/dev/null || true
            else
                codesign --force --sign "-" "${TARGET_SPARKLE}" 2>/dev/null || true
            fi
            APP_UPDATED=true
        fi
    fi
else
    # MAS / Steam: Strip Sparkle strictly
    if [ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]; then
        rm -rf "${FRAMEWORKS_DIR}/Sparkle.framework"
        APP_UPDATED=true
    fi
fi

# 5. Handle libmpv.dylib (Stamp-based change detection to avoid codesign diff loop)
MPV_SRC="${REPO_ROOT}/Frameworks/libmpv.dylib"

if [ -n "${MPV_SRC}" ] && [ -f "${MPV_SRC}" ]; then
    TARGET_MPV="${FRAMEWORKS_DIR}/libmpv.dylib"
    MPV_SRC_STAT="$(get_file_stat "${MPV_SRC}")"
    LAST_MPV_STAT="$(cat "${STATE_DIR}/libmpv.stamp" 2>/dev/null || true)"

    if [ ! -f "${TARGET_MPV}" ] || [ "${MPV_SRC_STAT}" != "${LAST_MPV_STAT}" ]; then
        echo "--> Bundling and signing libmpv.dylib..."
        mkdir -p "${FRAMEWORKS_DIR}"
        cp -f "${MPV_SRC}" "${TARGET_MPV}"
        chmod 755 "${TARGET_MPV}"
        install_name_tool -id @rpath/libmpv.dylib "${TARGET_MPV}" 2>/dev/null || true
        if [ "${SIGN_IDENTITY}" != "-" ]; then
            codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${TARGET_MPV}" 2>/dev/null || true
        else
            codesign --force --sign "-" "${TARGET_MPV}" 2>/dev/null || true
        fi
        echo -n "${MPV_SRC_STAT}" > "${STATE_DIR}/libmpv.stamp"
        APP_UPDATED=true
    fi
fi

# 6. Copy Auxiliary Dynamic Libraries from BIN_DIR (FinderSync / QuickLook)
if [ -d "${BIN_DIR}" ]; then
    for dylib_file in "${BIN_DIR}"/*.dylib; do
        if [ -f "${dylib_file}" ]; then
            dylib_name="$(basename "${dylib_file}")"
            target_dylib="${FRAMEWORKS_DIR}/${dylib_name}"
            if sync_file_if_changed "${dylib_file}" "${target_dylib}" 755; then
                codesign --force --sign "-" "${target_dylib}" 2>/dev/null || true
            fi
        fi
    done
fi

# 7. Copy Built-in Plugins
if [ -d "${REPO_ROOT}/Resources/Plugins" ]; then
    mkdir -p "${RESOURCES_DIR}/Plugins"
    cp -Rf "${REPO_ROOT}/Resources/Plugins/"* "${RESOURCES_DIR}/Plugins/" 2>/dev/null || true
fi
if [ -d "${REPO_ROOT}/PlugIns" ]; then
    mkdir -p "${PLUGINS_DIR}"
    cp -R "${REPO_ROOT}/PlugIns/"* "${PLUGINS_DIR}/" 2>/dev/null || true
fi

# Clean up Frameworks if empty
rmdir "${FRAMEWORKS_DIR}" 2>/dev/null || true

# 8. Intelligent Code Signing & Verification (Inside-Out Standard)
NEEDS_BUNDLE_SIGN=false
if [ "${APP_UPDATED}" = true ] || [ ! -d "${APP_DIR}/_CodeSignature" ]; then
    NEEDS_BUNDLE_SIGN=true
elif ! codesign --verify --strict "${APP_DIR}" 2>/dev/null; then
    NEEDS_BUNDLE_SIGN=true
fi

if [ "${NEEDS_BUNDLE_SIGN}" = true ]; then
    echo "--> [3/4] Performing code signing with Hardened Runtime..."
    SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")
    if [ -f "${ENTITLEMENTS}" ]; then
        SIGN_ARGS+=(--entitlements "${ENTITLEMENTS}")
    fi
    if [ "${SIGN_IDENTITY}" != "-" ]; then
        SIGN_ARGS+=(--options runtime --timestamp)
    fi

    codesign "${SIGN_ARGS[@]}" "${APP_DIR}"

    if [ "${BUILD_CONFIG}" = "release" ]; then
        echo "--> [4/4] Verifying .app bundle integrity..."
        codesign --verify --deep --strict "${APP_DIR}"
    fi
else
    echo "--> [3/4] Bundle structure and code signature are pristine (Up-to-date, skipped)."
fi

echo "======================================================================"
echo "✅ Successfully bundled [${CHANNEL} - ${BUILD_CONFIG}]: ${APP_DIR}"
echo "======================================================================"

if [ "${OPEN_APP}" = true ]; then
    echo "--> Launching freshly built TTZip.app..."
    pkill -x TTZip 2>/dev/null || true
    if [ "${APP_UPDATED}" = true ]; then
        /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "${APP_DIR}" 2>/dev/null || true
    fi
    open "${APP_DIR}"
    echo "🎉 TTZip.app 已成功在桌面启动！"
    echo "   产物路径: ${APP_DIR}"
    echo "======================================================================"
fi

