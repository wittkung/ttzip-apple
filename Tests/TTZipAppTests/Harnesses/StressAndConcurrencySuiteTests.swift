// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

@MainActor
final class StressAndConcurrencySuiteTests: XCTestCase {

    func testFiftyConcurrentBackgroundSessionsStress() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "StressSuite")
        XCTAssertFalse(tempDir.path.isEmpty)
        
        ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
        addTeardownBlock {
            Task { @MainActor in
                ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            }
        }
        
        let coordinator = ArchiveTaskCoordinator.shared
        let queueCenter = ArchiveOperationsQueueCenter.shared
        let concurrencyCount = 50
        
        var taskIDs: [UUID] = []
        for i in 0..<concurrencyCount {
            let id = UUID()
            taskIDs.append(id)
            
            let handle = coordinator.registerTask(id: id)
            let op = QueuedArchiveOperation(
                id: id,
                name: "BatchJob_\(i).zip",
                operationType: .compress,
                state: .queued,
                totalBytes: 100_000,
                bytesProcessed: 0,
                throughputMBs: 0.0
            )
            queueCenter.enqueue(operation: op)
            XCTAssertFalse(handle.isCancelled)
        }
        
        XCTAssertEqual(coordinator.activeCount, concurrencyCount)
        XCTAssertEqual(queueCenter.tasks.count, concurrencyCount)
        
        // Concurrently simulate progress updates and state changes
        await withTaskGroup(of: Void.self) { group in
            for id in taskIDs {
                group.addTask { @MainActor in
                    queueCenter.updateProgress(id: id, bytesProcessed: 50_000, totalBytes: 100_000, throughputMBs: 30.0)
                    coordinator.pauseTask(id: id)
                    queueCenter.pause(id: id)
                    coordinator.resumeTask(id: id)
                    queueCenter.resume(id: id)
                    queueCenter.markCompleted(id: id)
                    coordinator.unregisterTask(id: id)
                }
            }
        }
        
        XCTAssertEqual(coordinator.activeCount, 0, "All task coordinator handles should be unregistered")
        XCTAssertEqual(queueCenter.activeTasksCount, 0, "No active running tasks should remain")
        
        queueCenter.clearFinishedTasks()
        XCTAssertEqual(queueCenter.tasks.count, 0, "Queue should be completely clean after clearFinishedTasks")
    }

    func testConcurrentVFSTreeBuildingStress() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "StressSuite")
        XCTAssertFalse(tempDir.path.isEmpty)
        
        let entryCount = 1000
        var entries: [ArchiveEntry] = []
        for i in 0..<entryCount {
            let dirIdx = i / 50
            let subDirIdx = (i % 50) / 10
            entries.append(ArchiveEntry(
                path: "cluster_\(dirIdx)/sub_\(subDirIdx)/item_\(i).dat",
                uncompressedSize: Int64(i * 1024),
                isDirectory: false
            ))
        }
        
        let immutableEntries = entries
        // Concurrently build 20 trees across detached tasks
        let trees = await withTaskGroup(of: [ArchiveTreeNode].self) { group in
            for _ in 0..<20 {
                group.addTask {
                    return FastArchiveTreeBuilder.buildTree(from: immutableEntries)
                }
            }
            
            var results: [[ArchiveTreeNode]] = []
            for await tree in group {
                results.append(tree)
            }
            return results
        }
        
        XCTAssertEqual(trees.count, 20)
        for tree in trees {
            XCTAssertFalse(tree.isEmpty)
            XCTAssertEqual(tree.count, 20) // 1000 / 50 = 20 root clusters
        }
    }
}
