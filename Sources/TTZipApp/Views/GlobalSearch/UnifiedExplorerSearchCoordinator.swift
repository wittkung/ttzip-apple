// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import TTZipCore
import TTZipUI

/// Per-window coordinator driving the Dual-Group Top Search experience:
/// 1. Group 1: Current Directory (including accessible subdirectories or current archive entries)
/// 2. Group 2: Full Disk (accessible Spotlight system index + authorized/indexed semantic scopes)
///
/// Enforces:
/// - Fast lexical results never wait for semantic query encoding;
/// - Per-source slot merging so late-arriving lexical results never overwrite already-arrived semantic results;
/// - Canonical target identity deduplication within each group while preserving current-directory hits in Group 1;
/// - Request isolation keyed by `(windowID, query, scopeIdentity, requestID)`.
@MainActor
@Observable
public final class UnifiedExplorerSearchCoordinator {
    public let windowID: UUID
    public let semanticEngine: any SemanticSearchEngineProtocol
    public let modelManager: LocalModelManager
    public let directoryScanner: any DirectoryRecursiveSearching
    public let systemSearchProvider: any SystemFileSearchProviding
    public let semanticDebounceNanoseconds: UInt64

    public private(set) var activeQuery: String = ""
    public private(set) var activeScope: ExplorerSearchScopeIdentity = .unsupported(rawLocation: "", reason: "Idle")
    public private(set) var activeRequestID: UInt64 = 0

    public private(set) var currentDirectoryGroup: ExplorerSearchGroupSnapshot
    public private(set) var fullDiskGroup: ExplorerSearchGroupSnapshot

    public private(set) var selectedResultID: String?
    public private(set) var discardedStaleCallbackCount: Int = 0

    // Source slots for the current active request ID (preventing late lexical from overwriting semantic)
    @ObservationIgnored
    private var currentDirLexicalItems: [GlobalSearchResultItem] = []
    @ObservationIgnored
    private var currentDirSemanticItems: [GlobalSearchResultItem] = []
    @ObservationIgnored
    private var currentDirLexicalCompleted: Bool = false
    @ObservationIgnored
    private var currentDirSemanticCompleted: Bool = false
    @ObservationIgnored
    private var currentDirError: String?
    @ObservationIgnored
    private var currentDirVisitedEntries: Int = 0
    @ObservationIgnored
    private var currentDirMaxDepthVisited: Int = 0
    @ObservationIgnored
    private var currentDirTruncationReasons: Set<DirectoryScanTruncationReason> = []
    @ObservationIgnored
    private var currentDirSkippedUnauthorized: Int = 0
    @ObservationIgnored
    private var currentDirSkippedDataless: Int = 0

    @ObservationIgnored
    private var fullDiskFastItems: [GlobalSearchResultItem] = []
    @ObservationIgnored
    private var fullDiskSpotlightItems: [GlobalSearchResultItem] = []
    @ObservationIgnored
    private var fullDiskSemanticItems: [GlobalSearchResultItem] = []
    @ObservationIgnored
    private var fullDiskFastCompleted: Bool = false
    @ObservationIgnored
    private var fullDiskSpotlightCompleted: Bool = false
    @ObservationIgnored
    private var fullDiskSemanticCompleted: Bool = false
    @ObservationIgnored
    private var isSemanticQueryEncodedForRequest: Bool = false
    @ObservationIgnored
    private var hasSemanticContentHitsForRequest: Bool = false
    @ObservationIgnored
    private var indexedScopeCountForRequest: Int = 0
    @ObservationIgnored
    private var indexedSegmentCountForRequest: UInt32 = 0

    @ObservationIgnored
    private var activeTasks: [Task<Void, Never>] = []
    @ObservationIgnored
    private var fastProviderOverride: (@MainActor (String) async -> [GlobalSearchResultItem])?

    public init(
        windowID: UUID = UUID(),
        semanticEngine: (any SemanticSearchEngineProtocol)? = nil,
        modelManager: LocalModelManager = .shared,
        directoryScanner: any DirectoryRecursiveSearching = DefaultDirectoryRecursiveScanner(),
        systemSearchProvider: any SystemFileSearchProviding = SpotlightArchiveSearchProvider.shared,
        semanticDebounceNanoseconds: UInt64 = 120_000_000,
        fastProviderOverride: (@MainActor (String) async -> [GlobalSearchResultItem])? = nil
    ) {
        self.windowID = windowID
        self.modelManager = modelManager
        self.semanticEngine = semanticEngine ?? modelManager.engine
        self.directoryScanner = directoryScanner
        self.systemSearchProvider = systemSearchProvider
        self.semanticDebounceNanoseconds = semanticDebounceNanoseconds
        self.fastProviderOverride = fastProviderOverride

        let idleCoverage = ExplorerSearchCoverageNote(scopeDescription: "")
        self.currentDirectoryGroup = ExplorerSearchGroupSnapshot(
            title: Self.currentDirectoryGroupTitle(),
            subtitle: "",
            phase: .idle,
            items: [],
            coverage: idleCoverage
        )
        self.fullDiskGroup = ExplorerSearchGroupSnapshot(
            title: Self.fullDiskGroupTitle(),
            subtitle: Self.fullDiskGroupSubtitle(),
            phase: .idle,
            items: [],
            coverage: idleCoverage
        )
    }

    public static func currentDirectoryGroupTitle() -> String {
        AppLocalizationState.shared.uiString(
            zh: "当前目录（含可访问子目录）",
            en: "Current Directory (including accessible subfolders)"
        )
    }

    public static func fullDiskGroupTitle() -> String {
        AppLocalizationState.shared.uiString(
            zh: "全盘（可访问/已索引范围）",
            en: "Full Disk (accessible / indexed scope)"
        )
    }

    public static func fullDiskGroupSubtitle() -> String {
        AppLocalizationState.shared.uiString(
            zh: "系统文件名索引（Spotlight）+ 已授权目录与打开归档内容/语义索引 · 未授权或未索引不代表文件不存在",
            en: "System filename index (Spotlight) + authorized folder & open archive content/semantic index · Unindexed does not mean absent"
        )
    }

    /// Classifies the current browsing context of `viewModel` into a strict `ExplorerSearchScopeIdentity`.
    /// Never passes virtual archive URLs or external Android devices to local POSIX directory traversal.
    public static func classifyScope(for viewModel: AppViewState) -> ExplorerSearchScopeIdentity {
        if let device = AndroidDeviceViewModel.shared.activeDevice(forWindow: viewModel.windowID) {
            let locationDesc = AndroidDeviceViewModel.shared.currentLocation(forWindow: viewModel.windowID)
            let deviceTitle = locationDesc?.deviceName ?? device.deviceId
            let pathText = locationDesc?.breadcrumbs.joined(separator: "/") ?? ""
            return .externalDevice(
                deviceIdentifier: device.deviceId,
                displayPath: pathText.isEmpty ? deviceTitle : "\(deviceTitle):/\(pathText)"
            )
        }

        let location = viewModel.effectiveDisplayDirectory
        if let subpath = AcceptedArchiveDirectoryProjection.archiveSubpath(in: location) {
            return .archiveContext(
                archivePath: URL(fileURLWithPath: location.path).standardizedFileURL.path,
                subpath: subpath
            )
        }

        if let activeArchive = viewModel.explorerState.currentArchivePath, !activeArchive.isEmpty {
            let canonicalArchive = URL(fileURLWithPath: activeArchive).standardizedFileURL.path
            return .archiveContext(archivePath: canonicalArchive, subpath: "")
        }

        if AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(location),
           let projection = viewModel.explorerState.acceptedArchiveProjection(
               for: viewModel.navigationState.activeSessionID,
               archivePath: location.path
           ) {
            return .archiveContext(archivePath: projection.archivePath, subpath: "")
        }

        let classified = FolderSummaryAnalysisCoordinator.classifyPathIdentity(
            rawPath: location.path,
            isDirectory: true,
            isArchive: false
        )
        switch classified {
        case .localDirectory(let localURL):
            return .physicalDirectory(localURL)
        case .rejectedVirtualOrRemote(let rawPath, let reason):
            return .unsupported(rawLocation: rawPath, reason: reason)
        }
    }

    /// Starts or updates the dual-group search for `(query, scope)` on this window.
    public func updateSearch(
        query: String,
        scope: ExplorerSearchScopeIdentity,
        in viewModel: AppViewState? = nil,
        forceRefresh: Bool = false
    ) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSearch()
            return
        }

        if !forceRefresh && trimmed == activeQuery && scope == activeScope && activeRequestID > 0 {
            return
        }

        cancelInFlightTasksAndEngineRequest()

        let requestID = SearchRequestIDAllocator.nextRequestID()
        activeQuery = trimmed
        activeScope = scope
        activeRequestID = requestID

        resetSlotsForNewRequest(scope: scope)
        rebuildGroupSnapshots()

        let currentDirTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runCurrentDirectoryLexicalPipeline(
                query: trimmed,
                scope: scope,
                requestID: requestID,
                viewModel: viewModel
            )
        }

        let fullDiskFastTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runFullDiskFastAndSpotlightPipeline(
                query: trimmed,
                scope: scope,
                requestID: requestID
            )
        }

        let semanticTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSemanticPipeline(
                query: trimmed,
                scope: scope,
                requestID: requestID
            )
        }

        activeTasks = [currentDirTask, fullDiskFastTask, semanticTask]
    }

    /// Clears active search query, cancels in-flight work for this window, and resets groups to `.idle`.
    public func clearSearch() {
        cancelInFlightTasksAndEngineRequest()
        activeQuery = ""
        activeRequestID = 0
        selectedResultID = nil
        resetSlotsForNewRequest(scope: activeScope)
        let idleCoverage = ExplorerSearchCoverageNote(
            scopeDescription: activeScope.displayPath,
            isModelReady: modelManager.isSemanticSearchAvailable
        )
        currentDirectoryGroup = ExplorerSearchGroupSnapshot(
            title: Self.currentDirectoryGroupTitle(),
            subtitle: activeScope.displayPath,
            phase: .idle,
            items: [],
            coverage: idleCoverage
        )
        fullDiskGroup = ExplorerSearchGroupSnapshot(
            title: Self.fullDiskGroupTitle(),
            subtitle: Self.fullDiskGroupSubtitle(),
            phase: .idle,
            items: [],
            coverage: idleCoverage
        )
    }

    /// Waits for all in-flight search pipelines of the current request to settle (for deterministic tests).
    public func waitForActiveSearch() async {
        let tasks = activeTasks
        for task in tasks {
            await task.value
        }
    }

    private func cancelInFlightTasksAndEngineRequest() {
        let previousReq = activeRequestID
        for task in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()
        if previousReq > 0 {
            let engine = semanticEngine
            Task { await engine.cancelSearch(requestId: previousReq) }
        }
    }

    private func resetSlotsForNewRequest(scope: ExplorerSearchScopeIdentity) {
        currentDirLexicalItems = []
        currentDirSemanticItems = []
        currentDirLexicalCompleted = false
        currentDirSemanticCompleted = !modelManager.isSemanticSearchAvailable
        currentDirError = nil
        currentDirVisitedEntries = 0
        currentDirMaxDepthVisited = 0
        currentDirTruncationReasons = []
        currentDirSkippedUnauthorized = 0
        currentDirSkippedDataless = 0

        fullDiskFastItems = []
        fullDiskSpotlightItems = []
        fullDiskSemanticItems = []
        fullDiskFastCompleted = false
        fullDiskSpotlightCompleted = false
        fullDiskSemanticCompleted = !modelManager.isSemanticSearchAvailable
        isSemanticQueryEncodedForRequest = false
        hasSemanticContentHitsForRequest = false
        indexedScopeCountForRequest = RootFolderAccessManager.shared.accessingURLs.count
        indexedSegmentCountForRequest = 0
    }

    private func isCurrentRequest(requestID: UInt64, query: String, scope: ExplorerSearchScopeIdentity) -> Bool {
        guard !Task.isCancelled,
              activeRequestID == requestID,
              activeQuery == query,
              activeScope == scope else {
            discardedStaleCallbackCount += 1
            return false
        }
        return true
    }

    // MARK: - Pipeline 1: Current Directory / Archive Lexical Search

    private func runCurrentDirectoryLexicalPipeline(
        query: String,
        scope: ExplorerSearchScopeIdentity,
        requestID: UInt64,
        viewModel: AppViewState?
    ) async {
        switch scope {
        case .physicalDirectory(let dirURL):
            do {
                let outcome = try await directoryScanner.searchDirectoryRecursively(
                    rootURL: dirURL,
                    query: query,
                    maxResults: 60,
                    maxVisitedEntries: 8_000
                )
                guard isCurrentRequest(requestID: requestID, query: query, scope: scope) else { return }
                currentDirLexicalItems = outcome.items
                currentDirVisitedEntries = outcome.visitedEntryCount
                currentDirMaxDepthVisited = outcome.maxDepthVisited
                currentDirTruncationReasons = outcome.truncationReasons
                currentDirSkippedUnauthorized = outcome.skippedUnauthorizedDirectories
                currentDirSkippedDataless = outcome.skippedDatalessFiles
                currentDirLexicalCompleted = true
                rebuildGroupSnapshots()
            } catch is CancellationError {
                discardedStaleCallbackCount += 1
            } catch {
                guard isCurrentRequest(requestID: requestID, query: query, scope: scope) else { return }
                currentDirError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                currentDirLexicalCompleted = true
                rebuildGroupSnapshots()
            }

        case .archiveContext(let archivePath, let subpath):
            let hits = Self.searchOpenArchiveEntries(
                archivePath: archivePath,
                subpathPrefix: subpath,
                query: query,
                viewModel: viewModel
            )
            guard isCurrentRequest(requestID: requestID, query: query, scope: scope) else { return }
            currentDirLexicalItems = hits
            currentDirLexicalCompleted = true
            rebuildGroupSnapshots()

        case .externalDevice(_, let displayPath):
            guard isCurrentRequest(requestID: requestID, query: query, scope: scope) else { return }
            currentDirError = AppLocalizationState.shared.uiString(
                zh: "外部设备 (\(displayPath)) 不使用本机磁盘递归扫描",
                en: "External device (\(displayPath)) is isolated from local disk recursive scanning"
            )
            currentDirLexicalCompleted = true
            rebuildGroupSnapshots()

        case .unsupported(_, let reason):
            guard isCurrentRequest(requestID: requestID, query: query, scope: scope) else { return }
            currentDirError = reason
            currentDirLexicalCompleted = true
            rebuildGroupSnapshots()
        }
    }

    private static func searchOpenArchiveEntries(
        archivePath: String,
        subpathPrefix: String,
        query: String,
        viewModel: AppViewState?
    ) -> [GlobalSearchResultItem] {
        guard let viewModel else { return [] }
        let lowerQuery = query.lowercased()
        let archiveName = (archivePath as NSString).lastPathComponent
        let normalizedPrefix = subpathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefixWithSlash = normalizedPrefix.isEmpty ? "" : normalizedPrefix + "/"

        var entries = viewModel.explorerState.currentEntries
        if entries.isEmpty,
           let projection = viewModel.explorerState.acceptedArchiveProjection(
               for: viewModel.navigationState.activeSessionID,
               archivePath: archivePath
           ) {
            entries = projection.entries
        }

        var results: [GlobalSearchResultItem] = []
        for entry in entries {
            let cleanEntryPath = ArchivePasswordProbePolicy.normalizeEntryPath(entry.path)
            if !prefixWithSlash.isEmpty {
                guard cleanEntryPath == normalizedPrefix || cleanEntryPath.hasPrefix(prefixWithSlash) else {
                    continue
                }
            }
            guard entry.name.lowercased().contains(lowerQuery)
                    || cleanEntryPath.lowercased().contains(lowerQuery) else {
                continue
            }
            results.append(
                GlobalSearchResultItem(
                    id: "curarchive:\(archivePath):\(cleanEntryPath)",
                    title: entry.name,
                    subtitle: "\(archiveName) → \(cleanEntryPath)",
                    hitType: .archiveEntry,
                    archivePath: archivePath,
                    entrySubpath: cleanEntryPath,
                    targetWindowID: viewModel.windowID,
                    isDirectory: entry.isDirectory,
                    byteSize: entry.uncompressedSize,
                    score: 0.94,
                    matchBadge: nil
                )
            )
            if results.count >= 60 { break }
        }
        return results
    }

    // MARK: - Pipeline 2: Full-Disk Fast & Spotlight System Index Search

    private func runFullDiskFastAndSpotlightPipeline(
        query: String,
        scope: ExplorerSearchScopeIdentity,
        requestID: UInt64
    ) async {
        let fastHits: [GlobalSearchResultItem]
        if let override = fastProviderOverride {
            fastHits = await override(query)
        } else {
            fastHits = await GlobalSearchPanelController.shared.executeFastSearch(query: query)
        }
        guard isCurrentRequest(requestID: requestID, query: query, scope: scope) else { return }
        fullDiskFastItems = fastHits
        fullDiskFastCompleted = true
        rebuildGroupSnapshots()

        let extraScopes = Array(RootFolderAccessManager.shared.accessingURLs)
        let spotlightHits = await systemSearchProvider.searchAllAccessibleItems(
            query: query,
            maxResults: 40,
            additionalScopes: extraScopes
        )
        guard isCurrentRequest(requestID: requestID, query: query, scope: scope) else { return }
        fullDiskSpotlightItems = spotlightHits
        fullDiskSpotlightCompleted = true
        rebuildGroupSnapshots()
    }

    // MARK: - Pipeline 3: Debounced Semantic Search

    private func runSemanticPipeline(
        query: String,
        scope: ExplorerSearchScopeIdentity,
        requestID: UInt64
    ) async {
        guard !modelManager.isShuttingDown, !modelManager.isShutDown else {
            currentDirSemanticCompleted = true
            fullDiskSemanticCompleted = true
            rebuildGroupSnapshots()
            return
        }

        if semanticDebounceNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: semanticDebounceNanoseconds)
            guard isCurrentRequest(requestID: requestID, query: query, scope: scope) else { return }
        }

        let response = await semanticEngine.search(
            SemanticSearchRequest(
                requestId: requestID,
                windowId: windowID.uuidString,
                query: query,
                scopeIds: [],
                topK: 40
            )
        )
        guard isCurrentRequest(requestID: requestID, query: query, scope: scope) else { return }
        guard !response.isCancelled else {
            discardedStaleCallbackCount += 1
            return
        }

        isSemanticQueryEncodedForRequest = !response.degradedLexicalOnly
        hasSemanticContentHitsForRequest = response.hits.contains(where: { $0.matchKind != .lexicalOnly })
        let coverageSummary = await semanticEngine.indexedCoverageSummary()
        guard isCurrentRequest(requestID: requestID, query: query, scope: scope) else { return }
        indexedScopeCountForRequest = max(RootFolderAccessManager.shared.accessingURLs.count, coverageSummary.authorizedScopeCount)
        indexedSegmentCountForRequest = coverageSummary.totalIndexedSegments

        var dirGroupHits: [GlobalSearchResultItem] = []
        var fullGroupHits: [GlobalSearchResultItem] = []

        for hit in response.hits {
            let item = hit.toGlobalSearchResultItem()
            if Self.belongsToCurrentScope(item: item, scope: scope) {
                dirGroupHits.append(item)
            }
            fullGroupHits.append(item)
        }

        currentDirSemanticItems = dirGroupHits
        fullDiskSemanticItems = fullGroupHits
        currentDirSemanticCompleted = true
        fullDiskSemanticCompleted = true
        rebuildGroupSnapshots()
    }

    // MARK: - Snapshot Assembly & Deduplication

    private func rebuildGroupSnapshots() {
        let modelReady = modelManager.isSemanticSearchAvailable || isSemanticQueryEncodedForRequest
        currentDirectoryGroup = buildCurrentDirectoryGroupSnapshot(modelReady: modelReady)
        fullDiskGroup = buildFullDiskGroupSnapshot(modelReady: modelReady)

        if selectedResultID == nil {
            selectedResultID = currentDirectoryGroup.items.first?.id ?? fullDiskGroup.items.first?.id
        }
    }

    private func buildCurrentDirectoryGroupSnapshot(modelReady: Bool) -> ExplorerSearchGroupSnapshot {
        let mergedCurrentItems = Self.deduplicateWithinGroup(
            primary: currentDirSemanticItems,
            secondary: currentDirLexicalItems
        )
        let isCurrentLoading = !currentDirLexicalCompleted || (!currentDirSemanticCompleted && mergedCurrentItems.isEmpty)
        let currentPhase = Self.resolveGroupPhase(
            errorMessage: currentDirError,
            isLoading: isCurrentLoading,
            isEmpty: mergedCurrentItems.isEmpty
        )
        let currentCoverage = ExplorerSearchCoverageNote(
            scopeDescription: activeScope.displayPath,
            visitedEntryCount: currentDirVisitedEntries,
            maxDepthVisited: currentDirMaxDepthVisited,
            truncationReasons: currentDirTruncationReasons,
            skippedUnauthorizedSubdirectoryCount: currentDirSkippedUnauthorized,
            skippedDatalessFileCount: currentDirSkippedDataless,
            isModelReady: modelReady,
            isSemanticQueryEncoded: isSemanticQueryEncodedForRequest,
            hasSemanticContentHits: currentDirSemanticItems.contains(where: { $0.matchBadge == "AI" }),
            indexedScopeCount: indexedScopeCountForRequest,
            indexedSegmentCount: indexedSegmentCountForRequest
        )
        return ExplorerSearchGroupSnapshot(
            title: Self.currentDirectoryGroupTitle(),
            subtitle: activeScope.displayPath,
            phase: currentPhase,
            items: mergedCurrentItems,
            coverage: currentCoverage
        )
    }

    private func buildFullDiskGroupSnapshot(modelReady: Bool) -> ExplorerSearchGroupSnapshot {
        let mergedFullItems = Self.deduplicateWithinGroup(
            primary: fullDiskSemanticItems,
            secondary: fullDiskFastItems + fullDiskSpotlightItems
        )
        let isFullLoading = !fullDiskFastCompleted || !fullDiskSpotlightCompleted || (!fullDiskSemanticCompleted && mergedFullItems.isEmpty)
        let fullPhase = Self.resolveGroupPhase(
            errorMessage: nil,
            isLoading: isFullLoading,
            isEmpty: mergedFullItems.isEmpty
        )
        let fullCoverage = ExplorerSearchCoverageNote(
            scopeDescription: Self.fullDiskGroupSubtitle(),
            isModelReady: modelReady,
            isSemanticQueryEncoded: isSemanticQueryEncodedForRequest,
            hasSemanticContentHits: hasSemanticContentHitsForRequest,
            indexedScopeCount: indexedScopeCountForRequest,
            indexedSegmentCount: indexedSegmentCountForRequest
        )
        return ExplorerSearchGroupSnapshot(
            title: Self.fullDiskGroupTitle(),
            subtitle: Self.fullDiskGroupSubtitle(),
            phase: fullPhase,
            items: mergedFullItems,
            coverage: fullCoverage
        )
    }

    private static func resolveGroupPhase(
        errorMessage: String?,
        isLoading: Bool,
        isEmpty: Bool
    ) -> ExplorerSearchGroupPhase {
        if let errorMessage, isEmpty {
            return .error(errorMessage)
        }
        if isLoading && isEmpty {
            return .loading
        }
        return isEmpty ? .empty : .completed
    }

    /// Deduplicates items within a single group by canonical target identity.
    /// Items in `primary` (e.g. semantic hits with snippets/line numbers) win over `secondary` (lexical hits),
    /// ensuring late lexical arrivals never overwrite already-arrived semantic items.
    public static func deduplicateWithinGroup(
        primary: [GlobalSearchResultItem],
        secondary: [GlobalSearchResultItem]
    ) -> [GlobalSearchResultItem] {
        var seenKeys: Set<String> = []
        var result: [GlobalSearchResultItem] = []
        result.reserveCapacity(primary.count + secondary.count)

        for item in primary {
            let key = canonicalTargetIdentityKey(for: item)
            if seenKeys.insert(key).inserted {
                result.append(item)
            }
        }
        for item in secondary {
            let key = canonicalTargetIdentityKey(for: item)
            if seenKeys.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }

    /// Computes a canonical identity key for intra-group deduplication (`diskPath` or `archivePath::entrySubpath`).
    public static func canonicalTargetIdentityKey(for item: GlobalSearchResultItem) -> String {
        switch item.targetKind {
        case .archiveEntry(let archivePath, let entrySubpath):
            let canonicalArchive = URL(fileURLWithPath: archivePath).standardizedFileURL.resolvingSymlinksInPath().path
            let cleanEntry = ArchivePasswordProbePolicy.normalizeEntryPath(entrySubpath)
            return "archiveEntry:\(canonicalArchive)::\(cleanEntry)"
        case .archiveFile(let archivePath):
            let canonicalArchive = URL(fileURLWithPath: archivePath).standardizedFileURL.resolvingSymlinksInPath().path
            return "File:\(canonicalArchive)"
        case .diskItem(let path):
            let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            return "File:\(canonicalPath)"
        case .quickAction:
            return "action:\(item.id)"
        }
    }

    public static func belongsToCurrentScope(
        item: GlobalSearchResultItem,
        scope: ExplorerSearchScopeIdentity
    ) -> Bool {
        switch scope {
        case .physicalDirectory(let dirURL):
            return belongsToPhysicalDirectoryScope(item: item, dirURL: dirURL)
        case .archiveContext(let archivePath, let subpath):
            return belongsToArchiveScope(item: item, archivePath: archivePath, subpath: subpath)
        case .externalDevice, .unsupported:
            return false
        }
    }

    private static func belongsToPhysicalDirectoryScope(
        item: GlobalSearchResultItem,
        dirURL: URL
    ) -> Bool {
        let rootCanonical = dirURL.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootCanonical.hasSuffix("/") ? rootCanonical : rootCanonical + "/"
        let candidatePath: String? = switch item.targetKind {
        case .diskItem(let path): path
        case .archiveFile(let archivePath): archivePath
        case .archiveEntry(let archivePath, _): archivePath
        case .quickAction: nil
        }
        guard let candidatePath else { return false }
        let canonicalCandidate = URL(fileURLWithPath: candidatePath).standardizedFileURL.resolvingSymlinksInPath().path
        return canonicalCandidate.hasPrefix(prefix)
    }

    private static func belongsToArchiveScope(
        item: GlobalSearchResultItem,
        archivePath: String,
        subpath: String
    ) -> Bool {
        let canonicalScopeArchive = URL(fileURLWithPath: archivePath).standardizedFileURL.resolvingSymlinksInPath().path
        guard case .archiveEntry(let hitArchive, let entrySubpath) = item.targetKind else {
            return false
        }
        let canonicalHitArchive = URL(fileURLWithPath: hitArchive).standardizedFileURL.resolvingSymlinksInPath().path
        guard canonicalHitArchive == canonicalScopeArchive else { return false }
        let cleanSubpath = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanSubpath.isEmpty else { return true }
        let cleanEntry = ArchivePasswordProbePolicy.normalizeEntryPath(entrySubpath)
        return cleanEntry == cleanSubpath || cleanEntry.hasPrefix(cleanSubpath + "/")
    }

    // MARK: - Navigation & Reveal in Existing Miller Columns

    /// Selects a search result item and reveals it in `viewModel`'s existing Miller columns
    /// and preview inspector, clearing `explorerState.searchQuery` so the columns become visible.
    @discardableResult
    public func activateResult(
        _ item: GlobalSearchResultItem,
        in viewModel: AppViewState,
        clearQueryAfterNavigation: Bool = true
    ) -> Task<Bool, Never>? {
        selectedResultID = item.id
        if clearQueryAfterNavigation {
            viewModel.explorerState.searchQuery = ""
            clearSearch()
        }

        switch item.targetKind {
        case .diskItem(let path):
            revealDiskPathInMillerColumns(path: path, in: viewModel)
            return nil

        case .archiveFile(let archivePath):
            let archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
            viewModel.openArchiveAsFolder(url: archiveURL)
            return nil

        case .archiveEntry(let archivePath, let entrySubpath):
            return viewModel.selectArchiveEntryInWindow(
                archivePath: archivePath,
                entrySubpath: entrySubpath,
                highlightLine: item.matchedLineStart
            )

        case .quickAction:
            return nil
        }
    }

    private func revealDiskPathInMillerColumns(path: String, in viewModel: AppViewState) {
        let targetURL = URL(fileURLWithPath: path).standardizedFileURL
        let currentRoot = viewModel.navigationState.currentDirectory.standardizedFileURL
        let rootPrefix = currentRoot.path.hasSuffix("/") ? currentRoot.path : currentRoot.path + "/"

        if viewModel.explorerState.currentArchivePath != nil {
            viewModel.closeCurrentArchive()
        }
        viewModel.navigationState.activeTab = .home

        if targetURL.path != currentRoot.path && targetURL.path.hasPrefix(rootPrefix) {
            viewModel.initialSelectedFilePath = targetURL.path
            let diskItem = DiskItemInfo(url: targetURL)
            viewModel.selectionState.select(diskItem)
            NotificationCenter.default.post(
                name: NSNotification.Name("TTZipRevealDescendantInMillerColumns"),
                object: targetURL.path,
                userInfo: ["windowID": viewModel.windowID]
            )
        } else {
            viewModel.revealItemInWindow(targetURL)
        }
    }
}
