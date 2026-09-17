#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: High-performance native archiving and compression engine.

set -euo pipefail

WORKSPACE_DIR="${BUILD_WORKSPACE_DIRECTORY:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="${WORKSPACE_DIR}/products/ttzip/apple"

echo "======================================================================"
echo "🍏 Bazel Release DMG Packaging Pipeline for TTZip"
echo "======================================================================"

# Locate application bundle or zip produced by Bazel
APP_BUNDLE=""
ZIP_PATH=""
UNPACK_DIR=""

cleanup() {
    if [ -n "${UNPACK_DIR}" ] && [ -d "${UNPACK_DIR}" ]; then
        rm -rf "${UNPACK_DIR}"
    fi
}
trap cleanup EXIT

# 1. Inspect Bazel Runfiles
RUNFILES="${RUNFILES_DIR:-}"
if [ -z "$RUNFILES" ] && [ -d "${0}.runfiles" ]; then
    RUNFILES="${0}.runfiles"
fi

if [ -n "$RUNFILES" ]; then
    for candidate_zip in \
        "${RUNFILES}/_main/products/ttzip/apple/TTZipApp.zip" \
        "${RUNFILES}/products/ttzip/apple/TTZipApp.zip"; do
        if [ -f "$candidate_zip" ]; then
            ZIP_PATH="$candidate_zip"
            break
        fi
    done
fi

# 2. Inspect bazel-bin / bazel-out if not in runfiles
if [ -z "$ZIP_PATH" ]; then
    if [ -f "${WORKSPACE_DIR}/bazel-bin/products/ttzip/apple/TTZipApp.zip" ]; then
        ZIP_PATH="${WORKSPACE_DIR}/bazel-bin/products/ttzip/apple/TTZipApp.zip"
    else
        FOUND_ZIP="$(find -L "${WORKSPACE_DIR}/bazel-out" -maxdepth 8 -name "TTZipApp.zip" -type f 2>/dev/null | head -n 1)"
        if [ -n "$FOUND_ZIP" ] && [ -f "$FOUND_ZIP" ]; then
            ZIP_PATH="$FOUND_ZIP"
        fi
    fi
fi

# 3. Unpack zip if located
if [ -n "$ZIP_PATH" ] && [ -f "$ZIP_PATH" ]; then
    UNPACK_DIR="/tmp/ttzip_bazel_release_$$"
    mkdir -p "$UNPACK_DIR"
    echo "  ==> Unpacking Bazel bundle from ${ZIP_PATH}..."
    unzip -q -o "$ZIP_PATH" -d "$UNPACK_DIR"
    for app_cand in \
        "${UNPACK_DIR}/TTZip.app" \
        "${UNPACK_DIR}/TTZipApp.app"; do
        if [ -d "$app_cand" ]; then
            APP_BUNDLE="$app_cand"
            break
        fi
    done
    if [ -z "$APP_BUNDLE" ]; then
        APP_BUNDLE="$(find "$UNPACK_DIR" -maxdepth 2 -name "*.app" | head -n 1)"
    fi
fi

# 4. Fallback to existing unzipped app bundles in bazel-out or bazel-bin
if [ -z "$APP_BUNDLE" ] || [ ! -d "$APP_BUNDLE" ]; then
    CANDIDATES=(
        "${WORKSPACE_DIR}/bazel-bin/products/ttzip/apple/TTZipApp_archive-root/TTZip.app"
        "${WORKSPACE_DIR}/bazel-bin/products/ttzip/apple/TTZipApp_archive-root/TTZipApp.app"
        "${WORKSPACE_DIR}/bazel-bin/products/ttzip/apple/TTZip.app"
        "${WORKSPACE_DIR}/bazel-bin/products/ttzip/apple/TTZipApp.app"
        "${APPLE_DIR}/dist/TTZip.app"
    )
    for candidate in "${CANDIDATES[@]}"; do
        if [ -d "$candidate" ]; then
            APP_BUNDLE="$candidate"
            break
        fi
    done
fi

if [ -z "$APP_BUNDLE" ] || [ ! -d "$APP_BUNDLE" ]; then
    FOUND_APP="$(find -L "${WORKSPACE_DIR}/bazel-out" -maxdepth 8 \( -name "TTZip.app" -o -name "TTZipApp.app" \) -type d 2>/dev/null | head -n 1)"
    if [ -n "$FOUND_APP" ] && [ -d "$FOUND_APP" ]; then
        APP_BUNDLE="$FOUND_APP"
    fi
fi

if [ -z "$APP_BUNDLE" ] || [ ! -d "$APP_BUNDLE" ]; then
    echo "❌ Error: TTZip.app / TTZipApp.app bundle not found in Bazel output or runfiles."
    exit 1
fi

echo "  ✓ Found application bundle: ${APP_BUNDLE}"

# If bundle is named TTZipApp.app, standardize to TTZip.app in a temporary directory for DMG packaging
FINAL_APP_PATH="${APP_BUNDLE}"
if [ "$(basename "${APP_BUNDLE}")" != "TTZip.app" ]; then
    STANDARDIZED_DIR="/tmp/ttzip_dmg_stage_$$"
    mkdir -p "${STANDARDIZED_DIR}"
    cp -R "${APP_BUNDLE}" "${STANDARDIZED_DIR}/TTZip.app"
    FINAL_APP_PATH="${STANDARDIZED_DIR}/TTZip.app"
    trap 'rm -rf "${UNPACK_DIR}" "${STANDARDIZED_DIR}"' EXIT
fi

DIST_DIR="${APPLE_DIR}/dist"
mkdir -p "${DIST_DIR}"

VERSION="0.1.0"
if [ -f "${FINAL_APP_PATH}/Contents/Info.plist" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${FINAL_APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "0.1.0")"
fi
OUTPUT_DMG="${DIST_DIR}/TTZip-${VERSION}.dmg"

"${APPLE_DIR}/scripts/create_dmg_installer.sh" \
    --app "${FINAL_APP_PATH}" \
    --output "${OUTPUT_DMG}" \
    --background "${APPLE_DIR}/Resources/dmg_background.png" \
    "$@"
