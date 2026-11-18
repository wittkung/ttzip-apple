// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit

public enum AppIntentParser {

    private struct ResolvedIntentContext {
        let actionType: String
        let paths: [String]
        let bookmarkSession: ActiveBookmarkSession?
        let targetFormat: ArchiveCompressionFormat?
        let compressionLevel: Int?
        let destinationDirectory: URL?
        let password: String?
    }

    private struct PendingCLIRepairOutput: Equatable {
        let archivePath: String
        let outputPath: String
    }

    private static let cliRepairBridgeLock = NSLock()
    private nonisolated(unsafe) static var pendingCLIRepairOutput: PendingCLIRepairOutput?

    public static func clearPendingCLIRepairOutput() {
        cliRepairBridgeLock.lock()
        pendingCLIRepairOutput = nil
        cliRepairBridgeLock.unlock()
    }

    private static func recordAuthorizedCLIRepairOutput(archivePath: String, outputPath: String?) {
        cliRepairBridgeLock.lock()
        defer { cliRepairBridgeLock.unlock() }
        guard let trimmed = outputPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            pendingCLIRepairOutput = nil
            return
        }
        pendingCLIRepairOutput = PendingCLIRepairOutput(archivePath: archivePath, outputPath: trimmed)
    }

    private static func consumeAuthorizedCLIRepairOutput(
        archivePath: String,
        candidateOutput: String?
    ) -> String? {
        guard let candidate = candidateOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else {
            return nil
        }
        cliRepairBridgeLock.lock()
        defer { cliRepairBridgeLock.unlock() }
        guard let pending = pendingCLIRepairOutput,
              pending.archivePath == archivePath,
              pending.outputPath == candidate else {
            return nil
        }
        pendingCLIRepairOutput = nil
        return candidate
    }

    private static let documentExtensions: Set<String> = [
        "epub", "mobi", "azw3", "cbz", "cbr", "pdf",
        "docx", "xlsx", "pptx", "pages", "numbers", "keynote"
    ]

    private static let compressOptionsByAction: [String: CompressIntentOptions] = [
        "compress_quick_zip": CompressIntentOptions(targetFormat: .zip),
        "compress_quick_7z": CompressIntentOptions(targetFormat: .sevenZip),
        "compress_separate": CompressIntentOptions(separateArchives: true),
        "compress_and_delete_source": CompressIntentOptions(deleteSourceAfterCompression: true),
        "compress_modal_advanced": CompressIntentOptions(),
        "compress_workspace": CompressIntentOptions(),
        "new_archive": CompressIntentOptions()
    ]

    /// Normalizes CLI launch arguments (such as `--repair <archivePath> [--output <outputPath>]`) into an `AppIntentEnvelope`.
    public static func parse(arguments: [String], sourceHint: AppIntentSource = .internalNavigation) -> AppIntentEnvelope? {
        for (idx, arg) in arguments.enumerated() {
            if arg == "--repair" {
                return parseRepairFlagArguments(arguments, flagIndex: idx, sourceHint: sourceHint)
            }
            if arg.hasPrefix("--repair=") {
                let archivePath = String(arg.dropFirst("--repair=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !archivePath.isEmpty else { return nil }
                let outputPath = resolveOptionalOutputArgument(arguments, afterPathIndex: idx)
                if sourceHint == .internalNavigation {
                    recordAuthorizedCLIRepairOutput(archivePath: archivePath, outputPath: outputPath)
                }
                return AppIntentEnvelope(
                    intent: .repairArchive(archivePath: archivePath, outputPath: outputPath),
                    source: sourceHint
                )
            }
        }
        return nil
    }

    private static func parseRepairFlagArguments(
        _ arguments: [String],
        flagIndex: Int,
        sourceHint: AppIntentSource
    ) -> AppIntentEnvelope? {
        guard flagIndex + 1 < arguments.count else { return nil }
        let archivePath = arguments[flagIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !archivePath.isEmpty, !archivePath.hasPrefix("-") else { return nil }
        let outputPath = resolveOptionalOutputArgument(arguments, afterPathIndex: flagIndex + 1)
        if sourceHint == .internalNavigation {
            recordAuthorizedCLIRepairOutput(archivePath: archivePath, outputPath: outputPath)
        }
        return AppIntentEnvelope(
            intent: .repairArchive(archivePath: archivePath, outputPath: outputPath),
            source: sourceHint
        )
    }

    private static func resolveOptionalOutputArgument(
        _ arguments: [String],
        afterPathIndex: Int
    ) -> String? {
        let nextIndex = afterPathIndex + 1
        guard nextIndex < arguments.count else { return nil }
        let token = arguments[nextIndex]
        if token == "--output" || token == "-o" {
            guard nextIndex + 1 < arguments.count else { return nil }
            let val = arguments[nextIndex + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            return val.isEmpty ? nil : val
        }
        guard !token.hasPrefix("-") else { return nil }
        let val = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return val.isEmpty ? nil : val
    }

    /// Normalizes an incoming URL (`ttzip://` or `file://`) into an `AppIntentEnvelope`.
    public static func parse(url: URL, sourceHint: AppIntentSource = .urlScheme) -> AppIntentEnvelope? {
        if url.isFileURL {
            return parseFileURL(url, sourceHint: sourceHint)
        }
        guard url.scheme == "ttzip",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let items = components.queryItems ?? []
        let resolved = resolveActionAndPaths(from: url, queryItems: items)
        let sanitizedPaths = resolved.paths.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let intent = buildSchemeIntent(
            resolved: resolved,
            sanitizedPaths: sanitizedPaths,
            queryItems: items
        ) else {
            return nil
        }
        let effectiveSource: AppIntentSource = if case .repairArchive(_, let out) = intent,
            out != nil,
            resolved.destinationDirectory == nil,
            sourceHint == .urlScheme {
            .internalNavigation
        } else {
            sourceHint
        }
        return AppIntentEnvelope(
            intent: intent,
            source: effectiveSource,
            bookmarkSession: resolved.bookmarkSession
        )
    }

    private static func parseFileURL(_ url: URL, sourceHint: AppIntentSource) -> AppIntentEnvelope? {
        let path = url.path
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        if isDir.boolValue {
            return AppIntentEnvelope(
                intent: .createArchive(sourcePaths: [path], options: CompressIntentOptions()),
                source: sourceHint
            )
        }
        let ext = url.pathExtension.lowercased()
        if !documentExtensions.contains(ext),
           ArchiveCompressionFormat.isArchiveExtension(url.pathExtension, path: path) {
            return AppIntentEnvelope(intent: .openArchive(url: url, password: nil), source: sourceHint)
        }
        return AppIntentEnvelope(intent: .previewItem(url: url), source: sourceHint)
    }

    private static func queryValue(in items: [URLQueryItem], keys: Set<String>) -> String? {
        items.first { keys.contains($0.name) }?.value
    }

    private static func resolveActionAndPaths(
        from url: URL,
        queryItems: [URLQueryItem]
    ) -> ResolvedIntentContext {
        var actionType = queryValue(in: queryItems, keys: ["type"]) ?? ""
        if actionType.isEmpty, let host = url.host, host != "action" {
            actionType = host
        }
        if let spooled = consumeSpooledJobIfPresent(queryItems: queryItems, currentAction: actionType) {
            return spooled
        }
        let pathsStr = queryValue(in: queryItems, keys: ["paths", "path"]) ?? ""
        let rawPaths = pathsStr.components(separatedBy: "|").filter { !$0.isEmpty }
        return ResolvedIntentContext(
            actionType: actionType,
            paths: rawPaths,
            bookmarkSession: nil,
            targetFormat: nil,
            compressionLevel: nil,
            destinationDirectory: nil,
            password: nil
        )
    }

    private static func consumeSpooledJobIfPresent(
        queryItems: [URLQueryItem],
        currentAction: String
    ) -> ResolvedIntentContext? {
        guard let jobIdStr = queryValue(in: queryItems, keys: ["jobId", "job_id", "token"]),
              let jobId = UUID(uuidString: jobIdStr),
              let spooledJob = AppGroupSpoolManager.shared.consumeJob(id: jobId) else {
            return nil
        }
        let actionType = currentAction.isEmpty ? spooledJob.action : currentAction
        let targetFormat = spooledJob.targetFormat.flatMap { ArchiveCompressionFormat.from(extensionOrName: $0) }
        let destScope = spooledJob.destinationDirectoryBookmark.map {
            AppGroupSpoolManager.shared.resolveBookmarkScope([$0])
        }
        let destURL = destScope?.urls.first
        let (paths, session) = resolveSpooledBookmarks(spooledJob: spooledJob, destScope: destScope)
        return ResolvedIntentContext(
            actionType: actionType,
            paths: paths,
            bookmarkSession: session,
            targetFormat: targetFormat,
            compressionLevel: spooledJob.compressionLevel,
            destinationDirectory: destURL,
            password: spooledJob.password
        )
    }

    private static func resolveSpooledBookmarks(
        spooledJob: TTZipSpoolJob,
        destScope: SecurityScopedResourceScope?
    ) -> ([String], ActiveBookmarkSession?) {
        if spooledJob.sourceBookmarks.isEmpty {
            let session = destScope.map { ActiveBookmarkSession(scope: $0) }
            return (spooledJob.sourcePaths, session)
        }
        let sourceScope = AppGroupSpoolManager.shared.resolveBookmarkScope(spooledJob.sourceBookmarks)
        let paths = sourceScope.urls.isEmpty ? spooledJob.sourcePaths : sourceScope.urls.map(\.path)
        if let destScope {
            for url in destScope.urls {
                sourceScope.add(url, isSecurityScoped: false)
            }
        }
        let onInvalidate: (@Sendable () -> Void)? = if let destScope {
            { destScope.cleanup() }
        } else {
            nil
        }
        let session = ActiveBookmarkSession(scope: sourceScope, onInvalidate: onInvalidate)
        return (paths, session)
    }

    private static func mergedCompressOptions(
        base: CompressIntentOptions,
        resolved: ResolvedIntentContext,
        queryItems: [URLQueryItem]
    ) -> CompressIntentOptions {
        let queryFormat = queryValue(in: queryItems, keys: ["format", "target_format"])
            .flatMap { ArchiveCompressionFormat.from(extensionOrName: $0) }
        let queryLevel = queryValue(in: queryItems, keys: ["level", "compression_level"]).flatMap(Int.init)
        let queryOut = queryValue(in: queryItems, keys: ["output", "output_path"])
        let queryDestDir = queryValue(
            in: queryItems,
            keys: ["destination", "dest", "destination_dir", "destination_directory"]
        )
        let queryPwd = queryValue(in: queryItems, keys: ["password", "pwd"])
        return CompressIntentOptions(
            presetID: base.presetID,
            targetFormat: queryFormat ?? resolved.targetFormat ?? base.targetFormat,
            separateArchives: base.separateArchives,
            deleteSourceAfterCompression: base.deleteSourceAfterCompression,
            customOutputPath: queryOut ?? base.customOutputPath,
            password: queryPwd ?? resolved.password ?? base.password,
            compressionLevel: queryLevel ?? resolved.compressionLevel ?? base.compressionLevel,
            destinationDirectoryPath: queryDestDir ?? resolved.destinationDirectory?.path ?? base.destinationDirectoryPath
        )
    }

    private static func buildSchemeIntent(
        resolved: ResolvedIntentContext,
        sanitizedPaths: [String],
        queryItems: [URLQueryItem]
    ) -> AppIntent? {
        let actionType = resolved.actionType
        if let baseOptions = compressOptionsByAction[actionType] {
            let options = mergedCompressOptions(base: baseOptions, resolved: resolved, queryItems: queryItems)
            return .createArchive(sourcePaths: sanitizedPaths, options: options)
        }
        switch actionType {
        case "open_archive", "open":
            guard let first = sanitizedPaths.first else { return nil }
            let pwd = queryValue(in: queryItems, keys: ["password", "pwd"]) ?? resolved.password
            return .openArchive(url: URL(fileURLWithPath: first), password: pwd)
        case "extract_here":
            let dest = queryValue(in: queryItems, keys: ["destination", "dest"]).map { URL(fileURLWithPath: $0) }
                ?? resolved.destinationDirectory
            let pwd = queryValue(in: queryItems, keys: ["password", "pwd"]) ?? resolved.password
            return .extractArchive(
                archivePaths: sanitizedPaths,
                options: ExtractIntentOptions(
                    destinationDirectory: dest,
                    isSmartExtract: false,
                    password: pwd,
                    forceKeepBoth: true
                )
            )
        case "extract_to_subfolder", "extract":
            return buildExtractSchemeIntent(
                resolved: resolved,
                sanitizedPaths: sanitizedPaths,
                queryItems: queryItems
            )
        case "quickpeek", "quick_peek", "quickpeeker":
            let urls = sanitizedPaths.map { URL(fileURLWithPath: $0) }
            return urls.isEmpty ? nil : .quickPeek(urls: urls)
        default:
            return buildDiagnosticOrNavigationIntent(
                resolved: resolved,
                sanitizedPaths: sanitizedPaths,
                queryItems: queryItems
            )
        }
    }

    private static func buildExtractSchemeIntent(
        resolved: ResolvedIntentContext,
        sanitizedPaths: [String],
        queryItems: [URLQueryItem]
    ) -> AppIntent {
        let dest = queryValue(in: queryItems, keys: ["destination", "dest"])
        let destURL = dest.map { URL(fileURLWithPath: $0) } ?? resolved.destinationDirectory
        let smartParam = queryValue(in: queryItems, keys: ["smart"])
        let isSmart = (smartParam != "false") && (destURL == nil)
        let forceKeep = queryValue(in: queryItems, keys: ["force_keep_both"]) == "true"
        let pwd = queryValue(in: queryItems, keys: ["password", "pwd"]) ?? resolved.password
        return .extractArchive(
            archivePaths: sanitizedPaths,
            options: ExtractIntentOptions(
                destinationDirectory: destURL,
                isSmartExtract: isSmart,
                password: pwd,
                forceKeepBoth: forceKeep
            )
        )
    }

    private static func buildDiagnosticOrNavigationIntent(
        resolved: ResolvedIntentContext,
        sanitizedPaths: [String],
        queryItems: [URLQueryItem]
    ) -> AppIntent? {
        switch resolved.actionType {
        case "inspect_archive":
            return sanitizedPaths.first.map { .inspectArchive(archivePath: $0) }
        case "compute_hash":
            return sanitizedPaths.first.map { .verifyIntegrity(archivePath: $0) }
        case "repair_archive", "repair", "--repair":
            guard let first = sanitizedPaths.first else { return nil }
            let queryOut = queryValue(in: queryItems, keys: ["output", "output_path", "dest", "destination"])
            let cliOut = consumeAuthorizedCLIRepairOutput(archivePath: first, candidateOutput: queryOut)
            return .repairArchive(archivePath: first, outputPath: cliOut ?? resolved.destinationDirectory?.path)
        case "autofill_password":
            return sanitizedPaths.first.map { .autofillVaultPassword(archivePath: $0) }
        case "adb_guide":
            return .showAdbGuide
        case "tab":
            let tabName = queryValue(in: queryItems, keys: ["name"]) ?? ""
            return WorkspaceTab(rawValue: tabName).map { .switchTab(tab: $0) }
        case "compress", "create", "create_archive":
            guard !sanitizedPaths.isEmpty else { return nil }
            let options = mergedCompressOptions(
                base: CompressIntentOptions(),
                resolved: resolved,
                queryItems: queryItems
            )
            return .createArchive(sourcePaths: sanitizedPaths, options: options)
        default:
            return nil
        }
    }

    /// Asynchronously extracts valid filesystem paths from `[NSItemProvider]` avoiding type cast traps.
    @MainActor
    public static func extractPaths(from providers: [NSItemProvider]) async -> [String] {
        var collected: [String] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            if let path = await loadFilePath(from: provider),
               FileManager.default.fileExists(atPath: path) {
                collected.append(path)
            }
        }
        return collected
    }

    @MainActor
    private static func loadFilePath(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
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
    }
}
