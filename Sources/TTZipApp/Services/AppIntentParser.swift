// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AppKit
import TTZipCore

public enum AppIntentParser {
    
    /// Normalizes an incoming URL (`ttzip://` or `file://`) into an `AppIntentEnvelope`.
    public static func parse(url: URL, sourceHint: AppIntentSource = .urlScheme) -> AppIntentEnvelope? {
        if url.isFileURL {
            let path = url.path
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            
            if isDir.boolValue {
                return AppIntentEnvelope(intent: .createArchive(sourcePaths: [path], options: CompressIntentOptions()), source: sourceHint)
            } else if ArchiveCompressionFormat.isArchiveExtension(url.pathExtension, path: path) {
                return AppIntentEnvelope(intent: .openArchive(url: url, password: nil), source: sourceHint)
            } else {
                return AppIntentEnvelope(intent: .previewItem(url: url), source: sourceHint)
            }
        }
        
        guard url.scheme == "ttzip", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        
        let actionType = components.queryItems?.first(where: { $0.name == "type" })?.value ?? ""
        let pathsStr = components.queryItems?.first(where: { $0.name == "paths" })?.value ?? ""
        let rawPaths = pathsStr.components(separatedBy: "|").filter { !$0.isEmpty }
        let sanitizedPaths = rawPaths.filter { FileManager.default.fileExists(atPath: $0) }
        
        let intent: AppIntent
        switch actionType {
        case "extract_here":
            intent = .extractArchive(archivePaths: sanitizedPaths, options: ExtractIntentOptions(isSmartExtract: false))
            
        case "extract_to_subfolder":
            intent = .extractArchive(archivePaths: sanitizedPaths, options: ExtractIntentOptions(isSmartExtract: true))
            
        case "inspect_archive":
            guard let first = sanitizedPaths.first else { return nil }
            intent = .inspectArchive(archivePath: first)
            
        case "compute_hash":
            guard let first = sanitizedPaths.first else { return nil }
            intent = .verifyIntegrity(archivePath: first)
            
        case "autofill_password":
            guard let first = sanitizedPaths.first else { return nil }
            intent = .autofillVaultPassword(archivePath: first)
            
        case "compress_quick_zip":
            intent = .createArchive(sourcePaths: sanitizedPaths, options: CompressIntentOptions(targetFormat: .zip))
            
        case "compress_quick_7z":
            intent = .createArchive(sourcePaths: sanitizedPaths, options: CompressIntentOptions(targetFormat: .sevenZip))
            
        case "compress_separate":
            intent = .createArchive(sourcePaths: sanitizedPaths, options: CompressIntentOptions(separateArchives: true))
            
        case "compress_and_delete_source":
            intent = .createArchive(sourcePaths: sanitizedPaths, options: CompressIntentOptions(deleteSourceAfterCompression: true))
            
        case "compress_modal_advanced", "compress_workspace", "new_archive":
            intent = .createArchive(sourcePaths: sanitizedPaths, options: CompressIntentOptions())
            
        case "tab":
            let tabName = components.queryItems?.first(where: { $0.name == "name" })?.value ?? ""
            guard let tab = WorkspaceTab(rawValue: tabName) else { return nil }
            intent = .switchTab(tab: tab)
            
        default:
            if !sanitizedPaths.isEmpty {
                intent = .createArchive(sourcePaths: sanitizedPaths, options: CompressIntentOptions())
            } else {
                return nil
            }
        }
        
        return AppIntentEnvelope(intent: intent, source: sourceHint)
    }
    
    /// Asynchronously extracts valid filesystem paths from `[NSItemProvider]` avoiding type cast traps.
    @MainActor
    public static func extractPaths(from providers: [NSItemProvider]) async -> [String] {
        var collected: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                let path: String? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                        if let url = item as? URL {
                            continuation.resume(returning: url.path)
                        } else if let nsURL = item as? NSURL, let p = nsURL.path {
                            continuation.resume(returning: p)
                        } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            continuation.resume(returning: url.path)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let p = path, FileManager.default.fileExists(atPath: p) {
                    collected.append(p)
                }
            }
        }
        return collected
    }
}
