// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
@testable import TTZipApp
import TTZipCore
import TTZipUI

final class DirectoryNavigationResponsivenessTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await DiskDirectoryScanner.shared.invalidateAllCache()
    }

    override func tearDown() async throws {
        await DiskDirectoryScanner.shared.invalidateAllCache()
        try await super.tearDown()
    }

    private func createFixtureDirectory(itemCount: Int, prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-nav-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for idx in 0..<itemCount {
            if idx % 10 == 0 {
                let sub = dir.appendingPathComponent(String(format: "folder_%04d", idx), isDirectory: true)
                try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            } else {
                let file = dir.appendingPathComponent(String(format: "item_%04d.txt", idx))
                try Data("payload-\(idx)".utf8).write(to: file)
            }
        }
        return dir
    }

    private func percentile(_ sortedSamples: [Double], p: Double) -> Double {
        guard !sortedSamples.isEmpty else { return 0 }
        let idx = min(sortedSamples.count - 1, max(0, Int(ceil(p * Double(sortedSamples.count))) - 1))
        return sortedSamples[idx]
    }

    // MARK: - 1. Rapid A -> B -> C Navigation Convergence & Cancellation

    func testRapidDirectorySwitchingA_B_CConvergesOnCAndDiscardsStaleResults() async throws {
        let dirA = try createFixtureDirectory(itemCount: 8, prefix: "A")
        let dirB = try createFixtureDirectory(itemCount: 8, prefix: "B")
        let dirC = try createFixtureDirectory(itemCount: 12, prefix: "C")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
            try? FileManager.default.removeItem(at: dirC)
        }

        let scopeID = "window_rapid_col_0"

        // Launch A and B with artificial latency, then immediately navigate to C in the same scope
        let taskA = Task { () -> [DiskItemInfo]? in
            do {
                return try await DiskDirectoryScanner.shared.scanDirectory(
                    at: dirA,
                    sortOption: .nameAsc,
                    scopeID: scopeID,
                    bypassCache: true,
                    customScanOperation: { url in
                        try await Task.sleep(for: .milliseconds(120))
                        try Task.checkCancellation()
                        return [DiskItemInfo(url: url.appendingPathComponent("from_A.txt"))]
                    }
                )
            } catch {
                return nil
            }
        }

        try await Task.sleep(for: .milliseconds(10))

        let taskB = Task { () -> [DiskItemInfo]? in
            do {
                return try await DiskDirectoryScanner.shared.scanDirectory(
                    at: dirB,
                    sortOption: .nameAsc,
                    scopeID: scopeID,
                    bypassCache: true,
                    customScanOperation: { url in
                        try await Task.sleep(for: .milliseconds(120))
                        try Task.checkCancellation()
                        return [DiskItemInfo(url: url.appendingPathComponent("from_B.txt"))]
                    }
                )
            } catch {
                return nil
            }
        }

        try await Task.sleep(for: .milliseconds(10))

        let resultC = try await DiskDirectoryScanner.shared.scanDirectory(
            at: dirC,
            sortOption: .nameAsc,
            scopeID: scopeID,
            bypassCache: true
        )

        let resultA = await taskA.value
        let resultB = await taskB.value

        XCTAssertNil(resultA, "Superseded navigation A must be cancelled and never produce a valid result")
        XCTAssertNil(resultB, "Superseded navigation B must be cancelled and never produce a valid result")
        XCTAssertEqual(resultC.count, 12, "Latest navigation C must complete with all 12 items")
    }

    // MARK: - 2. Multi-Window Independent Navigation & Slow Scan Non-Interference

    func testMultiWindowIndependentNavigationDoesNotBlockOrCancelAcrossWindows() async throws {
        let slowDirA = try createFixtureDirectory(itemCount: 5, prefix: "winA")
        let fastDirB = try createFixtureDirectory(itemCount: 25, prefix: "winB")
        defer {
            try? FileManager.default.removeItem(at: slowDirA)
            try? FileManager.default.removeItem(at: fastDirB)
        }

        let scopeWindowA = "window_A_col_0"
        let scopeWindowB = "window_B_col_0"

        // Window A starts a slow scan (250ms)
        let slowTaskA = Task { () -> [DiskItemInfo] in
            try await DiskDirectoryScanner.shared.scanDirectory(
                at: slowDirA,
                sortOption: .nameAsc,
                scopeID: scopeWindowA,
                bypassCache: true,
                customScanOperation: { url in
                    try await Task.sleep(for: .milliseconds(250))
                    try Task.checkCancellation()
                    return [DiskItemInfo(url: url.appendingPathComponent("slow_item.txt"))]
                }
            )
        }

        try await Task.sleep(for: .milliseconds(15))

        // Window B navigates to fastDirB concurrently; must complete well before Window A's 250ms sleep!
        let startB = ProcessInfo.processInfo.systemUptime
        let itemsB = try await DiskDirectoryScanner.shared.scanDirectory(
            at: fastDirB,
            sortOption: .nameAsc,
            scopeID: scopeWindowB,
            bypassCache: true
        )
        let elapsedBMs = (ProcessInfo.processInfo.systemUptime - startB) * 1000.0

        XCTAssertEqual(itemsB.count, 25)
        XCTAssertLessThan(elapsedBMs, 150.0, "Window B must not serialize behind Window A's slow scan")

        // And Window A must still complete without being cancelled by Window B
        let itemsA = try await slowTaskA.value
        XCTAssertEqual(itemsA.count, 1)
    }

    // MARK: - 3. Cache Invalidation on File Mutation & Refresh

    func testCacheInvalidatesAutomaticallyWhenDirectoryContentsChangeOrOnExplicitRefresh() async throws {
        let dir = try createFixtureDirectory(itemCount: 6, prefix: "cache")
        defer { try? FileManager.default.removeItem(at: dir) }

        let scope = "window_cache_col_0"
        let initialItems = try await DiskDirectoryScanner.shared.scanDirectory(
            at: dir,
            sortOption: .nameAsc,
            scopeID: scope,
            bypassCache: false
        )
        XCTAssertEqual(initialItems.count, 6)
        let firstMetrics = await DiskDirectoryScanner.shared.latestMetrics(forScope: scope)
        XCTAssertEqual(firstMetrics?.isCacheHit, false)

        // Repeat open without mutation hits validated cache
        let cachedItems = try await DiskDirectoryScanner.shared.scanDirectory(
            at: dir,
            sortOption: .nameAsc,
            scopeID: scope,
            bypassCache: false
        )
        XCTAssertEqual(cachedItems.count, 6)
        let secondMetrics = await DiskDirectoryScanner.shared.latestMetrics(forScope: scope)
        XCTAssertEqual(secondMetrics?.isCacheHit, true)

        // Add a new file (mutates directory mtime) and verify scanner detects the change without stale cache
        let addedFile = dir.appendingPathComponent("newly_added.txt")
        try Data("new".utf8).write(to: addedFile)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: dir.path)

        let updatedItems = try await DiskDirectoryScanner.shared.scanDirectory(
            at: dir,
            sortOption: .nameAsc,
            scopeID: scope,
            bypassCache: false
        )
        XCTAssertEqual(updatedItems.count, 7)
        let thirdMetrics = await DiskDirectoryScanner.shared.latestMetrics(forScope: scope)
        XCTAssertEqual(thirdMetrics?.isCacheHit, false)
    }

    // MARK: - 4. Permission Denied & Read Error Sentinel Protection

    func testUnreadableDirectorySurfacesAccessRequiredSentinelInsteadOfEmptySuccess() async throws {
        let restrictedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-no-perm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: restrictedDir, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: restrictedDir.appendingPathComponent("inside.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restrictedDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: restrictedDir.path)
            try? FileManager.default.removeItem(at: restrictedDir)
        }

        // Skip if running as root in container where 0o000 is still readable
        guard !FileManager.default.isReadableFile(atPath: restrictedDir.path) else { return }

        let items = await MillerColumnDirectoryScanner.loadContentsOf(
            dirURL: restrictedDir,
            sortOption: .nameAsc,
            scopeID: "window_perm_col_0"
        )
        XCTAssertEqual(items.count, 1, "Unpermitted directory must not return empty [] success")
        XCTAssertEqual(items.first?.isEncryptedLockItem, true)
        XCTAssertTrue(items.first?.path.contains("__auth__") == true)
    }

    // MARK: - 5. Small & Large Directory Latency Benchmark (First Open & Repeat Open, Median & P95)

    func testSmallAndLargeDirectoryFirstOpenAndRepeatOpenLatency() async throws {
        let smallDir = try createFixtureDirectory(itemCount: 30, prefix: "small30")
        let largeDir = try createFixtureDirectory(itemCount: 1_500, prefix: "large1500")
        defer {
            try? FileManager.default.removeItem(at: smallDir)
            try? FileManager.default.removeItem(at: largeDir)
        }

        let scope = "window_bench_col_0"
        var smallColdSamples: [Double] = []
        var smallWarmSamples: [Double] = []
        var largeColdSamples: [Double] = []
        var largeWarmSamples: [Double] = []

        for _ in 0..<9 {
            await DiskDirectoryScanner.shared.invalidateAllCache()
            let t0 = ProcessInfo.processInfo.systemUptime
            await DiskDirectoryScanner.shared.recordSelectionStart(forScope: scope, uptime: t0)
            let coldSmall = await MillerColumnDirectoryScanner.loadContentsOf(
                dirURL: smallDir,
                sortOption: .nameAsc,
                scopeID: scope
            )
            smallColdSamples.append((ProcessInfo.processInfo.systemUptime - t0) * 1000.0)
            XCTAssertEqual(coldSmall.count, 30)

            let t1 = ProcessInfo.processInfo.systemUptime
            await DiskDirectoryScanner.shared.recordSelectionStart(forScope: scope, uptime: t1)
            let warmSmall = await MillerColumnDirectoryScanner.loadContentsOf(
                dirURL: smallDir,
                sortOption: .nameAsc,
                scopeID: scope
            )
            smallWarmSamples.append((ProcessInfo.processInfo.systemUptime - t1) * 1000.0)
            XCTAssertEqual(warmSmall.count, 30)

            let t2 = ProcessInfo.processInfo.systemUptime
            await DiskDirectoryScanner.shared.recordSelectionStart(forScope: scope, uptime: t2)
            let coldLarge = await MillerColumnDirectoryScanner.loadContentsOf(
                dirURL: largeDir,
                sortOption: .nameAsc,
                scopeID: scope
            )
            largeColdSamples.append((ProcessInfo.processInfo.systemUptime - t2) * 1000.0)
            XCTAssertEqual(coldLarge.count, 1_500)

            let t3 = ProcessInfo.processInfo.systemUptime
            await DiskDirectoryScanner.shared.recordSelectionStart(forScope: scope, uptime: t3)
            let warmLarge = await MillerColumnDirectoryScanner.loadContentsOf(
                dirURL: largeDir,
                sortOption: .nameAsc,
                scopeID: scope
            )
            largeWarmSamples.append((ProcessInfo.processInfo.systemUptime - t3) * 1000.0)
            XCTAssertEqual(warmLarge.count, 1_500)
        }

        smallColdSamples.sort()
        smallWarmSamples.sort()
        largeColdSamples.sort()
        largeWarmSamples.sort()

        let smallColdMedian = percentile(smallColdSamples, p: 0.50)
        let smallColdP95 = percentile(smallColdSamples, p: 0.95)
        let smallWarmMedian = percentile(smallWarmSamples, p: 0.50)
        let smallWarmP95 = percentile(smallWarmSamples, p: 0.95)
        let largeColdMedian = percentile(largeColdSamples, p: 0.50)
        let largeColdP95 = percentile(largeColdSamples, p: 0.95)
        let largeWarmMedian = percentile(largeWarmSamples, p: 0.50)
        let largeWarmP95 = percentile(largeWarmSamples, p: 0.95)

        print(String(
            format: "[W1-NavBench] small(30) cold med=%.2fms p95=%.2fms | warm med=%.2fms p95=%.2fms || large(1500) cold med=%.2fms p95=%.2fms | warm med=%.2fms p95=%.2fms",
            smallColdMedian, smallColdP95, smallWarmMedian, smallWarmP95,
            largeColdMedian, largeColdP95, largeWarmMedian, largeWarmP95
        ))

        XCTAssertLessThan(smallColdMedian, 50.0)
        XCTAssertLessThan(largeColdMedian, 100.0)
    }
}
