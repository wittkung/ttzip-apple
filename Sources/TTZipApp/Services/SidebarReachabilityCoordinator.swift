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
        let mountedURLs = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeLocalizedNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        let mountedPaths = Set(mountedURLs.map(\.path))

        var isVolumeMounted = true
        var targetVolumeName: String?
        var targetVolumeUUID: String?

        if path.hasPrefix("/Volumes/") {
            let components = path.split(separator: "/")
            if components.count >= 2 {
                let volPath = "/Volumes/" + String(components[1])
                if !mountedPaths.contains(volPath) {
                    isVolumeMounted = false
                    targetVolumeName = String(components[1])
                }
            }
        }

        if !isVolumeMounted {
            if let bookmarkData {
                var isStale = false
                if let resolved = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope, .withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ), fileManager.fileExists(atPath: resolved.path) {
                    return .accessible
                }

                let resValues = URL.resourceValues(
                    forKeys: [.volumeUUIDStringKey, .volumeLocalizedNameKey],
                    fromBookmarkData: bookmarkData
                )
                targetVolumeUUID = resValues?.volumeUUIDString
                if let name = resValues?.volumeLocalizedName {
                    targetVolumeName = name
                }
            }
            return .unmountedVolume(volumeName: targetVolumeName, volumeUUID: targetVolumeUUID)
        }

        var st = stat()
        let statResult = DatalessProtection.withMaterializationDisabled {
            lstat(path, &st)
        }

        if statResult != 0 {
            if errno == ENOENT {
                if let bookmarkData {
                    var isStale = false
                    if let resolved = try? URL(
                        resolvingBookmarkData: bookmarkData,
                        options: [.withoutUI, .withoutMounting],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    ), fileManager.fileExists(atPath: resolved.path) {
                        return .accessible
                    }
                }
                return .missing(lastKnownPath: path)
            } else if errno == EDEADLK {
                return .datalessCloud(isDownloading: false)
            }
            return .missing(lastKnownPath: path)
        }

        if (st.st_flags & UInt32(SF_DATALESS)) != 0 {
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.ubiquitousItemIsDownloadingKey])
            let isDownloading = values?.ubiquitousItemIsDownloading ?? false
            return .datalessCloud(isDownloading: isDownloading)
        }

        return .accessible
    }
}
