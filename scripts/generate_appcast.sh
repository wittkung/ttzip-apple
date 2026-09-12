#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# TTZip: High-performance native archiving and compression engine.

# ==============================================================================
# scripts/generate_appcast.sh
# Generates Sparkle 2.0 appcast.xml feed with Ed25519 signatures and delta updates.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFO_PLIST="${REPO_ROOT}/Sources/TTZipApp/Info.plist"

# Defaults
VERSION=""
BUILD_NUM=""
DMG_PATH=""
DELTA_PATH=""
OUTPUT_APPCAST="${REPO_ROOT}/appcast.xml"
KEY_FILE="${SPARKLE_PRIVATE_KEY_PATH:-${SPARKLE_KEY_FILE:-${HOME}/.sparkle/ttzip_ed25519.pem}}"
BASE_URL="https://github.com/wittkung/ttzip-apple/releases/download"

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="$2"; shift 2 ;;
        --build-num)
            BUILD_NUM="$2"; shift 2 ;;
        --dmg)
            DMG_PATH="$2"; shift 2 ;;
        --delta)
            DELTA_PATH="$2"; shift 2 ;;
        --output)
            OUTPUT_APPCAST="$2"; shift 2 ;;
        --key-file)
            KEY_FILE="$2"; shift 2 ;;
        --download-base-url)
            BASE_URL="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--version <ver>] [--build-num <num>] [--dmg <path>] [--delta <path>] [--key-file <path>] [--output <path>]"
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Resolve version & build number from Info.plist if not specified
if [ -z "${VERSION}" ] && [ -f "${INFO_PLIST}" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${INFO_PLIST}" 2>/dev/null || echo "0.1.0")"
fi
VERSION="${VERSION:-0.1.0}"

if [ -z "${BUILD_NUM}" ] && [ -f "${INFO_PLIST}" ]; then
    BUILD_NUM="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${INFO_PLIST}" 2>/dev/null || echo "1000")"
fi
BUILD_NUM="${BUILD_NUM:-1000}"

# Resolve DMG path
if [ -z "${DMG_PATH}" ]; then
    if [ -f "${REPO_ROOT}/dist/TTZip-${VERSION}.dmg" ]; then
        DMG_PATH="${REPO_ROOT}/dist/TTZip-${VERSION}.dmg"
    elif [ -f "${REPO_ROOT}/build/dist/TTZip-${VERSION}.dmg" ]; then
        DMG_PATH="${REPO_ROOT}/build/dist/TTZip-${VERSION}.dmg"
    else
        DMG_PATH="${REPO_ROOT}/dist/TTZip-${VERSION}.dmg"
    fi
fi

if [ ! -f "${DMG_PATH}" ]; then
    echo "==> DMG not found at ${DMG_PATH}. Attempting build via create_dmg_installer.sh..."
    "${SCRIPT_DIR}/create_dmg_installer.sh" || true
fi

if [ ! -f "${DMG_PATH}" ]; then
    echo "Error: DMG file not found at ${DMG_PATH}." >&2
    exit 1
fi

DMG_LEN="$(stat -f%z "${DMG_PATH}")"
PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
RELEASE_URL="${BASE_URL}/v${VERSION}/$(basename "${DMG_PATH}")"

# Resolve Sparkle sign_update binary
SIGN_UPDATE_BIN=""
CANDIDATE_PATHS=(
    "${REPO_ROOT}/.build/artifacts/sparkle/Sparkle/bin/sign_update"
    "${REPO_ROOT}/vendor/Sparkle/bin/sign_update"
    "${REPO_ROOT}/vendor/Sparkle/sign_update"
)
for candidate in "${CANDIDATE_PATHS[@]}"; do
    if [ -x "${candidate}" ]; then
        SIGN_UPDATE_BIN="${candidate}"
        break
    fi
done

if [ -z "${SIGN_UPDATE_BIN}" ]; then
    SIGN_UPDATE_BIN="$(which sign_update 2>/dev/null || true)"
fi

# Calculate Ed25519 signature
ED_SIG=""
if [ -n "${SIGN_UPDATE_BIN}" ] && [ -x "${SIGN_UPDATE_BIN}" ]; then
    if [ -f "${KEY_FILE}" ]; then
        echo "==> Signing DMG using key: ${KEY_FILE}"
        ED_SIG="$("${SIGN_UPDATE_BIN}" -f "${KEY_FILE}" -p "${DMG_PATH}")"
    else
        echo "==> Signing DMG using macOS Keychain..."
        ED_SIG="$("${SIGN_UPDATE_BIN}" -p "${DMG_PATH}" 2>/dev/null || true)"
    fi
fi

if [ -z "${ED_SIG}" ]; then
    echo "⚠️ Warning: Could not compute Ed25519 signature. (sign_update missing or key unavailable)." >&2
    echo "⚠️ Falling back to placeholder signature for development/testing." >&2
    ED_SIG="DEVELOPMENT_MODE_UNSIGNED_ED25519_PLACEHOLDER"
fi

# Delta update section if delta file exists
DELTA_XML=""
if [ -n "${DELTA_PATH}" ] && [ -f "${DELTA_PATH}" ]; then
    DELTA_LEN="$(stat -f%z "${DELTA_PATH}")"
    DELTA_URL="${BASE_URL}/v${VERSION}/$(basename "${DELTA_PATH}")"
    DELTA_SIG=""
    if [ -n "${SIGN_UPDATE_BIN}" ] && [ -x "${SIGN_UPDATE_BIN}" ] && [ -f "${KEY_FILE}" ]; then
        DELTA_SIG="$("${SIGN_UPDATE_BIN}" -f "${KEY_FILE}" -p "${DELTA_PATH}")"
    fi
    DELTA_XML=$(cat <<EOF
            <sparkle:deltas>
                <enclosure
                    url="${DELTA_URL}"
                    sparkle:version="${BUILD_NUM}"
                    sparkle:shortVersionString="${VERSION}"
                    sparkle:edSignature="${DELTA_SIG}"
                    sparkle:minimumSystemVersion="14.0"
                    length="${DELTA_LEN}"
                    type="application/octet-stream"
                />
            </sparkle:deltas>
EOF
)
fi

# Render Sparkle 2.0 appcast.xml
mkdir -p "$(dirname "${OUTPUT_APPCAST}")"
cat <<EOF > "${OUTPUT_APPCAST}"
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
                sparkle:edSignature="${ED_SIG}"
                sparkle:minimumSystemVersion="14.0"
                length="${DMG_LEN}"
                type="application/octet-stream"
            />
${DELTA_XML}
        </item>
    </channel>
</rss>
EOF

echo "======================================================================"
echo "✅ Generated Sparkle 2.0 Feed: ${OUTPUT_APPCAST}"
echo "   Version: ${VERSION} (Build ${BUILD_NUM})"
echo "   Payload: ${DMG_PATH} (${DMG_LEN} bytes)"
echo "   Ed25519: ${ED_SIG}"
echo "======================================================================"
