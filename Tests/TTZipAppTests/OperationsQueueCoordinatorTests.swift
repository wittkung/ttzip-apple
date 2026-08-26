// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import TTZipCore
@testable import TTZipApp

@MainActor
final class OperationsQueueCoordinatorTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
    }

    override func tearDown() async throws {
        ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
        try await super.tearDown()
    }

    func testOperationsQueueLifecycleAndTelemetry() async throws {
        let center = ArchiveOperationsQueueCenter.shared
        let viewModel = OperationsQueueViewModel()
        
        let op1Id = UUID()
        let op1 = QueuedArchiveOperation(
            id: op1Id,
            name: "Archive 1.zip",
            operationType: .compress,
            state: .queued,
            totalBytes: 1000,
            bytesProcessed: 0,
            throughputMBs: 0.0
        )
        
        center.enqueue(operation: op1)
        XCTAssertEqual(viewModel.tasks.count, 1)
        XCTAssertEqual(viewModel.activeTasksCount, 0)
        XCTAssertEqual(viewModel.overallProgress, 0.0)
        
        center.updateProgress(id: op1Id, bytesProcessed: 500, totalBytes: 1000, throughputMBs: 25.5)
        XCTAssertEqual(viewModel.activeTasksCount, 1)
        XCTAssertEqual(viewModel.overallProgress, 0.5, accuracy: 0.01)
        XCTAssertEqual(viewModel.overallThroughputMBs, 25.5, accuracy: 0.01)
        
        // Enqueue second task
        let op2Id = UUID()
        let op2 = QueuedArchiveOperation(
            id: op2Id,
            name: "Extract 2.7z",
            operationType: .extract,
            state: .running,
            totalBytes: 1000,
            bytesProcessed: 500,
            throughputMBs: 15.0
        )
        center.enqueue(operation: op2)
        XCTAssertEqual(viewModel.activeTasksCount, 2)
        XCTAssertEqual(viewModel.overallProgress, 0.5, accuracy: 0.01)
        XCTAssertEqual(viewModel.overallThroughputMBs, 40.5, accuracy: 0.01)
        
        // Pause op1
        viewModel.pauseTask(id: op1Id)
        XCTAssertEqual(viewModel.tasks.first(where: { $0.id == op1Id })?.state, .paused)
        XCTAssertEqual(viewModel.activeTasksCount, 1)
        
        // Resume op1
        viewModel.resumeTask(id: op1Id)
        XCTAssertEqual(viewModel.tasks.first(where: { $0.id == op1Id })?.state, .running)
        XCTAssertEqual(viewModel.activeTasksCount, 2)
        
        // Complete op1
        center.markCompleted(id: op1Id)
        XCTAssertEqual(viewModel.tasks.first(where: { $0.id == op1Id })?.state, .completed)
        XCTAssertEqual(viewModel.activeTasksCount, 1)
        
        // Cancel op2
        viewModel.cancelTask(id: op2Id)
        XCTAssertEqual(viewModel.tasks.first(where: { $0.id == op2Id })?.state, .cancelled)
        XCTAssertEqual(viewModel.activeTasksCount, 0)
        XCTAssertEqual(viewModel.overallProgress, 0.0)
        
        // Clear finished
        viewModel.clearFinishedTasks()
        XCTAssertEqual(viewModel.tasks.count, 0)
    }
}
