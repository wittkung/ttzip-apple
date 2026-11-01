#!/usr/bin/env bash
# Copyright 2026 MetastudyLine. All rights reserved.
# SPDX-License-Identifier: MIT OR Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SIGN_IDENTITY="-" CHANNEL="direct" ENTITLEMENTS="" OPEN_APP=false
BUILD_CONFIG="release" FAST_MODE=false DIST_DIR="${REPO_ROOT}/dist"
CUSTOM_BUILD_DIR="" FORCE_CLEAN=false DO_INSTALL=false

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
        --install) DO_INSTALL=true; shift ;;
        --open|-o) OPEN_APP=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

BUILD_DIR="${CUSTOM_BUILD_DIR:-${REPO_ROOT}/.build_${CHANNEL}}"
NCPU="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)"

if [ -z "${ENTITLEMENTS}" ]; then
    ENTITLEMENTS="${REPO_ROOT}/Sources/TTZipApp/$([ "${CHANNEL}" = "mas" ] && echo "TTZip.entitlements" || echo "TTZip-Direct.entitlements")"
fi

SWIFT_FLAGS=("-Xcc" "-DGL_SILENCE_DEPRECATION" "-Xswiftc" "-num-threads" "-Xswiftc" "${NCPU}")
case "${CHANNEL}" in
    mas) export TTZIP_CHANNEL="mas" MAS_BUILD="1"; SWIFT_FLAGS+=("-Xswiftc" "-DMAS_BUILD") ;;
    steam) export TTZIP_CHANNEL="steam"; unset MAS_BUILD 2>/dev/null || true; SWIFT_FLAGS+=("-Xswiftc" "-DSTEAM_BUILD") ;;
    community) export TTZIP_CHANNEL="community"; unset MAS_BUILD 2>/dev/null || true; SWIFT_FLAGS+=("-Xswiftc" "-DCOMMUNITY_BUILD") ;;
    direct|*) export TTZIP_CHANNEL="direct"; unset MAS_BUILD 2>/dev/null || true; SWIFT_FLAGS+=("-Xswiftc" "-DDIRECT_BUILD") ;;
esac

echo "======================================================================"
echo "🍎 Building and Bundling TTZip.app [${BUILD_CONFIG} mode, ${NCPU} cores] Channel: ${CHANNEL}"
echo "======================================================================"

cd "${REPO_ROOT}"

resolve_bin_dir() {
    local config="$1"
    local config_cap="Debug"
    [ "${config}" = "release" ] && config_cap="Release"
    for candidate in \
        "${BUILD_DIR}/out/Products/${config_cap}" \
        "${BUILD_DIR}/out/Products/${config}" \
        "${BUILD_DIR}/arm64-apple-macosx/${config}" \
        "${BUILD_DIR}/x86_64-apple-macosx/${config}" \
        "${BUILD_DIR}/${config}"; do
        if [ -f "${candidate}/TTZipApp" ]; then
            echo "${candidate}"
            return 0
        fi
    done
    echo "${BUILD_DIR}/${config}"
}

BIN_DIR="$(resolve_bin_dir "${BUILD_CONFIG}")"
BIN_PATH="${BIN_DIR}/TTZipApp"

NEED_SWIFT_BUILD=true
if [ "${FORCE_CLEAN}" = false ] && [ -f "${BIN_PATH}" ]; then
    DEP_TARGETS=("${REPO_ROOT}/Sources" "${REPO_ROOT}/Package.swift")
    [ -z "$(find "${DEP_TARGETS[@]}" -newer "${BIN_PATH}" 2>/dev/null | head -n 1 || true)" ] && NEED_SWIFT_BUILD=false
fi

if [ "${NEED_SWIFT_BUILD}" = true ]; then
    echo "--> [1/4] Compiling TTZipApp via Swift Package Manager..."
    swift build --build-path "${BUILD_DIR}" --jobs "${NCPU}" -c "${BUILD_CONFIG}" \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        -Xswiftc -warnings-as-errors "${SWIFT_FLAGS[@]}"
else
    echo "--> [1/4] TTZipApp sources up-to-date (Skipped SPM compilation)."
fi

BIN_DIR="$(resolve_bin_dir "${BUILD_CONFIG}")"
BIN_PATH="${BIN_DIR}/TTZipApp"
if [ ! -f "${BIN_PATH}" ]; then
    FOUND_BIN="$(find "${BUILD_DIR}" -name "TTZipApp" -type f ! -path "*/DWARF/*" ! -path "*.dSYM/*" 2>/dev/null | head -n 1 || true)"
    if [ -n "${FOUND_BIN}" ] && [ -f "${FOUND_BIN}" ]; then
        BIN_PATH="${FOUND_BIN}"
        BIN_DIR="$(dirname "${BIN_PATH}")"
    fi
fi

APP_DIR="${DIST_DIR}/TTZip.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PLUGINS_DIR="${CONTENTS_DIR}/PlugIns"
HELPERS_DIR="${CONTENTS_DIR}/Helpers"

[ "${FORCE_CLEAN}" = true ] && rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}" "${PLUGINS_DIR}" "${HELPERS_DIR}"

sync_file() {
    local src="$1" dst="$2" mode="${3:-}"
    if [ ! -f "${dst}" ] || ! cmp -s "${src}" "${dst}"; then
        mkdir -p "$(dirname "${dst}")"
        cp -f "${src}" "${dst}"
        if [ -n "${mode}" ]; then
            chmod "${mode}" "${dst}"
        fi
    fi
}

echo "--> [2/4] Assembling application bundle..."
cp -f "${BIN_PATH}" "${MACOS_DIR}/TTZip"
[ "${BUILD_CONFIG}" = "release" ] && strip -x "${MACOS_DIR}/TTZip" 2>/dev/null || true
chmod +x "${MACOS_DIR}/TTZip"

cp -f "${REPO_ROOT}/Sources/TTZipApp/Info.plist" "${CONTENTS_DIR}/Info.plist"
if [ "${CHANNEL}" = "direct" ] || [ "${CHANNEL}" = "community" ]; then
    if [ -f "${REPO_ROOT}/Sources/TTZipApp/Info-Direct.plist" ]; then
        /usr/libexec/PlistBuddy -c "Merge ${REPO_ROOT}/Sources/TTZipApp/Info-Direct.plist" "${CONTENTS_DIR}/Info.plist"
    fi
else
    /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true
fi
if [ -f "${REPO_ROOT}/Sources/TTZipApp/Resources/AppIcon.icns" ]; then
    sync_file "${REPO_ROOT}/Sources/TTZipApp/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi
if [ -f "${REPO_ROOT}/Sources/TTZipApp/PrivacyInfo.xcprivacy" ]; then
    sync_file "${REPO_ROOT}/Sources/TTZipApp/PrivacyInfo.xcprivacy" "${RESOURCES_DIR}/PrivacyInfo.xcprivacy"
fi
if [ -f "${REPO_ROOT}/Sources/TTZipApp/Resources/Acknowledgements.plist" ]; then
    sync_file "${REPO_ROOT}/Sources/TTZipApp/Resources/Acknowledgements.plist" "${RESOURCES_DIR}/Acknowledgements.plist"
fi
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

for lproj_dir in "${REPO_ROOT}"/Sources/TTZipApp/Resources/*.lproj; do
    if [ -d "${lproj_dir}" ]; then
        target_lproj="${RESOURCES_DIR}/$(basename "${lproj_dir}")"
        mkdir -p "${target_lproj}"
        cp -Rf "${lproj_dir}/"* "${target_lproj}/" 2>/dev/null || true
    fi
done

for spm_bundle in $(find "${BUILD_DIR}" "${REPO_ROOT}/.build" -name "*.bundle" -type d 2>/dev/null | sort -u); do
    case "${spm_bundle}" in
        *checkouts*|*xctest*|*SUUpdateValidatorTest*) continue ;;
        *) cp -Rf "${spm_bundle}" "${RESOURCES_DIR}/" 2>/dev/null || true ;;
    esac
done

package_extension() {
    local ext_name="$1" src_info="$2" src_dylib="$3"
    local ext_dir="${PLUGINS_DIR}/${ext_name}.appex"
    local ext_bin="${ext_dir}/Contents/MacOS/${ext_name}"
    mkdir -p "$(dirname "${ext_bin}")" "${ext_dir}/Contents/Resources"
    sync_file "${src_info}" "${ext_dir}/Contents/Info.plist"
    if [ -f "${REPO_ROOT}/Sources/${ext_name}/PrivacyInfo.xcprivacy" ]; then
        sync_file "${REPO_ROOT}/Sources/${ext_name}/PrivacyInfo.xcprivacy" "${ext_dir}/Contents/Resources/PrivacyInfo.xcprivacy"
    fi
    local resolved_src=""
    if [ -f "${BIN_DIR}/${src_dylib}" ]; then
        resolved_src="${BIN_DIR}/${src_dylib}"
    elif [ -f "${BIN_DIR}/${ext_name}" ]; then
        resolved_src="${BIN_DIR}/${ext_name}"
    fi
    if [ -n "${resolved_src}" ] && [ -f "${resolved_src}" ]; then
        cp -f "${resolved_src}" "${ext_bin}"
        if [ "${BUILD_CONFIG}" = "release" ]; then
            strip -x "${ext_bin}" 2>/dev/null || true
        fi
        chmod +x "${ext_bin}"
        install_name_tool -add_rpath "@executable_path/../../../../Frameworks" "${ext_bin}" 2>/dev/null || true
        install_name_tool -add_rpath "@loader_path/../../../../Frameworks" "${ext_bin}" 2>/dev/null || true
    fi
}
package_extension "TTZipFinderSync" "${REPO_ROOT}/Sources/TTZipFinderSync/Info.plist" "libTTZipFinderSync.dylib"
package_extension "TTZipQuickLook" "${REPO_ROOT}/Sources/TTZipQuickLook/Info.plist" "libTTZipQuickLook.dylib"

if [ "${CHANNEL}" = "direct" ]; then
    SPARKLE_SRC="$(find "${BUILD_DIR}" "${REPO_ROOT}/.build" -maxdepth 8 -name "Sparkle.framework" -type d 2>/dev/null | head -n 1 || true)"
    if [ -n "${SPARKLE_SRC}" ] && [ -d "${SPARKLE_SRC}" ] && [ ! -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]; then
        cp -R "${SPARKLE_SRC}" "${FRAMEWORKS_DIR}/"
    fi
else
    rm -rf "${FRAMEWORKS_DIR}/Sparkle.framework"
fi


rm -f "${FRAMEWORKS_DIR}/libTTZipFinderSync.dylib" "${FRAMEWORKS_DIR}/libTTZipQuickLook.dylib"
if [ -d "${BIN_DIR}" ]; then
    for dylib_file in "${BIN_DIR}"/*.dylib; do
        [ -f "${dylib_file}" ] || continue
        dylib_name="$(basename "${dylib_file}")"
        case "${dylib_name}" in
            libTTZipFinderSync.dylib|libTTZipQuickLook.dylib) continue ;;
            *) sync_file "${dylib_file}" "${FRAMEWORKS_DIR}/${dylib_name}" 755 ;;
        esac
    done
fi

rmdir "${FRAMEWORKS_DIR}" 2>/dev/null || true

# Compile and package the optional ttarchive-worker helper daemon.
# The worker crate is not part of this repository, so consumers point the
# bundler at their own Cargo workspace or a prebuilt binary.
WORKER_MANIFEST="${TTZIP_WORKER_MANIFEST:-}"
if [ -f "${WORKER_MANIFEST}" ]; then
    echo "--> Compiling ttarchive-worker helper daemon..."
    CARGO_FLAGS=("--manifest-path" "${WORKER_MANIFEST}" "-p" "ttarchive-worker")
    if [ "${BUILD_CONFIG}" = "release" ]; then
        CARGO_FLAGS+=("--release")
    fi
    LIBRARY_PATH="${LIBRARY_PATH:-}:/opt/homebrew/lib" \
    HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/opt/homebrew}" \
    TTZIP_SYS_LIB_DIR="${TTZIP_SYS_LIB_DIR:-/opt/homebrew/lib}" \
    cargo build "${CARGO_FLAGS[@]}"
fi

WORKER_BIN=""
WORKER_BIN="${TTZIP_WORKER_BIN:-}"

if [ -n "${WORKER_BIN}" ] && [ -f "${WORKER_BIN}" ]; then
    mkdir -p "${HELPERS_DIR}"
    sync_file "${WORKER_BIN}" "${HELPERS_DIR}/ttarchive-worker" 755
    if [ "${BUILD_CONFIG}" = "release" ]; then
        strip -x "${HELPERS_DIR}/ttarchive-worker" 2>/dev/null || true
    fi
fi
rmdir "${HELPERS_DIR}" 2>/dev/null || true

# Installed application hosts require the bundled media sandbox service.
MEDIA_SERVICE_SOURCE="${TTMEDIA_XPC_SERVICE_BUNDLE:-${BIN_DIR}/TTMediaWorker.xpc}"
MEDIA_SERVICE_ENTITLEMENTS="${TTMEDIA_XPC_ENTITLEMENTS:-${REPO_ROOT}/vendor/ttmedia/Sources/TTMediaWorkerService/Worker.entitlements}"
MEDIA_SERVICE_ARCHIVE="${TTMEDIA_XPC_SERVICE_ARCHIVE:-}"
if [ ! -d "${MEDIA_SERVICE_SOURCE}" ] && [ -f "${MEDIA_SERVICE_ARCHIVE}" ]; then
    MEDIA_SERVICE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ttzip-media-xpc.XXXXXX")"
    ditto -xk "${MEDIA_SERVICE_ARCHIVE}" "${MEDIA_SERVICE_STAGE}"
    MEDIA_SERVICE_SOURCE="${MEDIA_SERVICE_STAGE}/TTMediaWorker.xpc"
fi
if [ ! -d "${MEDIA_SERVICE_SOURCE}" ] || [ ! -f "${MEDIA_SERVICE_ENTITLEMENTS}" ]; then
    echo "Missing sandbox media service. Build the TTMediaWorker XPC service, or provide TTMEDIA_XPC_SERVICE_BUNDLE and TTMEDIA_XPC_ENTITLEMENTS." >&2
    exit 1
fi
mkdir -p "${CONTENTS_DIR}/XPCServices"
rm -rf "${CONTENTS_DIR}/XPCServices/TTMediaWorker.xpc"
cp -R "${MEDIA_SERVICE_SOURCE}" "${CONTENTS_DIR}/XPCServices/TTMediaWorker.xpc"
if [ -n "${MEDIA_SERVICE_STAGE:-}" ]; then
    rm -rf "${MEDIA_SERVICE_STAGE}"
fi
codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${MEDIA_SERVICE_ENTITLEMENTS}" "${CONTENTS_DIR}/XPCServices/TTMediaWorker.xpc"

echo "--> [3/4] Signing application bundle..."
if [ -d "${FRAMEWORKS_DIR}" ]; then
    for item in "${FRAMEWORKS_DIR}"/*.dylib; do
        [ -f "${item}" ] || continue
        codesign --force --sign "${SIGN_IDENTITY}" $([ "${SIGN_IDENTITY}" != "-" ] && echo "--options runtime --timestamp") "${item}"
    done
    if [ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]; then
        codesign --force --deep --sign "${SIGN_IDENTITY}" $([ "${SIGN_IDENTITY}" != "-" ] && echo "--options runtime --timestamp") "${FRAMEWORKS_DIR}/Sparkle.framework"
    fi
fi

WORKER_ENTITLEMENTS="${TTARCHIVE_WORKER_ENTITLEMENTS:-}"
if [ -d "${HELPERS_DIR}" ]; then
    for helper in "${HELPERS_DIR}"/*; do
        [ -f "${helper}" ] || continue
        if [ "${CHANNEL}" = "direct" ]; then
            codesign --force --sign "${SIGN_IDENTITY}" $([ "${SIGN_IDENTITY}" != "-" ] && echo "--options runtime --timestamp") "${helper}"
        else
            helper_ent="${WORKER_ENTITLEMENTS}"
            [ ! -f "${helper_ent}" ] && helper_ent="${ENTITLEMENTS}"
            codesign --force --sign "${SIGN_IDENTITY}" $([ -f "${helper_ent}" ] && echo "--entitlements ${helper_ent}") $([ "${SIGN_IDENTITY}" != "-" ] && echo "--options runtime --timestamp") "${helper}"
        fi
    done
fi

if [ -d "${PLUGINS_DIR}" ]; then
    for appex_dir in "${PLUGINS_DIR}"/*.appex; do
        [ -d "${appex_dir}" ] || continue
        ext_name="$(basename "${appex_dir}" .appex)"
        ext_ent="${REPO_ROOT}/Sources/${ext_name}/${ext_name}.entitlements"
        if [ ! -f "${ext_ent}" ]; then
            echo "❌ FATAL: Missing entitlements for extension ${ext_name} at ${ext_ent}" >&2
            exit 1
        fi
        codesign --force --sign "${SIGN_IDENTITY}" --entitlements "${ext_ent}" $([ "${SIGN_IDENTITY}" != "-" ] && echo "--options runtime --timestamp") "${appex_dir}"
    done
fi

MAIN_SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")
[ -f "${ENTITLEMENTS}" ] && MAIN_SIGN_ARGS+=(--entitlements "${ENTITLEMENTS}")
[ "${SIGN_IDENTITY}" != "-" ] && MAIN_SIGN_ARGS+=(--options runtime --timestamp)
codesign "${MAIN_SIGN_ARGS[@]}" "${APP_DIR}"

echo "--> [4/4] Verifying bundle..."
codesign --verify --deep --strict "${APP_DIR}"

if [ "${CHANNEL}" = "mas" ]; then
    if otool -L "${MACOS_DIR}/TTZip" | grep -i "Sparkle" >/dev/null 2>&1 || [ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]; then
        echo "❌ FATAL: MAS bundle violates zero-Sparkle invariant!" >&2
        exit 1
    fi
fi

echo "======================================================================"
echo "✅ Successfully bundled [${CHANNEL} - ${BUILD_CONFIG}]: ${APP_DIR}"
echo "======================================================================"

if [ "${DO_INSTALL}" = true ]; then
    INSTALL_TARGET_DIR="${TTZIP_INSTALL_DIR:-/Applications}"
    DEST_APP="${INSTALL_TARGET_DIR}/TTZip.app"
    pkill -x TTZip 2>/dev/null || true
    rm -rf "${DEST_APP}"
    cp -Rf "${APP_DIR}" "${DEST_APP}"
    LSREGISTER="$(find /System/Library/Frameworks/CoreServices.framework -name lsregister 2>/dev/null | head -n 1 || true)"
    if [ -n "${LSREGISTER}" ] && [ -x "${LSREGISTER}" ]; then
        "${LSREGISTER}" -f "${DEST_APP}" 2>/dev/null || true
    fi
    echo "🎉 Installed to ${DEST_APP}"
fi

if [ "${OPEN_APP}" = true ]; then
    pkill -x TTZip 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "${APP_DIR}" 2>/dev/null || true
    open "${APP_DIR}"
fi
