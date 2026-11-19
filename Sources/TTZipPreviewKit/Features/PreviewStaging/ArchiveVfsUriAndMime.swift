// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CryptoKit
import Foundation
import TTZipArchiveContract

extension TTZipArchiveVfsProvider {
    public func parseVfsUri(_ uri: String) -> (archiveId: String, entryPath: String)? {
        guard let url = URL(string: uri), url.scheme == ArchiveVfs.scheme else {
            return nil
        }

        guard let rawHost = url.host, !rawHost.isEmpty else { return nil }
        let host = (rawHost.removingPercentEncoding ?? rawHost).lowercased()
        let rawPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        let normalizedPath = Self.normalizePath(decodedPath)
        return (host, normalizedPath)
    }

    public static func makeArchiveId(from archivePath: String) -> String {
        let digest = SHA256.hash(data: Data(archivePath.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()

        let lastComponent = (archivePath as NSString).lastPathComponent
        var asciiScalars = String.UnicodeScalarView()
        for scalar in lastComponent.unicodeScalars where scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) {
            asciiScalars.append(scalar)
        }
        let rawPrefix = String(asciiScalars).prefix(12)
        let prefix = rawPrefix.isEmpty ? "arc" : String(rawPrefix)

        return "\(prefix)_\(hex)".lowercased()
    }

    public static func normalizePath(_ path: String) -> String {
        var clean = path.replacingOccurrences(of: "\\", with: "/")
        while clean.hasPrefix("/") { clean.removeFirst() }
        var parts: [String] = []
        for segment in clean.split(separator: "/") {
            if segment == "." || segment.isEmpty { continue }
            if segment == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(segment))
            }
        }
        return parts.joined(separator: "/")
    }

    private static let mimeTypeByExtension: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "xhtml": "application/xhtml+xml; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "application/javascript; charset=utf-8",
        "mjs": "application/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "xml": "application/xml; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "pdf": "application/pdf",
        "epub": "application/epub+zip",
        "mp4": "video/mp4",
        "webm": "video/webm",
        "mov": "video/quicktime",
        "mkv": "video/x-matroska",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "m4a": "audio/mp4",
        "aac": "audio/mp4",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "txt": "text/plain; charset=utf-8",
        "md": "text/plain; charset=utf-8"
    ]

    public static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return mimeTypeByExtension[ext] ?? "application/octet-stream"
    }
}
