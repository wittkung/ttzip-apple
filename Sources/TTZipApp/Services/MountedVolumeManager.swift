// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Darwin
import Foundation
import Observation

/// Errors that can occur during storage volume unmount and ejection.
public enum VolumeEjectError: LocalizedError, Sendable {
    case timeout(path: String)
    case notEjectable(path: String)
    case failed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let path):
            return "Unmount timed out for volume at \(path)"
        case .notEjectable(let path):
            return "Volume at \(path) is not ejectable"
        case .failed(let reason):
            return reason
        }
    }
}

/// Represents a mounted storage volume or cloud drive location.
public struct MountedVolumeItem: Identifiable, Hashable, Equatable, Sendable {
    package enum SourceKind: String, Sendable, Hashable {
        case rootVolume
        case mountedVolume
        case icloudDrive
        case cloudStorageLocation

        package var mergePriority: Int {
            switch self {
            case .rootVolume: return 4
            case .mountedVolume: return 3
            case .icloudDrive: return 2
            case .cloudStorageLocation: return 1
            }
        }
    }

    public var id: String { path }
    public let name: String
    public let path: String
    public let url: URL
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let systemImage: String
    public let isCloudStorage: Bool
    public let identity: FileIdentity
    package let sourceKind: SourceKind
    package let knownPaths: Set<String>

    public init(
        name: String,
        path: String,
        url: URL,
        isInternal: Bool,
        isRemovable: Bool,
        isEjectable: Bool,
        systemImage: String,
        isCloudStorage: Bool,
        identity: FileIdentity? = nil
    ) {
        let resolvedIdentity = identity ?? FileIdentity(url: url)
        self.init(
            name: name,
            path: path,
            url: url,
            isInternal: isInternal,
            isRemovable: isRemovable,
            isEjectable: isEjectable,
            systemImage: systemImage,
            isCloudStorage: isCloudStorage,
            identity: resolvedIdentity,
            sourceKind: path == "/" ? .rootVolume : (isCloudStorage ? .icloudDrive : .mountedVolume),
            knownPaths: [path, resolvedIdentity.canonicalPath]
        )
    }

    package init(
        name: String,
        path: String,
        url: URL,
        isInternal: Bool,
        isRemovable: Bool,
        isEjectable: Bool,
        systemImage: String,
        isCloudStorage: Bool,
        identity: FileIdentity? = nil,
        sourceKind: SourceKind,
        knownPaths: Set<String>? = nil
    ) {
        let resolvedIdentity = identity ?? FileIdentity(url: url)
        self.name = name
        self.path = path
        self.url = url
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.systemImage = systemImage
        self.isCloudStorage = isCloudStorage
        self.identity = resolvedIdentity
        self.sourceKind = sourceKind
        var paths = knownPaths ?? []
        paths.insert(path)
        paths.insert(resolvedIdentity.canonicalPath)
        self.knownPaths = paths
    }
}

/// Service managing mounted storage volumes, external drives, and cloud storage providers.
@MainActor
@Observable
public final class MountedVolumeManager {
    /// Shared singleton instance.
    public static let shared = MountedVolumeManager()

    /// Published list of currently detected mounted volumes and cloud drives.
    public private(set) var mountedVolumes: [MountedVolumeItem] = []

    /// Fast pre-hashed set of all currently mounted volume paths for zero-allocation containment checks.
    public private(set) var mountedPathSet: Set<String> = []

    /// Active debounced refresh task.
    @ObservationIgnored
    private var debounceTask: Task<Void, Never>?

    /// Active detached volume discovery task.
    @ObservationIgnored
    private var activeRefreshTask: Task<Void, Never>?

    /// Unified background notification monitoring task.
    @ObservationIgnored
    private var unifiedMonitorTask: Task<Void, Never>?

    /// Individual observation tasks feeding into the unified stream.
    @ObservationIgnored
    private var notificationTasks: [Task<Void, Never>] = []

    /// Initializes the manager, seeds with default root volume, starts notification monitoring, and triggers background refresh.
    public init() {
        let rootURL = URL(fileURLWithPath: "/")
        let rootItem = MountedVolumeItem(
            name: "Macintosh HD",
            path: "/",
            url: rootURL,
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            systemImage: "internaldrive.fill",
            isCloudStorage: false
        )
        self.mountedVolumes = [rootItem]
        self.mountedPathSet = ["/"]

        startMonitoring()
        refresh()
    }

    deinit {
        unifiedMonitorTask?.cancel()
        debounceTask?.cancel()
        activeRefreshTask?.cancel()
        for task in notificationTasks {
            task.cancel()
        }
    }

    /// Starts observing mount, unmount, and rename volume events unified into a debounced background refresh stream.
    public func startMonitoring() {
        stopMonitoring()

        let center = NSWorkspace.shared.notificationCenter
        let notificationNames: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]

        let (stream, continuation) = AsyncStream<Void>.makeStream()
        var subTasks: [Task<Void, Never>] = []

        for name in notificationNames {
            let task = Task { @MainActor [weak self] in
                for await _ in center.notifications(named: name) {
                    guard !Task.isCancelled, self != nil else { break }
                    continuation.yield()
                }
            }
            subTasks.append(task)
        }

        self.notificationTasks = subTasks
        self.unifiedMonitorTask = Task { @MainActor [weak self] in
            for await _ in stream {
                guard !Task.isCancelled, let self else { break }
                self.scheduleDebouncedRefresh()
            }
        }
    }

    /// Stops observing workspace notification streams and cancels pending refresh tasks.
    public func stopMonitoring() {
        for task in notificationTasks {
            task.cancel()
        }
        notificationTasks.removeAll()
        unifiedMonitorTask?.cancel()
        unifiedMonitorTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Schedules a debounced (150ms) refresh to coalesce rapid repeated events.
    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.refresh()
        }
    }

    package struct VolumeScanSnapshot: Sendable, Equatable {
        package let volumes: [MountedVolumeItem]
        package let pathSet: Set<String>
    }

    package struct VolumeScanEnvironment: Sendable {
        package var rootURL: URL
        package var mountedVolumeURLs: [URL]
        package var homeDirectoryURL: URL
        package var includeRootVolume: Bool
        package var userFacingVolumeFilter: @Sendable (URL) -> Bool

        package init(
            rootURL: URL = URL(fileURLWithPath: "/"),
            mountedVolumeURLs: [URL],
            homeDirectoryURL: URL,
            includeRootVolume: Bool = true,
            userFacingVolumeFilter: @escaping @Sendable (URL) -> Bool = { MountedVolumeManager.isUserFacingStorageVolume(url: $0) }
        ) {
            self.rootURL = rootURL
            self.mountedVolumeURLs = mountedVolumeURLs
            self.homeDirectoryURL = homeDirectoryURL
            self.includeRootVolume = includeRootVolume
            self.userFacingVolumeFilter = userFacingVolumeFilter
        }

        package static var live: VolumeScanEnvironment {
            let fileManager = FileManager.default
            let keys: [URLResourceKey] = [
                .volumeIsInternalKey,
                .volumeLocalizedNameKey,
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeIsBrowsableKey
            ]
            let mountedURLs = fileManager.mountedVolumeURLs(
                includingResourceValuesForKeys: keys,
                options: [.skipHiddenVolumes]
            ) ?? []
            return VolumeScanEnvironment(
                rootURL: URL(fileURLWithPath: "/"),
                mountedVolumeURLs: mountedURLs,
                homeDirectoryURL: fileManager.homeDirectoryForCurrentUser,
                includeRootVolume: true
            )
        }
    }

    /// Scans root volume, mounted file system volumes, and user cloud storage directories
    /// on a detached background worker thread to protect the main thread from blocking VFS I/O.
    public func refresh() {
        activeRefreshTask?.cancel()
        activeRefreshTask = Task { @MainActor [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                Self.scanVolumesBackground()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.mountedVolumes = snapshot.volumes
            self.mountedPathSet = snapshot.pathSet
        }
    }

    package nonisolated static func scanVolumesBackground(
        environment: VolumeScanEnvironment = .live
    ) -> VolumeScanSnapshot {
        let fileManager = FileManager.default
        var candidates: [MountedVolumeItem] = []

        if environment.includeRootVolume {
            candidates.append(buildRootVolumeCandidate(rootURL: environment.rootURL, fileManager: fileManager))
        }
        candidates.append(contentsOf: buildMountedVolumeCandidates(environment: environment))
        candidates.append(contentsOf: buildCloudStorageLocationCandidates(homeDirectoryURL: environment.homeDirectoryURL, fileManager: fileManager))
        if let icloudItem = inspectExplicitICloudDrive(homeDirectoryURL: environment.homeDirectoryURL, fileManager: fileManager) {
            candidates.append(icloudItem)
        }

        return coalesceCandidates(candidates)
    }

    /// Returns true only when `identity` resolved to a concrete physical inode `(st_dev, st_ino)`
    /// with `.none` or `.resolved` symlink state (excluding offline `.canonicalPath`, `.deadLink`,
    /// `.circularLoop`, and `.maxHopsExceeded` fallbacks).
    package nonisolated static func hasConfirmedTargetPhysicalIdentity(_ identity: FileIdentity) -> Bool {
        guard case .physical = identity.key else { return false }
        switch identity.symlinkState {
        case .none, .resolved:
            return true
        case .circularLoop, .deadLink, .maxHopsExceeded:
            return false
        }
    }

    /// Collects all known paths across the given mounted volume items.
    package nonisolated static func collectKnownPaths(from volumes: [MountedVolumeItem]) -> Set<String> {
        var paths: Set<String> = []
        for volume in volumes {
            paths.formUnion(volume.knownPaths)
        }
        return paths
    }

    /// Coalesces candidate volume items by confirmed physical target identity while preserving
    /// raw-path idempotency for degraded or offline fallback identities.
    package nonisolated static func coalesceCandidates(_ candidates: [MountedVolumeItem]) -> VolumeScanSnapshot {
        var volumes: [MountedVolumeItem] = []
        var seenRawPaths: Set<String> = []
        var allKnownPaths: Set<String> = []
        var indexByPhysicalKey: [FileIdentity.Key: Int] = [:]

        for item in candidates {
            if hasConfirmedTargetPhysicalIdentity(item.identity),
               let existingIdx = indexByPhysicalKey[item.identity.key] {
                let existing = volumes[existingIdx]
                let mergedPaths = existing.knownPaths.union(item.knownPaths)
                let winner = (item.sourceKind.mergePriority > existing.sourceKind.mergePriority)
                    ? item
                    : existing
                volumes[existingIdx] = MountedVolumeItem(
                    name: winner.name,
                    path: winner.path,
                    url: winner.url,
                    isInternal: winner.isInternal,
                    isRemovable: winner.isRemovable,
                    isEjectable: winner.isEjectable,
                    systemImage: winner.systemImage,
                    isCloudStorage: winner.isCloudStorage,
                    identity: winner.identity,
                    sourceKind: winner.sourceKind,
                    knownPaths: mergedPaths
                )
                seenRawPaths.insert(item.path)
                allKnownPaths.formUnion(mergedPaths)
                continue
            }

            guard !seenRawPaths.contains(item.path) else {
                continue
            }

            seenRawPaths.insert(item.path)
            allKnownPaths.formUnion(item.knownPaths)
            let newIdx = volumes.count
            volumes.append(item)
            if hasConfirmedTargetPhysicalIdentity(item.identity) {
                indexByPhysicalKey[item.identity.key] = newIdx
            }
        }

        return VolumeScanSnapshot(volumes: volumes, pathSet: allKnownPaths)
    }

    private nonisolated static func buildRootVolumeCandidate(
        rootURL: URL,
        fileManager: FileManager
    ) -> MountedVolumeItem {
        let rootPath = rootURL.path
        let rootValues = try? rootURL.resourceValues(forKeys: [.volumeLocalizedNameKey])
        let rawRootName = rootValues?.volumeLocalizedName ?? fileManager.displayName(atPath: rootPath)
        let rootName = (rawRootName.isEmpty || rawRootName == "/") ? "Macintosh HD" : rawRootName
        return MountedVolumeItem(
            name: rootName,
            path: rootPath,
            url: rootURL,
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            systemImage: "internaldrive.fill",
            isCloudStorage: false,
            sourceKind: .rootVolume
        )
    }

    private nonisolated static func buildMountedVolumeCandidates(
        environment: VolumeScanEnvironment
    ) -> [MountedVolumeItem] {
        let keys: Set<URLResourceKey> = [
            .volumeIsInternalKey,
            .volumeLocalizedNameKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsBrowsableKey
        ]
        var items: [MountedVolumeItem] = []
        for url in environment.mountedVolumeURLs {
            guard environment.userFacingVolumeFilter(url) else {
                continue
            }
            let path = url.path
            let values = try? url.resourceValues(forKeys: keys)
            let name = values?.volumeLocalizedName ?? url.lastPathComponent
            let isInternal = values?.volumeIsInternal ?? true
            let isRemovable = values?.volumeIsRemovable ?? false
            let isEjectable = values?.volumeIsEjectable ?? (!isInternal || isRemovable)
            let systemImage = (isInternal && !isRemovable) ? "internaldrive.fill" : "externaldrive.fill"

            items.append(
                MountedVolumeItem(
                    name: name,
                    path: path,
                    url: url,
                    isInternal: isInternal,
                    isRemovable: isRemovable,
                    isEjectable: isEjectable,
                    systemImage: systemImage,
                    isCloudStorage: false,
                    sourceKind: .mountedVolume
                )
            )
        }
        return items
    }

    private nonisolated static func buildCloudStorageLocationCandidates(
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) -> [MountedVolumeItem] {
        let cloudStorageDir = homeDirectoryURL
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        var dirStat = Darwin.stat()
        let dirStatResult = DatalessProtection.withMaterializationDisabled {
            cloudStorageDir.path.withCString { Darwin.lstat($0, &dirStat) }
        }
        guard dirStatResult == 0,
              let cloudEntries = try? fileManager.contentsOfDirectory(
                  at: cloudStorageDir,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            return []
        }

        var items: [MountedVolumeItem] = []
        for entry in cloudEntries {
            let logicalEntryURL = cloudStorageDir.appendingPathComponent(entry.lastPathComponent)
            if let item = inspectCloudStorageEntry(entry: logicalEntryURL, cloudStorageDir: cloudStorageDir, fileManager: fileManager) {
                items.append(item)
            }
        }
        return items
    }

    private nonisolated static func inspectCloudStorageEntry(
        entry: URL,
        cloudStorageDir: URL,
        fileManager: FileManager
    ) -> MountedVolumeItem? {
        var entryStat = Darwin.stat()
        let lstatResult = DatalessProtection.withMaterializationDisabled {
            entry.path.withCString { Darwin.lstat($0, &entryStat) }
        }
        guard lstatResult == 0 else { return nil }

        let entryMode = entryStat.st_mode & S_IFMT
        guard entryMode == S_IFDIR || entryMode == S_IFLNK else {
            return nil
        }

        let identity = FileIdentity(url: entry)
        guard hasConfirmedTargetPhysicalIdentity(identity) else {
            return nil
        }

        if entryMode == S_IFLNK {
            var isDir: ObjCBool = false
            let existsAsDirectory = DatalessProtection.withMaterializationDisabled {
                fileManager.fileExists(atPath: entry.path, isDirectory: &isDir) && isDir.boolValue
            }
            guard existsAsDirectory else {
                return nil
            }
        }

        let rawDisplayName = DatalessProtection.withMaterializationDisabled {
            fileManager.displayName(atPath: entry.path)
        }
        let name = rawDisplayName.isEmpty ? entry.lastPathComponent : rawDisplayName

        var knownPaths: Set<String> = [entry.path, identity.canonicalPath]
        let logicalPath = (cloudStorageDir.path as NSString).appendingPathComponent(entry.lastPathComponent)
        if logicalPath != entry.path {
            let logicalIdentity = FileIdentity(path: logicalPath)
            if logicalIdentity.key == identity.key {
                knownPaths.insert(logicalPath)
                knownPaths.insert(logicalIdentity.canonicalPath)
            }
        }

        return MountedVolumeItem(
            name: name,
            path: entry.path,
            url: entry,
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            systemImage: "folder.fill",
            isCloudStorage: false,
            identity: identity,
            sourceKind: .cloudStorageLocation,
            knownPaths: knownPaths
        )
    }

    private nonisolated static func inspectExplicitICloudDrive(
        homeDirectoryURL: URL,
        fileManager: FileManager
    ) -> MountedVolumeItem? {
        let iCloudDir = homeDirectoryURL
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var st = Darwin.stat()
        let lstatResult = DatalessProtection.withMaterializationDisabled {
            iCloudDir.path.withCString { Darwin.lstat($0, &st) }
        }
        guard lstatResult == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        let identity = FileIdentity(url: iCloudDir)
        guard hasConfirmedTargetPhysicalIdentity(identity) else {
            return nil
        }
        let rawDisplayName = DatalessProtection.withMaterializationDisabled {
            fileManager.displayName(atPath: iCloudDir.path)
        }
        let iCloudName = (rawDisplayName.isEmpty || rawDisplayName == "com~apple~CloudDocs")
            ? NSLocalizedString("iCloud Drive", comment: "iCloud Drive volume name")
            : rawDisplayName
        return MountedVolumeItem(
            name: iCloudName,
            path: iCloudDir.path,
            url: iCloudDir,
            isInternal: true,
            isRemovable: false,
            isEjectable: false,
            systemImage: "icloud.fill",
            isCloudStorage: true,
            identity: identity,
            sourceKind: .icloudDrive,
            knownPaths: [iCloudDir.path, identity.canonicalPath]
        )
    }

    /// Asynchronously and safely unmounts and ejects an ejectable storage device with a 5.0-second watchdog timeout.
    /// - Parameter item: The mounted volume item to eject.
    /// - Throws: An error if the unmount request fails or times out.
    public func ejectVolumeAsync(_ item: MountedVolumeItem) async throws {
        guard item.isEjectable else {
            throw VolumeEjectError.notEjectable(path: item.path)
        }
        let targetURL = item.url

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try NSWorkspace.shared.unmountAndEjectDevice(at: targetURL)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw VolumeEjectError.timeout(path: targetURL.path)
            }
            try await group.next()
            group.cancelAll()
        }

        scheduleDebouncedRefresh()
    }

    /// Safely unmounts and ejects an ejectable storage device.
    /// - Parameter item: The mounted volume item to eject.
    /// - Throws: An error if the unmount request fails.
    public func ejectVolume(_ item: MountedVolumeItem) throws {
        guard item.isEjectable else { return }
        try NSWorkspace.shared.unmountAndEjectDevice(at: item.url)
    }

    /// Evaluates whether a mounted volume is a genuine user-facing storage volume.
    /// Rejects Time Machine local snapshots, Cryptex disk images, and protected system mounts.
    public nonisolated static func isUserFacingStorageVolume(url: URL) -> Bool {
        let path = url.path

        // 1. Root volume '/' is always recognized as user-facing system volume
        if path == "/" {
            return true
        }

        // 2. Blacklisted path prefixes
        let blacklistedPathPrefixes: [String] = [
            "/System/Volumes",
            "/Volumes/com.apple.TimeMachine.localsnapshots",
            "/Volumes/.timemachine",
            "/Volumes/Recovery",
            "/Library/Developer/CoreSimulator/Volumes",
            "/private/var/run/com.apple.security.cryptexd",
            "/Users/"
        ]

        for prefix in blacklistedPathPrefixes {
            if path.hasPrefix(prefix) {
                return false
            }
        }

        // 3. Foundation resource values inspection
        let resourceKeys: Set<URLResourceKey> = [
            .volumeIsBrowsableKey
        ]

        if let values = try? url.resourceValues(forKeys: resourceKeys) {
            if let isBrowsable = values.volumeIsBrowsable, !isBrowsable {
                return false
            }
        }

        // 4. POSIX statfs kernel mount flags inspection
        var sfs = statfs()
        let statResult = path.withCString { cPath in
            statfs(cPath, &sfs)
        }

        guard statResult == 0 else {
            return false
        }

        let flags = UInt32(sfs.f_flags)

        // Reject mounts with MNT_DONTBROWSE (0x00100000)
        if (flags & UInt32(MNT_DONTBROWSE)) != 0 {
            return false
        }

        // Reject non-root APFS snapshot mounts with MNT_SNAPSHOT (0x40000000)
        if (flags & UInt32(MNT_SNAPSHOT)) != 0 {
            return false
        }

        // Inspect mount source name
        let mountFromName = withUnsafePointer(to: &sfs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                String(cString: $0)
            }
        }

        if mountFromName.contains("localsnapshots") || mountFromName.contains(".timemachine") {
            return false
        }

        // Inspect file system type
        let fsTypeName = withUnsafePointer(to: &sfs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }

        let virtualFsTypes: Set<String> = ["autofs", "devfs", "devicefs"]
        if virtualFsTypes.contains(fsTypeName) {
            return false
        }

        return true
    }
}
