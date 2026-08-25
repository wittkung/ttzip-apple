// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import WebKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(subsystem: "com.ttzip.app", category: "URLSchemeHandler")

/// High-performance zero-network scheme handler serving local React 19 web assets.
public final class TTZipURLSchemeHandler: NSObject, WKURLSchemeHandler {
    private let distFolderURL: URL?

    public init(distFolderURL: URL? = nil) {
        self.distFolderURL = distFolderURL
        super.init()
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "TTZipSchemeError", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        var relativePath = requestURL.path
        if relativePath.isEmpty || relativePath == "/" {
            relativePath = "index.html"
        } else if relativePath.hasPrefix("/") {
            relativePath = String(relativePath.dropFirst())
        }

        guard let fileURL = resolveAssetFileURL(relativePath: relativePath) else {
            logger.error("404 File Not Found for scheme request: \(relativePath, privacy: .public)")
            urlSchemeTask.didFailWithError(NSError(domain: "TTZipSchemeError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Asset \(relativePath) not found"]))
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let mimeType = mimeTypeForPath(fileURL.path)
            let response = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "\(mimeType); charset=utf-8",
                    "Content-Length": String(data.count),
                    "Cache-Control": "no-cache",
                    "Access-Control-Allow-Origin": "*"
                ]
            )!

            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            logger.error("Failed to read asset data for: \(fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            urlSchemeTask.didFailWithError(error)
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No-op for synchronous local disk reads
    }

    private func resolveAssetFileURL(relativePath: String) -> URL? {
        let candidates = candidateDirectories()
        for dir in candidates {
            let target = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: target.path) {
                return target
            }
        }
        return nil
    }

    private func candidateDirectories() -> [URL] {
        var dirs: [URL] = []
        if let explicit = distFolderURL {
            dirs.append(explicit)
        }

        if let resURL = Bundle.main.resourceURL {
            dirs.append(resURL.appendingPathComponent("dist"))
            dirs.append(resURL.appendingPathComponent("TTZipApp_TTZipApp.bundle/dist"))
        }

        dirs.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/dist"))

        let srcDist = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/dist")
        dirs.append(srcDist)

        let frontendDist = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("frontend/dist")
        dirs.append(frontendDist)

        return dirs
    }

    private func mimeTypeForPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
