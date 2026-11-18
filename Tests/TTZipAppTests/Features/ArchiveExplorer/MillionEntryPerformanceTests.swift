// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import AppKit
import Darwin
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class MillionEntryPerformanceTests: XCTestCase {

    /// Reads real physical resident memory (RSS) of the current process via Darwin Mach kernel API.
    private func getProcessMemoryRSS() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }

    /// Verifies that scrolling across a 1,000,000 entry archive with a 128-row AppKit sliding window
    /// strictly bounds memory retention (<= 256 cached items) and limits UI RSS growth to <= 25MB.
    func testMillionEntrySlidingWindowMemoryGrowth() async throws {
        let totalCount = 1_000_000

        // High-throughput synthetic slice provider simulating microsecond microkernel CSR responses
        let sliceProvider: NativeArchiveTableViewAdapter.PagedSliceProvider = { offset, limit, key, dir in
            let end = min(UInt32(totalCount), offset + limit)
            let nodes: [VfsPagedNode] = (offset..<end).map { i in
                let itemName = "item_\(i).dat"
                return VfsPagedNode(
                    nodeId: i,
                    name: itemName,
                    path: itemName,
                    isDir: i % 20 == 0,
                    isSymlink: false,
                    isEncrypted: false,
                    size: UInt64(i * 1024),
                    compressedSize: UInt64(i * 512),
                    mtimeSecs: 1700000000 + Int64(i)
                )
            }
            return VfsPageResult(totalCount: UInt32(totalCount), offset: offset, nodes: nodes)
        }

        let baseRss = getProcessMemoryRSS()

        let adapter = NativeArchiveTableViewAdapter(
            totalRowCount: totalCount,
            sortKey: .name,
            sortDirection: .ascending,
            sliceProvider: sliceProvider
        )

        XCTAssertEqual(adapter.totalRowCount, 1_000_000, "Adapter must report exactly 1,000,000 rows")
        XCTAssertLessThanOrEqual(adapter.cachedEntryCount, 128, "Initial prime window must hold <= 128 items")

        // Simulate jumping through 10,000 rows across sparse indices to exercise eviction
        let sampleCheckpoints = [
            0, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000,
            50_000, 100_000, 250_000, 500_000, 750_000, 900_000, 999_900, 999_999
        ]

        for targetRow in sampleCheckpoints {
            let visibleStart = max(0, targetRow - 25)
            let visibleEnd = min(totalCount, targetRow + 25)
            adapter.ensureWindowAvailable(visibleRange: visibleStart..<visibleEnd, bufferSize: 128)

            // Allow cooperative async prefetch task to fulfill and evict
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms per jump

            // Verify cache eviction invariant: cache never exceeds maxCacheCapacity (256)
            XCTAssertLessThanOrEqual(
                adapter.cachedEntryCount,
                256,
                "Cache size (\(adapter.cachedEntryCount)) exceeded 256-item sliding window limit at row \(targetRow)"
            )
        }

        let endRss = getProcessMemoryRSS()
        let growthBytes = endRss > baseRss ? (endRss - baseRss) : 0
        let growthMB = Double(growthBytes) / (1024.0 * 1024.0)

        // Strict TASK-105 & ADR-022 Performance Gate: RSS growth <= 25.0 MB
        XCTAssertLessThanOrEqual(
            growthMB,
            25.0,
            "1,000,000 entry scrolling RSS growth (\(growthMB) MB) exceeded the 25 MB hard ceiling"
        )
    }

    /// Verifies that dynamic Permutation Vector sorting switch on a 1,000,000 entry viewport
    /// executes within 20ms and invalidates the sliding window without unbounding memory.
    func testMillionEntryDynamicSortingLatency() async throws {
        let totalCount = 1_000_000
        let sliceProvider: NativeArchiveTableViewAdapter.PagedSliceProvider = { offset, limit, _, _ in
            let end = min(UInt32(totalCount), offset + limit)
            let nodes: [VfsPagedNode] = (offset..<end).map { i in
                let entryName = "entry_\(i).bin"
                return VfsPagedNode(
                    nodeId: i,
                    name: entryName,
                    path: entryName,
                    isDir: false,
                    isSymlink: false,
                    isEncrypted: false,
                    size: UInt64(i * 4096),
                    compressedSize: UInt64(i * 2048),
                    mtimeSecs: 1700000000
                )
            }
            return VfsPageResult(totalCount: UInt32(totalCount), offset: offset, nodes: nodes)
        }

        let adapter = NativeArchiveTableViewAdapter(
            totalRowCount: totalCount,
            sortKey: .name,
            sortDirection: .ascending,
            sliceProvider: sliceProvider
        )

        let clock = ContinuousClock()
        let sortDuration = clock.measure {
            adapter.setSortCriteria(key: .size, direction: .descending)
        }

        let durationMs = Double(sortDuration.components.seconds) * 1000.0 + (Double(sortDuration.components.attoseconds) / 1e15)

        XCTAssertLessThanOrEqual(
            durationMs,
            20.0,
            "1,000,000 entry dynamic sorting switch (\(durationMs) ms) exceeded 20ms threshold"
        )
        XCTAssertLessThanOrEqual(
            adapter.cachedEntryCount,
            256,
            "Cache after sorting must remain bounded within sliding window"
        )
    }
}
