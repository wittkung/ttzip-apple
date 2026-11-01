// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import Observation
import TTMediaKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
#if canImport(TTZipAppServices)
#endif

/// TTZip GUI main view ViewModel coordinating UI interactions with decoupled domain state trees.
/// Powered by Swift 5.9+ Observation framework for fine-grained property-level view invalidation.
@dynamicMemberLookup
@Observable
@MainActor
public final class AppViewState: BrowserWindowControlling {
    /// Stable identifier uniquely identifying this browser window session.
    public let windowID: UUID

    /// Window-owned modal presentation coordinator.
    public private(set) var presentationCoordinator: PresentationCoordinator!

    /// Window undo manager bridge for Edit menu and app commands.
    public weak var undoManager: UndoManager?
    
    // Domain Sub-States
    public let navigationState: NavigationState
    public let explorerState: ArchiveExplorerState
    public let taskState: TaskExecutionState
    public let overlayState: OverlayState
    public let selectionState: SelectionState
    public let compressSession: CompressFormSession
    
    /// Monotonically increasing generational epoch counter tracking archive load operations.
    /// Discards stale asynchronous metadata inspection results when rapidly switching between archives.
    public var operationEpoch: UInt64 = 0

    /// Monotonically increasing generational epoch counter tracking archive password operations.
    /// Discards late password verification results after cancel, archive switch, or window close.
    public var passwordOperationEpoch: UInt64 = 0

    /// Active pending password operation context for this window.
    public var pendingPasswordContext: ArchivePasswordOperationContext? = nil

    /// Current cryptographic password evidence state for the active archive in this window.
    public var passwordEvidenceState: ArchivePasswordEvidenceState = .notEncrypted

    /// Pluggable archive password operations driver (defaults to TTZipEngineFacade + ArchiveSelectiveExtractor).
    public var passwordDriver: any ArchivePasswordOperationsDriver = DefaultArchivePasswordOperationsDriver.shared

    /// Set only when the vault-backed archive credential adapter is available.
    public var archiveRememberedPasswordController: ArchiveRememberedPasswordController?

    /// Optional child path to highlight in Miller columns after programmatic directory navigation or window seeding.
    public var initialSelectedFilePath: String? = nil

    /// Current deepest browsing directory across Miller columns or hierarchical explorer views.
    public var activeBrowsingDirectory: URL? = nil

    /// Effective directory to display in Omnibar and breadcrumbs (deepest browsing directory if active, else root currentDirectory).
    public var effectiveDisplayDirectory: URL {
        activeBrowsingDirectory ?? navigationState.currentDirectory
    }

    /// Monotonically increasing generation counter for global-search-initiated archive entry navigation.
    public var searchNavigationGeneration: UInt64 = 0

    /// Optional 1-based line number highlighted when navigating to an archive entry from search.
    public var selectedArchiveHighlightLine: Int? = nil

    /// Tracks whether this window has consumed or checked its initial launch seed.
    public private(set) var hasAppliedLaunchSeed: Bool = false

    public func markLaunchSeedChecked() {
        hasAppliedLaunchSeed = true
    }

    /// Indicates whether `prepareForWindowClose()` has been invoked on this window.
    public private(set) var isWindowClosing: Bool = false
    
    /// Cached media items in the directory of the currently active immersive media item.
    public private(set) var activeMediaSiblings: [ImmersiveMediaItem] = []
    
    /// Published status driving directional navigation in the immersive media browser.
    public private(set) var hasPreviousMedia: Bool = false
    public private(set) var hasNextMedia: Bool = false
    
    /// Background task handle for directory media scanning.
    private var mediaScanTask: Task<Void, Never>?

    /// Consumer lease holder keeping ephemeral staged media alive throughout immersive fullscreen browsing.
    private let immersiveMediaLeaseBox = TTMediaEphemeralLeaseBox()

    /// Dedicated consumer ID for immersive fullscreen F4 preview cache leases.
    private let immersivePreviewCacheConsumerID = UUID()

    /// Active F4 LRU preview cache lease held while an archive-backed item is open in the immersive browser.
    public private(set) var activeImmersiveCacheLease: PreviewCacheLease? = nil

    /// Background task resolving uncached archive sibling entries during immersive prev/next navigation.
    private var immersiveArchiveResolveTask: Task<Void, Never>? = nil
    
    // MARK: - Sub-State Dynamic Member Lookup
    
    public subscript<T>(dynamicMember keyPath: KeyPath<NavigationState, T>) -> T {
        navigationState[keyPath: keyPath]
    }
    public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<NavigationState, T>) -> T {
        get { navigationState[keyPath: keyPath] }
        set { navigationState[keyPath: keyPath] = newValue }
    }
    public subscript<T>(dynamicMember keyPath: KeyPath<ArchiveExplorerState, T>) -> T {
        explorerState[keyPath: keyPath]
    }
    public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<ArchiveExplorerState, T>) -> T {
        get { explorerState[keyPath: keyPath] }
        set { explorerState[keyPath: keyPath] = newValue }
    }
    public subscript<T>(dynamicMember keyPath: KeyPath<TaskExecutionState, T>) -> T {
        taskState[keyPath: keyPath]
    }
    public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<TaskExecutionState, T>) -> T {
        get { taskState[keyPath: keyPath] }
        set { taskState[keyPath: keyPath] = newValue }
    }
    public subscript<T>(dynamicMember keyPath: KeyPath<OverlayState, T>) -> T {
        overlayState[keyPath: keyPath]
    }
    public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<OverlayState, T>) -> T {
        get { overlayState[keyPath: keyPath] }
        set { overlayState[keyPath: keyPath] = newValue }
    }
    public subscript<T>(dynamicMember keyPath: KeyPath<SelectionState, T>) -> T {
        selectionState[keyPath: keyPath]
    }
    public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<SelectionState, T>) -> T {
        get { selectionState[keyPath: keyPath] }
        set { selectionState[keyPath: keyPath] = newValue }
    }
    
    // MARK: - Delegated Sub-State Operations
    
    public func openNewTab(url: URL? = nil) { navigationState.openNewTab(url: url) }
    public func closeTab(at index: Int) { navigationState.closeTab(at: index) }
    public func selectTab(at index: Int) { navigationState.selectTab(at: index) }
    public func selectNextTab() { navigationState.selectNextTab() }
    public func selectPreviousTab() { navigationState.selectPreviousTab() }
    public func clearInspectedFile() {
        selectionState.selectedDiskItem = nil
        selectionState.selectedDiskItems = nil
        selectionState.selectedEntryID = nil
        if BrowserWindowRegistry.shared.shouldStopGlobalPlaybackOnSelectionChange(for: windowID) {
            TTPreviewPlaybackManager.stopAll()
        }
    }
    
    
    public var recentArchives: [RecentArchiveRecord] = []
    
    public var historyManager: CommandHistoryManager
    public var passwordVaultManager: PasswordVaultManager
    
    let fileViewer: FileViewerServiceProtocol
    let passwordVault: PasswordVaultManaging
    let progressThrottler = ThrottledProgressPublisher(maxFrequencyHz: 60.0)
    let recentArchivesKey = "TTZipRecentArchivesKey"
    @MainActor
    private final class NotificationTokenStore {
        var tokens: [NSObjectProtocol] = []
    }
    private let tokenStore = NotificationTokenStore()
    
    @MainActor
    public init(
        windowID: UUID = UUID(),
        navigationState: NavigationState? = nil,
        explorerState: ArchiveExplorerState? = nil,
        taskState: TaskExecutionState? = nil,
        overlayState: OverlayState? = nil,
        selectionState: SelectionState? = nil,
        fileViewer: FileViewerServiceProtocol? = nil,
        passwordVault: PasswordVaultManaging? = nil,
        historyManager: CommandHistoryManager? = nil,
        passwordVaultManager: PasswordVaultManager? = nil,
        passwordDriver: (any ArchivePasswordOperationsDriver)? = nil,
        archiveRememberedPasswordController: ArchiveRememberedPasswordController? = nil
    ) {
        self.windowID = windowID
        let resolvedVaultManager = passwordVaultManager ?? PasswordVaultManager.shared
        self.navigationState = navigationState ?? NavigationState()
        self.explorerState = explorerState ?? ArchiveExplorerState()
        self.taskState = taskState ?? TaskExecutionState()
        self.overlayState = overlayState ?? OverlayState()
        self.selectionState = selectionState ?? SelectionState(ownerWindowID: windowID)
        self.selectionState.ownerWindowID = windowID
        self.compressSession = CompressFormSession()
        self.fileViewer = fileViewer ?? MacNSWorkspaceFileViewer()
        self.passwordVault = passwordVault ?? PasswordVaultManager.shared
        self.historyManager = historyManager ?? CommandHistoryManager.shared
        self.passwordVaultManager = resolvedVaultManager
        self.archiveRememberedPasswordController = Self.makeArchiveRememberedPasswordController(
            provided: archiveRememberedPasswordController,
            vaultManager: resolvedVaultManager
        )
        self.presentationCoordinator = PresentationCoordinator(boundViewState: self)
        if let passwordDriver {
            self.passwordDriver = passwordDriver
        }
        installBrowsingContextCallbacks()
        
        // Restore process-wide bookmarks once, without retiring other windows' active leases.
        // Explicit bookmark reloads remain available through the shared access manager.
        _ = RootFolderAccessManager.shared
        loadRecentArchivesFromStorage()
        
        scheduleInitialDirectoryAuthorization()

        updateUndoRedoState()
    }

    /// Resolves the remembered-credential controller this window works with.
    ///
    /// A controller handed in by the caller wins. Otherwise the controller is only created when
    /// the process may use the vault: a CLI process has no user session to keep a credential in.
    private static func makeArchiveRememberedPasswordController(
        provided: ArchiveRememberedPasswordController?,
        vaultManager: PasswordVaultManager
    ) -> ArchiveRememberedPasswordController? {
        if let provided {
            return provided
        }
        guard !PasswordVaultManager.isCLIProcess else { return nil }
        return ArchiveRememberedPasswordController(
            store: VaultArchiveScopedCredentialStore(manager: vaultManager)
        )
    }

    /// Installs the navigation callbacks that reconcile and retire window-owned archive resources.
    ///
    /// The callbacks are installed after every stored property is initialized: their bodies read
    /// the window state, so a closure must never capture a partially initialized view state.
    private func installBrowsingContextCallbacks() {
        self.navigationState.onActiveBrowsingContextChange = { [weak self] in
            self?.handleActiveBrowsingContextChange()
        }
        self.navigationState.onSessionsRetired = { [weak self] retired in
            for id in retired { self?.retireAcceptedArchiveResources(for: id) }
        }
    }

    private func scheduleInitialDirectoryAuthorization() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !self.isWindowClosing else { return }
            _ = await RootFolderAccessManager.shared.ensureAccess(for: self.navigationState.currentDirectory, promptIfMissing: true)
        }
        
    }

    // MARK: - Immersive Media Browser State Machine
    
    @MainActor
    @discardableResult
    public func openStandalonePlaybackIfVideo(
        url: URL,
        name: String,
        fileSizeBytes: Int64? = nil,
        sourceArchivePath: String? = nil,
        archiveSubpath: String? = nil,
        resourceCacheKey: String? = nil,
        isEditable: Bool? = nil
    ) -> Bool {
        let f4 = MediaPreviewView.resolveImmersiveF4Identity(
            url: url,
            name: name,
            selectedDiskItemPath: selectionState.selectedDiskItem?.path,
            currentArchivePath: explorerState.currentArchivePath,
            currentEntries: explorerState.currentEntries,
            sourceArchivePath: sourceArchivePath,
            archiveSubpath: archiveSubpath,
            resourceCacheKey: resourceCacheKey,
            explicitEditable: isEditable
        )
        let size = fileSizeBytes ?? (try? f4.resolvedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
        let item = ImmersiveMediaItem(
            url: f4.resolvedURL,
            name: name,
            fileSizeBytes: size,
            sourceArchivePath: f4.archivePath,
            archiveSubpath: f4.subpath,
            resourceCacheKey: f4.cacheKey,
            isEditable: f4.isEditable,
            resourceContext: f4.resourceContext
        )
        guard !f4.isPhysicalComicArchive,
              StandalonePlaybackWindowManager.isVideoItem(item) else {
            return false
        }
        syncImmersiveSelectionAndResolution(f4: f4, name: name, size: size)
        _ = StandalonePlaybackWindowManager.shared.requestOpenOrFocus(
            item: item,
            originBrowserWindowID: windowID,
            originSelectedItem: selectionState.selectedDiskItem,
            originDirectoryURL: navigationState.currentDirectory,
            originArchivePath: explorerState.currentArchivePath
        )
        overlayState.showImmersiveMediaBrowser = false
        overlayState.immersiveMediaItem = nil
        return true
    }

    @MainActor
    public func openImmersiveMedia(
        url: URL,
        name: String,
        fileSizeBytes: Int64? = nil,
        sourceArchivePath: String? = nil,
        archiveSubpath: String? = nil,
        resourceCacheKey: String? = nil,
        isEditable: Bool? = nil
    ) {
        immersiveArchiveResolveTask?.cancel()
        immersiveArchiveResolveTask = nil

        let f4 = MediaPreviewView.resolveImmersiveF4Identity(
            url: url,
            name: name,
            selectedDiskItemPath: selectionState.selectedDiskItem?.path,
            currentArchivePath: explorerState.currentArchivePath,
            currentEntries: explorerState.currentEntries,
            sourceArchivePath: sourceArchivePath,
            archiveSubpath: archiveSubpath,
            resourceCacheKey: resourceCacheKey,
            explicitEditable: isEditable
        )

        if f4.isPhysicalComicArchive {
            openArchiveAsFolder(url: url.standardizedFileURL.resolvingSymlinksInPath())
            return
        }

        if BrowserWindowRegistry.shared.controller(for: windowID) != nil,
           openStandaloneMediaIfSupported(
               url: url,
               name: name,
               fileSizeBytes: fileSizeBytes,
               sourceArchivePath: sourceArchivePath,
               archiveSubpath: archiveSubpath,
               resourceCacheKey: resourceCacheKey,
               isEditable: isEditable
           ) {
            return
        }

        updateImmersivePreviewCacheLease(forKey: f4.cacheKey)
        BrowserWindowRegistry.shared.claimPlaybackOwnership(for: windowID)
        immersiveMediaLeaseBox.bind(url: f4.resolvedURL, consumeFullscreenHandoff: true)

        let size = fileSizeBytes ?? (try? f4.resolvedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
        let item = ImmersiveMediaItem(
            url: f4.resolvedURL,
            name: name,
            fileSizeBytes: size,
            sourceArchivePath: f4.archivePath,
            archiveSubpath: f4.subpath,
            resourceCacheKey: f4.cacheKey,
            isEditable: f4.isEditable,
            resourceContext: f4.resourceContext
        )
        overlayState.immersiveMediaItem = item
        overlayState.showImmersiveMediaBrowser = true
        syncImmersiveSelectionAndResolution(f4: f4, name: name, size: size)
        refreshActiveMediaSiblings(for: item)
    }

    @MainActor
    private func syncImmersiveSelectionAndResolution(
        f4: MediaPreviewView.ResolvedImmersiveF4Identity,
        name: String,
        size: Int64?
    ) {
        if f4.resolvedURL.isFileURL, f4.archivePath == nil, explorerState.currentArchivePath == nil,
           FileManager.default.fileExists(atPath: f4.resolvedURL.path) {
            let existingCanonical = selectionState.selectedDiskItem.map {
                URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath()
            }
            if existingCanonical != f4.resolvedURL {
                self.selectionState.selectedDiskItem = DiskItemInfo(url: f4.resolvedURL)
            }
        }
        if let archivePath = f4.archivePath, let subpath = f4.subpath,
           (!f4.resolvedURL.isFileURL || !FileManager.default.fileExists(atPath: f4.resolvedURL.path)) {
            scheduleImmersiveArchiveEntryResolution(
                archivePath: archivePath,
                subpath: subpath,
                name: name,
                estimatedBytes: UInt64(max(0, size ?? 0))
            )
        }
    }

    @MainActor
    private func updateImmersivePreviewCacheLease(forKey cacheKey: String?) {
        let previousLease = activeImmersiveCacheLease
        if let key = cacheKey, !key.isEmpty {
            let newLease = PreviewCacheLease(key: key, consumerID: immersivePreviewCacheConsumerID)
            activeImmersiveCacheLease = newLease
            let consumerID = immersivePreviewCacheConsumerID
            Task {
                _ = await PreviewLRUCacheManager.shared.acquireLease(forKey: key, consumerID: consumerID)
                if let previousLease, previousLease.key != newLease.key {
                    await PreviewLRUCacheManager.shared.releaseLease(previousLease)
                }
            }
        } else {
            activeImmersiveCacheLease = nil
            if let previousLease {
                Task { await PreviewLRUCacheManager.shared.releaseLease(previousLease) }
            }
        }
    }

    @MainActor
    private func scheduleImmersiveArchiveEntryResolution(
        archivePath: String,
        subpath: String,
        name: String,
        estimatedBytes: UInt64
    ) {
        let consumerID = immersivePreviewCacheConsumerID
        let expectedKey = PreviewLRUCacheManager.deterministicCacheKey(archivePath: archivePath, subpath: subpath)
        immersiveArchiveResolveTask = Task { @MainActor [weak self] in
            let cachedHit = await PreviewLRUCacheManager.shared.acquireCachedURL(
                forKey: expectedKey,
                expectedFilename: (subpath as NSString).lastPathComponent,
                consumerID: consumerID
            )
            guard let self, !Task.isCancelled,
                  self.overlayState.showImmersiveMediaBrowser,
                  self.overlayState.immersiveMediaItem?.resourceCacheKey == expectedKey,
                  let resolved = cachedHit else {
                if let lease = cachedHit?.lease { await PreviewLRUCacheManager.shared.releaseLease(lease) }
                return
            }
            self.activeImmersiveCacheLease = resolved.lease
            self.immersiveMediaLeaseBox.bind(url: resolved.url, consumeFullscreenHandoff: false)
            self.overlayState.immersiveMediaItem = ImmersiveMediaItem(
                url: resolved.url,
                name: name,
                fileSizeBytes: Int64(estimatedBytes),
                sourceArchivePath: archivePath,
                archiveSubpath: subpath,
                resourceCacheKey: resolved.lease.key,
                isEditable: false,
                resourceContext: .archiveEntry(
                    archivePath: archivePath,
                    entryPath: subpath,
                    stagedReadURL: resolved.url,
                    fileName: name
                )
            )
        }
    }
    
    @MainActor
    public func openImmersiveMedia(for item: DiskItemInfo) {
        let isVirtual = item.path.hasPrefix("ttzip://") || (URL(string: item.path)?.query?.contains("subpath=") == true)
        if !isVirtual && (item.isArchive || MediaPreviewView.isComicArchiveNameOrPath(item.name)) {
            let archiveURL = (item.path.hasPrefix("file://") ? URL(string: item.path) : nil) ?? URL(fileURLWithPath: item.path)
            openArchiveAsFolder(url: archiveURL.standardizedFileURL.resolvingSymlinksInPath())
            return
        }
        let targetURL: URL = {
            if item.path.hasPrefix("ttzip://") || item.path.hasPrefix("http://") || item.path.hasPrefix("https://")
                || (URL(string: item.path)?.query?.contains("subpath=") == true) {
                return URL(string: item.path) ?? URL(fileURLWithPath: item.path)
            }
            if item.path.hasPrefix("file://"), let parsed = URL(string: item.path), parsed.isFileURL {
                return parsed.standardizedFileURL.resolvingSymlinksInPath()
            }
            return URL(fileURLWithPath: item.path)
        }()
        openImmersiveMedia(url: targetURL, name: item.displayName, fileSizeBytes: item.fileSizeBytes, isEditable: !isVirtual)
    }
    
    @MainActor
    public func closeImmersiveMedia() {
        mediaScanTask?.cancel()
        mediaScanTask = nil
        immersiveArchiveResolveTask?.cancel()
        immersiveArchiveResolveTask = nil
        if let lease = activeImmersiveCacheLease {
            activeImmersiveCacheLease = nil
            Task { await PreviewLRUCacheManager.shared.releaseLease(lease) }
        }
        if let activeURL = overlayState.immersiveMediaItem?.url {
            TTMediaDetector.endFullscreenEphemeralHandoff(for: activeURL)
        }
        immersiveMediaLeaseBox.release()
        BrowserWindowRegistry.shared.releasePlaybackOwnership(for: windowID)
        overlayState.showImmersiveMediaBrowser = false
        overlayState.immersiveMediaItem = nil
        activeMediaSiblings = []
        hasPreviousMedia = false
        hasNextMedia = false
    }

    @MainActor
    private func matchesMediaSibling(_ candidate: ImmersiveMediaItem, current: ImmersiveMediaItem) -> Bool {
        if let cKey = candidate.resourceCacheKey, let curKey = current.resourceCacheKey, !cKey.isEmpty, cKey == curKey {
            return true
        }
        if let cSub = candidate.archiveSubpath, let curSub = current.archiveSubpath, !cSub.isEmpty, cSub == curSub {
            return true
        }
        return candidate.url.resolvingSymlinksInPath() == current.url.resolvingSymlinksInPath()
            || candidate.name == current.name
    }
    
    @MainActor
    private func updateMediaNavigationFlags(for currentItem: ImmersiveMediaItem) {
        guard let idx = activeMediaSiblings.firstIndex(where: {
            matchesMediaSibling($0, current: currentItem)
        }) else {
            hasPreviousMedia = false
            hasNextMedia = false
            return
        }
        hasPreviousMedia = (idx > 0)
        hasNextMedia = (idx < activeMediaSiblings.count - 1)
    }
    
    /// Asynchronously collects sibling media items in the background, updating published navigation state.
    @MainActor
    public func refreshActiveMediaSiblings(for currentItem: ImmersiveMediaItem) {
        mediaScanTask?.cancel()
        
        if !activeMediaSiblings.isEmpty,
           let idx = activeMediaSiblings.firstIndex(where: {
               matchesMediaSibling($0, current: currentItem)
           }) {
            hasPreviousMedia = (idx > 0)
            hasNextMedia = (idx < activeMediaSiblings.count - 1)
            return
        }
        
        activeMediaSiblings = [currentItem]
        hasPreviousMedia = false
        hasNextMedia = false
        
        if currentItem.isFromArchive || explorerState.currentArchivePath != nil {
            let archivePath = currentItem.sourceArchivePath ?? explorerState.currentArchivePath
            let entries = explorerState.currentEntries
            if !entries.isEmpty {
                let mediaItems = MediaPreviewView.buildArchiveMediaSiblings(
                    entries: entries,
                    archivePath: archivePath,
                    fallbackURL: currentItem.url
                )
                self.activeMediaSiblings = mediaItems.isEmpty ? [currentItem] : mediaItems
                self.updateMediaNavigationFlags(for: currentItem)
            }
            return
        }
        
        let parentDir = currentItem.url.deletingLastPathComponent()
        mediaScanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: parentDir,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            guard !Task.isCancelled else { return }
            
            let mediaItems: [ImmersiveMediaItem] = contents.compactMap { (url: URL) -> ImmersiveMediaItem? in
                let res = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if res?.isDirectory == true { return nil }
                let ext = url.pathExtension.lowercased()
                if MediaPreviewFactory.archiveExtensions.contains(ext) { return nil }
                let size = res?.fileSize.map { Int64($0) }
                return ImmersiveMediaItem(url: url, name: url.lastPathComponent, fileSizeBytes: size)
            }.sorted { a, b in
                NativeMicrokernelBridge.naturalCompare(a.name, b.name) == .orderedAscending
            }
            guard !Task.isCancelled else { return }
            
            await MainActor.run { [weak self] in
                guard let self = self, !Task.isCancelled else { return }
                guard let active = self.overlayState.immersiveMediaItem,
                      active.url.deletingLastPathComponent().path == parentDir.path else { return }
                self.activeMediaSiblings = mediaItems.isEmpty ? [currentItem] : mediaItems
                self.updateMediaNavigationFlags(for: active)
            }
        }
    }
    
    /// Awaits the active background media scan task, ensuring synchronization in tests and scripts.
    public func waitForMediaScan() async {
        await mediaScanTask?.value
    }
    
    /// Returns cached previewable sibling items from the active directory without blocking.
    public func activeDirectoryMediaItems() -> [ImmersiveMediaItem] {
        return activeMediaSiblings.isEmpty ? (overlayState.immersiveMediaItem.map { [$0] } ?? []) : activeMediaSiblings
    }
    
    @MainActor
    public func navigatePreviousMedia() {
        guard let current = overlayState.immersiveMediaItem else { return }
        guard let idx = activeMediaSiblings.firstIndex(where: {
            matchesMediaSibling($0, current: current)
        }), idx > 0 else { return }
        let prev = activeMediaSiblings[idx - 1]
        openImmersiveMedia(
            url: prev.url,
            name: prev.name,
            fileSizeBytes: prev.fileSizeBytes,
            sourceArchivePath: prev.sourceArchivePath,
            archiveSubpath: prev.archiveSubpath,
            resourceCacheKey: prev.resourceCacheKey,
            isEditable: prev.isEditable
        )
    }
    
    @MainActor
    public func navigateNextMedia() {
        guard let current = overlayState.immersiveMediaItem else { return }
        guard let idx = activeMediaSiblings.firstIndex(where: {
            matchesMediaSibling($0, current: current)
        }), idx < activeMediaSiblings.count - 1 else { return }
        let next = activeMediaSiblings[idx + 1]
        openImmersiveMedia(
            url: next.url,
            name: next.name,
            fileSizeBytes: next.fileSizeBytes,
            sourceArchivePath: next.sourceArchivePath,
            archiveSubpath: next.archiveSubpath,
            resourceCacheKey: next.resourceCacheKey,
            isEditable: next.isEditable
        )
    }

    // MARK: - BrowserWindowControlling Conformance

    public var currentDirectoryURL: URL {
        navigationState.currentDirectory
    }

    public var currentArchivePath: String? {
        explorerState.currentArchivePath
    }

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

    public var isShowingImmersiveMedia: Bool {
        overlayState.showImmersiveMediaBrowser
    }

    public var selectedItemPath: String? {
        selectionState.selectedDiskItem?.path
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
        if explorerState.currentArchivePath != nil {
            closeCurrentArchive()
        }
        activeBrowsingDirectory = nil
        navigationState.activeTab = .home
        navigationState.currentDirectory = standardized
        selectionState.selectedDiskItem = nil
        selectionState.selectedDiskItems = nil
        RecentLocationsStore.shared.recordDirectory(url: standardized)
    }

    public func revealItemInWindow(_ itemURL: URL) {
        let standardized = itemURL.standardizedFileURL
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir)
        if exists && isDir.boolValue && !DiskItemInfo(url: standardized).isApplicationBundle {
            navigateToDirectory(standardized)
            return
        }
        let parentDir = standardized.deletingLastPathComponent().standardizedFileURL
        if explorerState.currentArchivePath != nil {
            closeCurrentArchive()
        }
        navigationState.activeTab = .home
        navigationState.currentDirectory = parentDir
        initialSelectedFilePath = standardized.path
        let diskItem = DiskItemInfo(url: standardized)
        selectionState.selectedDiskItem = diskItem
        selectionState.selectedDiskItems = [diskItem]
    }

    public func openArchiveInWindow(
        at url: URL,
        password: String?,
        bookmarkSession: ActiveBookmarkSession?
    ) {
        openArchiveAsFolder(url: url, password: password, bookmarkSession: bookmarkSession)
    }

    /// Deterministically cleans up window-owned continuations, password prompts, preview leases,
    /// and playback ownership when a browser window closes, without interrupting other windows' tasks.
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
        if shouldStopPlayback {
            TTPreviewPlaybackManager.stopAll()
        }

        presentationCoordinator.dismissAll()
        BrowserWindowRegistry.shared.unregister(id: windowID)
        AppIntentDispatcher.shared.unregister(windowID: windowID)
    }
}

