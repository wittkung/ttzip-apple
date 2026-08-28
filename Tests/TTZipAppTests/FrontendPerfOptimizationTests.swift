// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class FrontendPerfOptimizationTests: XCTestCase {
    
    // MARK: - 1. ExplorerLRUCache
    
    func testExplorerLRUCacheBasicOperations() {
        let cache = ExplorerLRUCache<String, String>(capacity: 3)
        XCTAssertEqual(cache.capacity, 3)
        XCTAssertEqual(cache.count, 0)
        
        cache.set("a", value: "Alpha")
        cache.set("b", value: "Bravo")
        cache.set("c", value: "Charlie")
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.get("a"), "Alpha")
        XCTAssertEqual(cache.get("b"), "Bravo")
        XCTAssertEqual(cache.get("c"), "Charlie")
        
        // Access "a" to promote it to MRU. Eviction order becomes: b -> c -> a
        _ = cache.get("a")
        
        // Insert "d", capacity exceeded, least recently used "b" should be evicted
        cache.set("d", value: "Delta")
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.get("b"))
        XCTAssertEqual(cache.get("a"), "Alpha")
        XCTAssertEqual(cache.get("c"), "Charlie")
        XCTAssertEqual(cache.get("d"), "Delta")
        
        // Remove specific element
        XCTAssertEqual(cache.remove("c"), "Charlie")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.get("c"))
        
        // Purge all elements
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.get("a"))
        XCTAssertNil(cache.get("d"))
    }
    
    func testExplorerLRUCacheThreadSafety() {
        let cache = ExplorerLRUCache<Int, String>(capacity: 10)
        let queue = DispatchQueue(label: "com.metastudyline.ttzip.tests.lru.concurrent", attributes: .concurrent)
        let iterations = 1000
        let group = DispatchGroup()
        
        for i in 0..<iterations {
            group.enter()
            queue.async {
                cache.set(i % 20, value: "Val_\(i)")
                group.leave()
            }
            group.enter()
            queue.async {
                _ = cache.get(i % 20)
                group.leave()
            }
        }
        
        let result = group.wait(timeout: .now() + 3.0)
        XCTAssertEqual(result, .success, "Concurrent LRU cache read/write must complete without deadlock")
        XCTAssertLessThanOrEqual(cache.count, 10)
    }
    
    // MARK: - 2. ThrottledProgressPublisher
    
    func testThrottledProgressPublisherGating() {
        let throttler = ThrottledProgressPublisher(maxFrequencyHz: 60.0) // ~16.6ms frame interval
        
        let t0: UInt64 = 1_000_000_000
        XCTAssertTrue(throttler.shouldEmit(now: t0), "First progress event must always be emitted")
        
        // 5ms (5_000_000 ns) elapsed, under 16.6ms threshold -> must throttle
        let t1: UInt64 = t0 + 5_000_000
        XCTAssertFalse(throttler.shouldEmit(now: t1), "Event under minimum frame duration must be suppressed")
        
        // 20ms (20_000_000 ns) elapsed, exceeds 16.6ms threshold -> must emit
        let t2: UInt64 = t0 + 20_000_000
        XCTAssertTrue(throttler.shouldEmit(now: t2), "Event reaching minimum interval must be emitted")
        
        // Force emit bypasses throttling window
        let t3: UInt64 = t2 + 1_000_000
        XCTAssertFalse(throttler.shouldEmit(now: t3))
        throttler.forceEmit(now: t3)
        
        // Reset enables immediate subsequent emission
        throttler.reset()
        XCTAssertTrue(throttler.shouldEmit(now: t3), "First event following reset must be emitted immediately")
    }
    
    // MARK: - 3. ArchiveTreeStore Memoization
    
    @MainActor
    func testArchiveTreeStoreAsyncBuildAndMemoization() async {
        let store = ArchiveTreeStore()
        XCTAssertTrue(store.rootNodes.isEmpty)
        XCTAssertFalse(store.isBuildingTree)
        
        let entries: [ArchiveEntry] = [
            ArchiveEntry(path: "FolderA/", uncompressedSize: 0, isDirectory: true),
            ArchiveEntry(path: "FolderA/file1.txt", uncompressedSize: 1024, isDirectory: false),
            ArchiveEntry(path: "FolderA/file2.txt", uncompressedSize: 2048, isDirectory: false),
            ArchiveEntry(path: "rootFile.txt", uncompressedSize: 512, isDirectory: false)
        ]
        
        store.updateEntries(entries)
        
        // Wait for async hierarchical tree construction to complete
        for _ in 0..<50 {
            if !store.rootNodes.isEmpty && !store.isBuildingTree {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        
        XCTAssertFalse(store.rootNodes.isEmpty)
        XCTAssertEqual(store.rootNodes.count, 2) // FolderA, rootFile.txt
        
        // Verify memoization: unchanged entries should retain root instance
        let currentRoot = store.rootNodes
        store.updateEntries(entries)
        XCTAssertEqual(store.rootNodes, currentRoot)
        
        // Clear tree state
        store.clear()
        XCTAssertTrue(store.rootNodes.isEmpty)
        XCTAssertTrue(store.filteredEntries.isEmpty)
    }
    
    // MARK: - 4. ArchiveTreeStore Search Filter
    
    @MainActor
    func testArchiveTreeStoreSearchFilter() async {
        let store = ArchiveTreeStore()
        let entries: [ArchiveEntry] = [
            ArchiveEntry(path: "docs/Document.pdf", uncompressedSize: 1024, isDirectory: false),
            ArchiveEntry(path: "images/Photo.png", uncompressedSize: 2048, isDirectory: false),
            ArchiveEntry(path: "src/Source.swift", uncompressedSize: 512, isDirectory: false)
        ]
        
        store.updateEntries(entries)
        
        // Query "swift" with 10ms debounce
        store.filter(query: "swift", debounceMs: 10)
        
        for _ in 0..<30 {
            if !store.isFiltering && store.filteredEntries.count == 1 {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        
        XCTAssertEqual(store.filteredEntries.count, 1)
        XCTAssertEqual(store.filteredEntries.first?.name, "Source.swift")
        
        // Clear filter query
        store.filter(query: "", debounceMs: 0)
        XCTAssertEqual(store.filteredEntries.count, 3)
    }
    
    // MARK: - 5. AppViewState High Frequency Progress Throttling
    
    @MainActor
    func testAppViewStateHighFrequencyProgress() async {
        let appState = AppViewState(fileViewer: NoOpFileViewer())
        let throttler = ThrottledProgressPublisher(maxFrequencyHz: 60.0) // 16.6ms intervals
        
        var updateCount = 0
        let total = 2000
        let baseTime: UInt64 = 1_000_000_000
        
        for i in 1...total {
            let progress = Double(i) / Double(total)
            // Simulate events occurring every 100 microseconds (0.1ms) -> 200ms total simulated span
            let simulatedTime = baseTime + UInt64(i * 100_000)
            let isTerminal = (i == total)
            
            if isTerminal || throttler.shouldEmit(now: simulatedTime) {
                appState.progressValue = progress
                updateCount += 1
            }
        }
        
        // Over 200ms total simulated span at 60Hz (16.6ms frame time), expect ~13-15 updates instead of 2000
        XCTAssertLessThan(updateCount, 25, "Throttler must cap 2000 high-frequency notifications to <= 25 observer updates")
        XCTAssertGreaterThanOrEqual(updateCount, 10, "Throttler must allow periodic updates across time")
        XCTAssertEqual(appState.progressValue, 1.0, "Terminal progress frame must be applied")
    }
}
