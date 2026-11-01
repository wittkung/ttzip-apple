// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import os
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Keyed mutual exclusion lock pool for archive paths to serialize in-place disk mutations.
/// Enforces deterministic FIFO ordering via continuation queues, eliminating actor reentrancy race conditions.
public actor ArchivePathLockPool {
    public static let shared = ArchivePathLockPool()
    
    @TaskLocal
    private static var heldLocks: Set<String> = []
    
    private final class Waiter: Sendable {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        private let isResumed = OSAllocatedUnfairLock(initialState: false)

        init(id: UUID, continuation: CheckedContinuation<Void, Error>) {
            self.id = id
            self.continuation = continuation
        }

        func resumeOnce(returning value: Void) {
            let shouldResume = isResumed.withLock { resumed in
                if !resumed {
                    resumed = true
                    return true
                }
                return false
            }
            if shouldResume {
                continuation.resume(returning: value)
            }
        }

        func resumeOnce(throwing error: Error) {
            let shouldResume = isResumed.withLock { resumed in
                if !resumed {
                    resumed = true
                    return true
                }
                return false
            }
            if shouldResume {
                continuation.resume(throwing: error)
            }
        }
    }
    
    private struct WaiterQueue {
        var waiters: [Waiter] = []
    }
    
    private var queues: [String: WaiterQueue] = [:]
    
    public init() {}
    
    public func withLock<T: Sendable>(_ path: String, operation: @Sendable () async throws -> T) async throws -> T {
        let normalizedKey = URL(fileURLWithPath: path).standardizedFileURL.path
        if Self.heldLocks.contains(normalizedKey) {
            // Reentrant invocation on the same task: execute directly to eliminate self-deadlock
            return try await operation()
        }
        
        try await acquire(path: normalizedKey)
        defer {
            release(path: normalizedKey)
        }
        try Task.checkCancellation()
        return try await Self.$heldLocks.withValue(Self.heldLocks.union([normalizedKey])) {
            try await operation()
        }
    }
    
    private func acquire(path: String) async throws {
        try Task.checkCancellation()
        
        if queues[path] == nil {
            queues[path] = WaiterQueue(waiters: [])
            return
        }
        
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enqueueWaiter(path: path, id: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(path: path, id: waiterID)
            }
        }
    }
    
    private func enqueueWaiter(path: String, id: UUID, continuation: CheckedContinuation<Void, Error>) {
        if queues[path] == nil {
            queues[path] = WaiterQueue(waiters: [])
            continuation.resume(returning: ())
            return
        }
        queues[path]?.waiters.append(Waiter(id: id, continuation: continuation))
    }
    
    private func cancelWaiter(path: String, id: UUID) {
        guard var queue = queues[path] else { return }
        if let index = queue.waiters.firstIndex(where: { $0.id == id }) {
            let waiter = queue.waiters.remove(at: index)
            queues[path] = queue
            waiter.resumeOnce(throwing: CancellationError())
        }
    }
    
    private func release(path: String) {
        guard var queue = queues[path] else { return }
        if !queue.waiters.isEmpty {
            let next = queue.waiters.removeFirst()
            queues[path] = queue
            next.resumeOnce(returning: ())
        } else {
            queues.removeValue(forKey: path)
        }
    }
}

/// Centralized coordinator for in-place archive mutation and cross-view cache invalidation.
@MainActor
public final class InPlaceMutationCoordinator {
    public static let shared = InPlaceMutationCoordinator()
    
    private init() {}
    
    // MARK: - Background Compute Dispatcher (Off MainActor & Off Cooperative Thread Pool)
    
    /// Executes heavy UniFFI archive rewrite off the main thread to prevent UI freezing.
    /// Serializes mutations on the exact same physical archive path via ArchivePathLockPool.
    private nonisolated static func executeBackgroundMutation(
        archivePath: String,
        actions: [InPlaceMutationAction],
        password: String? = nil,
        credentialGeneration: UInt64
    ) async throws {
        // Resolve effective password from explicit parameter or thread-safe process store
        let effectivePassword = password ?? ArchivePasswordStore.shared.getPassword(for: archivePath)
        if let pwd = effectivePassword, !pwd.isEmpty {
            let logicalKey = ArchiveCredentialIdentity.logicalKey(for: archivePath)
            ArchiveCredentialGeneration.shared.performIfCurrent(
                credentialGeneration, for: logicalKey
            ) {
                ArchivePasswordStore.shared.setPassword(pwd, for: archivePath)
            }
        }

        try await ArchivePathLockPool.shared.withLock(archivePath) {
            try await NativeComputeDispatcher.shared.dispatchCompute(qos: .userInitiated) {
                try inPlaceMutateArchive(archivePath: archivePath, actions: actions)
            }
        }
    }
    
    /// Invalidates all in-memory caches and broadcasts archive update notification across all views.
    public func invalidateAndRefresh(archivePath: String) async {
        // 1. Invalidate hierarchy session cache
        await ArchiveHierarchySessionCache.shared.invalidate(path: archivePath)
        
        // 2. Invalidate VFS LZ4 cache session
        VFSLz4CachePool.shared.clearSession(sessionId: archivePath)
        
        // 3. Invalidate preview cache
        await EphemeralPreviewCacheManager.shared.cleanupAll()
        await PreviewLRUCacheManager.shared.purgeAll()
        
        // 4. Broadcast notification for all observing views (Miller columns, Explorer, Tabs)
        NotificationCenter.default.post(
            name: NSNotification.Name("TTZipArchiveUnlockedRefresh"),
            object: archivePath,
            userInfo: ["archiveContentsChanged": true]
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
        try await Self.executeBackgroundMutation(
            archivePath: archivePath,
            actions: [action],
            password: password,
            credentialGeneration: ArchiveCredentialGeneration.shared.snapshot(
                for: ArchiveCredentialIdentity.logicalKey(for: archivePath)
            )
        )
        await invalidateAndRefresh(archivePath: archivePath)
    }
    
    /// Appends external files/folders into a virtual folder inside the archive and triggers refresh.
    public func appendFiles(
        archivePath: String,
        sourceFilePaths: [String],
        destinationVirtualFolder: String? = nil,
        password: String? = nil
    ) async throws {
        guard !sourceFilePaths.isEmpty else { return }
        let actions = sourceFilePaths.map { path -> InPlaceMutationAction in
            let baseName = URL(fileURLWithPath: path).lastPathComponent
            let targetPath: String
            if let dest = destinationVirtualFolder, !dest.isEmpty, dest != "." {
                targetPath = "\(dest)/\(baseName)"
            } else {
                targetPath = baseName
            }
            return InPlaceMutationAction(isDelete: false, entryPath: targetPath, sourcePath: path)
        }
        try await Self.executeBackgroundMutation(
            archivePath: archivePath,
            actions: actions,
            password: password,
            credentialGeneration: ArchiveCredentialGeneration.shared.snapshot(
                for: ArchiveCredentialIdentity.logicalKey(for: archivePath)
            )
        )
        await invalidateAndRefresh(archivePath: archivePath)
    }
    
    /// Deletes specific entry paths from the archive and triggers refresh.
    public func deleteEntries(
        archivePath: String,
        entryPaths: [String],
        password: String? = nil
    ) async throws {
        guard !entryPaths.isEmpty else { return }
        let actions = entryPaths.map { entry in
            InPlaceMutationAction(isDelete: true, entryPath: entry, sourcePath: nil)
        }
        try await Self.executeBackgroundMutation(
            archivePath: archivePath,
            actions: actions,
            password: password,
            credentialGeneration: ArchiveCredentialGeneration.shared.snapshot(
                for: ArchiveCredentialIdentity.logicalKey(for: archivePath)
            )
        )
        await invalidateAndRefresh(archivePath: archivePath)
    }
}
