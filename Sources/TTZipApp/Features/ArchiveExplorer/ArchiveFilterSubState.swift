// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import TTMediaKit
import TTZipCore
import TTZipPreviewKit
import TTZipUI

/// Archive explorer and in-archive lexical/semantic filter sub-state.
@Observable
@MainActor
public final class ArchiveExplorerState {
    // Internal storage supports the same owner's companion-file API; never public writable state.
    internal var acceptedArchiveResources: [UUID: [String: AcceptedArchiveResource]] = [:]

    public var currentArchivePath: String? = nil
    public var activePassword: String? = nil

    public typealias VfsSnapshotContext = AnyObject & Sendable
    public var snapshotContext: VfsSnapshotContext? = nil
    public var vfsSession: VfsSession? = nil
    public var performSearch: (@Sendable (String, Int) -> [UInt32])? = nil
    public var getNodeCount: (@Sendable () -> Int)? = nil

    public var currentEntries: [ArchiveEntry] = [] {
        didSet {
            rebuildIndexAndResetFilter()
        }
    }
    public var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            applyFilter()
        }
    }

    /// Size threshold above which index build and search execute off the main actor in a cancellable Task.
    public let asyncThreshold: Int

    /// Flag indicating whether background search or index build is actively executing.
    public private(set) var isSearching: Bool = false

    private var filteredIndices: ContiguousArray<UInt32>? = nil
    private var lastFilteredQuery: String = ""
    private var searchGeneration: UInt64 = 0
    private var activeSearchTask: Task<Void, Never>? = nil

    /// Service coordinating background query vector encoding on ANE and hybrid search dispatch.
    public let semanticSearchService: SemanticSearchService

    public init(
        asyncThreshold: Int = 50_000,
        semanticSearchService: SemanticSearchService = SemanticSearchService()
    ) {
        self.asyncThreshold = asyncThreshold
        self.semanticSearchService = semanticSearchService
    }

    /// Returns a non-copying RandomAccessCollection view of entries matching active `searchQuery`.
    public var filteredEntries: ArchiveFilteredEntriesView {
        guard let indices = filteredIndices else {
            return ArchiveFilteredEntriesView(source: currentEntries, matchingIndices: nil)
        }
        let mapped = ContiguousArray(indices.map { Int32($0) })
        return ArchiveFilteredEntriesView(source: currentEntries, matchingIndices: mapped)
    }

    /// Forces index rebuilding, for use after modifying `currentEntries` in-place.
    public func reloadIndex() {
        rebuildIndexAndResetFilter()
    }

    /// Awaits completion of any in-flight background search filtering tasks.
    public func waitForActiveSearch() async {
        if let searchTask = activeSearchTask {
            _ = await searchTask.value
        }
        await semanticSearchService.waitForActiveSearch()
    }

    private func cancelActiveTasks() {
        activeSearchTask?.cancel()
        activeSearchTask = nil
        semanticSearchService.cancel()
    }

    private func rebuildIndexAndResetFilter() {
        cancelActiveTasks()
        searchGeneration &+= 1
        lastFilteredQuery = ""
        filteredIndices = nil

        let hasActiveQuery = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasActiveQuery {
            applyFilter()
        } else {
            isSearching = false
        }
    }

    private func resetEmptyFilter() {
        cancelActiveTasks()
        searchGeneration &+= 1
        isSearching = false
        lastFilteredQuery = ""
        filteredIndices = nil
    }

    private func refinedCandidateIndices(for trimmed: String) -> ContiguousArray<UInt32>? {
        guard !lastFilteredQuery.isEmpty, trimmed.hasPrefix(lastFilteredQuery) else {
            return nil
        }
        return filteredIndices
    }

    private func applyFilter() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            resetEmptyFilter()
            return
        }
        guard trimmed != lastFilteredQuery else { return }
        guard performSearch != nil || !currentEntries.isEmpty || vfsSession != nil else {
            isSearching = true
            filteredIndices = nil
            return
        }

        let candidates = refinedCandidateIndices(for: trimmed)
        let candidateCount = candidates?.count ?? (currentEntries.isEmpty ? 100_000 : currentEntries.count)

        cancelActiveTasks()
        searchGeneration &+= 1
        let currentGen = searchGeneration

        if candidateCount <= asyncThreshold {
            isSearching = false
            filteredIndices = Self.executeLexicalSearch(
                query: trimmed,
                performSearch: performSearch,
                vfsSession: vfsSession,
                entries: currentEntries,
                candidates: candidates
            )
            lastFilteredQuery = trimmed
        } else {
            runAsyncLexicalFilter(query: trimmed, generation: currentGen, candidates: candidates)
        }

        scheduleSemanticEnrichmentIfNeeded(query: trimmed, generation: currentGen)
    }

    private func runAsyncLexicalFilter(
        query: String,
        generation: UInt64,
        candidates: ContiguousArray<UInt32>?
    ) {
        isSearching = true
        let searchFn = performSearch
        let entries = currentEntries
        let session = vfsSession
        activeSearchTask = Task.detached(priority: .userInitiated) { [searchFn, entries, generation, candidates, session] in
            guard !Task.isCancelled else { return }
            let results = Self.executeLexicalSearch(
                query: query,
                performSearch: searchFn,
                vfsSession: session,
                entries: entries,
                candidates: candidates
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.activeSearchTask = nil
                guard generation == self.searchGeneration else { return }
                self.filteredIndices = results
                self.lastFilteredQuery = query
                self.isSearching = false
            }
        }
    }

    private func scheduleSemanticEnrichmentIfNeeded(query: String, generation: UInt64) {
        guard let session = vfsSession, session.hasVectorEmbeddings() else { return }
        semanticSearchService.performHybridSearch(
            query: query,
            generation: generation,
            session: session,
            limit: 1000,
            lexicalWeight: 0.6,
            semanticWeight: 0.4
        ) { [weak self] hybridMatches in
            guard let self, generation == self.searchGeneration else { return }
            self.filteredIndices = ContiguousArray(hybridMatches.map { $0.nodeId })
            self.isSearching = false
        }
    }

    nonisolated private static func executeLexicalSearch(
        query: String,
        performSearch: (@Sendable (String, Int) -> [UInt32])?,
        vfsSession: VfsSession?,
        entries: [ArchiveEntry],
        candidates: ContiguousArray<UInt32>?
    ) -> ContiguousArray<UInt32> {
        if let searchFn = performSearch {
            return ContiguousArray(searchFn(query, 100_000))
        }
        if let session = vfsSession {
            guard let paged = try? session.searchTopK(query: query, limit: 1000) else {
                return []
            }
            return ContiguousArray(paged.map { $0.nodeId })
        }
        let lower = query.lowercased()
        if let candidates {
            return ContiguousArray(candidates.filter { entries[Int($0)].path.lowercased().contains(lower) })
        }
        return ContiguousArray(entries.indices.compactMap {
            entries[$0].path.lowercased().contains(lower) ? UInt32($0) : nil
        })
    }
}

// MARK: - AppViewState Archive Inspection & BrowserWindowControlling

extension AppViewState {
    /// Abandons a pending browse password operation when the user navigates away.
    internal func invalidateBrowsePasswordOperationIfPending() {
        guard let context = pendingPasswordContext, case .browse = context.kind else { return }
        passwordOperationEpoch &+= 1
        pendingPasswordContext = nil
        overlayState.showPasswordPrompt = false
        overlayState.pendingEncryptedPath = nil
    }

    private func committedBrowsePasswordTarget(for context: ArchivePasswordOperationContext) -> UUID? {
        guard isPasswordOperationStillCurrent(operationID: context.operationID, epoch: context.captureEpoch),
              let capturedTabID = context.tabID,
              navigationState.activeSessionID == capturedTabID else {
            return nil
        }
        return capturedTabID
    }

    internal func applyUnverifiedBrowsableCatalogResult(
        context: ArchivePasswordOperationContext,
        inspection: InspectResult
    ) {
        guard !isWindowClosing,
              let targetTabID = committedBrowsePasswordTarget(for: context),
              Self.matchesArchiveInspection(inspection, archivePath: context.archivePath) else { return }
        let archivePath = context.archivePath
        explorerState.installAcceptedArchiveProjection(
            AcceptedArchiveDirectoryProjection(inspection: inspection),
            evidence: .directoryBrowsableUnverified, for: targetTabID
        )
        passwordEvidenceState = .directoryBrowsableUnverified
        explorerState.currentArchivePath = archivePath
        explorerState.activePassword = nil
        explorerState.currentEntries = inspection.entries
        navigationState.setArchive(path: archivePath, forTab: targetTabID, restoringLocation: context.browsingLocation)
        pruneUnreachableArchiveResources()
        taskState.statusMessage = AppLocalizationState.shared.t(ArchivePasswordLocaleKey.directoryBrowsableUnverifiedStatus)
        recordRecentArchive(url: URL(fileURLWithPath: archivePath))
        AppIntentDispatcher.shared.syncWindowArchiveSession(for: self)
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: archivePath)
    }

    internal func applyVerifiedBrowseResult(
        context: ArchivePasswordOperationContext,
        inspection: InspectResult,
        verifiedPassword: String,
        scope: ArchivePasswordVerificationScope
    ) {
        guard !isWindowClosing,
              let targetTabID = committedBrowsePasswordTarget(for: context),
              Self.matchesArchiveInspection(inspection, archivePath: context.archivePath) else { return }
        let archivePath = context.archivePath
        explorerState.installAcceptedArchiveProjection(
            AcceptedArchiveDirectoryProjection(inspection: inspection),
            evidence: .verified(scope), for: targetTabID
        )
        ArchivePasswordStore.shared.setPassword(verifiedPassword, for: archivePath)
        passwordEvidenceState = .verified(scope)
        explorerState.currentArchivePath = archivePath
        explorerState.activePassword = verifiedPassword
        explorerState.currentEntries = inspection.entries
        navigationState.setArchive(path: archivePath, forTab: targetTabID, restoringLocation: context.browsingLocation)
        pruneUnreachableArchiveResources()
        taskState.statusMessage = AppLocalizationState.shared.t(ArchivePasswordLocaleKey.passwordVerifiedStatus)
        recordRecentArchive(url: URL(fileURLWithPath: archivePath))
        AppIntentDispatcher.shared.syncWindowArchiveSession(for: self)
        prefetchArchiveEntries(path: archivePath, entries: inspection.entries, count: 16)
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: archivePath)
    }

    internal func inspectHeaderEncryptedArchive(
        path: String,
        explicitPassword: String?
    ) async throws -> ArchiveInspectionWithEvidence {
        if let explicitPassword, !explicitPassword.isEmpty {
            let res = try await passwordDriver.inspectArchive(archivePath: path, password: explicitPassword, autoVaultUnlock: false)
            return ArchiveInspectionWithEvidence(result: res, verifiedPassword: explicitPassword, evidence: .verified(.headerCatalog), isVaultUnlocked: false)
        }
        if let cached = reusablePasswordCandidate(for: path, explicitPassword: nil) {
            do {
                let res = try await passwordDriver.inspectArchive(archivePath: path, password: cached, autoVaultUnlock: false)
                return ArchiveInspectionWithEvidence(result: res, verifiedPassword: cached, evidence: .verified(.headerCatalog), isVaultUnlocked: false)
            } catch {
                let classified = ArchivePasswordErrorClassifier.classify(error)
                guard classified.category == .wrongPassword else { throw error }
                evictCachedPasswordIfMatches(cached, for: path)
            }
        }
        if passwordVault.autoUnlockArchives {
            let res = try await passwordDriver.inspectArchive(archivePath: path, password: nil, autoVaultUnlock: true)
            let isVaultUnlocked = (res.unlockedPassword != nil && !(res.unlockedPassword?.isEmpty ?? true))
            return ArchiveInspectionWithEvidence(result: res, verifiedPassword: res.unlockedPassword, evidence: .verified(.headerCatalog), isVaultUnlocked: isVaultUnlocked)
        }
        let res = try await passwordDriver.inspectArchive(archivePath: path, password: nil, autoVaultUnlock: false)
        return ArchiveInspectionWithEvidence(result: res, verifiedPassword: nil, evidence: .notEncrypted, isVaultUnlocked: false)
    }

    internal func inspectArchiveWithEvidence(
        path: String,
        explicitPassword: String?,
        unauthenticatedInspection: InspectResult? = nil
    ) async throws -> ArchiveInspectionWithEvidence {
        let unauthRes: InspectResult
        if let unauthenticatedInspection {
            unauthRes = unauthenticatedInspection
        } else {
            do {
                unauthRes = try await passwordDriver.inspectArchive(archivePath: path, password: nil, autoVaultUnlock: false)
            } catch {
                let classified = ArchivePasswordErrorClassifier.classify(error)
                guard classified.category == .wrongPassword else { throw error }
                return try await inspectHeaderEncryptedArchive(path: path, explicitPassword: explicitPassword)
            }
        }
        guard unauthRes.entries.contains(where: \.isEncrypted) else {
            return ArchiveInspectionWithEvidence(result: unauthRes, verifiedPassword: nil, evidence: .notEncrypted, isVaultUnlocked: false)
        }
        if let explicitPassword, !explicitPassword.isEmpty {
            let outcome = await verifyPlaintextCatalogPassword(
                archivePath: path, entries: unauthRes.entries, password: explicitPassword
            )
            switch outcome {
            case .verified(let scope):
                return ArchiveInspectionWithEvidence(result: unauthRes, verifiedPassword: explicitPassword, evidence: .verified(scope), isVaultUnlocked: false)
            case .noAvailableEvidence:
                return ArchiveInspectionWithEvidence(result: unauthRes, verifiedPassword: nil, evidence: .directoryBrowsableUnverified, isVaultUnlocked: false)
            case .wrongPassword:
                throw ArchiveError.wrongPassword(archivePath: path)
            case .otherFailure(let category, let message):
                throw ArchivePasswordProbeFailure(category: category, message: message)
            }
        }
        return ArchiveInspectionWithEvidence(result: unauthRes, verifiedPassword: nil, evidence: .directoryBrowsableUnverified, isVaultUnlocked: false)
    }

    // MARK: - BrowserWindowControlling Conformance

    public var currentDirectoryURL: URL { navigationState.currentDirectory }
    public var currentArchivePath: String? { explorerState.currentArchivePath }
    public var isShowingImmersiveMedia: Bool { overlayState.showImmersiveMediaBrowser }
    public var selectedItemPath: String? { selectionState.selectedDiskItem?.path }

    public var isBrowsingDefaultPristineState: Bool {
        let defaultDownloads = URL(
            fileURLWithPath: (NSHomeDirectory() as NSString).expandingTildeInPath + "/Downloads"
        ).standardizedFileURL
        return explorerState.currentArchivePath == nil
            && navigationState.tabSessions.count == 1
            && !navigationState.canGoBack
            && !navigationState.canGoForward
            && selectionState.selectedDiskItem == nil
            && navigationState.currentDirectory.standardizedFileURL == defaultDownloads
    }

    public func applyLaunchSeed(_ seed: BrowserWindowLaunchSeed) {
        hasAppliedLaunchSeed = true
        if let dirURL = seed.initialDirectoryURL {
            activeBrowsingDirectory = nil
            navigationState.currentDirectory = dirURL.standardizedFileURL
        }
        if let selectedPath = seed.initialSelectedPath {
            initialSelectedFilePath = selectedPath
            let selURL = URL(fileURLWithPath: selectedPath).standardizedFileURL
            selectionState.selectedDiskItem = DiskItemInfo(url: selURL)
            selectionState.selectedDiskItems = selectionState.selectedDiskItem.map { [$0] }
        }
        if let archiveURL = seed.initialArchiveURL {
            if let entrySubpath = seed.initialArchiveEntrySubpath, !entrySubpath.isEmpty {
                _ = selectArchiveEntryInWindow(
                    archivePath: archiveURL.path,
                    entrySubpath: entrySubpath,
                    highlightLine: seed.initialHighlightLine
                )
            } else {
                openArchiveAsFolder(url: archiveURL, password: seed.initialPassword)
            }
        }
    }

    public func navigateToDirectory(_ url: URL) {
        let standardized = url.standardizedFileURL
        if explorerState.currentArchivePath != nil { closeCurrentArchive() }
        activeBrowsingDirectory = nil
        navigationState.activeTab = .home
        navigationState.currentDirectory = standardized
        selectionState.selectedDiskItem = nil
        selectionState.selectedDiskItems = nil
        RecentLocationsStore.shared.recordDirectory(url: standardized)
    }

    public func revealItemInWindow(_ itemURL: URL) {
        let standardized = itemURL.standardizedFileURL
        if standardized.path == "/" {
            navigateToDirectory(standardized)
            return
        }
        let parentDir = standardized.deletingLastPathComponent().standardizedFileURL
        if explorerState.currentArchivePath != nil { closeCurrentArchive() }
        let diskItem = DiskItemInfo(url: standardized)
        initialSelectedFilePath = standardized.path
        activeBrowsingDirectory = diskItem.isBrowsableDirectory ? standardized : nil
        selectionState.selectedDiskItem = diskItem
        selectionState.selectedDiskItems = [diskItem]
        navigationState.activeTab = .home
        navigationState.currentDirectory = parentDir
    }

    public func openArchiveInWindow(at url: URL, password: String?, bookmarkSession: ActiveBookmarkSession?) {
        openArchiveAsFolder(url: url, password: password, bookmarkSession: bookmarkSession)
    }

    public func prepareForWindowClose() {
        guard !isWindowClosing else { return }
        isWindowClosing = true
        explorerState.discardAllAcceptedArchiveProjections()
        operationEpoch &+= 1
        passwordOperationEpoch &+= 1
        searchNavigationGeneration &+= 1
        pendingPasswordContext = nil
        overlayState.showPasswordPrompt = false
        overlayState.pendingEncryptedPath = nil
        explorerState.currentArchivePath = nil
        explorerState.activePassword = nil
        explorerState.currentEntries = []
        passwordEvidenceState = .notEncrypted

        if let collisionPrompt = overlayState.collisionPrompt {
            overlayState.collisionPrompt = nil
            collisionPrompt.resolver(.stop, false)
        }

        let shouldStopPlayback = BrowserWindowRegistry.shared.shouldStopGlobalPlaybackOnWindowClose(
            for: windowID,
            isShowingImmersiveMedia: overlayState.showImmersiveMediaBrowser
        )
        closeImmersiveMedia()
        if shouldStopPlayback { TTPreviewPlaybackManager.stopAll() }

        presentationCoordinator.dismissAll()
        BrowserWindowRegistry.shared.unregister(id: windowID)
        AppIntentDispatcher.shared.unregister(windowID: windowID)
    }

    // MARK: - Accepted Archive Resource & Prompt Lifecycle

    public func clearArchiveVFSCache(path: String) {
        VFSLz4CachePool.shared.clearSession(sessionId: path)
    }

    public func cancelPasswordPrompt() {
        self.passwordOperationEpoch &+= 1
        self.pendingPasswordContext = nil
        self.overlayState.showPasswordPrompt = false
        self.overlayState.pendingEncryptedPath = nil
        if self.explorerState.currentEntries.isEmpty {
            self.explorerState.currentArchivePath = nil
            self.explorerState.activePassword = nil
            self.passwordEvidenceState = .notEncrypted
            self.taskState.statusMessage = ArchivePasswordLocaleKey.operationCancelled.localized()
        } else {
            self.passwordEvidenceState = .directoryBrowsableUnverified
        }
    }

    public func reset() {
        explorerState.discardAcceptedArchiveProjections(for: navigationState.activeSessionID)
        if let path = self.explorerState.currentArchivePath {
            VFSLz4CachePool.shared.clearSession(sessionId: path)
        }
        self.operationEpoch &+= 1
        self.passwordOperationEpoch &+= 1
        self.searchNavigationGeneration &+= 1
        self.selectedArchiveHighlightLine = nil
        self.pendingPasswordContext = nil
        self.passwordEvidenceState = .notEncrypted
        self.overlayState.showPasswordPrompt = false
        self.overlayState.pendingEncryptedPath = nil
        self.explorerState.currentArchivePath = nil
        self.explorerState.activePassword = nil
        self.explorerState.currentEntries = []
        self.navigationState.clearArchiveForActiveTab()
        AppIntentDispatcher.shared.unregisterSession(id: self.windowID)
        self.taskState.invalidateArchiveRequest()
        self.taskState.statusMessage = "Ready"
        self.navigationState.activeTab = .home
        leaveClosedArchiveLocation()
    }

    internal static func matchesArchiveInspection(_ result: InspectResult, archivePath: String) -> Bool {
        URL(fileURLWithPath: result.archivePath).standardizedFileURL.path
            == URL(fileURLWithPath: archivePath).standardizedFileURL.path
    }

    internal func reconcileAcceptedArchiveResources() {
        explorerState.retainAcceptedArchiveProjections(for: Set(navigationState.tabSessions.map(\.id)))
    }

    internal func retireAcceptedArchiveResources(for sessionID: UUID) {
        explorerState.discardAcceptedArchiveProjections(for: sessionID)
    }

    internal func restoreAcceptedArchiveResources(for sessionID: UUID, archivePath: String) -> Bool {
        guard !isWindowClosing, navigationState.activeSessionID == sessionID,
              let projection = explorerState.acceptedArchiveProjection(for: sessionID, archivePath: archivePath),
              let evidence = explorerState.acceptedArchiveEvidence(for: sessionID, archivePath: archivePath) else {
            return false
        }
        explorerState.currentArchivePath = projection.archivePath
        explorerState.currentEntries = projection.entries
        explorerState.activePassword = nil
        passwordEvidenceState = evidence
        AppIntentDispatcher.shared.syncWindowArchiveSession(for: self)
        return true
    }

    internal func invalidateAcceptedArchiveResources(archivePath: String) {
        invalidateActiveArchiveWork()
        explorerState.invalidateAcceptedArchiveProjections(archivePath: archivePath)
        if let current = explorerState.currentArchivePath,
           URL(fileURLWithPath: current).standardizedFileURL.path == URL(fileURLWithPath: archivePath).standardizedFileURL.path {
            explorerState.currentEntries = []
            explorerState.activePassword = nil
            passwordEvidenceState = .notEncrypted
            selectionState.clear()
            AppIntentDispatcher.shared.unregisterSession(id: windowID)
        }
        NotificationCenter.default.post(name: NSNotification.Name("TTZipArchiveUnlockedRefresh"), object: archivePath)
    }
}
