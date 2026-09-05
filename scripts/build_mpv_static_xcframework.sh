#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: High-performance native archiving and compression engine.
#
# build_mpv_static_xcframework.sh: Self-contained static MPVKit.xcframework pipeline.
# Compiles FFmpeg (decode-only), dav1d, libass (CoreText backend), and libmpv into
# a pure LGPL, zero-JIT, sandbox-compliant universal XCFramework for macOS.

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration and Version Anchors
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APPLE_DIR="${REPO_ROOT}/apple"
BUILD_ROOT="${APPLE_DIR}/build_mpvkit"
OUTPUT_DIR="${APPLE_DIR}/Frameworks"

MACOS_MIN_VERSION="14.0"
DEFAULT_ARCH="universal" # Options: arm64, x86_64, universal
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
DRY_RUN=false
CLEAN_BUILD=false

# Deterministic dependency versions
DAV1D_VERSION="1.5.1"
FREETYPE_VERSION="2.13.3"
FRIBIDI_VERSION="1.0.16"
HARFBUZZ_VERSION="10.4.0"
LIBASS_VERSION="0.17.3"
FFMPEG_VERSION="7.1.1"
MPV_VERSION="0.39.0"

# -----------------------------------------------------------------------------
# CLI Argument Parsing
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build self-contained, minimal static MPVKit.xcframework for TTZip.

Options:
  --arch <arm64|x86_64|universal>  Target architecture (default: universal)
  --clean                          Remove previous build artifacts and scratch space
  --dry-run                        Print actions without executing compilers
  --jobs <N>                       Number of parallel build threads (default: ${JOBS})
  --prefix <DIR>                   Custom output directory (default: ${OUTPUT_DIR})
  -h, --help                       Show this help message and exit
EOF
    exit 0
}

TARGET_ARCH="${DEFAULT_ARCH}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --jobs)
            JOBS="$2"
            shift 2
            ;;
        --prefix)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "❌ Unknown option: $1" >&2
            usage
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Logging Utilities
# -----------------------------------------------------------------------------
log_info() {
    echo -e "\033[1;34m[INFO]\033[0m $*"
}

log_step() {
    echo -e "\033[1;32m==>\033[0m \033[1m$*\033[0m"
}

log_warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

log_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
}

execute_cmd() {
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# -----------------------------------------------------------------------------
# Environment and Prerequisite Validation
# -----------------------------------------------------------------------------
validate_toolchain() {
    log_step "Validating compilation toolchain and host SDK..."

    local missing=()
    local required_tools=(clang xcrun xcodebuild meson ninja nasm pkg-config cmake)

    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            missing+=("${tool}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ "${DRY_RUN}" == true ]]; then
            log_warn "Missing build tools in dry-run mode: ${missing[*]} (simulating pipeline without host execution)"
        else
            log_error "Missing required build tools: ${missing[*]}"
            log_error "Install them via Homebrew or Xcode Command Line Tools:"
            log_error "  brew install meson ninja nasm pkg-config cmake"
            exit 1
        fi
    fi

    local sdk_path
    sdk_path="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    if [[ -z "${sdk_path}" || ! -d "${sdk_path}" ]]; then
        log_error "Failed to locate macOS SDK. Ensure Xcode Command Line Tools are active."
        exit 1
    fi

    log_info "Host SDK located at: ${sdk_path}"
    log_info "Target architecture mode: ${TARGET_ARCH}"
}

# -----------------------------------------------------------------------------
# Directory Layout Setup
# -----------------------------------------------------------------------------
setup_directories() {
    if [[ "${CLEAN_BUILD}" == true && -d "${BUILD_ROOT}" ]]; then
        log_warn "Cleaning existing build directory: ${BUILD_ROOT}"
        execute_cmd rm -rf "${BUILD_ROOT}"
    fi

    SRC_DIR="${BUILD_ROOT}/sources"
    BUILD_SCRATCH="${BUILD_ROOT}/scratch"
    DEST_DIR="${BUILD_ROOT}/dest"

    execute_cmd mkdir -p "${SRC_DIR}" "${BUILD_SCRATCH}" "${DEST_DIR}" "${OUTPUT_DIR}"
}

# -----------------------------------------------------------------------------
# Source Code Acquisition
# -----------------------------------------------------------------------------
fetch_source_archive() {
    local name="$1"
    local url="$2"
    local target_dir="${SRC_DIR}/${name}"

    if [[ -d "${target_dir}" ]]; then
        log_info "Source directory ${name} already cached."
        return 0
    fi

    log_step "Fetching source archive for ${name}..."
    local archive_name
    archive_name="$(basename "${url}")"
    local temp_archive="${SRC_DIR}/${archive_name}"

    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] curl -fSL \"${url}\" -o \"${temp_archive}\""
        echo "[dry-run] tar -xf \"${temp_archive}\" -C \"${SRC_DIR}\""
        return 0
    fi

    curl -fSL "${url}" -o "${temp_archive}"
    mkdir -p "${target_dir}"
    tar -xf "${temp_archive}" -C "${target_dir}" --strip-components 1
    rm -f "${temp_archive}"
}

acquire_all_sources() {
    log_step "Acquiring pinned third-party sources..."
    fetch_source_archive "dav1d" "https://code.videolan.org/videolan/dav1d/-/archive/${DAV1D_VERSION}/dav1d-${DAV1D_VERSION}.tar.gz"
    fetch_source_archive "freetype" "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"
    fetch_source_archive "fribidi" "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz"
    fetch_source_archive "harfbuzz" "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"
    fetch_source_archive "libass" "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.gz"
    fetch_source_archive "ffmpeg" "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
    fetch_source_archive "mpv" "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz"
}

# -----------------------------------------------------------------------------
# Architecture-specific Environment Preparation
# -----------------------------------------------------------------------------
prepare_arch_env() {
    local arch="$1"
    local prefix="$2"
    local sdk_path
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

    export CC="$(xcrun -find clang)"
    export CXX="$(xcrun -find clang++)"
    export AR="$(xcrun -find ar)"
    export RANLIB="$(xcrun -find ranlib)"
    export STRIP="$(xcrun -find strip)"

    local target_triple="${arch}-apple-macos${MACOS_MIN_VERSION}"
    export CFLAGS="-target ${target_triple} -isysroot ${sdk_path} -I${prefix}/include -O3 -fPIC -fvisibility=hidden"
    export CXXFLAGS="-target ${target_triple} -isysroot ${sdk_path} -I${prefix}/include -O3 -fPIC -fvisibility=hidden"
    export LDFLAGS="-target ${target_triple} -isysroot ${sdk_path} -L${prefix}/lib"
    export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig:${prefix}/share/pkgconfig"
    export PKG_CONFIG_LIBDIR="${prefix}/lib/pkgconfig"

    # Setup Meson cross-compilation file if target arch differs from host
    local host_arch
    host_arch="$(uname -m)"
    MESON_CROSS_ARGS=()

    if [[ "${arch}" != "${host_arch}" ]]; then
        local cross_file="${BUILD_SCRATCH}/cross-${arch}.ini"
        local meson_cpu_family="${arch}"
        if [[ "${arch}" == "arm64" ]]; then
            meson_cpu_family="aarch64"
        fi

        if [[ "${DRY_RUN}" == true ]]; then
            echo "[dry-run] generate Meson cross-file: ${cross_file}"
        else
            mkdir -p "$(dirname "${cross_file}")"
            cat <<EOF > "${cross_file}"
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
ranlib = '${RANLIB}'
strip = '${STRIP}'
pkg-config = 'pkg-config'

[properties]
c_args = ['-target', '${target_triple}', '-isysroot', '${sdk_path}', '-I${prefix}/include', '-O3', '-fPIC']
cpp_args = ['-target', '${target_triple}', '-isysroot', '${sdk_path}', '-I${prefix}/include', '-O3', '-fPIC']
c_link_args = ['-target', '${target_triple}', '-isysroot', '${sdk_path}', '-L${prefix}/lib']
cpp_link_args = ['-target', '${target_triple}', '-isysroot', '${sdk_path}', '-L${prefix}/lib']

[host_machine]
system = 'darwin'
subsystem = 'macos'
kernel = 'xnu'
cpu_family = '${meson_cpu_family}'
cpu = '${meson_cpu_family}'
endian = 'little'
EOF
        fi
        MESON_CROSS_ARGS=("--cross-file" "${cross_file}")
        log_info "Configured Meson cross-compilation for ${arch} (cross-file: ${cross_file})"
    fi
}

# -----------------------------------------------------------------------------
# Module Compilation Slices
# -----------------------------------------------------------------------------
build_dav1d() {
    local arch="$1"
    local prefix="$2"
    local src="${SRC_DIR}/dav1d"
    local bld="${BUILD_SCRATCH}/dav1d-${arch}"

    log_step "Building dav1d (${arch})..."
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] meson setup ${bld} ${src} --default-library=static --prefix=${prefix}"
        return 0
    fi

    rm -rf "${bld}"
    meson setup "${bld}" "${src}" \
        --prefix="${prefix}" \
        --libdir="lib" \
        --default-library=static \
        --buildtype=release \
        -Denable_tools=false \
        -Denable_examples=false \
        -Denable_tests=false \
        -Denable_asm=true \
        -Dc_args="${CFLAGS}" \
        ${MESON_CROSS_ARGS[@]+"${MESON_CROSS_ARGS[@]}"}
    ninja -C "${bld}" -j "${JOBS}" install
}

build_freetype() {
    local arch="$1"
    local prefix="$2"
    local src="${SRC_DIR}/freetype"
    local bld="${BUILD_SCRATCH}/freetype-${arch}"

    log_step "Building FreeType (${arch})..."
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] meson setup ${bld} ${src} --default-library=static --prefix=${prefix}"
        return 0
    fi

    rm -rf "${bld}"
    meson setup "${bld}" "${src}" \
        --prefix="${prefix}" \
        --libdir="lib" \
        --default-library=static \
        --buildtype=release \
        -Dbrotli=disabled \
        -Dbzip2=disabled \
        -Dpng=disabled \
        -Dzlib=disabled \
        -Dharfbuzz=disabled \
        -Dc_args="${CFLAGS}" \
        ${MESON_CROSS_ARGS[@]+"${MESON_CROSS_ARGS[@]}"}
    ninja -C "${bld}" -j "${JOBS}" install
}

build_fribidi() {
    local arch="$1"
    local prefix="$2"
    local src="${SRC_DIR}/fribidi"
    local bld="${BUILD_SCRATCH}/fribidi-${arch}"

    log_step "Building FriBidi (${arch})..."
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] meson setup ${bld} ${src} --default-library=static --prefix=${prefix}"
        return 0
    fi

    rm -rf "${bld}"
    meson setup "${bld}" "${src}" \
        --prefix="${prefix}" \
        --libdir="lib" \
        --default-library=static \
        --buildtype=release \
        -Ddocs=false \
        -Dbin=false \
        -Dtests=false \
        -Dc_args="${CFLAGS}" \
        ${MESON_CROSS_ARGS[@]+"${MESON_CROSS_ARGS[@]}"}
    ninja -C "${bld}" -j "${JOBS}" install
}

build_harfbuzz() {
    local arch="$1"
    local prefix="$2"
    local src="${SRC_DIR}/harfbuzz"
    local bld="${BUILD_SCRATCH}/harfbuzz-${arch}"

    log_step "Building HarfBuzz (${arch})..."
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] meson setup ${bld} ${src} --default-library=static --prefix=${prefix}"
        return 0
    fi

    rm -rf "${bld}"
    meson setup "${bld}" "${src}" \
        --prefix="${prefix}" \
        --libdir="lib" \
        --default-library=static \
        --buildtype=release \
        -Dglib=disabled \
        -Dgobject=disabled \
        -Dcairo=disabled \
        -Dicu=disabled \
        -Dtests=disabled \
        -Ddocs=disabled \
        -Dfreetype=enabled \
        -Dcoretext=enabled \
        -Dc_args="${CFLAGS}" \
        -Dcpp_args="${CXXFLAGS}" \
        ${MESON_CROSS_ARGS[@]+"${MESON_CROSS_ARGS[@]}"}
    ninja -C "${bld}" -j "${JOBS}" install
}

build_libass() {
    local arch="$1"
    local prefix="$2"
    local src="${SRC_DIR}/libass"
    local bld="${BUILD_SCRATCH}/libass-${arch}"

    log_step "Building libass (${arch}) with native macOS CoreText backend (Zero fontconfig)..."
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] meson setup ${bld} ${src} -Dcoretext=enabled -Dfontconfig=disabled"
        return 0
    fi

    rm -rf "${bld}"
    meson setup "${bld}" "${src}" \
        --prefix="${prefix}" \
        --libdir="lib" \
        --default-library=static \
        --buildtype=release \
        -Dcoretext=enabled \
        -Dfontconfig=disabled \
        -Dlibunibreak=disabled \
        -Dasm=enabled \
        -Dtest=false \
        -Dc_args="${CFLAGS}" \
        ${MESON_CROSS_ARGS[@]+"${MESON_CROSS_ARGS[@]}"}
    ninja -C "${bld}" -j "${JOBS}" install
}

build_ffmpeg() {
    local arch="$1"
    local prefix="$2"
    local src="${SRC_DIR}/ffmpeg"
    local bld="${BUILD_SCRATCH}/ffmpeg-${arch}"

    log_step "Building FFmpeg (${arch}) with pure LGPL decode-only matrix..."
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] configure FFmpeg --disable-encoders --enable-videotoolbox --enable-libdav1d"
        return 0
    fi

    rm -rf "${bld}"
    mkdir -p "${bld}"
    pushd "${bld}" >/dev/null

    local ffmpeg_arch="${arch}"
    if [[ "${arch}" == "arm64" ]]; then
        ffmpeg_arch="aarch64"
    fi

    local cross_flags=()
    local host_arch
    host_arch="$(uname -m)"
    if [[ "${arch}" != "${host_arch}" ]]; then
        cross_flags+=("--enable-cross-compile")
    fi

    "${src}/configure" \
        --prefix="${prefix}" \
        --libdir="${prefix}/lib" \
        --arch="${ffmpeg_arch}" \
        --target-os=darwin \
        --cc="${CC}" \
        --cxx="${CXX}" \
        --ar="${AR}" \
        --ranlib="${RANLIB}" \
        --strip="${STRIP}" \
        --extra-cflags="${CFLAGS}" \
        --extra-ldflags="${LDFLAGS}" \
        --enable-static \
        --disable-shared \
        --enable-pic \
        --disable-gpl \
        --disable-nonfree \
        --disable-version3 \
        --disable-programs \
        --disable-ffmpeg \
        --disable-ffplay \
        --disable-ffprobe \
        --disable-doc \
        --disable-network \
        --disable-devices \
        --disable-encoders \
        --disable-muxers \
        --disable-hwaccels \
        --enable-hwaccel=h264_videotoolbox \
        --enable-hwaccel=hevc_videotoolbox \
        --enable-hwaccel=vp9_videotoolbox \
        --enable-hwaccel=prores_videotoolbox \
        --enable-videotoolbox \
        --enable-audiotoolbox \
        --enable-libdav1d \
        --disable-autodetect \
        --disable-debug \
        ${cross_flags[@]+"${cross_flags[@]}"}

    make -j "${JOBS}"
    make install
    popd >/dev/null
}

build_libmpv() {
    local arch="$1"
    local prefix="$2"
    local src="${SRC_DIR}/mpv"
    local bld="${BUILD_SCRATCH}/mpv-${arch}"

    log_step "Building libmpv static core (${arch}) without JIT / Lua / Vulkan..."
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] meson setup ${bld} ${src} -Dlibmpv=true -Ddefault_library=static -Dlua=disabled"
        return 0
    fi

    rm -rf "${bld}"
    meson setup "${bld}" "${src}" \
        --prefix="${prefix}" \
        --libdir="lib" \
        --default-library=static \
        --buildtype=release \
        -Dcplayer=false \
        -Dlibmpv=true \
        -Dlua=disabled \
        -Djavascript=disabled \
        -Dgl=enabled \
        -Dcocoa=enabled \
        -Dapple-remote=disabled \
        -Dshaderc=disabled \
        -Dlibplacebo=disabled \
        -Dvapoursynth=disabled \
        -Drubberband=disabled \
        -Dlcms2=disabled \
        -Duchardet=disabled \
        -Dtests=false \
        -Dmanpage-build=disabled \
        -Dhtml-build=disabled \
        -Dpdf-build=disabled \
        -Dc_args="${CFLAGS}" \
        ${MESON_CROSS_ARGS[@]+"${MESON_CROSS_ARGS[@]}"}
    ninja -C "${bld}" -j "${JOBS}" install
}

# -----------------------------------------------------------------------------
# Static Archive Fusion (Per Slice)
# -----------------------------------------------------------------------------
fuse_static_archive() {
    local arch="$1"
    local prefix="$2"
    local output_archive="${DEST_DIR}/libMPVKit-${arch}.a"

    log_step "Fusing all component static archives into single library for ${arch}..."
    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] libtool -static -o ${output_archive} [all .a files]"
        return 0
    fi

    local archives=(
        "${prefix}/lib/libmpv.a"
        "${prefix}/lib/libavcodec.a"
        "${prefix}/lib/libavformat.a"
        "${prefix}/lib/libavutil.a"
        "${prefix}/lib/libavfilter.a"
        "${prefix}/lib/libswscale.a"
        "${prefix}/lib/libswresample.a"
        "${prefix}/lib/libdav1d.a"
        "${prefix}/lib/libass.a"
        "${prefix}/lib/libfreetype.a"
        "${prefix}/lib/libfribidi.a"
        "${prefix}/lib/libharfbuzz.a"
    )

    local valid_archives=()
    for ar in "${archives[@]}"; do
        if [[ -f "${ar}" ]]; then
            valid_archives+=("${ar}")
        else
            log_warn "Archive not found, skipping: ${ar}"
        fi
    done

    xcrun libtool -static -o "${output_archive}" "${valid_archives[@]}"
    xcrun ranlib "${output_archive}"
    log_info "Generated fused static library: ${output_archive}"
}

# -----------------------------------------------------------------------------
# Single Architecture Full Pipeline
# -----------------------------------------------------------------------------
build_slice() {
    local arch="$1"
    local prefix="${DEST_DIR}/${arch}"

    log_step "Starting build process for architecture slice: [${arch}]"
    prepare_arch_env "${arch}" "${prefix}"

    build_dav1d "${arch}" "${prefix}"
    build_freetype "${arch}" "${prefix}"
    build_fribidi "${arch}" "${prefix}"
    build_harfbuzz "${arch}" "${prefix}"
    build_libass "${arch}" "${prefix}"
    build_ffmpeg "${arch}" "${prefix}"
    build_libmpv "${arch}" "${prefix}"
    fuse_static_archive "${arch}" "${prefix}"
}

# -----------------------------------------------------------------------------
# Headers and Umbrella Modulemap Generation
# -----------------------------------------------------------------------------
assemble_headers() {
    local headers_dir="${DEST_DIR}/Headers"
    log_step "Assembling C public headers and Swift modulemap..."

    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] mkdir -p ${headers_dir} && copy mpv headers"
        return 0
    fi

    rm -rf "${headers_dir}"
    mkdir -p "${headers_dir}/mpv"

    local sample_prefix="${DEST_DIR}/arm64"
    if [[ ! -d "${sample_prefix}/include/mpv" && -d "${DEST_DIR}/x86_64/include/mpv" ]]; then
        sample_prefix="${DEST_DIR}/x86_64"
    fi

    if [[ -d "${sample_prefix}/include/mpv" ]]; then
        cp -R "${sample_prefix}/include/mpv/" "${headers_dir}/mpv/"
    elif [[ -d "${SRC_DIR}/mpv/libmpv" ]]; then
        cp -R "${SRC_DIR}/mpv/libmpv/" "${headers_dir}/mpv/"
    fi

    # Generate MPVKit umbrella header
    cat <<'EOF' > "${headers_dir}/MPVKit.h"
/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
 * All rights reserved.
 *
 * TTZip: High-performance native archiving and compression engine.
 * MPVKit: Minimal self-contained static media preview framework.
 */

#ifndef MPVKIT_H
#define MPVKIT_H

#import <Foundation/Foundation.h>

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>
#include <mpv/stream_cb.h>

#endif /* MPVKIT_H */
EOF

    # Generate Swift modulemap
    cat <<'EOF' > "${headers_dir}/module.modulemap"
framework module MPVKit {
    umbrella header "MPVKit.h"
    export *
    module * { export * }

    link framework "AudioToolbox"
    link framework "VideoToolbox"
    link framework "CoreAudio"
    link framework "CoreFoundation"
    link framework "CoreMedia"
    link framework "CoreVideo"
    link framework "CoreText"
    link framework "CoreGraphics"
    link framework "OpenGL"
    link framework "Cocoa"
    link framework "Metal"
    link framework "QuartzCore"
    link "c++"
    link "iconv"
    link "z"
    link "bz2"
}
EOF
}

# -----------------------------------------------------------------------------
# Packaging MPVKit.xcframework
# -----------------------------------------------------------------------------
package_xcframework() {
    log_step "Creating packaged MPVKit.xcframework..."
    local final_xcframework="${OUTPUT_DIR}/MPVKit.xcframework"
    local headers_dir="${DEST_DIR}/Headers"

    if [[ "${DRY_RUN}" == true ]]; then
        echo "[dry-run] xcodebuild -create-xcframework -output ${final_xcframework}"
        return 0
    fi

    rm -rf "${final_xcframework}"

    local final_archive=""
    if [[ "${TARGET_ARCH}" == "universal" ]]; then
        final_archive="${DEST_DIR}/libMPVKit-universal.a"
        log_info "Creating Fat binary from arm64 and x86_64 slices..."
        xcrun lipo -create \
            "${DEST_DIR}/libMPVKit-arm64.a" \
            "${DEST_DIR}/libMPVKit-x86_64.a" \
            -output "${final_archive}"
    else
        final_archive="${DEST_DIR}/libMPVKit-${TARGET_ARCH}.a"
    fi

    # Validate Mach-O architecture
    local slice_info
    slice_info="$(xcrun lipo -info "${final_archive}")"
    log_info "Library architecture verification: ${slice_info}"

    # Generate XCFramework via xcodebuild
    xcrun xcodebuild -create-xcframework \
        -library "${final_archive}" \
        -headers "${headers_dir}" \
        -output "${final_xcframework}"

    log_step "Audit MAS compliance and symbol boundary..."
    audit_compliance "${final_archive}"

    log_step "Successfully packaged: ${final_xcframework}"
    local size_mb
    size_mb="$(du -sh "${final_xcframework}" | awk '{print $1}')"
    log_info "Total XCFramework size: ${size_mb}"
}

# -----------------------------------------------------------------------------
# MAS and Sandbox Compliance Audit
# -----------------------------------------------------------------------------
audit_compliance() {
    local archive="$1"
    log_info "Auditing static archive symbols for GPL / JIT violations..."

    # Check for LuaJIT symbols
    if nm -gU "${archive}" 2>/dev/null | grep -q "luaL_newstate"; then
        log_error "Audit failed: Lua / LuaJIT symbols detected in archive! Violates MAS W^X Hardened Runtime."
        exit 1
    fi

    # Check for GPL x264 / x265 symbols
    if nm -gU "${archive}" 2>/dev/null | grep -E -q "x264_encoder_open|x265_encoder_open"; then
        log_error "Audit failed: GPL encoder symbols detected in archive! Violates LGPL compliance."
        exit 1
    fi

    log_info "✅ Compliance audit passed: Zero LuaJIT JIT pages, Zero GPL encoder symbols."
}

# -----------------------------------------------------------------------------
# Main Execution Entry Point
# -----------------------------------------------------------------------------
main() {
    log_step "TTZip MPVKit.xcframework Static Build Pipeline Started."

    validate_toolchain
    setup_directories
    acquire_all_sources

    case "${TARGET_ARCH}" in
        arm64)
            build_slice "arm64"
            ;;
        x86_64)
            build_slice "x86_64"
            ;;
        universal)
            build_slice "arm64"
            build_slice "x86_64"
            ;;
        *)
            log_error "Invalid architecture: ${TARGET_ARCH}"
            exit 1
            ;;
    esac

    assemble_headers
    package_xcframework

    log_step "Pipeline finished successfully."
}

main "$@"
