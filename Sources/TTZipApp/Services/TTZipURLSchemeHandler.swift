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

/// Custom WKURLSchemeHandler serving static React/Vite web assets from App Bundle directly via `ttzip-app://`.
public final class TTZipURLSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let primaryFolderURL: URL
    private static let logger = Logger(subsystem: "com.ttzip.app", category: "URLSchemeHandler")
    
    public init(distFolderURL: URL) {
        self.primaryFolderURL = distFolderURL
        super.init()
    }
    
    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        
        var relativePath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if relativePath.isEmpty {
            relativePath = "index.html"
        }
        
        let fm = FileManager.default
        let searchDirectories = Self.candidateDirectories(primary: primaryFolderURL)
        
        // 1. Direct file lookup
        for dir in searchDirectories {
            let fileURL = dir.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: fileURL.path),
               let data = try? Data(contentsOf: fileURL) {
                let ext = fileURL.pathExtension.lowercased()
                let mimeType = Self.mimeType(for: ext)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "\(mimeType); charset=utf-8",
                        "Access-Control-Allow-Origin": "*",
                        "Cache-Control": "max-age=31536000, immutable"
                    ]
                )!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                return
            }
        }
        
        // 2. SPA Fallback to index.html
        for dir in searchDirectories {
            let indexURL = dir.appendingPathComponent("index.html")
            if fm.fileExists(atPath: indexURL.path),
               let indexData = try? Data(contentsOf: indexURL) {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "text/html; charset=utf-8",
                        "Access-Control-Allow-Origin": "*"
                    ]
                )!
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(indexData)
                urlSchemeTask.didFinish()
                return
            }
        }
        
        Self.logger.error("Asset not found for path: \(relativePath, privacy: .public)")
        urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
    }
    
    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    
    public static func candidateDirectories(primary: URL) -> [URL] {
        var dirs: [URL] = [primary]
        let fm = FileManager.default
        
        if let resURL = Bundle.main.resourceURL {
            dirs.append(resURL.appendingPathComponent("dist"))
            dirs.append(resURL.appendingPathComponent("TTZipApp_TTZipApp.bundle/dist"))
            dirs.append(resURL)
        }
        
        dirs.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/dist"))
        dirs.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/TTZipApp_TTZipApp.bundle/dist"))
        
        #if DEBUG
        // Development path fallbacks
        let devPaths = [
            "/Users/kevintung/Documents/dev/products/ttzip/apple/Sources/TTZipApp/Resources/dist",
            "/Users/kevintung/Documents/dev/products/ttzip/frontend/dist"
        ]
        for p in devPaths {
            dirs.append(URL(fileURLWithPath: p))
        }
        #endif
        
        return dirs.filter { fm.fileExists(atPath: $0.path) }
    }
    
    private static func mimeType(for ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        default:
            return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
