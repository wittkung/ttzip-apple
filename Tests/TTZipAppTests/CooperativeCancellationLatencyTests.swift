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
final class CooperativeCancellationLatencyTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipCancelTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    func testArchiveTaskCoordinatorRegistrationAndCancellation() async throws {
        let coordinator = ArchiveTaskCoordinator.shared
        let taskId = UUID()
        
        let handle = coordinator.registerTask(id: taskId)
        XCTAssertEqual(coordinator.activeCount, 1)
        XCTAssertFalse(handle.isCancelled)
        XCTAssertFalse(handle.isPaused)
        
        coordinator.pauseTask(id: taskId)
        XCTAssertTrue(handle.isPaused)
        
        coordinator.resumeTask(id: taskId)
        XCTAssertFalse(handle.isPaused)
        
        coordinator.cancelTask(id: taskId)
        XCTAssertTrue(handle.isCancelled)
        XCTAssertTrue(handle.uniffiToken.isCancelled())
        
        coordinator.unregisterTask(id: taskId)
        XCTAssertEqual(coordinator.activeCount, 0)
    }

    func testAppViewStateTaskControlIntegration() async throws {
        let viewState = AppViewState(fileViewer: NoOpFileViewer())
        let coordinator = ArchiveTaskCoordinator.shared
        let taskId = UUID()
        
        let handle = coordinator.registerTask(id: taskId)
        viewState.currentTaskID = taskId
        viewState.canPauseTask = true
        viewState.canCancelTask = true
        
        viewState.pauseCurrentTask()
        XCTAssertTrue(handle.isPaused)
        XCTAssertEqual(viewState.taskStateName, "Paused")
        XCTAssertFalse(viewState.canPauseTask)
        XCTAssertTrue(viewState.canResumeTask)
        
        viewState.resumeCurrentTask()
        XCTAssertFalse(handle.isPaused)
        XCTAssertEqual(viewState.taskStateName, "Processing")
        
        viewState.cancelCurrentTask()
        XCTAssertTrue(handle.isCancelled)
        XCTAssertEqual(viewState.taskStateName, "Cancelled")
        
        viewState.updateTaskStateUI()
        XCTAssertEqual(viewState.taskStateName, "Idle")
        XCTAssertNil(viewState.currentTaskID)
        
        coordinator.unregisterTask(id: taskId)
    }

    func testCooperativeCancellationResponsivenessUnderLoad() async throws {
        // Create 10MB test payload
        let sourceFile = tempDir.appendingPathComponent("large_payload.bin")
        let dummyData = Data(repeating: 0x42, count: 10 * 1024 * 1024)
        try dummyData.write(to: sourceFile)
        
        let outputFile = tempDir.appendingPathComponent("output_cancelled.zip")
        let handle = TaskExecutionHandle()
        
        let startCancelTime = CFAbsoluteTimeGetCurrent()
        
        let backgroundTask = Task.detached(priority: .userInitiated) {
            do {
                _ = try await TTZipEngineFacade.shared.quickCompress(
                    inputs: [sourceFile.path],
                    outputPath: outputFile.path,
                    format: .zip,
                    level: .level9,
                    token: handle.uniffiToken
                )
                return false
            } catch let error as ArchiveError {
                return error == .cancelled
            } catch {
                return false
            }
        }
        
        // Immediately trigger cancellation
        handle.cancel()
        
        let wasCancelledOrCaught = await backgroundTask.value
        let elapsed = CFAbsoluteTimeGetCurrent() - startCancelTime
        
        XCTAssertTrue(wasCancelledOrCaught, "Task should abort or throw upon cancellation specifically with ArchiveError.cancelled")
        XCTAssertLessThan(elapsed, 0.5, "Cancellation latency should be immediate (<500ms)")
    }
}
