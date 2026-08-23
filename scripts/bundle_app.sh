#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
#
# Builds and bundles TTZip.app for macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "======================================================================"
echo "🍎 Building and Bundling TTZip.app Native Desktop Application"
echo "======================================================================"

cd "${REPO_ROOT}"

echo "--> [1/4] Compiling TTZipApp via Swift Package Manager in release mode..."
swift build -c release --product TTZipApp

BIN_PATH="$(swift build -c release --show-bin-path)/TTZipApp"
DIST_DIR="${REPO_ROOT}/dist"
APP_DIR="${DIST_DIR}/TTZip.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "--> [2/4] Assembling .app bundle directory structure..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Copy Binary
cp "${BIN_PATH}" "${MACOS_DIR}/TTZip"
chmod +x "${MACOS_DIR}/TTZip"

# Copy Info.plist
cp "${REPO_ROOT}/Sources/TTZipApp/Info.plist" "${CONTENTS_DIR}/Info.plist"

# Copy AppIcon.icns
if [ -f "${REPO_ROOT}/Resources/AppIcon.icns" ]; then
    cp "${REPO_ROOT}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

# Copy PkgInfo
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

echo "--> [3/4] Performing ad-hoc code signing..."
codesign --force --deep --sign - "${APP_DIR}"

echo "--> [4/4] Verifying .app bundle integrity..."
codesign --verify --deep --strict "${APP_DIR}"

echo "======================================================================"
echo "✅ Successfully bundled: ${APP_DIR}"
echo "======================================================================"
