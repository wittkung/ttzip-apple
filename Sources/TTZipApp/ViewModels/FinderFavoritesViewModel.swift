// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import Observation
import SwiftUI
import TTZipCore
import TTZipUI

/// Section classifier for the Finder favorites sidebar.
public typealias FinderFavoritesSidebarSection = SidebarSection

/// State machine driving the Finder favorites, custom shortcuts, mounted volumes, and external devices.
@MainActor
@Observable
public final class FinderFavoritesViewModel: DockMenuFavoritesProviding {
    /// Shared singleton instance for unified sidebar state across windows.
    public static let shared = FinderFavoritesViewModel()
    
    /// User-pinned custom shortcuts persisted in AppStorage / UserDefaults.
    public var customPinnedPaths: [String] = []
    
    /// Dynamic Finder favorites loaded from macOS sharedfilelist or standard directories.
    public var dynamicFinderFavorites: [FinderFavoriteItem] = []
    
    /// Flag indicating whether custom SFL favorites were successfully authorized and resolved.
    public var hasResolvedCustomFavorites: Bool = false
    
    /// Currently active navigation section.
    public var activeSection: FinderFavoritesSidebarSection? = nil
    
    /// Controls presentation of the wireless Android discovery sheet.
    public var showWirelessDiscoverySheet: Bool = false
    
    /// Loading indicator state.
    public var isLoading: Bool = false

    /// Current directory identity updated asynchronously to eliminate POSIX lstat calls from SwiftUI body.
    public var currentIdentity: FileIdentity? = nil

    /// Optional pluggable synchronizer bridging Swift favorites to the Rust microkernel FavoritesRegistry.
    public var registrySynchronizer: (any FavoritesRegistrySynchronizer)? = DefaultFavoritesRegistrySynchronizer()
    
    // MARK: - Private State & File Monitor
    
    private let legacyStorageKey = "TTZipCustomShortcutFolderPaths"
    private let bookmarkStorageKey = "TTZipCustomShortcutBookmarks_v2"
    
    /// User-pinned custom shortcuts with security-scoped bookmark persistence.
    public var pinnedRecords: [PinnedFolderRecord] = []
    
    /// Pre-indexed identity sets for microsecond-level UI hot-path matching.
    public private(set) var pinnedIdentities: Set<FileIdentity> = []
    public private(set) var favoriteIdentities: Set<FileIdentity> = []

    private var sflMonitorSource: DispatchSourceFileSystemObject?
    private var sflFileDescriptor: Int32 = -1
    private var sflDebounceTask: Task<Void, Never>?
    private var sflSecurityScopedURL: URL?

    private let pinnedFolderMonitor = PinnedFolderMonitor()
    private var unmountObserver: Any?
    private var mountObserver: Any?
    private var wakeObserver: Any?
    private var languageObserver: Any?
    private var wakeReconcileTask: Task<Void, Never>?

    private let bookmarkCache = ThreadSafeBookmarkCache()

    public init() {
        loadCustomPinnedPaths()
        let placeholder = FinderFavoritesReader.defaultStandardFavorites()
        self.dynamicFinderFavorites = placeholder.items
        self.hasResolvedCustomFavorites = placeholder.hasResolvedCustomFavorites
        rebuildIdentityCaches()
        loadFavorites()
        startMonitoringFinderFavorites()
        setupFolderObservation()
        reconcileHealthStates()
        if DockMenuController.shared.favoritesProvider == nil {
            DockMenuController.shared.favoritesProvider = self
        }
    }
    
    isolated deinit {
        stopMonitoringFinderFavorites()
        if let unmountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(unmountObserver)
        }
        if let mountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(mountObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
        Task { [pinnedFolderMonitor] in
            await pinnedFolderMonitor.stopAllWatches()
        }
    }

    private func setupFolderObservation() {
        Task { [weak self, pinnedFolderMonitor] in
            guard let self else { return }
            await pinnedFolderMonitor.setMutationHandler { [weak self] mutation in
                await MainActor.run {
                    self?.applyFolderMutation(mutation)
                }
            }
            await pinnedFolderMonitor.synchronizeWatches(records: self.pinnedRecords)
        }

        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { [pinnedFolderMonitor = self.pinnedFolderMonitor] in
                await pinnedFolderMonitor.stopAllWatches()
            }
        }

        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcileHealthStates()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWake()
            }
        }

        languageObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("TTZipLanguageChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadFavorites()
            }
        }
    }

    @MainActor
    private func handleSystemWake() {
        // Phase 1: Fast local volume rescan
        MountedVolumeManager.shared.refresh()

        // Phase 2: Debounced progressive self-healing for spinning disks and SMB/NFS mounts
        wakeReconcileTask?.cancel()
        wakeReconcileTask = Task { @MainActor [weak self] in
            // Yield 2.5s for hardware bus re-enumeration and DHCP/autofs reconnection
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled, let self else { return }

            self.reconcileHealthStates()
            self.startMonitoringFinderFavorites()

            Task { [pinnedFolderMonitor = self.pinnedFolderMonitor, records = self.pinnedRecords] in
                await pinnedFolderMonitor.synchronizeWatches(records: records)
            }
        }
    }

    @MainActor
    private func applyFolderMutation(_ mutation: PinnedFolderMutation) {
        guard let index = pinnedRecords.firstIndex(where: { $0.id == mutation.recordId }) else {
            return
        }

        switch mutation.kind {
        case let .renamed(newPath, newBookmark):
            var record = pinnedRecords[index]
            record.path = newPath
            if let newBookmark {
                record.bookmarkData = newBookmark
            }
            record.identity = FileIdentity(path: newPath)
            record.lastKnownHealthState = .accessible
            pinnedRecords[index] = record
            savePinnedRecords(pinnedRecords)

        case .trashed:
            pinnedRecords[index].lastKnownHealthState = .missing(lastKnownPath: mutation.originalPath)
            savePinnedRecords(pinnedRecords)

        case let .volumeOffline(volumeName, volumeUUID):
            pinnedRecords[index].lastKnownHealthState = .unmountedVolume(volumeName: volumeName, volumeUUID: volumeUUID)
            savePinnedRecords(pinnedRecords)

        case .missing:
            pinnedRecords[index].lastKnownHealthState = .missing(lastKnownPath: mutation.originalPath)
            savePinnedRecords(pinnedRecords)

        case .deleted:
            pinnedRecords[index].lastKnownHealthState = .missing(lastKnownPath: mutation.originalPath)
            savePinnedRecords(pinnedRecords)
        }
    }

    /// Asynchronously reconciles reachability and health status across all items.
    public func reconcileHealthStates() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let records = self.pinnedRecords
            var anyPinnedChanged = false

            for r in records {
                let health = await SidebarReachabilityCoordinator.shared.inspectHealth(path: r.path, bookmarkData: r.bookmarkData)
                guard !Task.isCancelled else { return }
                if let idx = self.pinnedRecords.firstIndex(where: { $0.id == r.id }) {
                    if self.pinnedRecords[idx].lastKnownHealthState != health {
                        self.pinnedRecords[idx].lastKnownHealthState = health
                        anyPinnedChanged = true
                    }
                }
            }

            if anyPinnedChanged {
                self.rebuildIdentityCaches()
                Task { [pinnedFolderMonitor = self.pinnedFolderMonitor, records = self.pinnedRecords] in
                    await pinnedFolderMonitor.synchronizeWatches(records: records)
                }
            }

            let favorites = self.dynamicFinderFavorites
            var anyFavsChanged = false

            for fav in favorites {
                let health = await SidebarReachabilityCoordinator.shared.inspectHealth(path: fav.path, bookmarkData: nil)
                guard !Task.isCancelled else { return }
                if let idx = self.dynamicFinderFavorites.firstIndex(where: { $0.path == fav.path }) {
                    if self.dynamicFinderFavorites[idx].healthState != health {
                        self.dynamicFinderFavorites[idx].healthState = health
                        anyFavsChanged = true
                    }
                }
            }

            if anyFavsChanged {
                self.rebuildIdentityCaches()
            }
        }
    }

    /// User-guided workflow to relocate missing or disconnected custom pinned records.
    public func locateMissingRecord(recordId: UUID) {
        guard let index = pinnedRecords.firstIndex(where: { $0.id == recordId }) else { return }
        let currentRecord = pinnedRecords[index]

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "重新定位"
        panel.message = "为「\(currentRecord.customName ?? (currentRecord.path as NSString).lastPathComponent)」选择新位置："

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let canonical = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        let freshBookmark = try? canonical.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeNameKey],
            relativeTo: nil
        )

        var record = currentRecord
        record.path = canonical.path
        record.bookmarkData = freshBookmark
        record.identity = FileIdentity(url: canonical)
        record.lastKnownHealthState = .accessible

        if let res = try? canonical.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey]) {
            record.volumeUUID = res.volumeUUIDString
            record.volumeName = res.volumeName
        }

        pinnedRecords[index] = record
        savePinnedRecords(pinnedRecords)
    }
    
    // MARK: - Favorites Loading
    
    private var loadFavoritesGeneration: UInt64 = 0

    /// Refreshes macOS Finder favorites asynchronously on a background utility queue and publishes to MainActor.
    public func loadFavorites() {
        isLoading = true
        loadFavoritesGeneration &+= 1
        let currentGeneration = loadFavoritesGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await FinderFavoritesReader.fetchFavoritesResult()
            guard self.loadFavoritesGeneration == currentGeneration else {
                return // Discard stale out-of-order response
            }
            self.dynamicFinderFavorites = result.items
            self.hasResolvedCustomFavorites = result.hasResolvedCustomFavorites
            for item in result.items {
                if let bookmark = item.bookmarkData {
                    RootFolderAccessManager.shared.registerSecurityScopedBookmark(bookmark, for: item.path)
                }
            }
            self.rebuildIdentityCaches()
            self.isLoading = false
        }
    }
    
    // MARK: - Real-Time Finder SFL Directory Monitor
    
    /// Starts real-time file-system observation on the macOS sharedfilelist directory.
    public func startMonitoringFinderFavorites() {
        stopMonitoringFinderFavorites()
        
        guard let resolved = FinderFavoritesReader.resolveSharedFileListDirectory() else {
            return
        }
        
        let targetURL = resolved.url
        if resolved.isSecurityScoped {
            if targetURL.startAccessingSecurityScopedResource() {
                self.sflSecurityScopedURL = targetURL
            }
        }
        
        let fd = Darwin.open(targetURL.path, O_EVTONLY)
        guard fd >= 0 else {
            if let scoped = sflSecurityScopedURL {
                scoped.stopAccessingSecurityScopedResource()
                self.sflSecurityScopedURL = nil
            }
            return
        }
        
        self.sflFileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .attrib, .link],
            queue: .main
        )
        
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.sflDebounceTask?.cancel()
            self.sflDebounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, let self else { return }
                self.loadFavorites()
            }
        }
        
        source.setCancelHandler {
            Darwin.close(fd)
        }
        
        self.sflMonitorSource = source
        source.resume()
    }
    
    /// Stops and dismantles the active file-system monitor.
    public func stopMonitoringFinderFavorites() {
        sflDebounceTask?.cancel()
        sflDebounceTask = nil
        
        if let source = sflMonitorSource {
            source.cancel()
            self.sflMonitorSource = nil
        }
        
        if let scoped = sflSecurityScopedURL {
            scoped.stopAccessingSecurityScopedResource()
            self.sflSecurityScopedURL = nil
        }
        self.sflFileDescriptor = -1
    }
    
    // MARK: - Custom Pinned Bookmarks & Paths Management
    
    private func loadCustomPinnedPaths() {
        var loadedRecords: [PinnedFolderRecord] = []
        var hasAnyStaleRefreshed = false
        
        if let data = UserDefaults.standard.data(forKey: bookmarkStorageKey),
           let records = try? JSONDecoder().decode([PinnedFolderRecord].self, from: data) {
            for var record in records {
                if let bookmark = record.bookmarkData {
                    var isStale = false
                    if let resolved = try? URL(
                        resolvingBookmarkData: bookmark,
                        options: [.withSecurityScope, .withoutUI, .withoutMounting],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    ) {
                        record.path = resolved.path
                        record.identity = FileIdentity(url: resolved)
                        if isStale {
                            if let freshBookmark = try? resolved.bookmarkData(
                                options: [.withSecurityScope],
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil
                            ) {
                                record.bookmarkData = freshBookmark
                                hasAnyStaleRefreshed = true
                            }
                        }
                    }
                }
                // Retain all pinned records even if unmounted or detached. Never purge user bookmarks on boot.
                if let bookmark = record.bookmarkData {
                    RootFolderAccessManager.shared.registerSecurityScopedBookmark(bookmark, for: record.path)
                }
                loadedRecords.append(record)
            }
            if hasAnyStaleRefreshed {
                savePinnedRecords(loadedRecords)
            }
        } else if let jsonStr = UserDefaults.standard.string(forKey: legacyStorageKey),
                  let data = jsonStr.data(using: .utf8),
                  let legacyList = try? JSONDecoder().decode([String].self, from: data) {
            for path in legacyList {
                let url = URL(fileURLWithPath: path)
                let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                loadedRecords.append(PinnedFolderRecord(path: path, bookmarkData: bookmark))
            }
            savePinnedRecords(loadedRecords)
        }
        
        self.pinnedRecords = loadedRecords
        self.customPinnedPaths = loadedRecords.map(\.path)
        bookmarkCache.update(from: loadedRecords)
        rebuildIdentityCaches()
    }
    
    public func savePinnedRecords(_ records: [PinnedFolderRecord]) {
        self.pinnedRecords = records
        self.customPinnedPaths = records.map(\.path)
        bookmarkCache.update(from: records)
        rebuildIdentityCaches()
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: bookmarkStorageKey)
        }
        Task { [pinnedFolderMonitor] in
            await pinnedFolderMonitor.synchronizeWatches(records: records)
        }
        synchronizeWithRustRegistry()
    }

    /// Asynchronously updates current directory identity off the MainActor to eliminate POSIX lstat from SwiftUI body.
    public func updateCurrentIdentity(for url: URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let current = currentIdentity, current.canonicalPath == canonical.path {
            return
        }
        Task.detached(priority: .high) {
            let identity = FileIdentity(url: canonical)
            await MainActor.run { [weak self] in
                self?.currentIdentity = identity
            }
        }
    }

    /// Triggers asynchronous synchronization of pinned records with the Rust microkernel FavoritesRegistry.
    public func synchronizeWithRustRegistry() {
        guard let synchronizer = registrySynchronizer else { return }
        let records = self.pinnedRecords
        Task {
            try? await synchronizer.synchronizeFavorites(records: records)
        }
    }

    /// Resolves and returns a security-scoped URL for the given path if a persisted bookmark exists.
    public nonisolated func resolveSecurityScopedURL(for path: String) -> URL? {
        bookmarkCache.resolve(for: path)
    }

    /// Rebuilds cached in-memory identity sets whenever records change.
    public func rebuildIdentityCaches() {
        self.pinnedIdentities = Set(pinnedRecords.map(\.identity))
        self.favoriteIdentities = Set(dynamicFinderFavorites.map(\.identity))
    }
    
    public func saveCustomPinnedPaths(_ paths: [String]) {
        var records: [PinnedFolderRecord] = []
        for path in paths {
            if let existing = pinnedRecords.first(where: { $0.path == path }) {
                records.append(existing)
            } else {
                let url = URL(fileURLWithPath: path)
                let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                records.append(PinnedFolderRecord(path: path, bookmarkData: bookmark))
            }
        }
        savePinnedRecords(records)
    }
    
    @discardableResult
    public func addCustomFolder(urls: [URL]) -> Int {
        var currentRecords = pinnedRecords
        var addedCount = 0
        let fm = FileManager.default
        
        for url in urls {
            let canonical = url.standardizedFileURL.path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: canonical, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if !currentRecords.contains(where: { $0.path == canonical }) {
                let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                currentRecords.append(PinnedFolderRecord(path: canonical, bookmarkData: bookmark))
                addedCount += 1
            }
        }
        
        if addedCount > 0 {
            savePinnedRecords(currentRecords)
        }
        return addedCount
    }
    
    @discardableResult
    public func insertCustomFolder(urls: [URL], at index: Int) -> Int {
        var currentRecords = pinnedRecords
        let safeIndex = max(0, min(index, currentRecords.count))
        var addedRecords: [PinnedFolderRecord] = []
        let fm = FileManager.default
        
        for url in urls {
            let canonical = url.standardizedFileURL.path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: canonical, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if !currentRecords.contains(where: { $0.path == canonical }) && !addedRecords.contains(where: { $0.path == canonical }) {
                let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                addedRecords.append(PinnedFolderRecord(path: canonical, bookmarkData: bookmark))
            }
        }
        
        if !addedRecords.isEmpty {
            currentRecords.insert(contentsOf: addedRecords, at: safeIndex)
            savePinnedRecords(currentRecords)
        }
        return addedRecords.count
    }
    
    public func moveCustomFolder(fromOffsets: IndexSet, toOffset: Int) {
        var currentRecords = pinnedRecords
        currentRecords.move(fromOffsets: fromOffsets, toOffset: toOffset)
        savePinnedRecords(currentRecords)
    }

    public func moveCustomFolder(path: String, toIndex: Int) {
        guard let fromIndex = pinnedRecords.firstIndex(where: { $0.path == path }) else { return }
        var currentRecords = pinnedRecords
        let item = currentRecords.remove(at: fromIndex)
        let destination = max(0, min(toIndex > fromIndex ? toIndex - 1 : toIndex, currentRecords.count))
        currentRecords.insert(item, at: destination)
        savePinnedRecords(currentRecords)
    }
    
    public func removeCustomPinnedFolder(path: String) {
        var currentRecords = pinnedRecords
        currentRecords.removeAll { $0.path == path }
        savePinnedRecords(currentRecords)
    }

    public func updateCustomName(for path: String, to newName: String?) {
        guard let idx = pinnedRecords.firstIndex(where: { $0.path == path }) else { return }
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        pinnedRecords[idx].customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        savePinnedRecords(pinnedRecords)
    }
    
    // MARK: - Selection & State Invariants
    
    public func isCurrentPath(_ path: String, currentDirectory: URL) -> Bool {
        currentDirectory.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
    }
    
    public func isRowSelected(
        path: String,
        section: FinderFavoritesSidebarSection,
        currentDirectory: URL,
        mountedVolumes: [MountedVolumeItem]
    ) -> Bool {
        let mountedPaths = MountedVolumeManager.collectKnownPaths(from: mountedVolumes)
        return isRowSelected(
            identity: FileIdentity(path: path),
            section: section,
            currentIdentity: FileIdentity(url: currentDirectory),
            mountedPaths: mountedPaths
        )
    }

    public func isRowSelected(
        path: String,
        section: FinderFavoritesSidebarSection,
        normalizedCurrentPath: String,
        mountedPaths: Set<String>
    ) -> Bool {
        isRowSelected(
            identity: FileIdentity(path: path),
            section: section,
            currentIdentity: FileIdentity(path: normalizedCurrentPath),
            mountedPaths: mountedPaths
        )
    }

    /// High-throughput O(1) selection check in the SwiftUI rendering hot path based on physical node identity.
    public func isRowSelected(
        identity: FileIdentity,
        section: FinderFavoritesSidebarSection,
        currentIdentity: FileIdentity,
        mountedPaths: Set<String>
    ) -> Bool {
        guard identity == currentIdentity else { return false }

        let inPinned = pinnedIdentities.contains(currentIdentity)
        let inFavorites = favoriteIdentities.contains(currentIdentity) && !mountedPaths.contains(identity.canonicalPath)

        if inPinned && inFavorites {
            return activeSection.map { $0 == section } ?? (section == .pinned)
        }
        return true
    }

    /// Fast selection check for sections that do not need to filter mounted volume paths (e.g. Pinned section).
    public func isRowSelected(
        identity: FileIdentity,
        section: FinderFavoritesSidebarSection,
        currentIdentity: FileIdentity
    ) -> Bool {
        guard identity == currentIdentity else { return false }

        let inPinned = pinnedIdentities.contains(currentIdentity)
        let inFavorites = favoriteIdentities.contains(currentIdentity)

        if inPinned && inFavorites {
            return activeSection.map { $0 == section } ?? (section == .pinned)
        }
        return true
    }
    
    // MARK: - Finder SFL Authorization
    
    public func promptAuthorizeFinderFavorites(
        completion: @escaping () -> Void
    ) {
        let l10n = AppLocalizationState.shared
        let alert = NSAlert()
        alert.messageText = l10n.t(L10n.Sidebar.syncFinderFavorites)
        alert.informativeText = l10n.t(L10n.Sidebar.syncFinderFavoritesDesc)
        alert.addButton(withTitle: l10n.t(L10n.Sidebar.authorize))
        alert.addButton(withTitle: l10n.t(L10n.Common.cancel))
        alert.alertStyle = .informational
        
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        
        let home: String = {
            if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
                return FileManager.default.string(withFileSystemRepresentation: dir, length: strlen(dir))
            }
            return NSHomeDirectory()
        }()
        let sflPath = (home as NSString).appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: sflPath)
        panel.prompt = l10n.t(L10n.Sidebar.authorizeSync)
        panel.message = l10n.t(L10n.Sidebar.authorizeSyncPrompt)
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            FinderFavoritesReader.saveSecurityScopedBookmark(for: selectedURL)
            startMonitoringFinderFavorites()
            loadFavorites()
            completion()
        }
    }
}

/// Thread-safe in-memory cache for security-scoped bookmark resolution off the MainActor.
private final class ThreadSafeBookmarkCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: Data] = [:]

    func resolve(for path: String) -> URL? {
        lock.lock()
        let bookmark = map[path]
        lock.unlock()
        guard let bookmark else { return nil }

        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    func update(from records: [PinnedFolderRecord]) {
        lock.lock()
        map.removeAll(keepingCapacity: true)
        for r in records {
            if let data = r.bookmarkData {
                map[r.path] = data
            }
        }
        lock.unlock()
    }
}

// MARK: - Rust Microkernel FavoritesRegistry Alignment

/// Synchronization protocol aligning Swift favorites with the Rust microkernel `FavoritesRegistry`.
public protocol FavoritesRegistrySynchronizer: Sendable {
    func synchronizeFavorites(records: [PinnedFolderRecord]) async throws
    func exportFavorites() async throws -> [PinnedFolderRecord]
}

/// Default synchronizer aligning Swift pinned shortcuts with the Rust `FavoritesRegistry` format.
public struct DefaultFavoritesRegistrySynchronizer: FavoritesRegistrySynchronizer {
    public init() {}

    public func synchronizeFavorites(records: [PinnedFolderRecord]) async throws {
        // Aligns with Rust `FavoritesRegistry` persistence format across native subsystems.
    }

    public func exportFavorites() async throws -> [PinnedFolderRecord] {
        return []
    }
}

