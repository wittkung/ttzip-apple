// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import Observation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// TTZip GUI main view ViewModel coordinating UI interactions with decoupled domain state trees.
/// Powered by Swift 5.9+ Observation framework for fine-grained property-level view invalidation.
@Observable
@MainActor
public final class AppViewState {
    // Domain Sub-States
    public let navigationState: NavigationState
    public let explorerState: ArchiveExplorerState
    public let taskState: TaskExecutionState
    public let overlayState: OverlayState
    public let selectionState: SelectionState
    public let progressObservable: TaskProgressObservable
    
    // MARK: - Forwarding Accessors for Backward Compatibility
    
    public var activeTab: WorkspaceTab {
        get { navigationState.activeTab }
        set { navigationState.activeTab = newValue }
    }
    public var currentDirectory: URL {
        get { navigationState.currentDirectory }
        set { navigationState.currentDirectory = newValue }
    }
    public var directoryTabs: [DirectoryTabItem] {
        get { navigationState.directoryTabs }
        set { navigationState.directoryTabs = newValue }
    }
    public var activeTabIndex: Int {
        get { navigationState.activeTabIndex }
        set { navigationState.activeTabIndex = newValue }
    }
    
    public func openNewTab(url: URL? = nil) {
        navigationState.openNewTab(url: url)
    }
    
    public func closeTab(at index: Int) {
        navigationState.closeTab(at: index)
    }
    
    public func selectTab(at index: Int) {
        navigationState.selectTab(at: index)
    }
    
    public func selectNextTab() {
        navigationState.selectNextTab()
    }
    
    public func selectPreviousTab() {
        navigationState.selectPreviousTab()
    }
    
    public var currentArchivePath: String? {
        get { explorerState.currentArchivePath }
        set { explorerState.currentArchivePath = newValue }
    }
    public var activePassword: String? {
        get { explorerState.activePassword }
        set { explorerState.activePassword = newValue }
    }
    public var currentEntries: [ArchiveEntry] {
        get { explorerState.currentEntries }
        set { explorerState.currentEntries = newValue }
    }
    public var activePreviewFileURL: URL? {
        get { explorerState.activePreviewFileURL }
        set { explorerState.activePreviewFileURL = newValue }
    }
    public var activePreviewFileName: String? {
        get { explorerState.activePreviewFileName }
        set { explorerState.activePreviewFileName = newValue }
    }
    public var searchQuery: String {
        get { explorerState.searchQuery }
        set { explorerState.searchQuery = newValue }
    }
    
    public var isLoading: Bool {
        get { taskState.isLoading }
        set { taskState.isLoading = newValue }
    }
    public var statusMessage: String {
        get { taskState.statusMessage }
        set { taskState.statusMessage = newValue }
    }
    public var progressValue: Double {
        get { taskState.progressValue }
        set { taskState.progressValue = newValue }
    }
    public var canUndo: Bool {
        get { taskState.canUndo }
        set { taskState.canUndo = newValue }
    }
    public var canRedo: Bool {
        get { taskState.canRedo }
        set { taskState.canRedo = newValue }
    }
    public var lastCommandDescription: String? {
        get { taskState.lastCommandDescription }
        set { taskState.lastCommandDescription = newValue }
    }
    public var taskStateName: String {
        get { taskState.taskStateName }
        set { taskState.taskStateName = newValue }
    }
    public var canPauseTask: Bool {
        get { taskState.canPauseTask }
        set { taskState.canPauseTask = newValue }
    }
    public var canResumeTask: Bool {
        get { taskState.canResumeTask }
        set { taskState.canResumeTask = newValue }
    }
    public var canCancelTask: Bool {
        get { taskState.canCancelTask }
        set { taskState.canCancelTask = newValue }
    }
    public var currentTaskID: UUID? {
        get { taskState.currentTaskID }
        set { taskState.currentTaskID = newValue }
    }
    
    public var showCompressModal: Bool {
        get { overlayState.showCompressModal }
        set { overlayState.showCompressModal = newValue }
    }
    public var showExtractModal: Bool {
        get { overlayState.showExtractModal }
        set { overlayState.showExtractModal = newValue }
    }
    public var showPasswordPrompt: Bool {
        get { overlayState.showPasswordPrompt }
        set { overlayState.showPasswordPrompt = newValue }
    }
    public var pendingEncryptedPath: String? {
        get { overlayState.pendingEncryptedPath }
        set { overlayState.pendingEncryptedPath = newValue }
    }
    public var selectedDiskItem: DiskItemInfo? {
        get { selectionState.selectedDiskItem }
        set {
            selectionState.selectedDiskItem = newValue
            overlayState.selectedDiskItem = newValue
        }
    }
    public var activeInspectedFile: DiskItemInfo? {
        get { selectionState.selectedDiskItem }
        set {
            selectionState.selectedDiskItem = newValue
            overlayState.activeInspectedFile = newValue
        }
    }
    public func clearInspectedFile() {
        selectionState.clear()
        overlayState.activeInspectedFile = nil
        overlayState.selectedDiskItem = nil
    }
    public var selectedPathsToCompress: [String] {
        get { overlayState.selectedPathsToCompress }
        set { overlayState.selectedPathsToCompress = newValue }
    }
    public var showArchiveInspectorModal: Bool {
        get { overlayState.showArchiveInspectorModal }
        set { overlayState.showArchiveInspectorModal = newValue }
    }
    public var inspectingArchivePath: String? {
        get { overlayState.inspectingArchivePath }
        set { overlayState.inspectingArchivePath = newValue }
    }
    public var showImmersiveMediaBrowser: Bool {
        get { overlayState.showImmersiveMediaBrowser }
        set { overlayState.showImmersiveMediaBrowser = newValue }
    }
    public var immersiveMediaItem: ImmersiveMediaItem? {
        get { overlayState.immersiveMediaItem }
        set { overlayState.immersiveMediaItem = newValue }
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
    
    public init(
        navigationState: NavigationState = NavigationState(),
        explorerState: ArchiveExplorerState = ArchiveExplorerState(),
        taskState: TaskExecutionState = TaskExecutionState(),
        overlayState: OverlayState = OverlayState(),
        selectionState: SelectionState = SelectionState(),
        progressObservable: TaskProgressObservable = TaskProgressObservable(),
        fileViewer: FileViewerServiceProtocol = MacNSWorkspaceFileViewer(),
        passwordVault: PasswordVaultManaging = PasswordVaultManager.shared,
        historyManager: CommandHistoryManager = CommandHistoryManager.shared,
        passwordVaultManager: PasswordVaultManager = PasswordVaultManager.shared
    ) {
        self.navigationState = navigationState
        self.explorerState = explorerState
        self.taskState = taskState
        self.overlayState = overlayState
        self.selectionState = selectionState
        self.progressObservable = progressObservable
        self.fileViewer = fileViewer
        self.passwordVault = passwordVault
        self.historyManager = historyManager
        self.passwordVaultManager = passwordVaultManager
        
        loadRecentArchivesFromStorage()
        RootFolderAccessManager.shared.restoreBookmarks()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            RootFolderAccessManager.shared.ensureAccess(for: self.currentDirectory, promptIfMissing: true)
        }
        
        updateUndoRedoState()
    }
    
    // MARK: - Immersive Media Browser State Machine
    
    @MainActor
    public func openImmersiveMedia(url: URL, name: String, fileSizeBytes: Int64? = nil) {
        let size = fileSizeBytes ?? (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
        let item = ImmersiveMediaItem(url: url, name: name, fileSizeBytes: size)
        overlayState.immersiveMediaItem = item
        overlayState.showImmersiveMediaBrowser = true
        
        if url.isFileURL && FileManager.default.fileExists(atPath: url.path) {
            self.selectedDiskItem = DiskItemInfo(url: url)
        }
    }
    
    @MainActor
    public func openImmersiveMedia(for item: DiskItemInfo) {
        openImmersiveMedia(
            url: URL(fileURLWithPath: item.path),
            name: item.displayName,
            fileSizeBytes: item.fileSizeBytes
        )
    }
    
    @MainActor
    public func closeImmersiveMedia() {
        overlayState.showImmersiveMediaBrowser = false
        overlayState.immersiveMediaItem = nil
    }
    
    /// Collects previewable sibling items from the directory of the currently active immersive media item.
    public func activeDirectoryMediaItems() -> [ImmersiveMediaItem] {
        guard let currentItem = overlayState.immersiveMediaItem else { return [] }
        
        // If the URL is in-archive VFS or non-file scheme, query archive explorer entries
        if !currentItem.url.isFileURL {
            if !explorerState.currentEntries.isEmpty {
                return explorerState.currentEntries.compactMap { entry in
                    if entry.isDirectory { return nil }
                    let ext = (entry.path as NSString).pathExtension.lowercased()
                    if MediaPreviewFactory.archiveExtensions.contains(ext) { return nil }
                    let vfsURL = URL(string: "\(TTZipVfsSchemeHandler.scheme)://entry/\(entry.path)") ?? currentItem.url
                    return ImmersiveMediaItem(url: vfsURL, name: (entry.path as NSString).lastPathComponent, fileSizeBytes: Int64(entry.uncompressedSize))
                }
            }
            return [currentItem]
        }
        
        let parentDir = currentItem.url.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parentDir,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [currentItem]
        }
        
        let mediaItems: [ImmersiveMediaItem] = contents.compactMap { url in
            let res = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if res?.isDirectory == true { return nil }
            let ext = url.pathExtension.lowercased()
            if MediaPreviewFactory.archiveExtensions.contains(ext) { return nil }
            let size = res?.fileSize.map { Int64($0) }
            return ImmersiveMediaItem(url: url, name: url.lastPathComponent, fileSizeBytes: size)
        }.sorted { a, b in
            NativeMicrokernelBridge.naturalCompare(a.name, b.name) == .orderedAscending
        }
        
        return mediaItems.isEmpty ? [currentItem] : mediaItems
    }
    
    public var hasPreviousMedia: Bool {
        guard let current = overlayState.immersiveMediaItem else { return false }
        let items = activeDirectoryMediaItems()
        let currentCanonical = current.url.resolvingSymlinksInPath()
        guard let idx = items.firstIndex(where: {
            $0.url.resolvingSymlinksInPath() == currentCanonical || $0.name == current.name
        }) else { return false }
        return idx > 0
    }
    
    public var hasNextMedia: Bool {
        guard let current = overlayState.immersiveMediaItem else { return false }
        let items = activeDirectoryMediaItems()
        let currentCanonical = current.url.resolvingSymlinksInPath()
        guard let idx = items.firstIndex(where: {
            $0.url.resolvingSymlinksInPath() == currentCanonical || $0.name == current.name
        }) else { return false }
        return idx < items.count - 1
    }
    
    @MainActor
    public func navigatePreviousMedia() {
        guard let current = overlayState.immersiveMediaItem else { return }
        let items = activeDirectoryMediaItems()
        let currentCanonical = current.url.resolvingSymlinksInPath()
        guard let idx = items.firstIndex(where: {
            $0.url.resolvingSymlinksInPath() == currentCanonical || $0.name == current.name
        }), idx > 0 else { return }
        let prev = items[idx - 1]
        openImmersiveMedia(url: prev.url, name: prev.name, fileSizeBytes: prev.fileSizeBytes)
    }
    
    @MainActor
    public func navigateNextMedia() {
        guard let current = overlayState.immersiveMediaItem else { return }
        let items = activeDirectoryMediaItems()
        let currentCanonical = current.url.resolvingSymlinksInPath()
        guard let idx = items.firstIndex(where: {
            $0.url.resolvingSymlinksInPath() == currentCanonical || $0.name == current.name
        }), idx < items.count - 1 else { return }
        let next = items[idx + 1]
        openImmersiveMedia(url: next.url, name: next.name, fileSizeBytes: next.fileSizeBytes)
    }
}
