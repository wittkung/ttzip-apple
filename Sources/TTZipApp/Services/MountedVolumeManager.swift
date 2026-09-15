// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import Foundation
import Observation

/// Represents a mounted storage volume or cloud drive location.
public struct MountedVolumeItem: Identifiable, Hashable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let url: URL
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let systemImage: String
    public let isCloudStorage: Bool

    public init(
        name: String,
        path: String,
        url: URL,
        isInternal: Bool,
        isRemovable: Bool,
        isEjectable: Bool,
        systemImage: String,
        isCloudStorage: Bool
    ) {
        self.name = name
        self.path = path
        self.url = url
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.systemImage = systemImage
        self.isCloudStorage = isCloudStorage
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

    /// Active debounced refresh task.
    @ObservationIgnored
    private nonisolated(unsafe) var debounceTask: Task<Void, Never>?

    /// Notification tokens for workspace lifecycle observations.
    @ObservationIgnored
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    /// Initializes the manager, attaches workspace notification observers, and performs an initial refresh.
    public init() {
        registerWorkspaceNotifications()
        refresh()
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        debounceTask?.cancel()
    }

    /// Registers observers for mount, unmount, and rename volume events on NSWorkspace notification center.
    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        let notificationNames: [NSNotification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]

        for name in notificationNames {
            let token = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleDebouncedRefresh()
                }
            }
            observers.append(token)
        }
    }

    /// Schedules a debounced refresh to avoid rapid repeated rescans during volume mounting.
    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.refresh()
        }
    }

    /// Scans root volume, mounted file system volumes, and user cloud storage directories.
    public func refresh() {
        let fileManager = FileManager.default
        var result: [MountedVolumeItem] = []
        var seenPaths: Set<String> = []

        func appendItem(_ item: MountedVolumeItem) {
            if !seenPaths.contains(item.path) {
                seenPaths.insert(item.path)
                result.append(item)
            }
        }

        // 1. Root Volume (/)
        let rootURL = URL(fileURLWithPath: "/")
        let rootValues = try? rootURL.resourceValues(forKeys: [.volumeLocalizedNameKey])
        let rawRootName = rootValues?.volumeLocalizedName ?? fileManager.displayName(atPath: "/")
        let rootName = (rawRootName.isEmpty || rawRootName == "/") ? "Macintosh HD" : rawRootName
        appendItem(
            MountedVolumeItem(
                name: rootName,
                path: "/",
                url: rootURL,
                isInternal: true,
                isRemovable: false,
                isEjectable: false,
                systemImage: "internaldrive.fill",
                isCloudStorage: false
            )
        )

        // 2. Mounted File System Volumes
        let keys: [URLResourceKey] = [
            .volumeIsInternalKey,
            .volumeLocalizedNameKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey
        ]
        let mountedURLs = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        for url in mountedURLs {
            let path = url.path
            if path == "/" || path.hasPrefix("/System/Volumes") {
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeLocalizedName ?? url.lastPathComponent
            let isInternal = values?.volumeIsInternal ?? true
            let isRemovable = values?.volumeIsRemovable ?? false
            let isEjectable = values?.volumeIsEjectable ?? (!isInternal || isRemovable)
            let systemImage = (isInternal && !isRemovable) ? "internaldrive.fill" : "externaldrive.fill"

            appendItem(
                MountedVolumeItem(
                    name: name,
                    path: path,
                    url: url,
                    isInternal: isInternal,
                    isRemovable: isRemovable,
                    isEjectable: isEjectable,
                    systemImage: systemImage,
                    isCloudStorage: false
                )
            )
        }

        // 3. Local Cloud Storage Mount Points
        let cloudStorageDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if fileManager.fileExists(atPath: cloudStorageDir.path),
           let cloudEntries = try? fileManager.contentsOfDirectory(
               at: cloudStorageDir,
               includingPropertiesForKeys: [.isDirectoryKey],
               options: [.skipsHiddenFiles]
           ) {
            for entry in cloudEntries {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    let displayName = fileManager.displayName(atPath: entry.path)
                    let name = displayName.isEmpty ? entry.lastPathComponent : displayName
                    appendItem(
                        MountedVolumeItem(
                            name: name,
                            path: entry.path,
                            url: entry,
                            isInternal: true,
                            isRemovable: false,
                            isEjectable: false,
                            systemImage: "cloud.fill",
                            isCloudStorage: true
                        )
                    )
                }
            }
        }

        // 4. iCloud Drive Container
        let iCloudDir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if fileManager.fileExists(atPath: iCloudDir.path) {
            let rawDisplayName = fileManager.displayName(atPath: iCloudDir.path)
            let iCloudName = (rawDisplayName.isEmpty || rawDisplayName == "com~apple~CloudDocs")
                ? NSLocalizedString("iCloud Drive", comment: "iCloud Drive volume name")
                : rawDisplayName
            appendItem(
                MountedVolumeItem(
                    name: iCloudName,
                    path: iCloudDir.path,
                    url: iCloudDir,
                    isInternal: true,
                    isRemovable: false,
                    isEjectable: false,
                    systemImage: "icloud.fill",
                    isCloudStorage: true
                )
            )
        }

        self.mountedVolumes = result
    }

    /// Safely unmounts and ejects an ejectable storage device.
    /// - Parameter item: The mounted volume item to eject.
    /// - Throws: An error if the unmount request fails.
    public func ejectVolume(_ item: MountedVolumeItem) throws {
        guard item.isEjectable else { return }
        try NSWorkspace.shared.unmountAndEjectDevice(at: item.url)
    }
}
