// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Darwin
import Foundation
import SwiftUI

/// Represents a macOS Finder color tag associated with a file or folder.
public struct FinderTag: Sendable, Hashable, Identifiable {
    public var id: String { "\(name)_\(colorIndex)" }
    public let name: String
    public let colorIndex: Int // 0: None, 1: Gray, 2: Green, 3: Purple, 4: Blue, 5: Yellow, 6: Red, 7: Orange

    public init(name: String, colorIndex: Int) {
        self.name = name
        self.colorIndex = colorIndex
    }

    public var systemColor: Color {
        switch colorIndex {
        case 1: return Color(nsColor: .systemGray)
        case 2: return Color(nsColor: .systemGreen)
        case 3: return Color(nsColor: .systemPurple)
        case 4: return Color(nsColor: .systemBlue)
        case 5: return Color(nsColor: .systemYellow)
        case 6: return Color(nsColor: .systemRed)
        case 7: return Color(nsColor: .systemOrange)
        default: return Color.clear
        }
    }
}

/// High-performance, non-blocking metadata and Finder tag resolver.
/// Caches resolved tags in memory (0ms access) and isolates xattr I/O to a bounded worker thread.
@MainActor
public final class SidebarMetadataCache {
    public static let shared = SidebarMetadataCache()

    private let cache = ExplorerLRUCache<String, [FinderTag]>(capacity: 256)
    private var inFlightTasks: [String: Task<[FinderTag], Never>] = [:]

    private nonisolated static let workerQueue = DispatchQueue(
        label: "com.metastudyline.ttzip.sidebar-metadata-worker",
        qos: .utility,
        attributes: .concurrent
    )
    private nonisolated static let throttleSemaphore = DispatchSemaphore(value: 2)

    private init() {}

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

    /// Immediate synchronous cache lookup (0ms RAM hit).
    public func cachedTags(forPath path: String) -> [FinderTag]? {
        cache.get(path)
    }

    /// Asynchronous non-blocking Finder tag resolution with cancellation and timeout protection.
    public func resolveTags(forPath path: String) async -> [FinderTag] {
        if let cached = cache.get(path) {
            return cached
        }

        if let inFlight = inFlightTasks[path] {
            return await inFlight.value
        }

        let task = Task<[FinderTag], Never> {
            await Self.extractTagsWithTimeout(forPath: path)
        }

        inFlightTasks[path] = task
        let tags = await task.value
        inFlightTasks.removeValue(forKey: path)
        cache.set(path, value: tags)
        return tags
    }

    private nonisolated static func extractTagsWithTimeout(forPath path: String) async -> [FinderTag] {
        guard !Task.isCancelled else { return [] }

        return await withTaskGroup(of: [FinderTag]?.self) { group in
            group.addTask {
                await Self.performTagExtraction(forPath: path)
            }

            group.addTask {
                try? await Task.sleep(for: .milliseconds(60))
                return nil
            }

            if let first = await group.next(), let resolved = first {
                group.cancelAll()
                return resolved
            }

            group.cancelAll()
            return []
        }
    }

    private nonisolated static func performTagExtraction(forPath path: String) async -> [FinderTag]? {
        guard !Task.isCancelled else { return nil }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                workerQueue.async {
                    guard !Task.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }

                    throttleSemaphore.wait()
                    defer { throttleSemaphore.signal() }

                    guard !Task.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let tags: [FinderTag] = DatalessProtection.withMaterializationDisabled {
                        // 1. Level 0 Fast-Path: If dataless, skip deep xattr reading to avoid latency
                        if DatalessProtection.isDataless(atPath: path) {
                            return []
                        }

                        // 2. Try reading xattr com.apple.metadata:_kMDItemUserTags
                        let xattrName = "com.apple.metadata:_kMDItemUserTags"
                        let size = getxattr(path, xattrName, nil, 0, 0, 0)
                        if size > 0 {
                            var data = Data(count: size)
                            let bytesRead = data.withUnsafeMutableBytes { ptr in
                                getxattr(path, xattrName, ptr.baseAddress, size, 0, 0)
                            }
                            if bytesRead > 0,
                               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] {
                                let parsedTags: [FinderTag] = plist.compactMap { entry in
                                    let parts = entry.components(separatedBy: "\n")
                                    let name = parts.first ?? ""
                                    let colorIdx = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
                                    guard colorIdx > 0 else { return nil }
                                    return FinderTag(name: name, colorIndex: colorIdx)
                                }
                                if !parsedTags.isEmpty {
                                    return parsedTags
                                }
                            }
                        }

                        // 3. Fallback to Foundation labelNumberKey safely
                        let url = URL(fileURLWithPath: path)
                        if let values = try? url.resourceValues(forKeys: [.labelNumberKey]),
                           let labelNum = values.labelNumber, labelNum > 0 {
                            return [FinderTag(name: "", colorIndex: labelNum)]
                        }

                        return []
                    }

                    continuation.resume(returning: tags)
                }
            }
        } onCancel: {
            // Cooperative cancellation
        }
    }

    public func clear() {
        inFlightTasks.removeAll()
        cache.removeAll()
    }
}
