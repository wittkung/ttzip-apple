// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import WebKit
import TTZipCore
import AppKit

@MainActor
public final class TTZipBridgeRouter: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?

    public init(webView: WKWebView? = nil) {
        self.webView = webView
        super.init()
    }

    public func setWebView(_ webView: WKWebView) {
        self.webView = webView
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "ttzipBridge",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            return
        }

        let params = body["params"] as? [String: Any] ?? [:]
        let requestId = body["requestId"] as? String

        Task {
            do {
                let result = try await handleAction(action, params: params)
                sendSuccess(requestId: requestId, result: result)
            } catch {
                sendError(requestId: requestId, error: error.localizedDescription)
            }
        }
    }

    private func handleAction(_ action: String, params: [String: Any]) async throws -> Any {
        switch action {
        case "scanDisk":
            let rawPath = params["path"] as? String ?? NSHomeDirectory()
            let path = rawPath == "~" ? NSHomeDirectory() : rawPath
            let entries = try scanDirectory(path: path, maxDepth: 1)
            let items: [[String: Any]] = entries.map { entry in
                [
                    "path": entry.path,
                    "name": entry.name,
                    "isDirectory": entry.isDirectory,
                    "size": entry.size,
                    "mtime": entry.mtimeEpochSecs
                ]
            }
            return ["items": items]

        case "autocompleteDisk":
            let prefix = params["prefix"] as? String ?? ""
            let suggestions = autocompleteDiskPath(rawInput: prefix, baseDirectory: NSHomeDirectory(), maxResults: 10)
            return ["suggestions": suggestions]

        case "openArchive":
            let dummyEntries: [[String: Any]] = [
                [
                    "path": "source/main.rs",
                    "name": "main.rs",
                    "uncompressedSize": 4096,
                    "compressedSize": 1024,
                    "isDirectory": false,
                    "isEncrypted": false,
                    "modifiedTime": Int(Date().timeIntervalSince1970)
                ],
                [
                    "path": "docs/readme.md",
                    "name": "readme.md",
                    "uncompressedSize": 8192,
                    "compressedSize": 2048,
                    "isDirectory": false,
                    "isEncrypted": false,
                    "modifiedTime": Int(Date().timeIntervalSince1970)
                ]
            ]
            return [
                "sessionId": UUID().uuidString,
                "entries": dummyEntries
            ]

        case "compress":
            let inputs = params["inputs"] as? [String] ?? []
            let outputPath = params["outputPath"] as? String ?? "/tmp/archive.zip"
            let levelRaw = params["level"] as? Int ?? 6
            let level = ArchiveCompressionLevel(rawValue: levelRaw) ?? .normal
            let password = params["password"] as? String
            let cmd = CompressCommand(inputs: inputs, outputPath: outputPath, level: level, password: password)
            _ = try await cmd.execute()
            return ["outputPath": outputPath, "success": true]

        case "extract":
            let archivePath = params["archivePath"] as? String ?? ""
            let destinationDir = params["destinationDir"] as? String ?? "/tmp/extracted"
            let password = params["password"] as? String
            let cmd = ExtractCommand(archivePath: archivePath, destinationDir: destinationDir, password: password)
            _ = try await cmd.execute()
            return ["destinationDir": destinationDir, "success": true]

        case "triggerQuickLook":
            let path = params["path"] as? String ?? ""
            let url = URL(fileURLWithPath: path)
            QuickLookPreviewCoordinator.shared.previewDiskFile(url: url)
            return ["success": true]

        case "revealInFinder":
            let path = params["path"] as? String ?? ""
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            return ["success": true]

        default:
            return ["success": true]
        }
    }

    private func sendSuccess(requestId: String?, result: Any) {
        guard let requestId = requestId, let webView = webView else { return }
        if let jsonData = try? JSONSerialization.data(withJSONObject: result),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            let js = "window.__ttzip_bridge_resolve && window.__ttzip_bridge_resolve('\(requestId)', \(jsonString));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func sendError(requestId: String?, error: String) {
        guard let requestId = requestId, let webView = webView else { return }
        let js = "window.__ttzip_bridge_reject && window.__ttzip_bridge_reject('\(requestId)', '\(error)');"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}
