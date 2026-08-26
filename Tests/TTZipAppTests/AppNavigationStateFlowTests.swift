// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
@testable import TTZipApp
@testable import TTZipCore

final class AppNavigationStateFlowTests: XCTestCase {
    
    @MainActor
    private func createHarness() -> (AppViewState, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NavStateTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sut = AppViewState()
        AppIntentDispatcher.shared.bind(state: sut)
        return (sut, tempDir)
    }
    
    // MARK: - 1. Tab Transitions & Background Task Isolation
    
    @MainActor
    func testTabSwitchingPreservesBackgroundExecutionState() {
        let (sut, tempDir) = createHarness()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        sut.activeTab = .home
        sut.taskState.isLoading = true
        sut.taskState.progressValue = 0.65
        sut.taskState.statusMessage = "Compressing large dataset..."
        
        // Navigate across tabs
        sut.activeTab = .compressWorkspace
        XCTAssertEqual(sut.activeTab, .compressWorkspace)
        XCTAssertTrue(sut.isLoading)
        XCTAssertEqual(sut.progressValue, 0.65)
        
        sut.activeTab = .vault
        XCTAssertEqual(sut.activeTab, .vault)
        XCTAssertEqual(sut.statusMessage, "Compressing large dataset...")
        
        sut.activeTab = .home
        XCTAssertEqual(sut.activeTab, .home)
        XCTAssertTrue(sut.isLoading)
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
}
