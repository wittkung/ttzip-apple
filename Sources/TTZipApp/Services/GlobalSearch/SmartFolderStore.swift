// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import TTZipCore
import TTZipUI

/// Persistent store and evaluation service for TTZip Smart Folders (Saved Searches — Slice B).
@Observable
@MainActor
public final class SmartFolderStore {
    public static let shared = SmartFolderStore()
    public static let storageKey = "com.metastudyline.ttzip.smart_folders.v1"

    public private(set) var records: [SmartFolderRecord] = []
    public private(set) var lastCorruptedRecordLoadError: String?

    public var defaultDirectoryScanner: any DirectoryRecursiveSearching = DefaultDirectoryRecursiveScanner()
    public var defaultSystemSearchProvider: any SystemFileSearchProviding = SpotlightArchiveSearchProvider.shared
    public var defaultAccessChecker: (@MainActor (URL) -> Bool)? = nil
    public var additionalFullDiskScopeURLs: [URL] = []

    private let userDefaults: UserDefaults
    private var customStorageFileURL: URL?

    public init(userDefaults: UserDefaults = .standard, customStorageFileURL: URL? = nil, loadOnInit: Bool = true) {
        self.userDefaults = userDefaults
        self.customStorageFileURL = customStorageFileURL
        if loadOnInit { loadFromStorage() }
    }

    public func configureStorageFileForTesting(_ fileURL: URL?, reload: Bool = true) {
        self.customStorageFileURL = fileURL
        if reload { loadFromStorage() }
    }

    // MARK: - CRUD Operations

    @discardableResult
    public func createSmartFolder(name: String, criteria: SmartFolderCriteria, scope: SmartFolderSearchScope) throws -> SmartFolderRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SmartFolderOperationError.emptyName }
        guard !criteria.isEmptyCondition else { throw SmartFolderOperationError.emptyCriteria }
        let now = Date()
        let record = SmartFolderRecord(name: trimmedName, criteria: criteria, scope: scope, createdAt: now, updatedAt: now)
        records.insert(record, at: 0)
        saveToStorage()
        return record
    }

    @discardableResult
    public func updateSmartFolder(
        id: UUID,
        name: String? = nil,
        criteria: SmartFolderCriteria? = nil,
        scope: SmartFolderSearchScope? = nil
    ) throws -> SmartFolderRecord {
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw SmartFolderOperationError.notFound(id)
        }
        var updated = records[idx]
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SmartFolderOperationError.emptyName }
            updated.name = trimmed
        }
        if let criteria {
            guard !criteria.isEmptyCondition else { throw SmartFolderOperationError.emptyCriteria }
            updated.criteria = criteria
        }
        if let scope { updated.scope = scope }
        updated.updatedAt = Date()
        records[idx] = updated
        saveToStorage()
        return updated
    }

    @discardableResult
    public func renameSmartFolder(id: UUID, newName: String) throws -> SmartFolderRecord {
        try updateSmartFolder(id: id, name: newName)
    }

    /// Removes the saved Smart Folder definition from persistence without touching any files on disk.
    public func deleteSmartFolder(id: UUID) {
        records.removeAll { $0.id == id }
        saveToStorage()
    }

    public func record(for id: UUID) -> SmartFolderRecord? {
        records.first { $0.id == id }
    }

    // MARK: - Persistence & Corrupted Payload Recovery

    public func loadFromStorage() {
        lastCorruptedRecordLoadError = nil
        let rawData = customStorageFileURL.flatMap { try? Data(contentsOf: $0) } ?? userDefaults.data(forKey: Self.storageKey)
        guard let data = rawData, !data.isEmpty else {
            records = []
            return
        }
        do {
            records = try JSONDecoder().decode([SmartFolderRecord].self, from: data)
        } catch {
            lastCorruptedRecordLoadError = error.localizedDescription
            records = []
        }
    }

    public func saveToStorage() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        if let fileURL = customStorageFileURL {
            try? data.write(to: fileURL, options: [.atomic])
        } else {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Dynamic Evaluation Engine (No Model Required, Re-Queries Live Filesystem)

    /// Evaluates `record` dynamically against its configured scope.
    public func evaluate(
        record: SmartFolderRecord,
        directoryScanner: (any DirectoryRecursiveSearching)? = nil,
        systemSearchProvider: (any SystemFileSearchProviding)? = nil,
        checkAccess: (@MainActor (URL) -> Bool)? = nil
    ) async -> SmartFolderEvaluationResult {
        let effectiveScanner = directoryScanner ?? defaultDirectoryScanner
        let effectiveProvider = systemSearchProvider ?? defaultSystemSearchProvider
        let effectiveAccessCheck = checkAccess ?? defaultAccessChecker
        guard !record.criteria.isEmptyCondition else {
            return SmartFolderEvaluationResult(
                recordID: record.id,
                items: [],
                phase: .error(SmartFolderOperationError.emptyCriteria.localizedDescription),
                coverage: ExplorerSearchCoverageNote(scopeDescription: scopeDisplayDescription(for: record.scope))
            )
        }

        switch record.scope {
        case .directory(let path, let bookmarkData):
            return await evaluateDirectoryScope(
                record: record,
                path: path,
                bookmarkData: bookmarkData,
                directoryScanner: effectiveScanner,
                checkAccess: effectiveAccessCheck
            )

        case .fullDisk:
            return await evaluateFullDiskScope(
                record: record,
                directoryScanner: effectiveScanner,
                systemSearchProvider: effectiveProvider,
                checkAccess: effectiveAccessCheck
            )
        }
    }

    private func evaluateDirectoryScope(
        record: SmartFolderRecord,
        path: String,
        bookmarkData: Data?,
        directoryScanner: any DirectoryRecursiveSearching,
        checkAccess: (@MainActor (URL) -> Bool)?
    ) async -> SmartFolderEvaluationResult {
        if Task.isCancelled {
            return makeCancelledScopeResult(recordID: record.id, path: path)
        }
        let dirURL = URL(fileURLWithPath: path).standardizedFileURL
        if let checkAccess, !checkAccess(dirURL) {
            return makeUnauthorizedScopeResult(recordID: record.id, path: path)
        }
        let ownerGranted = await RootFolderAccessManager.shared.ensureAccess(for: dirURL, promptIfMissing: false)
        guard ownerGranted, let scopeLease = RootFolderAccessManager.shared.acquireLease(for: dirURL) else {
            return makeUnauthorizedScopeResult(recordID: record.id, path: path)
        }
        defer { scopeLease.release() }

        let scannerToken = Self.resolveScannerToken(for: record.criteria)
        do {
            try Task.checkCancellation()
            let outcome = try await performDirectoryScan(
                dirURL: dirURL,
                scannerToken: scannerToken,
                directoryScanner: directoryScanner
            )
            try Task.checkCancellation()
            let filtered = Self.applyCriteriaFilter(items: outcome.items, criteria: record.criteria)
            let coverage = ExplorerSearchCoverageNote(
                scopeDescription: path,
                visitedEntryCount: outcome.visitedEntryCount,
                maxDepthVisited: outcome.maxDepthVisited,
                truncationReasons: outcome.truncationReasons,
                skippedUnauthorizedSubdirectoryCount: outcome.skippedUnauthorizedDirectories,
                skippedDatalessFileCount: outcome.skippedDatalessFiles,
                isModelReady: LocalModelManager.shared.isSemanticSearchAvailable
            )
            return SmartFolderEvaluationResult(
                recordID: record.id,
                items: filtered,
                phase: filtered.isEmpty ? .empty : .completed,
                coverage: coverage,
                isScopeUnauthorized: false,
                isCancelled: false
            )
        } catch is CancellationError {
            return makeCancelledScopeResult(recordID: record.id, path: path)
        } catch {
            if Task.isCancelled {
                return makeCancelledScopeResult(recordID: record.id, path: path)
            }
            return mapDirectoryScanError(error, recordID: record.id, path: path)
        }
    }

    private func makeCancelledScopeResult(recordID: UUID, path: String) -> SmartFolderEvaluationResult {
        let msg = AppLocalizationState.shared.uiString(
            zh: "智能文件夹扫描已取消。",
            en: "Smart folder scan cancelled."
        )
        return SmartFolderEvaluationResult(
            recordID: recordID,
            items: [],
            phase: .error(msg),
            coverage: ExplorerSearchCoverageNote(scopeDescription: path),
            isScopeUnauthorized: false,
            isCancelled: true
        )
    }

    private func makeUnauthorizedScopeResult(recordID: UUID, path: String) -> SmartFolderEvaluationResult {
        let msg = AppLocalizationState.shared.uiString(
            zh: "未获得目录访问授权：\(path)",
            en: "Directory access not authorized: \(path)"
        )
        return SmartFolderEvaluationResult(
            recordID: recordID,
            items: [],
            phase: .error(msg),
            coverage: ExplorerSearchCoverageNote(
                scopeDescription: path,
                skippedUnauthorizedSubdirectoryCount: 1
            ),
            isScopeUnauthorized: true,
            isCancelled: false
        )
    }

    private static func resolveScannerToken(for criteria: SmartFolderCriteria) -> String {
        if !criteria.nameQuery.isEmpty && !criteria.fileExtension.isEmpty {
            return "\(criteria.nameQuery) .\(criteria.fileExtension)"
        }
        if !criteria.nameQuery.isEmpty {
            return criteria.nameQuery
        }
        if !criteria.fileExtension.isEmpty {
            return ".\(criteria.fileExtension)"
        }
        return ""
    }

    private func performDirectoryScan(
        dirURL: URL,
        scannerToken: String,
        directoryScanner: any DirectoryRecursiveSearching
    ) async throws -> DirectoryRecursiveSearchOutcome {
        if scannerToken.isEmpty {
            return try await Self.scanAllForKindFilter(
                rootURL: dirURL,
                directoryScanner: directoryScanner
            )
        }
        return try await directoryScanner.searchDirectoryRecursively(
            rootURL: dirURL,
            query: scannerToken,
            maxResults: SmartFolderScanBudget.defaultBudget.maxDirectoryResults,
            maxVisitedEntries: SmartFolderScanBudget.defaultBudget.maxVisitedEntries
        )
    }

    private func mapDirectoryScanError(
        _ error: Error,
        recordID: UUID,
        path: String
    ) -> SmartFolderEvaluationResult {
        if let scanError = error as? DirectoryRecursiveScanError {
            var isDenied = false
            if case .targetAccessDenied = scanError {
                isDenied = true
            }
            return SmartFolderEvaluationResult(
                recordID: recordID,
                items: [],
                phase: .error(scanError.errorDescription ?? scanError.localizedDescription),
                coverage: ExplorerSearchCoverageNote(
                    scopeDescription: path,
                    skippedUnauthorizedSubdirectoryCount: isDenied ? 1 : 0
                ),
                isScopeUnauthorized: isDenied,
                isCancelled: false
            )
        }
        return SmartFolderEvaluationResult(
            recordID: recordID,
            items: [],
            phase: .error(error.localizedDescription),
            coverage: ExplorerSearchCoverageNote(scopeDescription: path),
            isScopeUnauthorized: false,
            isCancelled: false
        )
    }

    private struct FullDiskAggregationState {
        var combinedRaw: [GlobalSearchResultItem]
        var seenKeys: Set<String>
        var totalVisitedEntries = 0
        var maxDepthVisited = 0
        var truncationReasons: Set<DirectoryScanTruncationReason> = []
        var skippedUnauthorizedDirs = 0
        var skippedDatalessFiles = 0
        var encounterErrors: [String] = []
        var unauthorizedScopeCount = 0
        var scannedScopeCount = 0

        init(spotlightHits: [GlobalSearchResultItem]) {
            self.combinedRaw = spotlightHits
            self.seenKeys = Set(spotlightHits.compactMap { SmartFolderStore.canonicalItemKey(for: $0) })
        }

        mutating func recordUnauthorizedScope(errorMessage: String? = nil) {
            unauthorizedScopeCount += 1
            skippedUnauthorizedDirs += 1
            if let errorMessage {
                encounterErrors.append(errorMessage)
            }
        }

        mutating func mergeOutcome(_ outcome: DirectoryRecursiveSearchOutcome) {
            scannedScopeCount += 1
            totalVisitedEntries += outcome.visitedEntryCount
            if outcome.maxDepthVisited > maxDepthVisited {
                maxDepthVisited = outcome.maxDepthVisited
            }
            truncationReasons.formUnion(outcome.truncationReasons)
            skippedUnauthorizedDirs += outcome.skippedUnauthorizedDirectories
            skippedDatalessFiles += outcome.skippedDatalessFiles
            for item in outcome.items {
                if let key = SmartFolderStore.canonicalItemKey(for: item) {
                    if seenKeys.insert(key).inserted {
                        combinedRaw.append(item)
                    }
                } else {
                    combinedRaw.append(item)
                }
            }
        }
    }

    private func evaluateFullDiskScope(
        record: SmartFolderRecord,
        directoryScanner: any DirectoryRecursiveSearching,
        systemSearchProvider: any SystemFileSearchProviding,
        checkAccess: (@MainActor (URL) -> Bool)?
    ) async -> SmartFolderEvaluationResult {
        let scopeTitle = AppLocalizationState.shared.uiString(
            zh: "全盘已授权范围与系统索引",
            en: "Full Disk (Authorized Scopes & Spotlight)"
        )
        if Task.isCancelled {
            return makeCancelledScopeResult(recordID: record.id, path: scopeTitle)
        }
        let candidateScopes = Self.deduplicatedDirectories(
            Array(RootFolderAccessManager.shared.accessingURLs) + additionalFullDiskScopeURLs
        )
        let spotlightHits = await systemSearchProvider.searchAllAccessibleItems(
            query: record.criteria.effectiveScannerQuery,
            maxResults: SmartFolderScanBudget.defaultBudget.maxSpotlightResults,
            additionalScopes: candidateScopes
        )
        if Task.isCancelled {
            return makeCancelledScopeResult(recordID: record.id, path: scopeTitle)
        }

        var state = FullDiskAggregationState(spotlightHits: spotlightHits)
        let scannerToken = Self.resolveScannerToken(for: record.criteria)
        for scopeURL in candidateScopes {
            if let cancelled = await scanSingleFullDiskCandidate(
                scopeURL: scopeURL,
                recordID: record.id,
                scopeTitle: scopeTitle,
                scannerToken: scannerToken,
                directoryScanner: directoryScanner,
                checkAccess: checkAccess,
                state: &state
            ) {
                return cancelled
            }
        }
        return finalizeFullDiskResult(record: record, scopeTitle: scopeTitle, candidateCount: candidateScopes.count, state: state)
    }

    private func scanSingleFullDiskCandidate(
        scopeURL: URL,
        recordID: UUID,
        scopeTitle: String,
        scannerToken: String,
        directoryScanner: any DirectoryRecursiveSearching,
        checkAccess: (@MainActor (URL) -> Bool)?,
        state: inout FullDiskAggregationState
    ) async -> SmartFolderEvaluationResult? {
        if Task.isCancelled {
            return makeCancelledScopeResult(recordID: recordID, path: scopeTitle)
        }
        if let checkAccess, !checkAccess(scopeURL) {
            state.recordUnauthorizedScope()
            return nil
        }
        let ownerGranted = await RootFolderAccessManager.shared.ensureAccess(for: scopeURL, promptIfMissing: false)
        guard ownerGranted, let scopeLease = RootFolderAccessManager.shared.acquireLease(for: scopeURL) else {
            state.recordUnauthorizedScope()
            return nil
        }
        defer { scopeLease.release() }

        do {
            let outcome = try await performDirectoryScan(
                dirURL: scopeURL,
                scannerToken: scannerToken,
                directoryScanner: directoryScanner
            )
            state.mergeOutcome(outcome)
        } catch is CancellationError {
            return makeCancelledScopeResult(recordID: recordID, path: scopeTitle)
        } catch let scanError as DirectoryRecursiveScanError {
            let msg = scanError.errorDescription ?? scanError.localizedDescription
            if case .targetAccessDenied = scanError {
                state.recordUnauthorizedScope(errorMessage: msg)
            } else {
                state.encounterErrors.append(msg)
            }
        } catch {
            if Task.isCancelled {
                return makeCancelledScopeResult(recordID: recordID, path: scopeTitle)
            }
            state.encounterErrors.append(error.localizedDescription)
        }
        return nil
    }

    private func finalizeFullDiskResult(
        record: SmartFolderRecord,
        scopeTitle: String,
        candidateCount: Int,
        state: FullDiskAggregationState
    ) -> SmartFolderEvaluationResult {
        let filtered = Self.applyCriteriaFilter(items: state.combinedRaw, criteria: record.criteria)
        let allUnauthorized = candidateCount > 0 && state.scannedScopeCount == 0 && state.unauthorizedScopeCount > 0 && filtered.isEmpty
        let coverage = ExplorerSearchCoverageNote(
            scopeDescription: scopeTitle,
            visitedEntryCount: state.totalVisitedEntries,
            maxDepthVisited: state.maxDepthVisited,
            truncationReasons: state.truncationReasons,
            skippedUnauthorizedSubdirectoryCount: state.skippedUnauthorizedDirs,
            skippedDatalessFileCount: state.skippedDatalessFiles,
            isModelReady: LocalModelManager.shared.isSemanticSearchAvailable,
            indexedScopeCount: state.scannedScopeCount
        )
        let phase: ExplorerSearchGroupPhase
        if allUnauthorized {
            let msg = state.encounterErrors.first ?? AppLocalizationState.shared.uiString(
                zh: "未获得全盘候选目录访问授权",
                en: "Directory access not authorized for full-disk scope"
            )
            phase = .error(msg)
        } else if let firstErr = state.encounterErrors.first, filtered.isEmpty {
            phase = .error(firstErr)
        } else {
            phase = filtered.isEmpty ? .empty : .completed
        }
        return SmartFolderEvaluationResult(
            recordID: record.id,
            items: filtered,
            phase: phase,
            coverage: coverage,
            isScopeUnauthorized: allUnauthorized,
            isCancelled: false
        )
    }

    private static func deduplicatedDirectories(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var output: [URL] = []
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if seen.insert(canonical.path).inserted {
                output.append(canonical)
            }
        }
        return output
    }

    /// Post-filters candidate items against extension and kind criteria.
    public nonisolated static func applyCriteriaFilter(
        items: [GlobalSearchResultItem],
        criteria: SmartFolderCriteria
    ) -> [GlobalSearchResultItem] {
        items.filter { item in
            if !criteria.nameQuery.isEmpty {
                let tokens = criteria.nameQuery
                    .lowercased()
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                let lowerTitle = item.title.lowercased()
                let lowerSub = item.subtitle.lowercased()
                guard tokens.allSatisfy({ lowerTitle.contains($0) || lowerSub.contains($0) }) else {
                    return false
                }
            }
            if !criteria.fileExtension.isEmpty {
                let itemExt = (item.title as NSString).pathExtension.lowercased()
                guard itemExt == criteria.fileExtension else {
                    return false
                }
            }
            switch criteria.kindFilter {
            case .any:
                return true
            case .archivesOnly:
                if case .archiveFile = item.targetKind { return true }
                let ext = (item.title as NSString).pathExtension.lowercased()
                return !item.isDirectory && SpotlightArchiveSearchProvider.supportedArchiveExtensions.contains(ext)
            case .foldersOnly:
                return item.isDirectory
            case .filesOnly:
                return !item.isDirectory
            }
        }
    }

    private struct KindScanAccumulator {
        let canonicalRoot: URL
        let maxResults = SmartFolderScanBudget.defaultBudget.maxDirectoryResults
        let maxVisitedEntries = SmartFolderScanBudget.defaultBudget.maxVisitedEntries
        let maxDepth = SmartFolderScanBudget.defaultBudget.maxDepth
        var results: [GlobalSearchResultItem] = []
        var visitedEntries = 0
        var maxDepthVisited = 0
        var skippedUnauthorized = 0
        var skippedDataless = 0
        var truncationReasons: Set<DirectoryScanTruncationReason> = []

        func buildOutcome() -> DirectoryRecursiveSearchOutcome {
            DirectoryRecursiveSearchOutcome(
                items: results,
                visitedEntryCount: visitedEntries,
                maxDepthVisited: maxDepthVisited,
                truncationReasons: truncationReasons,
                skippedUnauthorizedDirectories: skippedUnauthorized,
                skippedDatalessFiles: skippedDataless
            )
        }
    }

    private nonisolated static func validateReadableDirectory(_ rootURL: URL) throws -> URL {
        let fm = FileManager.default
        let canonical = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: canonical.path, isDirectory: &isDir) else {
            throw DirectoryRecursiveScanError.targetDoesNotExist(canonical.path)
        }
        guard isDir.boolValue else {
            throw DirectoryRecursiveScanError.targetNotDirectory(canonical.path)
        }
        guard fm.isReadableFile(atPath: canonical.path) else {
            throw DirectoryRecursiveScanError.targetAccessDenied(canonical.path)
        }
        return canonical
    }

    private nonisolated static func canonicalItemKey(for item: GlobalSearchResultItem) -> String? {
        if let archivePath = item.archivePath {
            let p = URL(fileURLWithPath: archivePath).standardizedFileURL.resolvingSymlinksInPath().path
            if let sub = item.entrySubpath, !sub.isEmpty {
                return "entry:\(p)#\(sub)"
            }
            return "archive:\(p)"
        }
        if let diskPath = item.diskPath {
            let p = URL(fileURLWithPath: diskPath).standardizedFileURL.resolvingSymlinksInPath().path
            return "disk:\(p)"
        }
        return nil
    }

    private nonisolated static func scanAllForKindFilter(
        rootURL: URL,
        directoryScanner: any DirectoryRecursiveSearching
    ) async throws -> DirectoryRecursiveSearchOutcome {
        let canonical = try validateReadableDirectory(rootURL)
        var state = KindScanAccumulator(canonicalRoot: canonical)
        var queue: [(url: URL, depth: Int)] = [(canonical, 0)]
        var head = 0

        while head < queue.count {
            try Task.checkCancellation()
            let (dirURL, depth) = queue[head]
            head += 1
            if depth > state.maxDepthVisited { state.maxDepthVisited = depth }

            guard let entries = readDirectoryEntries(at: dirURL) else {
                if depth == 0 {
                    throw DirectoryRecursiveScanError.targetAccessDenied(canonical.path)
                }
                state.skippedUnauthorized += 1
                continue
            }

            for entryURL in entries {
                try Task.checkCancellation()
                guard state.visitedEntries < state.maxVisitedEntries else {
                    state.truncationReasons.insert(.maxVisitedEntriesReached)
                    break
                }
                state.visitedEntries += 1
                processKindScanEntry(entryURL, depth: depth, state: &state, queue: &queue)
            }
        }
        return state.buildOutcome()
    }

    private nonisolated static func readDirectoryEntries(at dirURL: URL) -> [URL]? {
        guard let entries = try? DatalessProtection.withMaterializationDisabled({
            try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        }) else {
            return nil
        }
        return entries.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private nonisolated static func processKindScanEntry(
        _ entryURL: URL,
        depth: Int,
        state: inout KindScanAccumulator,
        queue: inout [(url: URL, depth: Int)]
    ) {
        var st = stat()
        guard DatalessProtection.withMaterializationDisabled({ lstat(entryURL.path, &st) == 0 }) else {
            return
        }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK { return }
        let entryIsDir = (mode == S_IFDIR)
        if !entryIsDir && (Int32(st.st_flags) & Int32(SF_DATALESS)) != 0 {
            state.skippedDataless += 1
            return
        }
        if entryIsDir && DefaultDirectoryRecursiveScanner.excludedDirectoryNames.contains(entryURL.lastPathComponent) {
            return
        }
        if entryIsDir {
            if depth + 1 <= state.maxDepth {
                queue.append((entryURL, depth + 1))
            } else {
                state.truncationReasons.insert(.maxDepthReached)
            }
        }
        if state.results.count < state.maxResults {
            state.results.append(
                makeKindScanItem(url: entryURL, rootURL: state.canonicalRoot, isDir: entryIsDir, size: Int64(st.st_size))
            )
        } else {
            state.truncationReasons.insert(.maxResultsReached)
        }
    }

    private nonisolated static func makeKindScanItem(
        url: URL,
        rootURL: URL,
        isDir: Bool,
        size: Int64
    ) -> GlobalSearchResultItem {
        let name = url.lastPathComponent
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let relPath = url.path.hasPrefix(rootPrefix) ? String(url.path.dropFirst(rootPrefix.count)) : name
        let ext = url.pathExtension.lowercased()
        let isArch = !isDir && SpotlightArchiveSearchProvider.supportedArchiveExtensions.contains(ext)
        if isArch {
            return GlobalSearchResultItem(
                id: "smart:archive:\(url.path)",
                title: name,
                subtitle: relPath,
                hitType: .archiveFile,
                archivePath: url.path,
                diskPath: nil,
                isDirectory: false,
                byteSize: size,
                score: 0.95
            )
        }
        return GlobalSearchResultItem(
            id: "smart:item:\(url.path)",
            title: name,
            subtitle: relPath,
            hitType: .archiveEntry,
            archivePath: nil,
            entrySubpath: nil,
            diskPath: url.path,
            isDirectory: isDir,
            byteSize: size,
            score: 0.95
        )
    }

    public func scopeDisplayDescription(for scope: SmartFolderSearchScope) -> String {
        switch scope {
        case .directory(let path, _):
            return path
        case .fullDisk:
            return AppLocalizationState.shared.uiString(zh: "全盘范围", en: "Full Disk")
        }
    }
}

/// Evaluation snapshot returned when running a `SmartFolderRecord`.
public struct SmartFolderEvaluationResult: Sendable, Equatable {
    public let recordID: UUID
    public let items: [GlobalSearchResultItem]
    public let phase: ExplorerSearchGroupPhase
    public let coverage: ExplorerSearchCoverageNote
    public let isScopeUnauthorized: Bool
    public let isCancelled: Bool
    public let scanBudget: SmartFolderScanBudget

    public init(
        recordID: UUID,
        items: [GlobalSearchResultItem],
        phase: ExplorerSearchGroupPhase,
        coverage: ExplorerSearchCoverageNote,
        isScopeUnauthorized: Bool = false,
        isCancelled: Bool = false,
        scanBudget: SmartFolderScanBudget = .defaultBudget
    ) {
        self.recordID = recordID
        self.items = items
        self.phase = phase
        self.coverage = coverage
        self.isScopeUnauthorized = isScopeUnauthorized
        self.isCancelled = isCancelled
        self.scanBudget = scanBudget
    }
}
