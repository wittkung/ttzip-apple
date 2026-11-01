// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import Observation

import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTKitUI
#if canImport(TTZipAppServices)
import TTZipAppServices
#endif

/// Window layout presentation mode for standard and immersive media focus states.
public enum WindowLayoutMode: Sendable, Hashable {
    case standard
    case mediaFocus
}

import TTMediaKit

/// Strongly-typed immutable descriptor for an item displayed in the immersive media browser.
public typealias ImmersiveMediaItem = TTMediaKit.ImmersiveMediaItem

extension NSNotification.Name {
    public static let ttzipToggleMediaFocus = NSNotification.Name("TTZipToggleMediaFocusNotification")
}

/// Strongly-typed immutable descriptor for a tab in the multi-directory tab bar.
public struct DirectoryTabItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var url: URL
    public var customTitle: String?
    public var isCompressWorkspace: Bool
    public var isStorageInspector: Bool
    public var history: [URL]
    public var historyIndex: Int
    
    @MainActor
    public var title: String {
        let l10n = AppLocalizationState.shared
        if isCompressWorkspace {
            return l10n.t(L10n.Sidebar.newArchive)
        }
        if isStorageInspector {
            return l10n.t(L10n.Sidebar.storageInspector)
        }
        return customTitle ?? TTZipPathPresentationService.shared.displayName(
            for: url,
            language: l10n.currentLanguage
        )
    }
    
    public init(
        id: UUID = UUID(),
        url: URL,
        customTitle: String? = nil,
        isCompressWorkspace: Bool = false,
        isStorageInspector: Bool = false,
        history: [URL]? = nil,
        historyIndex: Int = 0
    ) {
        self.id = id
        self.url = url
        self.customTitle = customTitle
        self.isCompressWorkspace = isCompressWorkspace
        self.isStorageInspector = isStorageInspector
        self.history = history ?? [url]
        self.historyIndex = historyIndex
    }
    
    public var canGoBack: Bool {
        historyIndex > 0
    }
    
    public var canGoForward: Bool {
        historyIndex < history.count - 1
    }
    
    public var canGoUp: Bool {
        url.standardizedFileURL.path != "/" && url.standardizedFileURL.pathComponents.count > 1
    }
    
    public mutating func pushURL(_ newURL: URL) {
        let standardized = newURL.standardizedFileURL
        guard standardized.path != url.standardizedFileURL.path else { return }
        if historyIndex + 1 < history.count {
            history = Array(history.prefix(historyIndex + 1))
        }
        history.append(standardized)
        historyIndex = history.count - 1
        url = standardized
    }
    
    public mutating func back() -> URL? {
        guard canGoBack else { return nil }
        historyIndex -= 1
        url = history[historyIndex]
        return url
    }
    
    public mutating func forward() -> URL? {
        guard canGoForward else { return nil }
        historyIndex += 1
        url = history[historyIndex]
        return url
    }
    
    public mutating func up() -> URL? {
        guard canGoUp else { return nil }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        pushURL(parent)
        return parent
    }
}

/// 1. Navigation and routing state.
@Observable
@MainActor
public final class NavigationState {
    public var activeTab: WorkspaceTab = .home
    public var isInspectorVisible: Bool = true
    public var isLeftSidebarVisible: Bool = true
    private var isNavigatingHistory: Bool = false

    /// Invoked when the active browsing context changes.
    ///
    /// The owning view state uses it to abandon foreground work that was bound to the page the
    /// user just left, so that a late result can never land on the page the user navigated to.
    @ObservationIgnored public var onActiveBrowsingContextChange: (@MainActor () -> Void)?
    @ObservationIgnored internal var onSessionsRetired: (@MainActor ([UUID]) -> Void)?

    /// Suppresses the context-change callback while already committed state is applied.
    ///
    /// Committing an archive into the active tab writes its accepted virtual location. That is
    /// state the owner applies on purpose and not a navigation, so it must not invalidate the
    /// request that is committing it.
    @ObservationIgnored private var isApplyingCommittedState: Bool = false

    public var currentDirectory: URL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).expandingTildeInPath + "/Downloads").standardizedFileURL {
        didSet {
            if !isNavigatingHistory, let active = activeTabSession, !active.kind.isCompressWorkspace {
                updateActiveURL(currentDirectory)
            }
            guard !isApplyingCommittedState else { return }
            onActiveBrowsingContextChange?()
        }
    }
    public var isOmnibarFocused: Bool = false
    public var layoutMode: WindowLayoutMode = .standard
    
    // MARK: - Multi-Directory Tab Session State (SSOT)
    public private(set) var tabSessions: [WorkspaceTabSession] = [
        WorkspaceTabSession(url: URL(fileURLWithPath: (NSHomeDirectory() as NSString).expandingTildeInPath + "/Downloads").standardizedFileURL)
    ] {
        didSet {
            let liveIDs = Set(tabSessions.map(\.id))
            let retired = oldValue.map(\.id).filter { !liveIDs.contains($0) }
            if !retired.isEmpty { onSessionsRetired?(retired) }
        }
    }
    public private(set) var activeTabIndex: Int = 0
    public private(set) var activeSessionID: UUID = UUID() {
        didSet {
            guard oldValue != self.activeSessionID else { return }
            onActiveBrowsingContextChange?()
        }
    }

    /// Read-only presentation projection; session mutations belong to navigation intents.
    public var directoryTabs: [DirectoryTabItem] {
        tabSessions.map { session in
            DirectoryTabItem(
                id: session.id,
                url: session.historyStack.current,
                customTitle: session.customTitle,
                isCompressWorkspace: session.kind.isCompressWorkspace,
                isStorageInspector: session.kind.isStorageInspector,
                history: session.historyStack.backStack + [session.historyStack.current] + session.historyStack.forwardStack.reversed(),
                historyIndex: session.historyStack.backStack.count
            )
        }
    }

    public var activeTabSession: WorkspaceTabSession? {
        tabSessions.first(where: { $0.id == activeSessionID })
    }

    public var activeDirectoryTab: DirectoryTabItem? {
        guard directoryTabs.indices.contains(activeTabIndex) else { return nil }
        return directoryTabs[activeTabIndex]
    }
    
    public var isCompressWorkspaceActive: Bool {
        activeTabSession?.kind.isCompressWorkspace == true
    }
    
    public var isStorageInspectorActive: Bool {
        activeTabSession?.kind.isStorageInspector == true || currentDirectory.absoluteString == "ttzip://storage-inspector"
    }
    
    public init() {
        let initialURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).expandingTildeInPath + "/Downloads").standardizedFileURL
        let initialSession = WorkspaceTabSession(url: initialURL)
        self.tabSessions = [initialSession]
        self.activeSessionID = initialSession.id
        self.activeTabIndex = 0
    }
    
    public func triggerOmnibarFocus() {
        self.isOmnibarFocused = true
    }
    
    public func toggleMediaFocusMode() {
        layoutMode = (layoutMode == .standard ? .mediaFocus : .standard)
    }
    
    public func setLayoutMode(_ mode: WindowLayoutMode) {
        self.layoutMode = mode
    }
    
    // MARK: - Tab Management Operations
    
    /// Shows a directory in a browsing session, replacing the active tool slot only if needed.
    public func showDirectory(at url: URL) {
        guard tabSessions.indices.contains(activeTabIndex) else { return }
        let targetURL = url.standardizedFileURL
        switch tabSessions[activeTabIndex].kind {
        case .compressWorkspace, .storageInspector:
            if let browsingIndex = tabSessions.firstIndex(where: { $0.kind.isDirectory || $0.kind.isArchive }) {
                switchToTab(at: browsingIndex)
            } else {
                let session = WorkspaceTabSession(url: targetURL)
                tabSessions[activeTabIndex] = session
                activeSessionID = session.id
            }
        case .directory, .archive:
            break
        }
        clearArchiveForActiveTab()
        activeTab = .home
        currentDirectory = targetURL
    }

    @discardableResult
    public func openTab(session: WorkspaceTabSession) -> UUID {
        tabSessions.append(session)
        activeTabIndex = tabSessions.count - 1
        activeSessionID = session.id
        if session.kind.isCompressWorkspace {
            activeTab = .compressWorkspace
        } else {
            activeTab = .home
            currentDirectory = session.historyStack.current
        }
        return session.id
    }

    @discardableResult
    public func openTab(url: URL? = nil) -> UUID {
        let targetURL = url ?? currentDirectory
        return openTab(session: WorkspaceTabSession(url: targetURL))
    }

    public func openNewTab(url: URL? = nil) {
        _ = openTab(url: url)
    }
    
    public func openCompressWorkspaceTab() {
        if let existing = tabSessions.first(where: { $0.kind.isCompressWorkspace }) {
            switchToTab(id: existing.id)
        } else {
            let session = WorkspaceTabSession(url: URL(string: "ttzip://compress-workspace")!, kind: .compressWorkspace, customTitle: nil)
            _ = openTab(session: session)
        }
        activeTab = .compressWorkspace
    }
    
    public func closeCompressWorkspaceTab() {
        if let existing = tabSessions.first(where: { $0.kind.isCompressWorkspace }) {
            closeTab(id: existing.id)
        }
    }
    
    public func openStorageInspectorTab() {
        let storageURL = URL(string: "ttzip://storage-inspector")!
        if let existing = tabSessions.first(where: { $0.kind.isStorageInspector }) {
            switchToTab(id: existing.id)
            currentDirectory = storageURL
        } else {
            let session = WorkspaceTabSession(url: storageURL, kind: .storageInspector, customTitle: "存储透视")
            _ = openTab(session: session)
            currentDirectory = storageURL
        }
        activeTab = .home
    }
    
    public func closeStorageInspectorTab() {
        if let existing = tabSessions.first(where: { $0.kind.isStorageInspector }) {
            closeTab(id: existing.id)
        }
    }

    public func closeTab(id: UUID) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        closeTab(at: index)
    }
    
    public func closeTab(at index: Int) {
        guard tabSessions.indices.contains(index) else { return }
        
        let closingSession = tabSessions[index]
        if tabSessions.count == 1 {
            if closingSession.kind.isCompressWorkspace || closingSession.kind.isStorageInspector || closingSession.kind.isArchive {
                let defaultURL = URL(fileURLWithPath: (NSHomeDirectory() as NSString).expandingTildeInPath + "/Downloads").standardizedFileURL.resolvingSymlinksInPath()
                let defaultSession = WorkspaceTabSession(url: defaultURL)
                tabSessions[0] = defaultSession
                activeSessionID = defaultSession.id
                activeTabIndex = 0
                currentDirectory = defaultURL
                activeTab = .home
            }
            return
        }
        
        tabSessions.remove(at: index)
        if index < activeTabIndex {
            activeTabIndex -= 1
        } else if activeTabIndex >= tabSessions.count {
            activeTabIndex = max(0, tabSessions.count - 1)
        }

        if tabSessions.indices.contains(activeTabIndex), closingSession.id == activeSessionID {
            let active = tabSessions[activeTabIndex]
            activeSessionID = active.id
            if active.kind.isCompressWorkspace {
                activeTab = .compressWorkspace
            } else {
                activeTab = .home
                currentDirectory = active.historyStack.current
            }
        }
    }

    public func switchToTab(id: UUID) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        switchToTab(at: index)
    }
    
    public func switchToTab(at index: Int) {
        guard tabSessions.indices.contains(index) else { return }
        activeTabIndex = index
        let session = tabSessions[index]
        activeSessionID = session.id
        if session.kind.isCompressWorkspace {
            activeTab = .compressWorkspace
        } else {
            activeTab = .home
            currentDirectory = session.historyStack.current
        }
    }

    public func selectTab(id: UUID) {
        switchToTab(id: id)
    }
    
    public func selectTab(at index: Int) {
        switchToTab(at: index)
    }
    
    public func selectNextTab() {
        guard !tabSessions.isEmpty else { return }
        let nextIndex = (activeTabIndex + 1) % tabSessions.count
        switchToTab(id: tabSessions[nextIndex].id)
    }
    
    public func selectPreviousTab() {
        guard !tabSessions.isEmpty else { return }
        let prevIndex = (activeTabIndex - 1 + tabSessions.count) % tabSessions.count
        switchToTab(id: tabSessions[prevIndex].id)
    }
    
    public func updateActiveURL(_ newURL: URL) {
        guard tabSessions.indices.contains(activeTabIndex) else { return }
        if tabSessions[activeTabIndex].historyStack.current != newURL {
            tabSessions[activeTabIndex].historyStack.push(newURL)
        }
    }

    public func updateActiveTabURL(_ newURL: URL) {
        updateActiveURL(newURL)
    }

    public func updateTabURL(id: UUID, newURL: URL) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        if tabSessions[index].historyStack.current != newURL {
            tabSessions[index].historyStack.push(newURL)
            if activeSessionID == id {
                currentDirectory = newURL
            }
        }
    }

    public func setArchiveForActiveTab(path: String) {
        guard tabSessions.indices.contains(activeTabIndex) else { return }
        setArchive(path: path, forTab: tabSessions[activeTabIndex].id)
    }

    public func setArchive(path: String, forTab id: UUID, restoringLocation: URL? = nil) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        let root = URL(fileURLWithPath: path).appending(queryItems: [URLQueryItem(name: "subpath", value: "")])
        let url = restoringLocation.flatMap {
            $0.isFileURL && $0.standardizedFileURL.path == root.standardizedFileURL.path ? $0 : nil
        } ?? root
        setAcceptedArchiveContext(path: path, forTab: id)
        tabSessions[index].historyStack.push(url)
        if activeSessionID == id {
            isApplyingCommittedState = true
            currentDirectory = url
            isApplyingCommittedState = false
        }
    }

    /// Restores presentation metadata without adding a second history entry.
    internal func setAcceptedArchiveContext(path: String?, forTab id: UUID) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        if let path {
            tabSessions[index].kind = .archive(path: path)
            tabSessions[index].customTitle = URL(fileURLWithPath: path).lastPathComponent
        } else if tabSessions[index].kind.isArchive {
            tabSessions[index].kind = .directory
            tabSessions[index].customTitle = nil
        }
    }

    public func clearArchiveForActiveTab() {
        guard tabSessions.indices.contains(activeTabIndex) else { return }
        clearArchive(forTab: tabSessions[activeTabIndex].id)
    }

    public func clearArchive(forTab id: UUID) {
        guard let index = tabSessions.firstIndex(where: { $0.id == id }) else { return }
        if tabSessions[index].kind.isArchive {
            tabSessions[index].kind = .directory
            tabSessions[index].customTitle = nil
        }
    }
    
    // MARK: - History Navigation Operations
    
    public var canGoBack: Bool {
        activeTabSession?.historyStack.canGoBack ?? false
    }
    
    public var canGoForward: Bool {
        activeTabSession?.historyStack.canGoForward ?? false
    }
    
    public var canGoUp: Bool {
        activeTabSession?.historyStack.canGoUp ?? false
    }
    
    public var backHistoryList: [URL] {
        guard let session = activeTabSession else { return [] }
        return session.historyStack.backList
    }
    
    public var forwardHistoryList: [URL] {
        guard let session = activeTabSession else { return [] }
        return session.historyStack.forwardList
    }
    
    public func navigateTo(_ targetURL: URL) {
        let canonical = WorkspaceHistoryStack.standardizedLocation(targetURL)
        guard tabSessions.indices.contains(activeTabIndex) else {
            currentDirectory = canonical
            return
        }
        tabSessions[activeTabIndex].historyStack.navigateToHistoryItem(canonical)
        isNavigatingHistory = true
        currentDirectory = canonical
        isNavigatingHistory = false
    }
    
    public func goBack() {
        guard tabSessions.indices.contains(activeTabIndex),
              let target = tabSessions[activeTabIndex].historyStack.goBack() else { return }
        isNavigatingHistory = true
        currentDirectory = target
        isNavigatingHistory = false
    }
    
    public func goForward() {
        guard tabSessions.indices.contains(activeTabIndex),
              let target = tabSessions[activeTabIndex].historyStack.goForward() else { return }
        isNavigatingHistory = true
        currentDirectory = target
        isNavigatingHistory = false
    }
    
    public func goUp() {
        guard tabSessions.indices.contains(activeTabIndex),
              let target = tabSessions[activeTabIndex].historyStack.goUp() else { return }
        isNavigatingHistory = true
        currentDirectory = target
        isNavigatingHistory = false
    }
    
    public func refresh() {
        NotificationCenter.default.post(
            name: NSNotification.Name("TTZipDirectoryRefreshNotification"),
            object: currentDirectory
        )
    }
}

/// 2. Archive explorer and in-archive preview state.
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

    private func applyFilter() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            cancelActiveTasks()
            searchGeneration &+= 1
            isSearching = false
            lastFilteredQuery = ""
            filteredIndices = nil
            return
        }

        if trimmed == lastFilteredQuery {
            return
        }

        guard performSearch != nil || !currentEntries.isEmpty || vfsSession != nil else {
            isSearching = true
            filteredIndices = nil
            return
        }

        let isRefinement = !lastFilteredQuery.isEmpty &&
            trimmed.hasPrefix(lastFilteredQuery) &&
            filteredIndices != nil
        let candidates = isRefinement ? filteredIndices : nil
        let candidateCount = candidates?.count ?? (currentEntries.isEmpty ? 100_000 : currentEntries.count)

        cancelActiveTasks()
        searchGeneration &+= 1
        let currentGen = searchGeneration

        // 1. Fast Path: Immediate synchronous/low-latency Four-Tier lexical search on @MainActor without delay.
        if candidateCount <= asyncThreshold {
            isSearching = false
            let results: ContiguousArray<UInt32>
            if let searchFn = self.performSearch {
                results = ContiguousArray(searchFn(trimmed, 100_000))
            } else if let session = self.vfsSession {
                if let paged = try? session.searchTopK(query: trimmed, limit: 1000) {
                    results = ContiguousArray(paged.map { $0.nodeId })
                } else {
                    results = []
                }
            } else {
                let entries = self.currentEntries
                let lower = trimmed.lowercased()
                if let c = candidates {
                    results = ContiguousArray(c.filter { entries[Int($0)].path.lowercased().contains(lower) })
                } else {
                    results = ContiguousArray(entries.indices.compactMap {
                        entries[$0].path.lowercased().contains(lower) ? UInt32($0) : nil
                    })
                }
            }
            self.filteredIndices = results
            self.lastFilteredQuery = trimmed
        } else {
            isSearching = true
            let searchFn = self.performSearch
            let entries = self.currentEntries
            let session = self.vfsSession
            activeSearchTask = Task.detached(priority: .userInitiated) { [searchFn, entries, currentGen, candidates, session] in
                guard !Task.isCancelled else { return }
                let results: ContiguousArray<UInt32>
                if let searchFn = searchFn {
                    results = ContiguousArray(searchFn(trimmed, 100_000))
                } else if let session = session {
                    if let paged = try? session.searchTopK(query: trimmed, limit: 1000) {
                        results = ContiguousArray(paged.map { $0.nodeId })
                    } else {
                        results = []
                    }
                } else {
                    let lower = trimmed.lowercased()
                    if let c = candidates {
                        results = ContiguousArray(c.filter { entries[Int($0)].path.lowercased().contains(lower) })
                    } else {
                        results = ContiguousArray(entries.indices.compactMap {
                            entries[$0].path.lowercased().contains(lower) ? UInt32($0) : nil
                        })
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.activeSearchTask = nil
                    guard currentGen == self.searchGeneration else { return }
                    self.filteredIndices = results
                    self.lastFilteredQuery = trimmed
                    self.isSearching = false
                }
            }
        }

        // 2. Background Semantic Enrichment Path:
        // When session.hasVectorEmbeddings() (or vector capability is available),
        // spawn a cooperative Task.detached(priority: .userInitiated) to encode the query vector
        // on ANE, call session.searchHybridTopK(query: q, queryVector: vec, limit: 1000, lexicalWeight: 0.6, semanticWeight: 0.4),
        // and update the table viewport on @MainActor checking generation token.
        if let session = self.vfsSession, session.hasVectorEmbeddings() {
            semanticSearchService.performHybridSearch(
                query: trimmed,
                generation: currentGen,
                session: session,
                limit: 1000,
                lexicalWeight: 0.6,
                semanticWeight: 0.4
            ) { [weak self] hybridMatches in
                guard let self = self else { return }
                guard currentGen == self.searchGeneration else { return }
                self.filteredIndices = ContiguousArray(hybridMatches.map { $0.nodeId })
                self.isSearching = false
            }
        }
    }
}

/// 6. Selection and inspected disk item state as single source of truth.
@Observable
@MainActor
public final class SelectionState {
    public var ownerWindowID: UUID? = nil
    public var selectedDiskItem: DiskItemInfo? = nil
    public var selectedDiskItems: [DiskItemInfo]? = nil
    
    public init(
        ownerWindowID: UUID? = nil,
        selectedDiskItem: DiskItemInfo? = nil,
        selectedDiskItems: [DiskItemInfo]? = nil
    ) {
        self.ownerWindowID = ownerWindowID
        self.selectedDiskItem = selectedDiskItem
        self.selectedDiskItems = selectedDiskItems
    }
    
    public func select(_ item: DiskItemInfo?) {
        let previous = self.selectedDiskItem
        self.selectedDiskItem = item
        self.selectedDiskItems = item.map { [$0] }
        if let ownerWindowID {
            StandalonePlaybackWindowManager.shared.notifyOriginSelectionChanged(
                windowID: ownerWindowID,
                newSelectedItem: item
            )
        }
        if let prevPath = previous?.path, prevPath != item?.path, shouldStopGlobalPlayback() {
            TTPreviewPlaybackManager.stopAll()
        }
    }

    public func selectMultiple(_ items: [DiskItemInfo]) {
        self.selectedDiskItems = items
        self.selectedDiskItem = items.first
        if let ownerWindowID {
            StandalonePlaybackWindowManager.shared.notifyOriginSelectionChanged(
                windowID: ownerWindowID,
                newSelectedItem: items.first
            )
        }
        if shouldStopGlobalPlayback() {
            TTPreviewPlaybackManager.stopAll()
        }
    }
    
    public func clear() {
        let previous = self.selectedDiskItem
        self.selectedDiskItem = nil
        self.selectedDiskItems = nil
        self.selectedEntryID = nil
        if let ownerWindowID {
            StandalonePlaybackWindowManager.shared.notifyOriginSelectionChanged(
                windowID: ownerWindowID,
                newSelectedItem: nil
            )
        }
        if previous != nil, shouldStopGlobalPlayback() {
            TTPreviewPlaybackManager.stopAll()
        }
    }

    private func shouldStopGlobalPlayback() -> Bool {
        if StandalonePlaybackWindowManager.shared.hasActivePlaybackSession {
            return false
        }
        if let ownerWindowID {
            return BrowserWindowRegistry.shared.shouldStopGlobalPlaybackOnSelectionChange(for: ownerWindowID)
        }
        return true
    }
}
