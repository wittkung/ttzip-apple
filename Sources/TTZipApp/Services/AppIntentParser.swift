// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit

public enum AppIntentParser {
    
    /// Normalizes an incoming URL (`ttzip://` or `file://`) into an `AppIntentEnvelope`.
    public static func parse(url: URL, sourceHint: AppIntentSource = .urlScheme) -> AppIntentEnvelope? {
        if url.isFileURL {
            let path = url.path
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            
            let ext = url.pathExtension.lowercased()
            let documentExtensions: Set<String> = [
                "epub", "mobi", "azw3", "cbz", "cbr", "pdf",
                "docx", "xlsx", "pptx", "pages", "numbers", "keynote"
            ]
            if isDir.boolValue {
                return AppIntentEnvelope(intent: .createArchive(sourcePaths: [path], options: CompressIntentOptions()), source: sourceHint)
            } else if documentExtensions.contains(ext) {
                return AppIntentEnvelope(intent: .previewItem(url: url), source: sourceHint)
            } else if ArchiveCompressionFormat.isArchiveExtension(url.pathExtension, path: path) {
                return AppIntentEnvelope(intent: .openArchive(url: url, password: nil), source: sourceHint)
            } else {
                return AppIntentEnvelope(intent: .previewItem(url: url), source: sourceHint)
            }
        }
        
        guard url.scheme == "ttzip", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        
        var actionType = components.queryItems?.first(where: { $0.name == "type" })?.value ?? ""
        var rawPaths: [String] = []
        var activeBookmarkSession: ActiveBookmarkSession?
        
        // Priority 1: Check for App Group spooled job token (jobId, job_id, token)
        if let jobIdStr = components.queryItems?.first(where: { $0.name == "jobId" || $0.name == "job_id" || $0.name == "token" })?.value,
           let jobId = UUID(uuidString: jobIdStr),
           let spooledJob = AppGroupSpoolManager.shared.consumeJob(id: jobId) {
            if actionType.isEmpty {
                actionType = spooledJob.action
            }
            if !spooledJob.sourceBookmarks.isEmpty {
                let scope = AppGroupSpoolManager.shared.resolveBookmarkScope(spooledJob.sourceBookmarks)
                activeBookmarkSession = ActiveBookmarkSession(scope: scope)
                
                if !scope.urls.isEmpty {
                    rawPaths = scope.urls.map { $0.path }
                } else {
                    rawPaths = spooledJob.sourcePaths
                }
            } else if !spooledJob.sourcePaths.isEmpty {
                rawPaths = spooledJob.sourcePaths
            }
        }
        
        // Priority 2: Fallback to direct query parameter paths for small/legacy batches
        if rawPaths.isEmpty, let pathsStr = components.queryItems?.first(where: { $0.name == "paths" || $0.name == "path" })?.value {
            rawPaths = pathsStr.components(separatedBy: "|").filter { !$0.isEmpty }
        }
        
        // Preserve raw spooled paths without pre-filtering via fileExists.
        // Under App Sandbox, file existence checks fail before security-scoped bookmark
        // leases are activated; verification is deferred to RootFolderAccessManager during execution.
        let sanitizedPaths = rawPaths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        let intent: AppIntent
        switch actionType {
        case "open_archive", "open":
            guard let first = sanitizedPaths.first else { return nil }
            let pwd = components.queryItems?.first(where: { $0.name == "password" || $0.name == "pwd" })?.value
            intent = .openArchive(url: URL(fileURLWithPath: first), password: pwd)
            
        case "extract_here":
            intent = .extractArchive(archivePaths: sanitizedPaths, options: ExtractIntentOptions(isSmartExtract: false, forceKeepBoth: true))
            
        case "extract_to_subfolder", "extract":
            let dest = components.queryItems?.first(where: { $0.name == "destination" || $0.name == "dest" })?.value
            let destURL = dest != nil ? URL(fileURLWithPath: dest!) : nil
            let smartParam = components.queryItems?.first(where: { $0.name == "smart" })?.value
            let isSmart = (smartParam != "false") && (dest == nil)
            let forceKeep = components.queryItems?.first(where: { $0.name == "force_keep_both" })?.value == "true"
            intent = .extractArchive(archivePaths: sanitizedPaths, options: ExtractIntentOptions(destinationDirectory: destURL, isSmartExtract: isSmart, forceKeepBoth: forceKeep))
            
        case "quickpeek", "quick_peek", "quickpeeker":
            let urls = sanitizedPaths.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return nil }
            intent = .quickPeek(urls: urls)
            
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
            
        case "adb_guide":
            intent = .showAdbGuide

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
        
        return AppIntentEnvelope(intent: intent, source: sourceHint, bookmarkSession: activeBookmarkSession)
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
