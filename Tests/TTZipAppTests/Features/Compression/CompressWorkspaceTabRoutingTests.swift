// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipWorkspace
import SwiftUI
import AppKit
import TTZipUI
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class CompressWorkspaceTabRoutingTests: XCTestCase {

    func testCompressWorkspaceTabLifecycle() async throws {
        let nav = NavigationState()
        XCTAssertEqual(nav.directoryTabs.count, 1)
        XCTAssertFalse(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTabIndex, 0)

        nav.openCompressWorkspaceTab()
        XCTAssertEqual(nav.directoryTabs.count, 2)
        XCTAssertTrue(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTabIndex, 1)

        let compressTab = nav.directoryTabs[1]
        XCTAssertTrue(compressTab.isCompressWorkspace)
        XCTAssertEqual(compressTab.url.absoluteString, "ttzip://compress-workspace")
        XCTAssertFalse(compressTab.title.isEmpty)

        nav.selectTab(at: 0)
        XCTAssertEqual(nav.activeTabIndex, 0)
        XCTAssertFalse(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTab, .home)

        nav.selectTab(at: 1)
        XCTAssertEqual(nav.activeTabIndex, 1)
        XCTAssertTrue(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTab, .compressWorkspace)

        nav.closeCompressWorkspaceTab()
        XCTAssertEqual(nav.directoryTabs.count, 1)
        XCTAssertFalse(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTabIndex, 0)
        XCTAssertEqual(nav.activeTab, .home)
    }

    func testCompressWorkspaceTabReentrance() async throws {
        let nav = NavigationState()

        nav.openCompressWorkspaceTab()
        XCTAssertEqual(nav.directoryTabs.count, 2)
        XCTAssertEqual(nav.activeTabIndex, 1)

        nav.selectTab(at: 0)
        XCTAssertEqual(nav.activeTabIndex, 0)

        nav.openCompressWorkspaceTab()
        XCTAssertEqual(nav.directoryTabs.count, 2)
        XCTAssertEqual(nav.activeTabIndex, 1)
        XCTAssertTrue(nav.isCompressWorkspaceActive)
    }

    func testCompressWorkspaceCloseTabByIndex() async throws {
        let nav = NavigationState()
        nav.openCompressWorkspaceTab()
        XCTAssertEqual(nav.directoryTabs.count, 2)

        nav.closeTab(at: 1)
        XCTAssertEqual(nav.directoryTabs.count, 1)
        XCTAssertFalse(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTabIndex, 0)
    }

    func testCompressWorkspaceTabCycling() async throws {
        let nav = NavigationState()
        nav.openCompressWorkspaceTab()
        XCTAssertEqual(nav.activeTabIndex, 1)

        nav.selectPreviousTab()
        XCTAssertEqual(nav.activeTabIndex, 0)
        XCTAssertFalse(nav.isCompressWorkspaceActive)

        nav.selectNextTab()
        XCTAssertEqual(nav.activeTabIndex, 1)
        XCTAssertTrue(nav.isCompressWorkspaceActive)
    }

    func testCompressFormSessionInitialState() async throws {
        let session = CompressFormSession()
        XCTAssertTrue(session.itemsList.isEmpty)
        XCTAssertEqual(session.selectedFormat, .sevenZip)
        XCTAssertEqual(session.compressionLevel, .normal)
        XCTAssertFalse(session.outputName.isEmpty)
        XCTAssertFalse(session.isProcessing)
    }

    // MARK: - Issue #311 (CW-01..CW-05) Compression Workbench UX & Validation Tests

    func testCW01WhitespaceOnlyPasswordRejectedAndVisibilityToggleState() async throws {
        let (session, tempDir) = try makeConfiguredSession(prefix: "CW01PasswordValidation")
        AppErrorReporter.shared.dismiss()
        defer {
            AppErrorReporter.shared.dismiss()
            try? FileManager.default.removeItem(at: tempDir)
        }

        XCTAssertFalse(session.isPasswordRevealed)
        session.isPasswordRevealed.toggle()
        XCTAssertTrue(session.isPasswordRevealed)

        session.enableEncryption = true
        session.password = "   \t\n  "
        XCTAssertFalse(session.hasValidEncryptionPassword)
        XCTAssertFalse(session.canStartCompression, "CW-01: Whitespace-only password must disable canStartCompression")

        let executorCalls = LockedArray<String>()
        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            executorCalls.append(outputPath)
            return CompressWorkspaceTabTests.makeResult(outputPath: outputPath, compressedBytes: 64)
        }
        session.startCompression()
        XCTAssertTrue(executorCalls.snapshot().isEmpty, "CW-01: startCompression() must reject whitespace-only password")
        XCTAssertFalse(session.isProcessing)
        XCTAssertTrue(AppErrorReporter.shared.isPresentingError)
        XCTAssertNotNil(AppErrorReporter.shared.activeError)

        AppErrorReporter.shared.dismiss()
        session.password = "  Secret123  "
        XCTAssertTrue(session.hasValidEncryptionPassword)
        XCTAssertTrue(session.canStartCompression)
        XCTAssertEqual(session.trimmedPassword, "Secret123")
    }

    func testCW02CustomSplitVolumeOverflowProtectionValidationAndPresetSync() async throws {
        let (session, tempDir) = try makeConfiguredSession(prefix: "CW02SplitVolume")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        session.selectedFormat = .sevenZip
        session.isCustomVolumeSelected = true

        session.customVolumeUnit = "GB"
        session.customVolumeValueString = "9999999999"
        XCTAssertFalse(session.isCustomVolumeValid)
        XCTAssertNil(session.splitVolumeOption)
        XCTAssertFalse(session.canStartCompression, "CW-02: Invalid custom volume must disable canStartCompression")

        session.customVolumeValueString = ""
        XCTAssertFalse(session.isCustomVolumeValid)
        XCTAssertFalse(session.canStartCompression)

        session.customVolumeValueString = "1.5"
        XCTAssertTrue(session.isCustomVolumeValid)
        XCTAssertEqual(session.splitVolumeOption, 1536 * 1024 * 1024)
        XCTAssertTrue(session.canStartCompression)

        let customPreset = CompressionPreset(
            name: "Custom250MB",
            format: .sevenZip,
            level: .normal,
            splitVolumeSizeBytes: 250 * 1024 * 1024,
            defaultPassword: nil,
            skipMacJunk: true
        )
        PresetManager.shared.savePreset(customPreset)
        defer { PresetManager.shared.deletePreset(id: customPreset.id) }

        session.applyPreset(id: customPreset.id)
        XCTAssertTrue(session.isCustomVolumeSelected, "CW-02: Non-standard preset split size must select custom volume pill")
        XCTAssertEqual(session.splitVolumeOption, 250 * 1024 * 1024)
        XCTAssertEqual(session.customVolumeUnit, "MB")
        XCTAssertEqual(session.customVolumeValueString, "250")
        XCTAssertTrue(session.isCustomVolumeValid)

        session.syncSplitVolumeFromPreset(700 * 1024 * 1024)
        XCTAssertFalse(session.isCustomVolumeSelected, "CW-02: Standard 700MB preset size must deselect custom volume pill")
        XCTAssertEqual(session.splitVolumeOption, 700 * 1024 * 1024)
    }

    func testCW03ResolvedOutputFileNameDeduplicatesExtensionAndUsesFileExtension() async throws {
        let session = CompressFormSession()
        session.selectedFormat = .zip
        session.outputName = "Backup.zip"
        XCTAssertEqual(session.resolvedOutputFileName, "Backup.zip", "CW-03: Must not duplicate .zip extension")

        session.outputName = "Backup.ZIP"
        XCTAssertEqual(session.resolvedOutputFileName, "Backup.zip", "CW-03: Case-insensitive extension deduplication")

        session.selectedFormat = .tarZst
        session.outputName = "Bundle.tar.zst"
        XCTAssertEqual(session.resolvedOutputFileName, "Bundle.tar.zst", "CW-03: Must not duplicate composite .tar.zst extension")

        session.selectedFormat = .brotli
        session.outputName = "payload.txt"
        XCTAssertEqual(session.resolvedOutputFileName, "payload.txt.br", "CW-03: Must use fileExtension (.br) instead of rawValue (brotli)")
    }

    func testCW04CompressionGuideSheetLocalizationAndAlgorithmMatrixSheetBinding() async throws {
        let l10n = AppLocalizationState.shared
        let originalLang = l10n.currentLanguage
        defer { l10n.setLanguage(originalLang) }

        var isShown = true
        let binding = Binding(get: { isShown }, set: { isShown = $0 })
        let guideView = CompressionGuideSheetView(isPresented: binding, initialTab: 1)

        l10n.setLanguage(.en)
        XCTAssertEqual(guideView.headerBadgeText, "COMPRESSION ENCYCLOPEDIA")
        XCTAssertEqual(guideView.doneButtonTitle, "Done")
        XCTAssertTrue(guideView.tabTitles.contains("⚡ Algorithms"))

        l10n.setLanguage(.zhHans)
        XCTAssertEqual(guideView.headerBadgeText, "压缩百科指南")
        XCTAssertEqual(guideView.doneButtonTitle, "完成")
        XCTAssertTrue(guideView.tabTitles.contains("⚡ 压缩算法"))

        let session = CompressFormSession()
        XCTAssertFalse(session.isAlgorithmMatrixPresented)
        session.isAlgorithmMatrixPresented = true
        XCTAssertTrue(session.isAlgorithmMatrixPresented)
    }

    func testCW05CreateSeparateArchivesCompressesEachInputIntoSeparateArchive() async throws {
        let tempDir = try makeTemporaryDirectory(prefix: "CW05SeparateArchives")
        let fileA = tempDir.appendingPathComponent("alpha.txt")
        let fileB = tempDir.appendingPathComponent("beta.log")
        try Data("ALPHA_PAYLOAD".utf8).write(to: fileA)
        try Data("BETA_PAYLOAD".utf8).write(to: fileB)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tempDir)
        }

        let session = CompressFormSession(initialInputPaths: [fileA.path, fileB.path])
        session.targetDirectory = tempDir.path
        session.selectedFormat = .zip
        session.createSeparateArchives = true
        session.openFinderAfterCompress = false

        let jobs = session.resolvedExecutionJobs()
        XCTAssertEqual(jobs.count, 2, "CW-05: createSeparateArchives=true with 2 inputs must produce 2 jobs")
        XCTAssertEqual(jobs[0].inputPaths, [fileA.path])
        XCTAssertEqual(jobs[0].outputFileName, "alpha.zip")
        XCTAssertEqual(jobs[1].inputPaths, [fileB.path])
        XCTAssertEqual(jobs[1].outputFileName, "beta.zip")

        let recorder = BoundaryReceiptRecorder(session: session)
        let recordedInvocations = LockedArray<([String], String)>()
        session.quickCompressExecutor = { inputs, outputPath, _, _, _, _, _, _, _, _ in
            recordedInvocations.append((inputs, outputPath))
            try Data("ARCHIVE".utf8).write(to: URL(fileURLWithPath: outputPath))
            return CompressWorkspaceTabTests.makeResult(outputPath: outputPath, compressedBytes: 128)
        }

        session.startCompression()
        let taskId = try XCTUnwrap(session.activeSessionTaskId)
        let done = recorder.expectTerminalBoundaryReceipt(for: taskId)
        await fulfillment(of: [done], timeout: 3.0)

        let calls = recordedInvocations.snapshot()
        XCTAssertEqual(calls.count, 2, "CW-05: Executor must be invoked once per input item")
        XCTAssertEqual(calls[0].0, [fileA.path])
        XCTAssertEqual(calls[0].1, tempDir.appendingPathComponent("alpha.zip").path)
        XCTAssertEqual(calls[1].0, [fileB.path])
        XCTAssertEqual(calls[1].1, tempDir.appendingPathComponent("beta.zip").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: calls[0].1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: calls[1].1))
        XCTAssertEqual(session.completedSummary?.compressedBytes, 256)
    }

    private func makeConfiguredSession(prefix: String) throws -> (CompressFormSession, URL) {
        let tempDir = try makeTemporaryDirectory(prefix: prefix)
        let inputURL = tempDir.appendingPathComponent("payload.txt")
        try Data(repeating: 0x41, count: 1024).write(to: inputURL)
        let session = CompressFormSession(initialInputPaths: [inputURL.path])
        session.targetDirectory = tempDir.path
        session.openFinderAfterCompress = false
        session.deleteSourceAfterCompress = false
        return (session, tempDir)
    }
}
