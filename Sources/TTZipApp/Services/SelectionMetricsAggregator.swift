// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

/// Background actor responsible for aggregating multi-selection metrics without blocking the UI thread.
/// Yields cooperatively every 256 items to ensure 120 FPS UI responsiveness.
public actor SelectionMetricsAggregator {
    public static let shared = SelectionMetricsAggregator()

    public init() {}

    /// Aggregates metrics from an array of file system URLs.
    public func aggregate(urls: [URL]) async -> AggregatedSelectionMetrics {
        guard !urls.isEmpty else {
            return AggregatedSelectionMetrics()
        }

        var totalByteSize: Int64 = 0
        var directoryCount = 0
        var fileCount = 0
        var largestItemName: String? = nil
        var largestItemBytes: Int64 = 0
        var mimeCounts: [String: Int] = [:]

        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey, .localizedNameKey]

        for (index, url) in urls.enumerated() {
            if Task.isCancelled { break }
            if index > 0 && index % 256 == 0 {
                await Task.yield()
            }

            let values = try? url.resourceValues(forKeys: keys)
            let isDir = values?.isDirectory ?? (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = values?.localizedName ?? url.lastPathComponent
            let size = Int64(values?.fileSize ?? 0)

            if isDir {
                directoryCount += 1
            } else {
                fileCount += 1
                totalByteSize += size
                if size > largestItemBytes {
                    largestItemBytes = size
                    largestItemName = name
                }
                let ext = url.pathExtension.lowercased()
                let kind = ext.isEmpty ? "unknown" : ext
                mimeCounts[kind, default: 0] += 1
            }
        }

        return AggregatedSelectionMetrics(
            totalItemCount: urls.count,
            totalByteSize: totalByteSize,
            directoryCount: directoryCount,
            fileCount: fileCount,
            largestItemName: largestItemName,
            largestItemBytes: largestItemBytes,
            topMimeTypes: mimeCounts
        )
    }

    /// Aggregates metrics from an array of DiskItemInfo items.
    public func aggregate(items: [DiskItemInfo]) async -> AggregatedSelectionMetrics {
        guard !items.isEmpty else {
            return AggregatedSelectionMetrics()
        }

        var totalByteSize: Int64 = 0
        var directoryCount = 0
        var fileCount = 0
        var largestItemName: String? = nil
        var largestItemBytes: Int64 = 0
        var mimeCounts: [String: Int] = [:]

        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            if index > 0 && index % 256 == 0 {
                await Task.yield()
            }

            if item.isDirectory {
                directoryCount += 1
            } else {
                fileCount += 1
                let size = item.rawSizeBytes
                totalByteSize += size
                if size > largestItemBytes {
                    largestItemBytes = size
                    largestItemName = item.displayName
                }
                let ext = (item.name as NSString).pathExtension.lowercased()
                let kind = ext.isEmpty ? (item.kindText.isEmpty ? "file" : item.kindText) : ext
                mimeCounts[kind, default: 0] += 1
            }
        }

        return AggregatedSelectionMetrics(
            totalItemCount: items.count,
            totalByteSize: totalByteSize,
            directoryCount: directoryCount,
            fileCount: fileCount,
            largestItemName: largestItemName,
            largestItemBytes: largestItemBytes,
            topMimeTypes: mimeCounts
        )
    }

    /// Aggregates metrics from an array of FileSystemEntryMetadata items.
    public func aggregate(entries: [FileSystemEntryMetadata]) async -> AggregatedSelectionMetrics {
        guard !entries.isEmpty else {
            return AggregatedSelectionMetrics()
        }

        var totalByteSize: Int64 = 0
        var directoryCount = 0
        var fileCount = 0
        var largestItemName: String? = nil
        var largestItemBytes: Int64 = 0
        var mimeCounts: [String: Int] = [:]

        for (index, entry) in entries.enumerated() {
            if Task.isCancelled { break }
            if index > 0 && index % 256 == 0 {
                await Task.yield()
            }

            if entry.isDirectory {
                directoryCount += 1
            } else {
                fileCount += 1
                let size = entry.sizeInBytes
                totalByteSize += size
                if size > largestItemBytes {
                    largestItemBytes = size
                    largestItemName = entry.name
                }
                let ext = entry.url.pathExtension.lowercased()
                let kind = ext.isEmpty ? (entry.mimeType.isEmpty ? "file" : entry.mimeType) : ext
                mimeCounts[kind, default: 0] += 1
            }
        }

        return AggregatedSelectionMetrics(
            totalItemCount: entries.count,
            totalByteSize: totalByteSize,
            directoryCount: directoryCount,
            fileCount: fileCount,
            largestItemName: largestItemName,
            largestItemBytes: largestItemBytes,
            topMimeTypes: mimeCounts
        )
    }
}

// MARK: - Convenient Placeholders

extension AggregatedSelectionMetrics {
    /// Zero-state metrics when no items are selected.
    public static let zero = AggregatedSelectionMetrics()

    /// Creates a lightweight placeholder metrics object before background calculation finishes.
    public static func placeholder(count: Int, bytes: Int64 = 0) -> AggregatedSelectionMetrics {
        AggregatedSelectionMetrics(
            totalItemCount: count,
            totalByteSize: bytes,
            directoryCount: 0,
            fileCount: count,
            largestItemName: nil,
            largestItemBytes: 0,
            topMimeTypes: [:]
        )
    }
}
