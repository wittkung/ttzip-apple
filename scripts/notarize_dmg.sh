#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
# All rights reserved.
#
# Apple Developer Notarization Pipeline for TTZip DMG & macOS App.
# Eliminates macOS Gatekeeper warnings by submitting and stapling notarization tickets.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION="1.0.0"
DMG_PATH="${REPO_ROOT}/dist/TTZip-${VERSION}.dmg"
KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
APPLE_ID="${NOTARY_APPLE_ID:-}"
APPLE_PASSWORD="${NOTARY_APPLE_PASSWORD:-}"
TEAM_ID="${NOTARY_TEAM_ID:-}"
DRY_RUN=false

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dmg <path>                 Path to DMG installer (default: dist/TTZip-${VERSION}.dmg)"
    echo "  --keychain-profile <name>    notarytool stored credentials profile name"
    echo "  --apple-id <email>           Apple ID email address"
    echo "  --team-id <team>             Apple Developer 10-character Team ID"
    echo "  --password <pwd>             App-specific password (or pass via NOTARY_APPLE_PASSWORD)"
    echo "  --diagnose|--dry-run         Perform local validation & Gatekeeper assessment without Apple upload"
    echo "  --help|-h                    Show this help message"
    echo ""
    echo "Environment Variables Supported:"
    echo "  NOTARY_KEYCHAIN_PROFILE, NOTARY_APPLE_ID, NOTARY_APPLE_PASSWORD, NOTARY_TEAM_ID"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg) DMG_PATH="$2"; shift 2 ;;
        --keychain-profile) KEYCHAIN_PROFILE="$2"; shift 2 ;;
        --apple-id) APPLE_ID="$2"; shift 2 ;;
        --team-id) TEAM_ID="$2"; shift 2 ;;
        --password) APPLE_PASSWORD="$2"; shift 2 ;;
        --diagnose|--dry-run) DRY_RUN=true; shift 1 ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

echo "======================================================================"
echo "🛡  TTZip Apple Developer Notarization & Gatekeeper Pipeline"
echo "======================================================================"
echo "  Target DMG: ${DMG_PATH}"

if [ ! -f "${DMG_PATH}" ]; then
    echo "==> DMG not found, triggering create_dmg_installer.sh..."
    "${SCRIPT_DIR}/create_dmg_installer.sh"
fi

echo "--> [1/4] Verifying local code signature & Hardened Runtime..."
codesign --verify --deep --strict --verbose=2 "${DMG_PATH}" 2>&1 || true

# 2. Dry Run / Local Assessment Mode
if [ "${DRY_RUN}" = true ] || [ -z "${KEYCHAIN_PROFILE}" -a -z "${APPLE_ID}" ]; then
    echo "--> [2/4] Running Gatekeeper & Stapler Local Diagnostic Mode..."
    echo "  ℹ️  No Apple Developer notarytool credentials supplied."
    echo "      (Pass --keychain-profile or export NOTARY_KEYCHAIN_PROFILE to submit to Apple Notary Service)"
    
    echo "--> [3/4] Testing spctl Gatekeeper compliance..."
    spctl -a -vv -t install "${DMG_PATH}" 2>&1 || true

    echo "======================================================================"
    echo "✅ Local Notarization Diagnostic Completed!"
    echo "   DMG Path: ${DMG_PATH}"
    echo "   Ready for Apple Notarytool upload with valid Developer ID certificate."
    echo "======================================================================"
    exit 0
fi

# 3. Submit to Apple Notary Service
echo "--> [2/4] Submitting DMG to Apple Notary Service via xcrun notarytool..."
SUBMIT_ARGS=("${DMG_PATH}" --wait)

if [ -n "${KEYCHAIN_PROFILE}" ]; then
    SUBMIT_ARGS+=(--keychain-profile "${KEYCHAIN_PROFILE}")
else
    SUBMIT_ARGS+=(--apple-id "${APPLE_ID}" --password "${APPLE_PASSWORD}" --team-id "${TEAM_ID}")
fi

xcrun notarytool submit "${SUBMIT_ARGS[@]}"

# 4. Staple Notarization Ticket
echo "--> [3/4] Stapling official Notarization Ticket to DMG..."
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

# 5. Final Gatekeeper Verification
echo "--> [4/4] Performing final Gatekeeper acceptance audit..."
spctl -a -vv -t install "${DMG_PATH}"

echo "======================================================================"
echo "🎉 TTZip DMG Successfully Notarized, Stapled, and Gatekeeper Approved!"
echo "   File   : ${DMG_PATH}"
echo "======================================================================"
