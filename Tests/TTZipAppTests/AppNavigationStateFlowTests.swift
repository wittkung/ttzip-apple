// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp
@testable import TTZipCore

@MainActor
final class AppNavigationStateFlowTests: XCTestCase {
    
    @MainActor
    private func createHarness() -> (AppViewState, URL) {
        AppLocalizationState.shared.setLanguage(.en)
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
        let busyOperationID = sut.taskState.beginBusyOperation()
        defer { sut.taskState.endBusyOperation(id: busyOperationID) }
        sut.taskState.progressValue = 0.65
        sut.taskState.statusMessage = "Compressing large dataset..."
        sut.explorerState.searchQuery = "test_query"
        sut.overlayState.showExtractModal = false
        
        // Navigate across all tabs and assert instance identity persistence
        let tabsToTest: [WorkspaceTab] = [.compressWorkspace, .presets, .benchmark, .vault, .settings, .home]
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
        XCTAssertEqual(sut.compressSession.itemsList.map(\.path), [file1.path, file2.path])
    }

    @MainActor
    func testContextMenuCompressToZipAnd7zDeliverTargetFormatToCompressWorkspace() throws {
        let (sut, tempDir) = createHarness()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("alpha.txt")
        let file2 = tempDir.appendingPathComponent("beta.txt")
        try "Alpha".write(to: file1, atomically: true, encoding: .utf8)
        try "Beta".write(to: file2, atomically: true, encoding: .utf8)

        sut.compressSession.selectedFormat = .sevenZip
        let singleMenu = TTZipContextMenuBuilder.shared.buildMenu(
            for: .singleItem(url: file1, isDirectory: false, isArchive: false)
        )

        let zipSingleTitle = AppLocalizationState.shared.t(L10n.Menu.compressZip)
        let zipSingleItem = try XCTUnwrap(singleMenu.items.first(where: { $0.title == zipSingleTitle }))
        _ = zipSingleItem.target?.perform(zipSingleItem.action, with: zipSingleItem)

        XCTAssertEqual(sut.activeTab, .compressWorkspace)
        XCTAssertEqual(sut.compressSession.itemsList.map(\.path), [file1.path])
        XCTAssertEqual(sut.compressSession.selectedFormat, .zip)

        let sevenZipSingleTitle = AppLocalizationState.shared.t(L10n.Menu.compress7z)
        let sevenZipSingleItem = try XCTUnwrap(singleMenu.items.first(where: { $0.title == sevenZipSingleTitle }))
        _ = sevenZipSingleItem.target?.perform(sevenZipSingleItem.action, with: sevenZipSingleItem)

        XCTAssertEqual(sut.activeTab, .compressWorkspace)
        XCTAssertEqual(sut.compressSession.itemsList.map(\.path), [file1.path])
        XCTAssertEqual(sut.compressSession.selectedFormat, .sevenZip)

        let multiMenu = TTZipContextMenuBuilder.shared.buildMenu(
            for: .multipleItems(urls: [file1, file2])
        )
        let zipMultiTitle = AppLocalizationState.shared.format(L10n.Menu.compressZipItemsFormat, 2)
        let zipMultiItem = try XCTUnwrap(multiMenu.items.first(where: { $0.title == zipMultiTitle }))
        _ = zipMultiItem.target?.perform(zipMultiItem.action, with: zipMultiItem)

        XCTAssertEqual(sut.activeTab, .compressWorkspace)
        XCTAssertEqual(sut.compressSession.itemsList.map(\.path), [file1.path, file2.path])
        XCTAssertEqual(sut.compressSession.selectedFormat, .zip)
    }

    @MainActor
    func testCreateArchiveIntentOptionsOverrideAndDefaultPolicy() throws {
        let (sut, tempDir) = createHarness()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file1 = tempDir.appendingPathComponent("report.txt")
        try "Report content".write(to: file1, atomically: true, encoding: .utf8)
        let customOutDir = tempDir.appendingPathComponent("CustomOut")
        try FileManager.default.createDirectory(at: customOutDir, withIntermediateDirectories: true)

        let presetID = try XCTUnwrap(PresetManager.shared.presets.first?.id)
        let explicitOptions = CompressIntentOptions(
            presetID: presetID,
            targetFormat: .zip,
            separateArchives: true,
            deleteSourceAfterCompression: true,
            customOutputPath: customOutDir.appendingPathComponent("custom_bundle.zip").path,
            password: "intent-password"
        )
        let explicitResult = AppIntentDispatcher.shared.dispatch(
            AppIntentEnvelope(
                intent: .createArchive(sourcePaths: [file1.path], options: explicitOptions),
                source: .urlScheme
            )
        )
        XCTAssertEqual(explicitResult, .success)
        XCTAssertEqual(sut.compressSession.selectedPresetID, presetID)
        XCTAssertEqual(sut.compressSession.selectedFormat, .zip)
        XCTAssertTrue(sut.compressSession.createSeparateArchives)
        XCTAssertTrue(sut.compressSession.deleteSourceAfterCompress)
        XCTAssertEqual(sut.compressSession.targetDirectory, customOutDir.path)
        XCTAssertEqual(sut.compressSession.outputName, "custom_bundle")
        XCTAssertTrue(sut.compressSession.enableEncryption)
        XCTAssertEqual(sut.compressSession.password, "intent-password")

        // Default options preserve existing format while resetting per-intent flags and deriving path/name from input
        let defaultResult = AppIntentDispatcher.shared.dispatch(
            AppIntentEnvelope(
                intent: .createArchive(sourcePaths: [file1.path], options: CompressIntentOptions()),
                source: .contextMenu
            )
        )
        XCTAssertEqual(defaultResult, .success)
        XCTAssertEqual(sut.compressSession.selectedFormat, .zip)
        XCTAssertFalse(sut.compressSession.createSeparateArchives)
        XCTAssertFalse(sut.compressSession.deleteSourceAfterCompress)
        XCTAssertEqual(sut.compressSession.targetDirectory, tempDir.path)
        XCTAssertEqual(sut.compressSession.outputName, "report")
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
