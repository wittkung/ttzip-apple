// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp
@testable import TTZipCore

@MainActor
final class AppViewStateSubStateTests: XCTestCase {
    
    func testAppViewStateSubStateIsolationAndDecoupling() {
        let navState = NavigationState()
        let explorerState = ArchiveExplorerState()
        let taskState = TaskExecutionState()
        let overlayState = OverlayState()
        
        let coordinator = AppViewState(
            navigationState: navState,
            explorerState: explorerState,
            taskState: taskState,
            overlayState: overlayState,
            fileViewer: NoOpFileViewer()
        )
        
        // 1. NavigationState
        navState.activeTab = .compressWorkspace
        XCTAssertEqual(coordinator.navigationState.activeTab, .compressWorkspace)
        
        coordinator.navigationState.activeTab = .vault
        XCTAssertEqual(navState.activeTab, .vault)
        
        navState.isLeftSidebarVisible = false
        XCTAssertFalse(coordinator.navigationState.isLeftSidebarVisible)
        coordinator.navigationState.isLeftSidebarVisible = true
        XCTAssertTrue(navState.isLeftSidebarVisible)
        
        // 2. ArchiveExplorerState
        explorerState.currentArchivePath = "/tmp/test.zip"
        XCTAssertEqual(coordinator.explorerState.currentArchivePath, "/tmp/test.zip")
        
        coordinator.explorerState.currentArchivePath = "/tmp/new.7z"
        XCTAssertEqual(explorerState.currentArchivePath, "/tmp/new.7z")
        
        // 3. TaskExecutionState
        taskState.statusMessage = "正在解压..."
        XCTAssertEqual(coordinator.taskState.statusMessage, "正在解压...")
        
        coordinator.taskState.statusMessage = "完成"
        XCTAssertEqual(taskState.statusMessage, "完成")
        
        // 4. OverlayState
        overlayState.showExtractModal = true
        XCTAssertTrue(coordinator.overlayState.showExtractModal)
        
        coordinator.overlayState.showExtractModal = false
        XCTAssertFalse(overlayState.showExtractModal)
    }
    
    // MARK: - 5. UndoManager Bridge Invariants
    
    func testAppViewStateUndoManagerBridge() async throws {
        let coordinator = AppViewState(fileViewer: NoOpFileViewer())
        let undoManager = UndoManager()
        coordinator.undoManager = undoManager
        
        struct DummyTestCommand: ArchiveCommandProtocol, @unchecked Sendable {
            let commandId = UUID().uuidString
            let description = "Rename Item"
            let isUndoable = true
            func execute() async throws -> CommandResult {
                CommandResult(commandId: commandId, success: true, message: "Item renamed")
            }
            func undo() async throws {}
        }
        
        let command = DummyTestCommand()
        _ = try await coordinator.executeCommand(command)
        
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertEqual(undoManager.undoActionName, "Rename Item")
        
        undoManager.undo()
        XCTAssertTrue(undoManager.canRedo)
        XCTAssertEqual(undoManager.redoActionName, "Rename Item")
    }
}
