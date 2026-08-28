// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class FrontendPerformanceGateTests: XCTestCase {

    // MARK: - 1. 50,000 Nodes Deep VFS Tree Scroll & Render Pressure Gate (FPS >= 58)

    func testDeepVFSTreeScrollAndRenderPressureGate() async {
        let nodeCount = 50_000
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(nodeCount)

        // 1. Generate realistic 10-level deep VFS hierarchy
        for i in 0..<nodeCount {
            let depth = (i % 10) + 1
            var components: [String] = []
            for d in 1...depth {
                components.append("Level_\(d)_\(i % (10 * d))")
            }
            let isDir = (i % 25 == 0)
            let path = isDir
                ? components.joined(separator: "/") + "/"
                : components.joined(separator: "/") + "/item_\(i).dat"

            let entry = ArchiveEntry(
                path: path,
                uncompressedSize: isDir ? 0 : Int64((i % 2048) * 1024),
                isDirectory: isDir,
                detectedEncoding: "UTF-8"
            )
            entries.append(entry)
        }

        // 2. Build Hierarchical Tree
        let treeClock = ContinuousClock()
        var rootNodes: [ArchiveTreeNode] = []
        let treeBuildDuration = treeClock.measure {
            rootNodes = ArchiveTreeBuilder.buildTree(from: entries)
        }
        let treeBuildMs = Double(treeBuildDuration.components.seconds) * 1000.0 + (Double(treeBuildDuration.components.attoseconds) / 1e15)
        XCTAssertFalse(rootNodes.isEmpty)
        XCTAssertLessThanOrEqual(treeBuildMs, 600.0, "50k nodes tree build duration (\(treeBuildMs)ms) exceeded 600ms hard floor")

        // 3. Virtualized List Viewport Scrolling Simulation across 1,000 frames
        // Viewport displays 50 visible rows; we scroll through 1,000 consecutive offset windows
        let frameCount = 1_000
        let visibleRowsCount = 50
        var frameDurations: [Double] = []
        frameDurations.reserveCapacity(frameCount)

        let scrollClock = ContinuousClock()
        let totalScrollDuration = scrollClock.measure {
            for frame in 0..<frameCount {
                let startIndex = (frame * 49) % max(1, nodeCount - visibleRowsCount)
                let frameStart = DispatchTime.now().uptimeNanoseconds

                // Simulate SwiftUI / AppKit row cell lifecycle: extraction, string formatting, depth calculation
                var renderedCellsCount = 0
                for rowIdx in startIndex..<(startIndex + visibleRowsCount) {
                    let item = entries[rowIdx]
                    let displayName = item.name
                    let isFolder = item.isDirectory
                    let sizeStr = isFolder ? "--" : "\(item.uncompressedSize / 1024) KB"
                    let depthLevel = item.path.split(separator: "/").count
                    if !displayName.isEmpty && depthLevel > 0 && !sizeStr.isEmpty {
                        renderedCellsCount += 1
                    }
                }
                XCTAssertEqual(renderedCellsCount, visibleRowsCount)

                let frameEnd = DispatchTime.now().uptimeNanoseconds
                let frameDurationMs = Double(frameEnd - frameStart) / 1_000_000.0
                frameDurations.append(frameDurationMs)
            }
        }

        let totalScrollSeconds = Double(totalScrollDuration.components.seconds) + (Double(totalScrollDuration.components.attoseconds) / 1e18)
        let effectiveFps = Double(frameCount) / max(0.001, totalScrollSeconds)
        let avgFrameMs = (totalScrollSeconds / Double(frameCount)) * 1000.0

        let sortedDurations = frameDurations.sorted()
        let p95FrameMs = sortedDurations[Int(Double(frameCount) * 0.95)]
        let p99FrameMs = sortedDurations[Int(Double(frameCount) * 0.99)]

        print("📊 [50,000 Nodes VFS Scroll Telemetry]")
        print(String(format: "  - Effective FPS:        %6.1f FPS (Gate Floor: >= 58.0 FPS)", effectiveFps))
        print(String(format: "  - Average Frame Time:   %6.3f ms  (Target: <= 17.24 ms)", avgFrameMs))
        print(String(format: "  - p95 Frame Time:       %6.3f ms", p95FrameMs))
        print(String(format: "  - p99 Frame Time:       %6.3f ms  (Gate Floor: <= 33.33 ms)", p99FrameMs))

        // Strict Gate Assertions: FPS >= 58.0 and p99 <= 33.33ms (30fps floor)
        XCTAssertGreaterThanOrEqual(
            effectiveFps,
            58.0,
            "50k VFS tree scroll FPS (\(effectiveFps)) fell below 58.0 FPS hard performance gate floor"
        )
        XCTAssertLessThanOrEqual(
            avgFrameMs,
            17.24,
            "Average frame render time (\(avgFrameMs)ms) exceeded 17.24ms (60Hz frame window)"
        )
        XCTAssertLessThanOrEqual(
            p99FrameMs,
            33.33,
            "99th percentile frame render time (\(p99FrameMs)ms) exceeded 33.33ms threshold"
        )
    }

    // MARK: - 2. ViewModel WeakReference Memory Leak Automated Detection Suite

    @MainActor
    func testViewModelWeakReferenceLifecycleMemoryLeakGate() {
        // 1. AppViewState Leak Detection
        assertNoMemoryLeak(name: "AppViewState") {
            AppViewState(fileViewer: NoOpFileViewer())
        } afterOperations: { appState in
            appState.progressValue = 0.75
            appState.statusMessage = "Extracting..."
            appState.activeTab = .compressWorkspace
            appState.searchQuery = "test"
            appState.searchQuery = ""
        }


        // 2. BenchmarkViewModel Leak Detection
        assertNoMemoryLeak(name: "BenchmarkViewModel") {
            BenchmarkViewModel()
        } afterOperations: { benchVM in
            benchVM.selectedSize = .medium
            benchVM.selectedProfile = .mixedOffice
            benchVM.isRunning = false
        }

        // 3. PasswordVaultViewModel Leak Detection
        assertNoMemoryLeak(name: "PasswordVaultViewModel") {
            PasswordVaultViewModel(manager: .shared)
        } afterOperations: { vaultVM in
            vaultVM.newMasterPasswordInput = "SecurePass123!"
            vaultVM.unlockErrorMessage = ""
            vaultVM.newMasterPasswordInput = ""
        }

        // 4. ArchiveTreeStore Leak Detection
        assertNoMemoryLeak(name: "ArchiveTreeStore") {
            ArchiveTreeStore()
        } afterOperations: { store in
            let sampleEntries = [
                ArchiveEntry(path: "Folder/file1.txt", uncompressedSize: 1024, isDirectory: false),
                ArchiveEntry(path: "Folder/file2.txt", uncompressedSize: 2048, isDirectory: false)
            ]
            store.updateEntries(sampleEntries)
            store.filter(query: "file", debounceMs: 0)
            store.clear()
        }

        // 5. OperationsQueueViewModel Leak Detection
        assertNoMemoryLeak(name: "OperationsQueueViewModel") {
            OperationsQueueViewModel()
        } afterOperations: { queueVM in
            queueVM.clearFinishedTasks()
        }

        // 6. PresetWorkspaceViewModel Leak Detection
        assertNoMemoryLeak(name: "PresetWorkspaceViewModel") {
            PresetWorkspaceViewModel(manager: .shared)
        } afterOperations: { presetVM in
            presetVM.editorName = "Custom Preset"
            presetVM.statusMessage = "Ready"
        }
    }

    /// Generic leak detector asserting that weak reference to created instance drops to nil after teardown.
    @MainActor
    private func assertNoMemoryLeak<T: AnyObject>(
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        create: () -> T,
        afterOperations: (T) -> Void
    ) {
        weak var weakInstance: T?

        autoreleasepool {
            let instance = create()
            weakInstance = instance
            afterOperations(instance)
            XCTAssertNotNil(weakInstance, "\(name) instance must be retained during active scope", file: file, line: line)
        }

        XCTAssertNil(
            weakInstance,
            "CRITICAL MEMORY LEAK: \(name) was retained after teardown. Potential circular reference or uncancelled task.",
            file: file,
            line: line
        )
    }

    // MARK: - 3. Tree Construction Latency Hard Floor Gate

    func testTreeBuildHardPerformanceFloor() async {
        let runner = FrontendBenchmarkRunner.shared

        let metrics = await runner.runTreeBuildBenchmark(entryCounts: [1000, 10000, 50000])
        XCTAssertEqual(metrics.count, 3)

        // 1k nodes build gate: <= 10ms
        let m1k = metrics[0]
        XCTAssertLessThanOrEqual(
            m1k.durationMs,
            10.0,
            "1,000 nodes tree build duration (\(m1k.durationMs)ms) exceeded 10ms gate floor"
        )

        // 10k nodes build gate: <= 120ms
        let m10k = metrics[1]
        XCTAssertLessThanOrEqual(
            m10k.durationMs,
            120.0,
            "10,000 nodes tree build duration (\(m10k.durationMs)ms) exceeded 120ms gate floor"
        )

        // 50k nodes build gate: <= 600ms (Debug environment), >= 50,000 items/s
        let m50k = metrics[2]
        XCTAssertLessThanOrEqual(
            m50k.durationMs,
            600.0,
            "50,000 nodes tree build duration (\(m50k.durationMs)ms) exceeded 600ms gate floor"
        )
        XCTAssertGreaterThanOrEqual(
            m50k.throughputItemsPerSec,
            50_000.0,
            "50,000 nodes tree build throughput (\(m50k.throughputItemsPerSec) items/s) below 50,000 items/s floor"
        )
    }

    // MARK: - 4. Search and Filter Throughput Hard Floor Gate

    func testSearchFilterThroughputHardFloor() async {
        let runner = FrontendBenchmarkRunner.shared
        let metrics = await runner.runSearchFilterBenchmark(datasetSize: 20000, queries: ["file_100", "Folder_2", "sub"])

        XCTAssertEqual(metrics.count, 3)
        for m in metrics {
            XCTAssertLessThanOrEqual(
                m.durationMs,
                60.0,
                "20,000 items search [\(m.query)] duration (\(m.durationMs)ms) exceeded 60ms gate floor"
            )
            XCTAssertGreaterThanOrEqual(
                m.filterThroughputItemsPerSec,
                300_000.0,
                "20,000 items search [\(m.query)] throughput (\(m.filterThroughputItemsPerSec) items/s) below 300,000 items/s floor"
            )
        }
    }

    // MARK: - 5. LRU Memory Cache Operations and Eviction Throughput Gate

    func testLRUCacheOperationsHardFloor() {
        let cache = ExplorerLRUCache<Int, String>(capacity: 64)
        let opsCount = 10000

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<opsCount {
                cache.set(i % 128, value: "Item_\(i)")
                _ = cache.get(i % 128)
            }
        }

        let durationMs = Double(elapsed.components.seconds) * 1000.0 + (Double(elapsed.components.attoseconds) / 1e15)
        let opsPerSec = Double(opsCount * 2) / (durationMs / 1000.0)

        // Strict O(1) floor: 10,000 ops <= 40ms, throughput >= 500,000 ops/s
        XCTAssertLessThanOrEqual(
            durationMs,
            40.0,
            "10,000 LRU cache ops duration (\(durationMs)ms) exceeded 40ms gate floor"
        )
        XCTAssertGreaterThanOrEqual(
            opsPerSec,
            500_000.0,
            "LRU cache operation throughput (\(opsPerSec) ops/s) below 500,000 ops/s floor"
        )
    }

    // MARK: - 6. High-Frequency Progress Event Throttling Suppression Rate Gate

    func testProgressThrottleSuppressionHardFloor() async {
        let throttler = ThrottledProgressPublisher(maxFrequencyHz: 60.0)
        let totalEvents = 10000
        var emittedCount = 0

        var currentNano: UInt64 = 1_000_000_000
        for _ in 0..<totalEvents {
            currentNano += 1000
            if throttler.shouldEmit(now: currentNano) {
                emittedCount += 1
            }
        }

        let metric = ProgressThrottleMetric(totalEvents: totalEvents, emittedEvents: emittedCount, durationMs: 10.0)
        XCTAssertGreaterThanOrEqual(
            metric.suppressionRatio,
            97.0,
            "Progress throttle suppression ratio (\(metric.suppressionRatio)%) below 97% gate floor"
        )
        XCTAssertLessThanOrEqual(
            emittedCount,
            300,
            "10,000 microsecond-level events emitted count (\(emittedCount)) exceeded 300 threshold"
        )
    }

    // MARK: - 7. Full Frontend Performance Suite Report Verification

    func testFullFrontendSuiteReportGeneration() async {
        let runner = FrontendBenchmarkRunner.shared
        let report = await runner.runFullFrontendSuite()

        XCTAssertFalse(report.hardwareSummary.isEmpty)
        XCTAssertFalse(report.treeBuildMetrics.isEmpty)
        XCTAssertFalse(report.searchFilterMetrics.isEmpty)
        XCTAssertFalse(report.throttleMetrics.isEmpty)
        XCTAssertTrue(report.isAllPassed)
    }
}
