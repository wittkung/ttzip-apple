// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Darwin
import Foundation

/// Background reachability and lifecycle health probe coordinator.
/// Executes asynchronous filesystem inspections with zero MainActor I/O stalls and dataless protection.
public actor SidebarReachabilityCoordinator {
    public static let shared = SidebarReachabilityCoordinator()

    private let fileManager = FileManager.default

    public init() {}

    /// Inspects the reachability and lifecycle status of a path.
    public func inspectHealth(path: String, bookmarkData: Data?) -> SidebarItemHealthState {
        if let unmountedVolumeName = unmountedVolumeNameIfOffline(forPath: path) {
            return resolveUnmountedVolumeHealth(volumeName: unmountedVolumeName, bookmarkData: bookmarkData)
        }

        var st = stat()
        let statResult = DatalessProtection.withMaterializationDisabled {
            lstat(path, &st)
        }

        guard statResult == 0 else {
            return resolveStatFailureHealth(path: path, errnoValue: errno, bookmarkData: bookmarkData)
        }

        if (st.st_flags & UInt32(SF_DATALESS)) != 0 {
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.ubiquitousItemIsDownloadingKey])
            return .datalessCloud(isDownloading: values?.ubiquitousItemIsDownloading ?? false)
        }

        return .accessible
    }

    private func unmountedVolumeNameIfOffline(forPath path: String) -> String? {
        guard path.hasPrefix("/Volumes/") else { return nil }
        let components = path.split(separator: "/")
        guard components.count >= 2 else { return nil }
        let volumeName = String(components[1])
        let volPath = "/Volumes/" + volumeName
        let mountedURLs = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeLocalizedNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        let mountedPaths = Set(mountedURLs.map(\.path))
        return mountedPaths.contains(volPath) ? nil : volumeName
    }

    private func resolveUnmountedVolumeHealth(
        volumeName: String,
        bookmarkData: Data?
    ) -> SidebarItemHealthState {
        guard let bookmarkData else {
            return .unmountedVolume(volumeName: volumeName, volumeUUID: nil)
        }
        if isBookmarkTargetAccessible(bookmarkData, options: [.withSecurityScope, .withoutUI, .withoutMounting]) {
            return .accessible
        }
        let resValues = URL.resourceValues(
            forKeys: [.volumeUUIDStringKey, .volumeLocalizedNameKey],
            fromBookmarkData: bookmarkData
        )
        return .unmountedVolume(
            volumeName: resValues?.volumeLocalizedName ?? volumeName,
            volumeUUID: resValues?.volumeUUIDString
        )
    }

    private func resolveStatFailureHealth(
        path: String,
        errnoValue: Int32,
        bookmarkData: Data?
    ) -> SidebarItemHealthState {
        if errnoValue == EDEADLK {
            return .datalessCloud(isDownloading: false)
        }
        if errnoValue == ENOENT,
           let bookmarkData,
           isBookmarkTargetAccessible(bookmarkData, options: [.withoutUI, .withoutMounting]) {
            return .accessible
        }
        return .missing(lastKnownPath: path)
    }

    private func isBookmarkTargetAccessible(
        _ bookmarkData: Data,
        options: URL.BookmarkResolutionOptions
    ) -> Bool {
        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return false
        }
        return fileManager.fileExists(atPath: resolved.path)
    }
}
