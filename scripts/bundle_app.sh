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
if [ ! -f "${BIN_DIR}/TTZipApp" ] && [ -f "${BUILD_DIR}/arm64-apple-macosx/${BUILD_CONFIG}/TTZipApp" ]; then
    BIN_DIR="${BUILD_DIR}/arm64-apple-macosx/${BUILD_CONFIG}"
elif [ ! -f "${BIN_DIR}/TTZipApp" ] && [ -f "${BUILD_DIR}/x86_64-apple-macosx/${BUILD_CONFIG}/TTZipApp" ]; then
    BIN_DIR="${BUILD_DIR}/x86_64-apple-macosx/${BUILD_CONFIG}"
fi
BIN_PATH="${BIN_DIR}/TTZipApp"
FINDER_SYNC_SRC="${BIN_DIR}/libTTZipFinderSync.dylib"
QUICKLOOK_SRC="${BIN_DIR}/libTTZipQuickLook.dylib"

NEED_SWIFT_BUILD=true
if [ "${FORCE_CLEAN}" = false ] && [ -f "${BIN_PATH}" ]; then
    # Check if Sources, Package.swift, or Package.resolved are newer than the binary
    NEWER_FILE="$(find "${REPO_ROOT}/Sources" "${REPO_ROOT}/Package.swift" "${REPO_ROOT}/Package.resolved" -newer "${BIN_PATH}" 2>/dev/null | head -n 1 || true)"
    if [ -z "${NEWER_FILE}" ]; then
        NEED_SWIFT_BUILD=false
    fi
fi

if [ "${NEED_SWIFT_BUILD}" = true ]; then
    echo "--> [1/4] Compiling TTZipApp and App Extensions via Swift Package Manager in ${BUILD_CONFIG} mode (${NCPU} threads)..."
    swift build \
        --build-path "${BUILD_DIR}" \
        --jobs "${NCPU}" \
        -c "${BUILD_CONFIG}" \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        -Xswiftc -warnings-as-errors \
        "${SWIFT_FLAGS[@]}"
else
    echo "--> [1/4] TTZipApp and Extension sources are up-to-date (Skipped SPM compilation in 0.01s)."
fi

APP_DIR="${DIST_DIR}/TTZip.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PLUGINS_DIR="${CONTENTS_DIR}/PlugIns"

if [ ! -f "${BIN_PATH}" ]; then
    BIN_PATH="$(swift build --build-path "${BUILD_DIR}" -c "${BUILD_CONFIG}" --show-bin-path 2>/dev/null || true)/TTZipApp"
    if [ -f "${BIN_PATH}" ]; then
        BIN_DIR="$(dirname "${BIN_PATH}")"
    fi
fi

if [ "${FORCE_CLEAN}" = true ]; then
    echo "--> [Clean Mode] Removing existing bundle: ${APP_DIR}"
    rm -rf "${APP_DIR}" "${BUILD_DIR}/.bundle_state"
fi

STATE_DIR="${BUILD_DIR}/.bundle_state"
mkdir -p "${MACOS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}" "${PLUGINS_DIR}" "${STATE_DIR}"

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

if [ -f "${REPO_ROOT}/Sources/TTZipApp/Resources/AppIcon.icns" ]; then
    sync_file_if_changed "${REPO_ROOT}/Sources/TTZipApp/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns" "" || true
elif [ -f "${REPO_ROOT}/Resources/AppIcon.icns" ]; then
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

# 4. Packaging App Extensions (.appex) for FinderSync & QuickLook
package_extension() {
    local ext_name="$1"
    local src_info="$2"
    local src_dylib="$3"

    local ext_dir="${PLUGINS_DIR}/${ext_name}.appex"
    local ext_contents="${ext_dir}/Contents"
    local ext_macos="${ext_contents}/MacOS"
    local ext_bin="${ext_macos}/${ext_name}"

    mkdir -p "${ext_macos}"
    sync_file_if_changed "${src_info}" "${ext_contents}/Info.plist" "" || true

    local resolved_src=""
    if [ -f "${BIN_DIR}/${src_dylib}" ]; then
        resolved_src="${BIN_DIR}/${src_dylib}"
    elif [ -f "${BIN_DIR}/${ext_name}" ]; then
        resolved_src="${BIN_DIR}/${ext_name}"
    fi

    if [ -n "${resolved_src}" ] && [ -f "${resolved_src}" ]; then
        local src_stat
        src_stat="$(get_file_stat "${resolved_src}")"
        local last_stat
        last_stat="$(cat "${STATE_DIR}/${ext_name}.stamp" 2>/dev/null || true)"

        if [ ! -f "${ext_bin}" ] || [ "${src_stat}" != "${last_stat}" ]; then
            echo "--> Packaging extension: ${ext_name}.appex..."
            cp -f "${resolved_src}" "${ext_bin}"
            if [ "${BUILD_CONFIG}" = "release" ]; then
                strip -x "${ext_bin}" 2>/dev/null || true
            fi
            chmod +x "${ext_bin}"
            echo -n "${src_stat}" > "${STATE_DIR}/${ext_name}.stamp"
            APP_UPDATED=true
        fi
    fi
}

package_extension "TTZipFinderSync" "${REPO_ROOT}/Sources/TTZipFinderSync/Info.plist" "libTTZipFinderSync.dylib"
package_extension "TTZipQuickLook" "${REPO_ROOT}/Sources/TTZipQuickLook/Info.plist" "libTTZipQuickLook.dylib"

# 5. Handle Sparkle Framework (Direct Channel only)
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

# 6. Bundle libmpv.dylib and Transitive Dynamic Libraries with @rpath Relocation
bundle_and_relocate_mpv_deps() {
    local mpv_src="${REPO_ROOT}/Frameworks/libmpv.dylib"
    if [ ! -f "${mpv_src}" ]; then
        echo "--> [Warning] libmpv.dylib not found at ${mpv_src}, skipping preview engine bundling."
        return 0
    fi

    local target_mpv="${FRAMEWORKS_DIR}/libmpv.dylib"
    local mpv_src_stat
    mpv_src_stat="$(get_file_stat "${mpv_src}")"
    local last_stat
    last_stat="$(cat "${STATE_DIR}/libmpv.stamp" 2>/dev/null || true)"
    local state_done="${STATE_DIR}/libmpv_relocated.done"
    local existing_dylib_count
    existing_dylib_count="$(find "${FRAMEWORKS_DIR}" -maxdepth 1 -name "*.dylib" -type f 2>/dev/null | wc -l | tr -d ' ')"

    # Fast incremental check: skip if binary stamp matches, relocation marker exists, and closure is populated (>10 dylibs)
    if [ "${existing_dylib_count}" -gt 10 ] && [ -f "${target_mpv}" ] && [ "${mpv_src_stat}" = "${last_stat}" ] && [ -f "${state_done}" ]; then
        echo "--> [2.5/4] libmpv.dylib and transitive dependencies (${existing_dylib_count} libraries) are up-to-date (Skipped)."
        return 0
    fi

    echo "--> Bundling libmpv.dylib and recursively collecting transitive dynamic dependencies..."
    mkdir -p "${FRAMEWORKS_DIR}"
    cp -f "${mpv_src}" "${target_mpv}"
    chmod 755 "${target_mpv}"

    # Recursively collect all non-system dependencies into FRAMEWORKS_DIR
    local copied=true
    while [ "${copied}" = true ]; do
        copied=false
        for dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
            [ -f "${dylib}" ] || continue
            while read -r dep _; do
                case "${dep}" in
                    /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*|"")
                        continue
                        ;;
                    *)
                        local base="${dep##*/}"
                        local target="${FRAMEWORKS_DIR}/${base}"
                        if [ ! -f "${target}" ] && [ -f "${dep}" ]; then
                            cp -L "${dep}" "${target}"
                            chmod 755 "${target}"
                            copied=true
                        fi
                        ;;
                esac
            done < <(otool -L "${dylib}" | tail -n +2)
        done
    done

    local dylib_count
    dylib_count="$(find "${FRAMEWORKS_DIR}" -maxdepth 1 -name "*.dylib" -type f 2>/dev/null | wc -l | tr -d ' ')"
    echo "    • Collected ${dylib_count} dynamic libraries into Frameworks."

    # Batch rewrite Mach-O install names (LC_ID_DYLIB) and inject @loader_path
    echo "    • Rewriting Mach-O install names (LC_ID_DYLIB) to @rpath..."
    for dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
        [ -f "${dylib}" ] || continue
        local base="${dylib##*/}"
        chmod 755 "${dylib}"
        install_name_tool -id "@rpath/${base}" "${dylib}" 2>/dev/null || true
        if ! otool -l "${dylib}" | grep -A2 LC_RPATH | grep -q "@loader_path"; then
            install_name_tool -add_rpath "@loader_path" "${dylib}" 2>/dev/null || true
        fi
    done

    # Batch rewrite inter-dylib dependency paths to @rpath/<filename>
    echo "    • Relocating inter-library references to @rpath..."
    for dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
        [ -f "${dylib}" ] || continue
        local changes=()
        while read -r dep _; do
            case "${dep}" in
                /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*|"")
                    continue
                    ;;
                *)
                    local base="${dep##*/}"
                    if [ -f "${FRAMEWORKS_DIR}/${base}" ]; then
                        changes+=("-change" "${dep}" "@rpath/${base}")
                    fi
                    ;;
            esac
        done < <(otool -L "${dylib}" | tail -n +2)

        if [ ${#changes[@]} -gt 0 ]; then
            install_name_tool "${changes[@]}" "${dylib}" 2>/dev/null || true
        fi
    done

    # Relocate any non-system references in main executable TTZip to @rpath
    if [ -f "${MACOS_DIR}/TTZip" ]; then
        local main_changes=()
        while read -r dep _; do
            case "${dep}" in
                /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*|"")
                    continue
                    ;;
                *)
                    local base="${dep##*/}"
                    if [ -f "${FRAMEWORKS_DIR}/${base}" ]; then
                        main_changes+=("-change" "${dep}" "@rpath/${base}")
                    fi
                    ;;
            esac
        done < <(otool -L "${MACOS_DIR}/TTZip" | tail -n +2)

        if [ ${#main_changes[@]} -gt 0 ]; then
            chmod 755 "${MACOS_DIR}/TTZip"
            install_name_tool "${main_changes[@]}" "${MACOS_DIR}/TTZip" 2>/dev/null || true
        fi
    fi

    # Zero-leak audit: ensure no dangling external dependencies remain
    echo "    • Verifying zero external dependency leaks in bundled libraries..."
    local leak_count=0
    for dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
        [ -f "${dylib}" ] || continue
        while read -r dep _; do
            case "${dep}" in
                /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*|"")
                    continue
                    ;;
                *)
                    echo "      ❌ ERROR: External dependency leak in $(basename "${dylib}"): ${dep}"
                    leak_count=$((leak_count + 1))
                    ;;
            esac
        done < <(otool -L "${dylib}" | tail -n +2)
    done

    if [ -f "${MACOS_DIR}/TTZip" ]; then
        while read -r dep _; do
            case "${dep}" in
                /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*|"")
                    continue
                    ;;
                *)
                    echo "      ❌ ERROR: External dependency leak in TTZip binary: ${dep}"
                    leak_count=$((leak_count + 1))
                    ;;
            esac
        done < <(otool -L "${MACOS_DIR}/TTZip" | tail -n +2)
    fi

    if [ "${leak_count}" -gt 0 ]; then
        echo "❌ Aborting: ${leak_count} external dependencies remained uncontained!"
        exit 1
    fi
    echo "    • Verification passed: All ${dylib_count} dynamic libraries are fully self-contained."

    echo -n "${mpv_src_stat}" > "${STATE_DIR}/libmpv.stamp"
    touch "${state_done}"
    APP_UPDATED=true
}

bundle_and_relocate_mpv_deps

# 7. Clean up loose extension dylibs from Frameworks and Copy genuine Auxiliary Dynamic Libraries
rm -f "${FRAMEWORKS_DIR}/libTTZipFinderSync.dylib" "${FRAMEWORKS_DIR}/libTTZipQuickLook.dylib"

if [ -d "${BIN_DIR}" ]; then
    for dylib_file in "${BIN_DIR}"/*.dylib; do
        if [ -f "${dylib_file}" ]; then
            dylib_name="$(basename "${dylib_file}")"
            if [ "${dylib_name}" != "libTTZipFinderSync.dylib" ] && [ "${dylib_name}" != "libTTZipQuickLook.dylib" ]; then
                target_dylib="${FRAMEWORKS_DIR}/${dylib_name}"
                sync_file_if_changed "${dylib_file}" "${target_dylib}" 755 || true
            fi
        fi
    done
fi

# 8. Copy Built-in Plugins
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

# 9. Intelligent Code Signing & Verification (Inside-Out Standard)
NEEDS_BUNDLE_SIGN=false
if [ "${APP_UPDATED}" = true ] || [ ! -d "${APP_DIR}/_CodeSignature" ]; then
    NEEDS_BUNDLE_SIGN=true
elif ! codesign --verify --deep --strict "${APP_DIR}" 2>/dev/null; then
    NEEDS_BUNDLE_SIGN=true
fi

if [ "${NEEDS_BUNDLE_SIGN}" = true ]; then
    echo "--> [3/4] Performing Inside-Out code signing with Hardened Runtime..."

    # Step 1: Sign Embedded Dynamic Libraries (libmpv.dylib and transitive dependencies)
    if [ -d "${FRAMEWORKS_DIR}" ]; then
        for item in "${FRAMEWORKS_DIR}"/*.dylib; do
            if [ -f "${item}" ]; then
                echo "    • Signing embedded library: $(basename "${item}")..."
                LIB_SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")
                if [ "${SIGN_IDENTITY}" != "-" ]; then
                    LIB_SIGN_ARGS+=(--options runtime --timestamp)
                fi
                codesign "${LIB_SIGN_ARGS[@]}" "${item}"
            fi
        done
    fi

    # Step 2: Sign Embedded Frameworks (Sparkle.framework)
    if [ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]; then
        echo "    • Signing embedded Sparkle.framework..."
        SPARKLE_SIGN_ARGS=(--force --deep --sign "${SIGN_IDENTITY}")
        if [ "${SIGN_IDENTITY}" != "-" ]; then
            SPARKLE_SIGN_ARGS+=(--options runtime --timestamp)
        fi
        codesign "${SPARKLE_SIGN_ARGS[@]}" "${FRAMEWORKS_DIR}/Sparkle.framework"
    fi

    # Step 3: Sign App Extensions (.appex)
    if [ -d "${PLUGINS_DIR}" ]; then
        for appex_dir in "${PLUGINS_DIR}"/*.appex; do
            if [ -d "${appex_dir}" ]; then
                echo "    • Signing extension: $(basename "${appex_dir}")..."
                EXT_SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")
                if [ "${SIGN_IDENTITY}" != "-" ]; then
                    EXT_SIGN_ARGS+=(--options runtime --timestamp)
                fi
                codesign "${EXT_SIGN_ARGS[@]}" "${appex_dir}"
            fi
        done
    fi

    # Step 4: Sign Root Main App Bundle with Hardened Runtime and Entitlements
    echo "    • Signing main application bundle..."
    SIGN_ARGS=(--force --sign "${SIGN_IDENTITY}")
    if [ -f "${ENTITLEMENTS}" ]; then
        SIGN_ARGS+=(--entitlements "${ENTITLEMENTS}")
    fi
    if [ "${SIGN_IDENTITY}" != "-" ]; then
        SIGN_ARGS+=(--options runtime --timestamp)
    fi

    codesign "${SIGN_ARGS[@]}" "${APP_DIR}"

    echo "--> [4/4] Verifying .app bundle integrity with deep strict checks..."
    codesign --verify --deep --strict "${APP_DIR}"
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
    echo "🎉 TTZip.app launched successfully!"
    echo "   Bundle path: ${APP_DIR}"
    echo "======================================================================"
fi

