// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Darwin
import Foundation
import TTZipCore

/// Payload describing a detected filesystem mutation on a pinned directory.
public struct PinnedFolderMutation: Sendable {
    public enum Kind: Sendable {
        case renamed(newPath: String, newBookmark: Data?)
        case trashed(trashPath: String)
        case volumeOffline(volumeName: String?, volumeUUID: String?)
        case missing
        case deleted
    }

    public let recordId: UUID
    public let originalPath: String
    public let originalIdentity: FileIdentity
    public let kind: Kind

    public init(recordId: UUID, originalPath: String, originalIdentity: FileIdentity, kind: Kind) {
        self.recordId = recordId
        self.originalPath = originalPath
        self.originalIdentity = originalIdentity
        self.kind = kind
    }
}

/// Actor managing low-level kqueue DispatchSources and APFS Inode self-healing.
/// Incorporates FileDescriptorGuard to gracefully fall back to zero-FD Inode polling under high load.
public actor PinnedFolderMonitor {
    private struct WatchedEntry {
        let recordId: UUID
        let path: String
        let identity: FileIdentity
        let fd: Int32
        let source: DispatchSourceFileSystemObject
    }

    private struct PolledEntry {
        let record: PinnedFolderRecord
        var lastChecked: Date
    }

    private struct EventPayload: Sendable {
        let recordId: UUID
        let fd: Int32
        let originalPath: String
        let originalIdentity: FileIdentity
    }

    private var activeWatches: [UUID: WatchedEntry] = [:]
    private var fallbackQueue: [UUID: PolledEntry] = [:]

    private let monitorQueue = DispatchQueue(
        label: "com.metastudyline.ttzip.pinned-monitor",
        qos: .utility
    )

    private nonisolated let eventContinuation: AsyncStream<EventPayload>.Continuation
    private nonisolated(unsafe) var eventLoopTask: Task<Void, Never>?
    private nonisolated(unsafe) var pollingLoopTask: Task<Void, Never>?

    public typealias MutationHandler = @Sendable (PinnedFolderMutation) async -> Void
    private var onMutation: MutationHandler?

    public init(onMutation: MutationHandler? = nil) {
        self.onMutation = onMutation
        let (stream, continuation) = AsyncStream.makeStream(of: EventPayload.self)
        self.eventContinuation = continuation

        // 1. Kqueue event loop
        self.eventLoopTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.handleFileSystemEvent(
                    recordId: event.recordId,
                    fd: event.fd,
                    originalPath: event.originalPath,
                    originalIdentity: event.originalIdentity
                )
            }
        }

        // 2. Active zero-FD self-healing polling loop for downgraded entries
        self.pollingLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3-second cycle
                guard !Task.isCancelled else { break }
                await self?.executeActiveHealingCycle()
            }
        }
    }

    deinit {
        eventContinuation.finish()
        eventLoopTask?.cancel()
        pollingLoopTask?.cancel()
    }

    public func setMutationHandler(_ handler: @escaping MutationHandler) {
        self.onMutation = handler
    }

    /// Synchronizes current watched records with the requested list.
    public func synchronizeWatches(records: [PinnedFolderRecord]) {
        let activeRecords = records.filter { $0.lastKnownHealthState.isInteractive }
        let desiredIds = Set(activeRecords.map(\.id))

        // 1. Dismantle obsolete watches and clear fallback entries
        for (id, entry) in activeWatches where !desiredIds.contains(id) {
            dismantle(entry: entry)
            activeWatches.removeValue(forKey: id)
        }
        for id in fallbackQueue.keys where !desiredIds.contains(id) {
            fallbackQueue.removeValue(forKey: id)
        }

        // 2. Install or update active watches
        for record in activeRecords {
            if let existing = activeWatches[record.id] {
                if existing.path != record.path {
                    dismantle(entry: existing)
                    activeWatches.removeValue(forKey: record.id)
                    installOrEnqueue(record: record)
                }
            } else if fallbackQueue[record.id] == nil {
                installOrEnqueue(record: record)
            }
        }
    }

    /// Stops and releases all open file descriptors and dispatch sources.
    public func stopAllWatches() {
        for (_, entry) in activeWatches {
            dismantle(entry: entry)
        }
        activeWatches.removeAll()
        fallbackQueue.removeAll()
    }

    // MARK: - Private Watch Plumbing

    private func installOrEnqueue(record: PinnedFolderRecord) {
        // Attempt allocation via FileDescriptorGuard
        let fd = FileDescriptorGuard.safeOpen(path: record.path, flags: O_EVTONLY | O_NONBLOCK)
        if fd >= 0 {
            installWatch(for: record, fd: fd)
        } else {
            // Headroom exhausted or error: Graceful fallback to Zero-FD Polling
            fallbackQueue[record.id] = PolledEntry(record: record, lastChecked: Date())
        }
    }

    private func installWatch(for record: PinnedFolderRecord, fd: Int32) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.rename, .delete, .revoke],
            queue: monitorQueue
        )

        let recordId = record.id
        let originalPath = record.path
        let originalIdentity = record.identity
        let continuation = self.eventContinuation

        source.setEventHandler {
            continuation.yield(EventPayload(
                recordId: recordId,
                fd: fd,
                originalPath: originalPath,
                originalIdentity: originalIdentity
            ))
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        let entry = WatchedEntry(
            recordId: recordId,
            path: originalPath,
            identity: originalIdentity,
            fd: fd,
            source: source
        )
        activeWatches[recordId] = entry
        source.resume()
    }

    private func dismantle(entry: WatchedEntry) {
        entry.source.cancel()
    }

    /// Active Zero-FD Self-Healing Poller executed periodically.
    private func executeActiveHealingCycle() async {
        // A. Opportunity for Hysteresis Promotion: If FD headroom recovered, promote polled items to kqueue
        if FileDescriptorGuard.hasAvailableHeadroom(reserve: FileDescriptorGuard.promotionSafeHeadroom), !fallbackQueue.isEmpty {
            let candidates = Array(fallbackQueue.values)
            for item in candidates {
                if FileDescriptorGuard.hasAvailableHeadroom(reserve: FileDescriptorGuard.criticalReservedHeadroom) {
                    fallbackQueue.removeValue(forKey: item.record.id)
                    installOrEnqueue(record: item.record)
                } else {
                    break
                }
            }
        }

        // B. Zero-FD Inode Health Inspection for remaining fallback items
        for (_, item) in fallbackQueue {
            let record = item.record
            var st = stat()
            let statResult = DatalessProtection.withMaterializationDisabled {
                record.path.withCString { stat($0, &st) }
            }

            if statResult == 0 {
                // Node exists physically: verify Inode identity
                if case let .physical(dev, ino) = record.identity.key {
                    if st.st_dev != dev || st.st_ino != ino {
                        await resolveMutationViaBookmark(record: record)
                    }
                }
            } else {
                await resolveMutationViaBookmark(record: record)
            }
        }
    }

    private func resolveMutationViaBookmark(record: PinnedFolderRecord) async {
        guard let bookmark = record.bookmarkData else {
            await onMutation?(PinnedFolderMutation(
                recordId: record.id,
                originalPath: record.path,
                originalIdentity: record.identity,
                kind: .missing
            ))
            return
        }

        var isStale = false
        if let resolvedURL = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            let resolvedPath = resolvedURL.path
            if resolvedPath.contains("/.Trash/") || resolvedPath.contains("/.Trashes/") {
                fallbackQueue.removeValue(forKey: record.id)
                await onMutation?(PinnedFolderMutation(
                    recordId: record.id,
                    originalPath: record.path,
                    originalIdentity: record.identity,
                    kind: .trashed(trashPath: resolvedPath)
                ))
                return
            }

            if resolvedPath != record.path {
                let newBookmark = try? resolvedURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                await onMutation?(PinnedFolderMutation(
                    recordId: record.id,
                    originalPath: record.path,
                    originalIdentity: record.identity,
                    kind: .renamed(newPath: resolvedPath, newBookmark: newBookmark)
                ))
            }
        }
    }

    private func handleFileSystemEvent(
        recordId: UUID,
        fd: Int32,
        originalPath: String,
        originalIdentity: FileIdentity
    ) async {
        guard let entry = activeWatches[recordId] else { return }
        let events = entry.source.data

        if events.contains(.rename) {
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let getPathResult = fcntl(fd, F_GETPATH, &pathBuffer)

            if getPathResult >= 0 {
                let currentPath = pathBuffer.withUnsafeBufferPointer { ptr in
                    String(cString: ptr.baseAddress!)
                }

                // Case A: Moved to Trash
                if currentPath.contains("/.Trash/") || currentPath.contains("/.Trashes/") {
                    dismantle(entry: entry)
                    activeWatches.removeValue(forKey: recordId)
                    await onMutation?(PinnedFolderMutation(
                        recordId: recordId,
                        originalPath: originalPath,
                        originalIdentity: originalIdentity,
                        kind: .trashed(trashPath: currentPath)
                    ))
                    return
                }

                // Case B: Renamed or moved within the same APFS container
                if currentPath != originalPath {
                    var st = stat()
                    var inodeValid = false
                    if stat(currentPath, &st) == 0 {
                        if case let .physical(dev, ino) = originalIdentity.key {
                            inodeValid = (st.st_dev == dev && st.st_ino == ino)
                        }
                    }

                    if inodeValid {
                        let newURL = URL(fileURLWithPath: currentPath)
                        let newBookmark = try? newURL.bookmarkData(
                            options: [.withSecurityScope],
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )

                        // Re-arm watcher for the new path
                        dismantle(entry: entry)
                        activeWatches.removeValue(forKey: recordId)

                        let updatedRecord = PinnedFolderRecord(
                            id: recordId,
                            path: currentPath,
                            bookmarkData: newBookmark,
                            identity: FileIdentity(url: newURL)
                        )
                        installOrEnqueue(record: updatedRecord)

                        await onMutation?(PinnedFolderMutation(
                            recordId: recordId,
                            originalPath: originalPath,
                            originalIdentity: originalIdentity,
                            kind: .renamed(newPath: currentPath, newBookmark: newBookmark)
                        ))
                        return
                    }
                }
            }
        }

        if events.contains(.delete) || events.contains(.revoke) {
            dismantle(entry: entry)
            activeWatches.removeValue(forKey: recordId)

            let isVolumeMounted = checkVolumeMounted(forPath: originalPath)
            if !isVolumeMounted {
                await onMutation?(PinnedFolderMutation(
                    recordId: recordId,
                    originalPath: originalPath,
                    originalIdentity: originalIdentity,
                    kind: .volumeOffline(volumeName: nil, volumeUUID: nil)
                ))
            } else {
                await onMutation?(PinnedFolderMutation(
                    recordId: recordId,
                    originalPath: originalPath,
                    originalIdentity: originalIdentity,
                    kind: .missing
                ))
            }
        }
    }

    private func checkVolumeMounted(forPath path: String) -> Bool {
        guard path.hasPrefix("/Volumes/") else { return true }
        let comps = path.split(separator: "/")
        guard comps.count >= 2 else { return true }
        let volPath = "/Volumes/" + String(comps[1])
        return FileManager.default.fileExists(atPath: volPath)
    }
}
