#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: High-performance native archiving and compression engine.

set -euo pipefail

WORKSPACE_DIR="${BUILD_WORKSPACE_DIRECTORY:-$(pwd)}"
APPLE_DIR="${WORKSPACE_DIR}/products/ttzip/apple"

VERSION="0.1.0"
INFO_PLIST="${APPLE_DIR}/Sources/TTZipApp/Info.plist"
if [ -f "${INFO_PLIST}" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}" 2>/dev/null || echo "0.1.0")"
fi
DMG_PATH="${APPLE_DIR}/dist/TTZip-${VERSION}.dmg"

if [ ! -f "${DMG_PATH}" ]; then
    echo "==> DMG not found at ${DMG_PATH}, invoking release_dmg..."
    "${APPLE_DIR}/scripts/bazel_release_dmg.sh"
fi

"${APPLE_DIR}/scripts/notarize_dmg.sh" --dmg "${DMG_PATH}" "$@"
