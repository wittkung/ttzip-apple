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
@testable import TTZipApp
@testable import TTZipCore

final class AppNavigationStateFlowTests: XCTestCase {
    
    @MainActor
    private func createHarness() -> (AppViewState, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NavStateTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sut = AppViewState(fileViewer: NoOpFileViewer())
        AppIntentDispatcher.shared.bind(state: sut)
        return (sut, tempDir)
    }
    
    // MARK: - 1. Tab Transitions & Sub-Workspace Instance Persistence
    
    @MainActor
    func testTabSwitchingPreservesBackgroundExecutionState() {
        let (sut, tempDir) = createHarness()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let initialNav = sut.navigationState
        let initialExplorer = sut.explorerState
        let initialTask = sut.taskState
        let initialOverlay = sut.overlayState
        let initialHistory = sut.historyManager
        let initialVault = sut.passwordVaultManager
        
        sut.activeTab = .home
        sut.taskState.isLoading = true
        sut.taskState.progressValue = 0.65
        sut.taskState.statusMessage = "Compressing large dataset..."
        sut.explorerState.searchQuery = "test_query"
        sut.overlayState.showCompressModal = false
        
        // Navigate across all tabs and assert instance identity persistence
        let tabsToTest: [WorkspaceTab] = [.compressWorkspace, .presets, .benchmark, .vault, .plugins, .settings, .home]
        for tab in tabsToTest {
            sut.activeTab = tab
            XCTAssertEqual(sut.activeTab, tab)
            
            // Assert sub-state references remain strictly identical (sub-workspace instance persistence)
            XCTAssertTrue(sut.navigationState === initialNav, "NavigationState instance must persist across tab switch to \(tab)")
            XCTAssertTrue(sut.explorerState === initialExplorer, "ArchiveExplorerState instance must persist across tab switch to \(tab)")
            XCTAssertTrue(sut.taskState === initialTask, "TaskExecutionState instance must persist across tab switch to \(tab)")
            XCTAssertTrue(sut.overlayState === initialOverlay, "OverlayState instance must persist across tab switch to \(tab)")
            XCTAssertTrue(sut.historyManager === initialHistory, "CommandHistoryManager instance must persist across tab switch to \(tab)")
            XCTAssertTrue(sut.passwordVaultManager === initialVault, "PasswordVaultManager instance must persist across tab switch to \(tab)")
            
            // Assert domain property values are preserved
            XCTAssertTrue(sut.isLoading)
            XCTAssertEqual(sut.progressValue, 0.65)
            XCTAssertEqual(sut.statusMessage, "Compressing large dataset...")
            XCTAssertEqual(sut.searchQuery, "test_query")
        }
    }
    
    // MARK: - 2. KeepAlive Container State Retention
    
    @MainActor
    func testKeepAliveTabContainerStateRetentionHarness() {
        let harness = KeepAliveTabHarness(initialTab: .home)
        
        XCTAssertEqual(harness.visitedTabs, [.home])
        
        harness.switchTab(to: .compressWorkspace)
        harness.switchTab(to: .presets)
        harness.switchTab(to: .home)
        
        XCTAssertEqual(harness.visitedTabs, [.home, .compressWorkspace, .presets])
        XCTAssertEqual(harness.currentTab, .home)
    }
    
    // MARK: - 3. Modal & Overlay Stacking Invariants
    
    @MainActor
    func testOverlayStackingAndCancellationInvariants() {
        let (sut, tempDir) = createHarness()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let testPath = tempDir.appendingPathComponent("vault_locked.zip").path
        
        sut.pendingEncryptedPath = testPath
        sut.showPasswordPrompt = true
        sut.statusMessage = "Password required"
        
        XCTAssertTrue(sut.showPasswordPrompt)
        XCTAssertEqual(sut.pendingEncryptedPath, testPath)
        
        sut.cancelPasswordPrompt()
        
        XCTAssertFalse(sut.showPasswordPrompt)
        XCTAssertNil(sut.pendingEncryptedPath)
        XCTAssertEqual(sut.statusMessage, "Decryption cancelled")
    }
    
    // MARK: - 4. Intent Dispatcher: Multi-Path Compression Injection
    
    @MainActor
    func testIntentDispatcherFlattensAndInjectsPaths() throws {
        let (sut, tempDir) = createHarness()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)
        
        let envelope = AppIntentEnvelope(
            intent: .createArchive(sourcePaths: [file1.path, file2.path], options: CompressIntentOptions()),
            source: .contextMenu
        )
        
        let result = AppIntentDispatcher.shared.dispatch(envelope)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(sut.activeTab, .compressWorkspace)
        XCTAssertEqual(sut.selectedPathsToCompress, [file1.path, file2.path])
    }
    
    // MARK: - 5. Intent Dispatcher: Deep Link Tab Switching
    
    @MainActor
    func testIntentDispatcherDeepLinkTabSwitch() {
        let (sut, tempDir) = createHarness()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let envelope = AppIntentEnvelope(
            intent: .switchTab(tab: .settings),
            source: .urlScheme
        )
        
        let result = AppIntentDispatcher.shared.dispatch(envelope)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(sut.activeTab, .settings)
    }
    
    // MARK: - 6. Multi-Directory Tab Operations & Synchronizations
    
    @MainActor
    func testMultiDirectoryTabOperationsAndSync() {
        let (sut, tempDir) = createHarness()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let initialTabCount = sut.directoryTabs.count
        XCTAssertEqual(initialTabCount, 1)
        XCTAssertEqual(sut.activeTabIndex, 0)
        
        // Open new tab
        let folderA = tempDir.appendingPathComponent("FolderA")
        try? FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        sut.openNewTab(url: folderA)
        
        XCTAssertEqual(sut.directoryTabs.count, 2)
        XCTAssertEqual(sut.activeTabIndex, 1)
        XCTAssertEqual(sut.currentDirectory, folderA)
        XCTAssertEqual(sut.directoryTabs[1].url, folderA)
        
        // Open another tab
        let folderB = tempDir.appendingPathComponent("FolderB")
        try? FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        sut.openNewTab(url: folderB)
        
        XCTAssertEqual(sut.directoryTabs.count, 3)
        XCTAssertEqual(sut.activeTabIndex, 2)
        XCTAssertEqual(sut.currentDirectory, folderB)
        
        // Cycle tabs
        sut.selectNextTab()
        XCTAssertEqual(sut.activeTabIndex, 0)
        
        sut.selectPreviousTab()
        XCTAssertEqual(sut.activeTabIndex, 2)
        
        // Select specific tab
        sut.selectTab(at: 1)
        XCTAssertEqual(sut.activeTabIndex, 1)
        XCTAssertEqual(sut.currentDirectory, folderA)
        
        // Close middle tab
        sut.closeTab(at: 1)
        XCTAssertEqual(sut.directoryTabs.count, 2)
        
        // Cannot close last remaining tab
        sut.closeTab(at: 0)
        XCTAssertEqual(sut.directoryTabs.count, 1)
        sut.closeTab(at: 0) // Should be guarded
        XCTAssertEqual(sut.directoryTabs.count, 1)
    }
}
