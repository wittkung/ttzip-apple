#!/usr/bin/env bash
# Copyright 2026 MetastudyLine. All rights reserved.
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Builds `TTMediaVendor.xcframework`, the prebuilt media engine that the
# outbound `ttzip-apple` projection ships for the vendored `ttmedia` package.
#
# The vendored Swift package links the Rust engine through a `binaryTarget`,
# so the static library has to exist before the projection runs. Bazel builds
# the same code from source; this script exists for the standalone SwiftPM
# projection, which has no Bazel.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEDIA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${MEDIA_DIR}/Frameworks/TTMediaVendor.xcframework"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
TARGET="${TTMEDIA_TARGET:-aarch64-apple-darwin}"

echo "--> Building the ttmedia engine for ${TARGET} (macOS ${DEPLOYMENT_TARGET})"
cd "${MEDIA_DIR}"
MACOSX_DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET}" \
    cargo build --release --target "${TARGET}" --lib

STATIC_LIB="${MEDIA_DIR}/target/${TARGET}/release/libttmedia.a"
if [[ ! -f "${STATIC_LIB}" ]]; then
    echo "error: cargo did not produce ${STATIC_LIB}" >&2
    exit 1
fi

echo "--> Stripping the static library"
STRIPPED_LIB="$(mktemp -t ttmedia-lib)"
trap 'rm -f "${STRIPPED_LIB}"' EXIT
cp "${STATIC_LIB}" "${STRIPPED_LIB}"
strip -S "${STRIPPED_LIB}" 2>/dev/null || true

echo "--> Assembling ${OUTPUT_DIR}"
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}/macos-arm64/Headers"
cp "${STRIPPED_LIB}" "${OUTPUT_DIR}/macos-arm64/libttmedia.a"
cp "${MEDIA_DIR}/include/ttmedia.h" "${OUTPUT_DIR}/macos-arm64/Headers/ttmedia.h"
cp "${MEDIA_DIR}/include/ttmedia_demux.h" "${OUTPUT_DIR}/macos-arm64/Headers/ttmedia_demux.h"
cp "${MEDIA_DIR}/include/empty.c" "${OUTPUT_DIR}/macos-arm64/Headers/empty.c"
cp "${MEDIA_DIR}/include/module.modulemap" "${OUTPUT_DIR}/macos-arm64/Headers/module.modulemap"

cat >"${OUTPUT_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>libttmedia.a</string>
			<key>HeadersPath</key>
			<string>Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64</string>
			<key>LibraryPath</key>
			<string>libttmedia.a</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST

echo "--> Built ${OUTPUT_DIR}"
