#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: High-performance native archiving and compression engine.

# Generates Sparkle 2.0 appcast.xml feed for automated updates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION="1.0.0"
BUILD_NUM="10000"
DMG_PATH="${REPO_ROOT}/dist/TTZip-${VERSION}.dmg"
APPCAST_PATH="${REPO_ROOT}/appcast.xml"
RELEASE_URL="https://github.com/wittkung/ttzip-apple/releases/download/v${VERSION}/TTZip-${VERSION}.dmg"

if [ ! -f "${DMG_PATH}" ]; then
    echo "==> DMG not found at ${DMG_PATH}, building..."
    "${SCRIPT_DIR}/create_dmg_installer.sh"
fi

DMG_LEN="$(stat -f%z "${DMG_PATH}")"
PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

# Generate Sparkle 2.0 appcast.xml
cat <<EOF > "${APPCAST_PATH}"
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>TTZip Changelog &amp; Updates</title>
        <link>https://github.com/wittkung/ttzip-apple</link>
        <description>Most recent changes with links to updates.</description>
        <language>en</language>
        <item>
            <title>TTZip Version ${VERSION}</title>
            <sparkle:releaseNotesLink>https://raw.githubusercontent.com/wittkung/ttzip-apple/main/RELEASE_NOTES.md</sparkle:releaseNotesLink>
            <pubDate>${PUB_DATE}</pubDate>
            <enclosure
                url="${RELEASE_URL}"
                sparkle:version="${BUILD_NUM}"
                sparkle:shortVersionString="${VERSION}"
                length="${DMG_LEN}"
                type="application/octet-stream"
            />
        </item>
    </channel>
</rss>
EOF

echo "======================================================================"
echo "✅ Generated Sparkle 2.0 Feed: ${APPCAST_PATH}"
echo "======================================================================"
