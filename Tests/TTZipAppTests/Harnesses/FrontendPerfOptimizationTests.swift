// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
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
    
    // MARK: - 3. AppViewState High Frequency Progress Throttling
    
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

    // MARK: - 6. Lock-free ProgressAtomicSheet & SampledProgressStream Polling

    func testProgressAtomicSheet128ByteAlignmentAndLockFreeOperations() {
        let sheet = ProgressAtomicSheet(totalBytes: 50_000)
        let ptrAddress = UInt(bitPattern: sheet.rawPointer)
        XCTAssertEqual(ptrAddress % 128, 0, "ProgressAtomicSheet storage must be strictly 128-byte aligned to Apple Silicon cache lines")

        sheet.updateProgress(processed: 10_000, instantBps: 2_500_000, itemName: "test_entry.bin")
        var snap = sheet.readSnapshot()
        XCTAssertEqual(snap.processedBytes, 10_000)
        XCTAssertEqual(snap.totalBytes, 50_000)
        XCTAssertEqual(snap.instantBps, 2_500_000)
        XCTAssertEqual(snap.currentItemName, "test_entry.bin")
        XCTAssertEqual(snap.fraction, 0.2, accuracy: 0.001)
        XCTAssertFalse(snap.isFinished)
        XCTAssertFalse(snap.isCancelled)

        sheet.addProcessed(delta: 15_000)
        snap = sheet.readSnapshot()
        XCTAssertEqual(snap.processedBytes, 25_000)
        XCTAssertEqual(snap.fraction, 0.5, accuracy: 0.001)

        sheet.markFinished()
        snap = sheet.readSnapshot()
        XCTAssertTrue(snap.isFinished)
        XCTAssertTrue(snap.isTerminal)

        sheet.reset()
        snap = sheet.readSnapshot()
        XCTAssertEqual(snap.processedBytes, 0)
        XCTAssertEqual(snap.totalBytes, 0)
        XCTAssertFalse(snap.isFinished)
    }

    func testSampledProgressStreamTimerPolling() async throws {
        let sheet = ProgressAtomicSheet(totalBytes: 10_000)
        let stream = SampledProgressStream.makeStream(sheet: sheet, frequency: .custom(100.0)) // 10ms sampling

        var receivedSnapshots: [ProgressSnapshot] = []

        let consumerTask = Task {
            for await snap in stream {
                receivedSnapshots.append(snap)
                if snap.isTerminal {
                    break
                }
            }
        }

        // Simulate worker thread pushing atomic telemetry
        try await Task.sleep(nanoseconds: 15_000_000)
        sheet.updateProgress(processed: 3_000, instantBps: 1_000_000)

        try await Task.sleep(nanoseconds: 15_000_000)
        sheet.updateProgress(processed: 7_000, instantBps: 1_200_000)

        try await Task.sleep(nanoseconds: 15_000_000)
        sheet.markFinished()

        await consumerTask.value

        XCTAssertGreaterThanOrEqual(receivedSnapshots.count, 2, "Stream should receive initial and updated/terminal snapshots")
        let finalSnap = receivedSnapshots.last
        XCTAssertEqual(finalSnap?.isFinished, true)
    }

    func testThrottledProgressPublisherMainActorCoalescing() async throws {
        let throttler = ThrottledProgressPublisher(maxFrequencyHz: 60.0)
        var receivedValues: [Double] = []

        for i in 1...100 {
            throttler.coalesceOnMain(value: Double(i) / 100.0) { val in
                receivedValues.append(val)
            }
        }

        // Allow MainActor to process coalesced updates
        try await Task.sleep(nanoseconds: 30_000_000)

        // Multiple rapid dispatches should be coalesced down
        XCTAssertLessThan(receivedValues.count, 50, "Coalescing must reduce 100 rapid dispatches to fewer RunLoop invocations")
        XCTAssertFalse(receivedValues.isEmpty, "At least one coalesced update must reach MainActor")
    }
}
