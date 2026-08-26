// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AppKit
import TTZipCore

/// Centralized coordinator for in-place archive mutation and cross-view cache invalidation.
@MainActor
public final class InPlaceMutationCoordinator {
    public static let shared = InPlaceMutationCoordinator()
    
    private init() {}
    
    /// Invalidates all in-memory caches and broadcasts archive update notification across all views.
    public func invalidateAndRefresh(archivePath: String) async {
        // 1. Invalidate hierarchy session cache
        await ArchiveHierarchySessionCache.shared.invalidate(path: archivePath)
        
        // 2. Invalidate VFS LZ4 cache session
        VFSLz4CachePool.shared.clearSession(sessionId: archivePath)
        
        // 3. Invalidate preview cache
        await EphemeralPreviewCacheManager.shared.cleanupAll()
        PreviewLRUCacheManager.shared.purgeAll()
        
        // 4. Broadcast notification for all observing views (Miller columns, Explorer, Tabs)
        NotificationCenter.default.post(
            name: NSNotification.Name("TTZipArchiveUnlockedRefresh"),
            object: archivePath
        )
    }
    
    /// Replaces an existing entry in the archive with an external file and triggers refresh.
    public func replaceEntry(
        archivePath: String,
        entryPath: String,
        sourceFilePath: String,
        password: String? = nil
    ) async throws {
        let action = InPlaceMutationAction(isDelete: false, entryPath: entryPath, sourcePath: sourceFilePath)
        try inPlaceMutateArchive(archivePath: archivePath, actions: [action])
        await invalidateAndRefresh(archivePath: archivePath)
    }
    
    /// Appends external files/folders into a virtual folder inside the archive and triggers refresh.
    public func appendFiles(
        archivePath: String,
        sourceFilePaths: [String],
        destinationVirtualFolder: String? = nil,
        password: String? = nil
    ) async throws {
        try InPlaceArchiveMutationEngine.shared.addFilesToArchiveSync(
            archivePath: archivePath,
            sourceFilePaths: sourceFilePaths,
            destinationVirtualFolder: destinationVirtualFolder,
            password: password
        )
        await invalidateAndRefresh(archivePath: archivePath)
    }
    
    /// Deletes specific entry paths from the archive and triggers refresh.
    public func deleteEntries(
        archivePath: String,
        entryPaths: [String],
        password: String? = nil
    ) async throws {
        try await InPlaceArchiveMutationEngine.shared.deleteEntriesFromArchive(
            archivePath: archivePath,
            entryPathsToDelete: entryPaths,
            password: password
        )
        await invalidateAndRefresh(archivePath: archivePath)
    }
}
