#!/usr/bin/env bash
# Copyright 2026 MetastudyLine. All rights reserved.
# SPDX-License-Identifier: MIT OR Apache-2.0

# Builds the TTMediaWorker XPC service and assembles it into a `.xpc` bundle.
#
# The service source ships with the vendored media package, so this repository
# builds it with the native Swift toolchain: SwiftPM compiles the
# `TTMediaWorkerService` executable and this script wraps it into the
# `TTMediaWorker.xpc` bundle that `scripts/bundle_app.sh` embeds into the app.
#
# Only the bundle path is written to stdout; every progress message goes to
# stderr, so the caller can capture the path with `$(...)`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MEDIA_PACKAGE="${REPO_ROOT}/vendor/ttmedia"
SERVICE_SOURCE_DIR="${MEDIA_PACKAGE}/Sources/TTMediaWorkerService"
SERVICE_PRODUCT="TTMediaWorkerService"
BUNDLE_NAME="TTMediaWorker"
BUNDLE_IDENTIFIER="${TTMEDIA_XPC_BUNDLE_IDENTIFIER:-com.metastudyline.ttzip.media-worker}"
CONFIGURATION="${TTMEDIA_XPC_BUILD_CONFIG:-release}"
OUT_DIR="${TTMEDIA_XPC_OUT_DIR:-${REPO_ROOT}/dist}"

set_plist_value() {
    local plist="$1"
    local key="$2"
    local value="$3"
    /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${plist}" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "${plist}" >/dev/null 2>&1 \
        || {
            echo "Failed to write ${key} into ${plist}" >&2
            exit 1
        }
}

if [ ! -d "${MEDIA_PACKAGE}" ]; then
    echo "Missing the vendored media package: ${MEDIA_PACKAGE}" >&2
    exit 1
fi

if [ ! -d "${MEDIA_PACKAGE}/Frameworks/TTMediaVendor.xcframework" ]; then
    echo "Missing the prebuilt media engine framework: ${MEDIA_PACKAGE}/Frameworks/TTMediaVendor.xcframework" >&2
    exit 1
fi

echo "--> Building the ${BUNDLE_NAME} XPC service [${CONFIGURATION}]..." >&2
swift build \
    --package-path "${MEDIA_PACKAGE}" \
    --configuration "${CONFIGURATION}" \
    --product "${SERVICE_PRODUCT}" >&2

SERVICE_BIN="${MEDIA_PACKAGE}/.build/${CONFIGURATION}/${SERVICE_PRODUCT}"
if [ ! -f "${SERVICE_BIN}" ]; then
    SERVICE_BIN="$(find "${MEDIA_PACKAGE}/.build" -type f -name "${SERVICE_PRODUCT}" 2>/dev/null | head -n 1 || true)"
fi
if [ -z "${SERVICE_BIN}" ] || [ ! -f "${SERVICE_BIN}" ]; then
    echo "swift build did not produce ${SERVICE_PRODUCT} under ${MEDIA_PACKAGE}/.build" >&2
    exit 1
fi

BUNDLE_DIR="${OUT_DIR}/${BUNDLE_NAME}.xpc"
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS" "${BUNDLE_DIR}/Contents/Resources"
cp -f "${SERVICE_BIN}" "${BUNDLE_DIR}/Contents/MacOS/${BUNDLE_NAME}"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/${BUNDLE_NAME}"
cp -f "${SERVICE_SOURCE_DIR}/Info.plist" "${BUNDLE_DIR}/Contents/Info.plist"
cp -f "${SERVICE_SOURCE_DIR}/PrivacyInfo.xcprivacy" "${BUNDLE_DIR}/Contents/Resources/PrivacyInfo.xcprivacy"

# SwiftPM compiles the media resources into a bundle next to the executable and
# the service resolves them through `Bundle.module` at runtime.
for resource_bundle in "${MEDIA_PACKAGE}/.build/${CONFIGURATION}"/TTMediaKit_*.bundle; do
    if [ -d "${resource_bundle}" ]; then
        cp -Rf "${resource_bundle}" "${BUNDLE_DIR}/Contents/Resources/"
    fi
done

set_plist_value "${BUNDLE_DIR}/Contents/Info.plist" "CFBundleIdentifier" "${BUNDLE_IDENTIFIER}"
set_plist_value "${BUNDLE_DIR}/Contents/Info.plist" "CFBundleExecutable" "${BUNDLE_NAME}"
set_plist_value "${BUNDLE_DIR}/Contents/Info.plist" "CFBundleName" "${BUNDLE_NAME}"
set_plist_value "${BUNDLE_DIR}/Contents/Info.plist" "CFBundlePackageType" "XPC!"

echo "${BUNDLE_DIR}"
