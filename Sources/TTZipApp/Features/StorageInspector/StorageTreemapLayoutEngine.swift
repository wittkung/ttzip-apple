// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreGraphics
import TTZipCore
import TTZipUI

// MARK: - Bruls Squarified Treemap Layout Engine (Isomorphic with app-core/src/workspace/treemap.rs)

/// Pure layout computer implementing the Bruls, Huizing, and van Wijk (2000) Squarified Treemap
/// algorithm with exact byte conservation, deterministic equal-byte tie breaking, and viewport tail merging.
public enum StorageTreemapLayoutEngine {
    /// Maximum number of individual tiles promoted before folding the tail into `Others`.
    public static let maxPromotedTiles: Int = 255
    /// Minimum relative byte fraction (0.1%) required for an entry to avoid tail merging.
    public static let minContainerRatio: Double = 0.001
    /// Synthetic node identifier reserved for the `Others` aggregate tile.
    public static let othersNodeId: UInt32 = 0xFFFF_FFFF

    private struct PromotedItem {
        let nodeId: UInt32
        let name: String
        let path: String
        let bytes: UInt64
        let category: TileCategory
        let flags: TileFlags
    }

    private struct RowLayoutState {
        var indices: [Int] = []
        var areas: [Double] = []
        var sum: Double = 0.0
        var minArea: Double = .greatestFiniteMagnitude
        var maxArea: Double = 0.0

        mutating func reset() {
            indices.removeAll(keepingCapacity: true)
            areas.removeAll(keepingCapacity: true)
            sum = 0.0
            minArea = .greatestFiniteMagnitude
            maxArea = 0.0
        }

        mutating func append(index: Int, area: Double) {
            indices.append(index)
            areas.append(area)
            sum += area
            minArea = min(minArea, area)
            maxArea = max(maxArea, area)
        }
    }

    /// Computes normalized `[0..1] × [0..1]` squarified treemap tiles for directory scan entries.
    public static func computeSquarifiedLayout(
        entries: [(name: String, path: String, bytes: UInt64, category: TileCategory, isReclaim: Bool, isDir: Bool)],
        totalBytes: UInt64
    ) -> [TreemapTile] {
        guard !entries.isEmpty else { return [] }

        let (promoted, itemAreas) = filterAndPromoteEntries(entries: entries, totalBytes: totalBytes)
        guard !promoted.isEmpty else { return [] }

        return partitionSquarifiedRows(promoted: promoted, itemAreas: itemAreas)
    }

    private static func filterAndPromoteEntries(
        entries: [(name: String, path: String, bytes: UInt64, category: TileCategory, isReclaim: Bool, isDir: Bool)],
        totalBytes: UInt64
    ) -> ([PromotedItem], [Double]) {
        let indexed = entries.enumerated().map { (idx, entry) in
            (nodeId: UInt32(idx), entry: entry)
        }

        let nonZero = indexed.filter { $0.entry.bytes > 0 }
        let working = nonZero.isEmpty ? indexed : nonZero

        let sorted = working.sorted { lhs, rhs in
            if lhs.entry.bytes != rhs.entry.bytes {
                return lhs.entry.bytes > rhs.entry.bytes
            }
            return lhs.nodeId < rhs.nodeId
        }

        let sumBytes = sorted.reduce(0 as UInt64) { $0 &+ $1.entry.bytes }
        let effectiveTotal = totalBytes > 0 ? totalBytes : sumBytes

        var promoted: [PromotedItem] = []
        var tailBytes: UInt64 = 0
        var tailCount = 0

        if effectiveTotal == 0 {
            for item in sorted.prefix(maxPromotedTiles) {
                promoted.append(makePromotedItem(from: item.entry, nodeId: item.nodeId))
            }
        } else {
            let wTotal = Double(effectiveTotal)
            for item in sorted {
                let ratio = Double(item.entry.bytes) / wTotal
                if ratio >= minContainerRatio && promoted.count < maxPromotedTiles {
                    promoted.append(makePromotedItem(from: item.entry, nodeId: item.nodeId))
                } else {
                    tailBytes &+= item.entry.bytes
                    tailCount += 1
                }
            }
        }

        if tailCount > 0 && tailBytes > 0 {
            promoted.append(PromotedItem(
                nodeId: othersNodeId,
                name: StorageLocaleKey.othersTileTitle.resolve(),
                path: "",
                bytes: tailBytes,
                category: .others,
                flags: [.tailCollapsed, .isLeaf]
            ))
        }

        let n = promoted.count
        guard n > 0 else { return ([], []) }

        let promotedByteSum = promoted.reduce(0 as UInt64) { $0 &+ $1.bytes }
        var itemAreas: [Double] = []
        itemAreas.reserveCapacity(n)

        if promotedByteSum == 0 {
            let uniform = 1.0 / Double(n)
            itemAreas = Array(repeating: uniform, count: n)
        } else {
            let wTotal = Double(promotedByteSum)
            for item in promoted {
                itemAreas.append(max(0.0, Double(item.bytes) / wTotal))
            }
        }

        return (promoted, itemAreas)
    }

    private static func makePromotedItem(
        from entry: (name: String, path: String, bytes: UInt64, category: TileCategory, isReclaim: Bool, isDir: Bool),
        nodeId: UInt32
    ) -> PromotedItem {
        var flags: TileFlags = entry.isDir ? [.isDir] : [.isLeaf]
        if entry.isReclaim {
            flags.insert(.reclaimable)
        }
        return PromotedItem(
            nodeId: nodeId,
            name: entry.name,
            path: entry.path,
            bytes: entry.bytes,
            category: entry.category,
            flags: flags
        )
    }

    private static func partitionSquarifiedRows(
        promoted: [PromotedItem],
        itemAreas: [Double]
    ) -> [TreemapTile] {
        var rect = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        var outTiles: [TreemapTile] = []
        outTiles.reserveCapacity(promoted.count)

        var row = RowLayoutState()
        var index = 0
        let count = promoted.count

        while index < count {
            let area = itemAreas[index]
            let shortSide = max(0.000001, Double(min(rect.width, rect.height)))

            if row.indices.isEmpty {
                row.append(index: index, area: area)
                index += 1
                continue
            }

            let curWorst = worstAspectRatio(
                sum: row.sum,
                minA: row.minArea,
                maxA: row.maxArea,
                count: row.indices.count,
                side: shortSide
            )
            let candWorst = worstAspectRatio(
                sum: row.sum + area,
                minA: min(row.minArea, area),
                maxA: max(row.maxArea, area),
                count: row.indices.count + 1,
                side: shortSide
            )

            if candWorst <= curWorst {
                row.append(index: index, area: area)
                index += 1
            } else {
                flushRow(row: &row, promoted: promoted, rect: &rect, isLast: false, outTiles: &outTiles)
            }
        }

        if !row.indices.isEmpty {
            flushRow(row: &row, promoted: promoted, rect: &rect, isLast: true, outTiles: &outTiles)
        }

        return outTiles
    }

    private static func worstAspectRatio(
        sum: Double,
        minA: Double,
        maxA: Double,
        count: Int,
        side: Double
    ) -> Double {
        if count == 0 || side <= 0.0 || sum <= 0.0 || minA <= 0.0 {
            return .greatestFiniteMagnitude
        }
        let s2 = side * side
        let sum2 = sum * sum
        return max((s2 * maxA) / sum2, sum2 / (s2 * minA))
    }

    private static func flushRow(
        row: inout RowLayoutState,
        promoted: [PromotedItem],
        rect: inout CGRect,
        isLast: Bool,
        outTiles: inout [TreemapTile]
    ) {
        guard !row.indices.isEmpty else { return }
        if rect.width >= rect.height {
            layoutVerticalStrip(row: row, promoted: promoted, rect: &rect, isLast: isLast, outTiles: &outTiles)
        } else {
            layoutHorizontalStrip(row: row, promoted: promoted, rect: &rect, isLast: isLast, outTiles: &outTiles)
        }
        row.reset()
    }

    private static func layoutVerticalStrip(
        row: RowLayoutState,
        promoted: [PromotedItem],
        rect: inout CGRect,
        isLast: Bool,
        outTiles: inout [TreemapTile]
    ) {
        let rectH = Double(rect.height)
        let rectW = Double(rect.width)
        let rowW = isLast ? rectW : min(rectW, row.sum / max(0.000001, rectH))
        var curY = Double(rect.minY)
        let maxY = Double(rect.maxY)
        let n = row.indices.count

        for (k, idx) in row.indices.enumerated() {
            let area = row.areas[k]
            let itemH: Double
            if k == n - 1 {
                itemH = max(0.0, maxY - curY)
            } else if row.sum > 0.0 {
                itemH = min(maxY - curY, (area / row.sum) * rectH)
            } else {
                itemH = rectH / Double(n)
            }
            let node = promoted[idx]
            outTiles.append(TreemapTile(
                id: node.nodeId,
                x: rect.minX,
                y: CGFloat(curY),
                width: CGFloat(max(0.0, rowW)),
                height: CGFloat(max(0.0, itemH)),
                nodeId: node.nodeId,
                depth: 1,
                category: node.category,
                flags: node.flags,
                bytes: node.bytes,
                name: node.name,
                relativePath: node.path
            ))
            curY += itemH
        }

        let newX = Double(rect.minX) + rowW
        let newW = max(0.0, rectW - rowW)
        rect = CGRect(x: newX, y: Double(rect.minY), width: newW, height: rectH)
    }

    private static func layoutHorizontalStrip(
        row: RowLayoutState,
        promoted: [PromotedItem],
        rect: inout CGRect,
        isLast: Bool,
        outTiles: inout [TreemapTile]
    ) {
        let rectW = Double(rect.width)
        let rectH = Double(rect.height)
        let rowH = isLast ? rectH : min(rectH, row.sum / max(0.000001, rectW))
        var curX = Double(rect.minX)
        let maxX = Double(rect.maxX)
        let n = row.indices.count

        for (k, idx) in row.indices.enumerated() {
            let area = row.areas[k]
            let itemW: Double
            if k == n - 1 {
                itemW = max(0.0, maxX - curX)
            } else if row.sum > 0.0 {
                itemW = min(maxX - curX, (area / row.sum) * rectW)
            } else {
                itemW = rectW / Double(n)
            }
            let node = promoted[idx]
            outTiles.append(TreemapTile(
                id: node.nodeId,
                x: CGFloat(curX),
                y: rect.minY,
                width: CGFloat(max(0.0, itemW)),
                height: CGFloat(max(0.0, rowH)),
                nodeId: node.nodeId,
                depth: 1,
                category: node.category,
                flags: node.flags,
                bytes: node.bytes,
                name: node.name,
                relativePath: node.path
            ))
            curX += itemW
        }

        let newY = Double(rect.minY) + rowH
        let newH = max(0.0, rectH - rowH)
        rect = CGRect(x: Double(rect.minX), y: newY, width: rectW, height: newH)
    }
}
