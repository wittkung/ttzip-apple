// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import UniformTypeIdentifiers

/// High-throughput, fault-tolerant sidebar icon resolution engine.
/// Protects Swift Concurrency cooperative thread pool from blocking I/O starvation
/// via a dedicated bounded dispatch queue and strict race-timeout fuses.
@MainActor
public final class SidebarIconCache {
    /// Shared singleton instance.
    public static let shared = SidebarIconCache()

    private let cache = ExplorerLRUCache<String, NSImage>(capacity: 256)
    private var inFlightTasks: [String: Task<NSImage, Never>] = [:]

    /// Default system generic folder icon cached in memory (0ms access).
    private let defaultFolderIcon: NSImage

    /// Dedicated bounded worker queue isolated from Swift Concurrency thread pool.
    private nonisolated static let workerQueue = DispatchQueue(
        label: "com.metastudyline.ttzip.sidebar-icon-worker",
        qos: .userInitiated,
        attributes: .concurrent
    )
    /// Max concurrent disk/network I/O tasks to prevent thread explosion.
    private nonisolated static let ioThrottleSemaphore = DispatchSemaphore(value: 2)

    private init() {
        let folder = NSWorkspace.shared.icon(for: .folder)
        folder.size = NSSize(width: 16, height: 16)
        self.defaultFolderIcon = folder
    }

    /// Emergency purge invoked during Critical memory pressure.
    public func emergencyPurge(targetCapacity: Int = 16) {
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
        cache.removeAll()
        cache.resizeCapacity(to: targetCapacity)
    }

    /// Throttles capacity during Warning memory pressure.
    public func throttleCapacity(targetCapacity: Int = 64) {
        cache.resizeCapacity(to: targetCapacity)
    }

    /// Adjusts capacity during warm-up.
    public func setCapacity(_ newCapacity: Int) {
        cache.resizeCapacity(to: newCapacity)
    }

    /// Immediate synchronous memory-cache check.
    /// Returns non-nil immediately if already decoded in RAM, avoiding asynchronous hops.
    public func cachedIcon(forPath path: String) -> NSImage? {
        cache.get(path)
    }

    /// Asynchronous non-blocking icon resolution with strict timeout fuse.
    /// Fast-path returns from LRU in 0ms without thread suspension.
    /// Off-pool background extraction protects Swift Concurrency worker threads from SMB/spin-down hangs.
    public func resolveIcon(forPath path: String) async -> NSImage {
        if let cached = cache.get(path) {
            return cached
        }

        if let inFlight = inFlightTasks[path] {
            return await inFlight.value
        }

        let fallback = defaultFolderIcon

        let task = Task<NSImage, Never> { [fallback] in
            let resolved = await Self.extractIconWithTimeout(
                forPath: path,
                fallback: fallback,
                timeoutMs: Self.determineTimeoutMs(forPath: path)
            )
            return resolved
        }

        inFlightTasks[path] = task
        let resolved = await task.value
        inFlightTasks.removeValue(forKey: path)
        cache.set(path, value: resolved)
        return resolved
    }

    /// Determines timeout window based on storage medium (network vs local).
    private nonisolated static func determineTimeoutMs(forPath path: String) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           let isLocal = values.volumeIsLocal, !isLocal {
            return 60 // Tighter timeout for remote SMB/NFS mounts
        }
        return 150 // Standard local filesystem timeout
    }

    /// Executes the extraction race between the dedicated background worker and a timeout timer.
    private nonisolated static func extractIconWithTimeout(
        forPath path: String,
        fallback: NSImage,
        timeoutMs: UInt64
    ) async -> NSImage {
        await withTaskGroup(of: NSImage?.self) { group in
            group.addTask {
                await Self.performIsolatedExtraction(forPath: path, timeoutMs: timeoutMs)
            }

            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                return nil
            }

            if let first = await group.next(), let resolvedImage = first {
                group.cancelAll()
                return resolvedImage
            }

            group.cancelAll()
            return fallback
        }
    }

    /// Performs synchronous AppKit extraction strictly off the cooperative thread pool with cancellation guards.
    private nonisolated static func performIsolatedExtraction(forPath path: String, timeoutMs: UInt64) async -> NSImage? {
        guard !Task.isCancelled else { return nil }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                workerQueue.async {
                    guard !Task.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let waitResult = ioThrottleSemaphore.wait(timeout: .now() + .milliseconds(Int(timeoutMs)))
                    guard waitResult == .success else {
                        continuation.resume(returning: nil)
                        return
                    }
                    defer { ioThrottleSemaphore.signal() }

                    guard !Task.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }

                    // 1. Level 0 Fast-Path: If dataless, resolve icon purely in-memory via UTType without disk I/O
                    if DatalessProtection.isDataless(atPath: path) {
                        let ext = URL(fileURLWithPath: path).pathExtension
                        if !ext.isEmpty, let uti = UTType(filenameExtension: ext) {
                            let icon = NSWorkspace.shared.icon(for: uti)
                            icon.size = NSSize(width: 16, height: 16)
                            continuation.resume(returning: icon)
                            return
                        }
                    }

                    // 2. Level 1 Hardened AppKit Extraction strictly guarded against cloud materialization
                    let image = DatalessProtection.withMaterializationDisabled { () -> NSImage in
                        let fm = FileManager.default
                        if fm.fileExists(atPath: path) {
                            return NSWorkspace.shared.icon(forFile: path)
                        } else {
                            return NSWorkspace.shared.icon(for: .folder)
                        }
                    }
                    let rasterized = rasterizeToStandardSize(image)
                    continuation.resume(returning: rasterized)
                }
            }
        } onCancel: {
            // Task cancellation handled cooperatively via Task.isCancelled guards
        }
    }

    nonisolated private static func rasterizeToStandardSize(_ source: NSImage) -> NSImage {
        let targetSize = NSSize(width: 16, height: 16)
        let pixelSize = NSSize(width: 32, height: 32)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width),
            pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            source.size = targetSize
            return source
        }
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        context?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let rasterized = NSImage(size: targetSize)
        rasterized.addRepresentation(rep)
        return rasterized
    }

    /// Pre-warms the icon cache for a batch of file paths asynchronously.
    public func prewarm(paths: [String]) {
        for path in paths {
            Task {
                _ = await resolveIcon(forPath: path)
            }
        }
    }

    /// Clears the cached icons.
    public func clear() {
        inFlightTasks.removeAll()
        cache.removeAll()
    }
}
