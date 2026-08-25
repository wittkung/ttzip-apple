// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import WebKit
import UniformTypeIdentifiers

/// Custom WKURLSchemeHandler serving static React/Vite web assets from App Bundle directly via `ttzip-app://`.
public final class TTZipURLSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let baseBundleURL: URL
    
    public init(distFolderURL: URL) {
        self.baseBundleURL = distFolderURL
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
        
        let fileURL = baseBundleURL.appendingPathComponent(relativePath)
        
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL) {
            let ext = fileURL.pathExtension
            let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
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
        
        // SPA Fallback to index.html for virtual routes
        let indexURL = baseBundleURL.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: indexURL.path),
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
        } else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
        }
    }
    
    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
