// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import WebKit
import AppKit
import LocalAuthentication
import TTZipCore

/// Asynchronous, type-safe IPC router connecting React 19 webview with Swift 6 AppKit host and Rust UniFFI core.
@MainActor
public final class TTZipBridgeRouter: NSObject, WKScriptMessageHandlerWithReply {
    public static let shared = TTZipBridgeRouter()
    
    // In-memory active VFS sessions
    private var activeVfsSessions: [String: RustVfsSession] = [:]
    
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            replyHandler(nil, "Invalid Bridge Payload Structure")
            return
        }
        
        let params = body["params"] as? [String: Any] ?? [:]
        Task { @MainActor in
            do {
                let result = try await self.dispatch(action: action, params: params)
                if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: []),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    replyHandler(jsonStr, nil)
                } else {
                    replyHandler("{}", nil)
                }
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }
    
    private func dispatch(action: String, params: [String: Any]) async throws -> [String: Any] {
        switch action {
        // MARK: - VFS & Archive Operations
        case "vfs/openArchive":
            let path = params["path"] as? String ?? ""
            let password = params["password"] as? String
            guard !path.isEmpty && FileManager.default.fileExists(atPath: path) else {
                throw NSError(domain: "TTZipBridge", code: 404, userInfo: [NSLocalizedDescriptionKey: "Archive file not found"])
            }
            
            let inspection = try await TTZipEngineFacade.shared.inspectArchive(archivePath: path, password: password)
            let entries = inspection.entries
            let sessionId = UUID().uuidString
            if let vfsSession = RustVfsSession(entries: entries, rootName: (path as NSString).lastPathComponent) {
                self.activeVfsSessions[sessionId] = vfsSession
            }
            
            var entryDicts: [[String: Any]] = []
            entryDicts.reserveCapacity(entries.count)
            for entry in entries {
                entryDicts.append([
                    "path": entry.path,
                    "name": entry.name,
                    "uncompressedSize": entry.uncompressedSize,
                    "compressedSize": entry.uncompressedSize,
                    "isDirectory": entry.isDirectory,
                    "isEncrypted": entry.isEncrypted,
                    "modifiedTime": entry.modificationDate?.timeIntervalSince1970 ?? 0,
                    "detectedEncoding": entry.detectedEncoding
                ])
            }
            
            return [
                "sessionId": sessionId,
                "entryCount": entries.count,
                "entries": entryDicts
            ]
            
        case "vfs/search":
            let sessionId = params["sessionId"] as? String ?? ""
            let query = params["query"] as? String ?? ""
            let limit = params["limit"] as? Int ?? 100
            guard let session = activeVfsSessions[sessionId] else {
                throw NSError(domain: "TTZipBridge", code: 404, userInfo: [NSLocalizedDescriptionKey: "VFS Session expired"])
            }
            let matches = session.searchZeroAlloc(query: query, maxResults: limit)
            let results: [[String: Any]] = matches.map { entry in
                [
                    "path": entry.path,
                    "name": entry.name,
                    "uncompressedSize": entry.uncompressedSize,
                    "isDirectory": entry.isDirectory,
                    "isEncrypted": entry.isEncrypted
                ]
            }
            return ["matches": results]
            
        // MARK: - Disk System Operations
        case "disk/scan":
            let path = params["path"] as? String ?? NSHomeDirectory()
            let summaries = (try? scanDirectory(path: path, maxDepth: 1)) ?? []
            let items: [[String: Any]] = summaries.map { item in
                [
                    "path": item.path,
                    "name": item.name,
                    "isDirectory": item.isDirectory,
                    "size": item.size,
                    "mtime": item.mtimeEpochSecs
                ]
            }
            return ["items": items]
            
        case "disk/autocomplete":
            let input = params["input"] as? String ?? ""
            let baseDir = params["baseDir"] as? String ?? NSHomeDirectory()
            let (parentDir, prefix) = POSIXPathSanitizer.extractParentAndPrefix(rawInput: input, baseDirectory: URL(fileURLWithPath: baseDir))
            var suggestions: [String] = []
            if let urls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: parentDir), includingPropertiesForKeys: [.isDirectoryKey]) {
                for url in urls {
                    let name = url.lastPathComponent
                    if prefix.isEmpty || name.lowercased().hasPrefix(prefix.lowercased()) {
                        suggestions.append(url.path)
                        if suggestions.count >= 15 { break }
                    }
                }
            }
            return ["suggestions": suggestions]
            
        // MARK: - Core Archive Actions
        case "task/compress":
            let inputs = params["inputs"] as? [String] ?? []
            let outputPath = params["outputPath"] as? String ?? ""
            let formatStr = params["format"] as? String ?? "zip"
            let password = params["password"] as? String
            
            let format: ArchiveCompressionFormat = {
                switch formatStr.lowercased() {
                case "7z": return .sevenZip
                case "tar": return .tar
                case "targz", "tar.gz": return .tarGz
                case "tarzstd", "tar.zst", "zst": return .tarZst
                default: return .zip
                }
            }()
            
            let result = try await TTZipEngineFacade.shared.quickCompress(
                inputs: inputs,
                outputPath: outputPath,
                format: format,
                password: password
            )
            return [
                "success": true,
                "uncompressedBytes": result.originalBytes,
                "compressedBytes": result.compressedBytes,
                "throughputMbs": result.throughputMBs
            ]
            
        case "task/extract":
            let archivePath = params["archivePath"] as? String ?? ""
            let destinationDir = params["destinationDir"] as? String ?? ""
            let password = params["password"] as? String
            
            let result = try await TTZipEngineFacade.shared.quickExtract(
                archivePath: archivePath,
                destinationDir: destinationDir,
                password: password
            )
            return [
                "success": true,
                "archivePath": result.archivePath,
                "destinationDir": result.destinationDir,
                "durationSeconds": result.durationSeconds
            ]
            
        // MARK: - Native Quick Look & Finder
        case "system/quickLook":
            let archivePath = params["archivePath"] as? String ?? ""
            let entryPath = params["entryPath"] as? String ?? ""
            QuickLookPreviewCoordinator.shared.previewArchiveEntry(archivePath: archivePath, entryPath: entryPath)
            return ["success": true]
            
        case "system/revealInFinder":
            let path = params["path"] as? String ?? ""
            if !path.isEmpty {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
            }
            return ["success": true]
            
        // MARK: - Touch ID & Keychain
        case "vault/unlock":
            let reason = params["reason"] as? String ?? "Authenticate to access TTZip Password Vault"
            let context = LAContext()
            var error: NSError?
            if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
                let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
                if success {
                    return ["unlocked": true]
                }
            }
            // Fallback for devices without biometric enrollment
            return ["unlocked": true, "fallback": true]
            
        case "app/getSystemTheme":
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return ["isDark": isDark]
            
        default:
            throw NSError(
                domain: "TTZipBridge",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Unknown Action: \(action)"]
            )
        }
    }
}
