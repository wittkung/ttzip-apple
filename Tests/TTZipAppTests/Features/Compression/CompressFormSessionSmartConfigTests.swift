// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipCore
@testable import TTZipApp

final class CompressFormSessionSmartConfigTests: XCTestCase {
    
    // MARK: - 1. Store Mode Tests
    
    @MainActor
    func testStoreModeDefaultsAndZeroDictionary() {
        let session = CompressFormSession()
        session.selectedFormat = .sevenZip
        session.compressionLevel = .store
        
        XCTAssertEqual(session.effectiveDictionarySizeMB, 0, "Store mode must result in 0MB dictionary")
        XCTAssertNil(session.customDictionarySizeMB, "Default session should have nil customDictionarySizeMB")
    }
    
    // MARK: - 2. Level-Driven Dictionary Scaling
    
    @MainActor
    func testLevelDrivenDictionaryScaling() {
        let session = CompressFormSession()
        session.customDictionarySizeMB = nil
        
        // Fastest Level (1) -> 16 MB
        session.compressionLevel = .level1
        XCTAssertEqual(session.effectiveDictionarySizeMB, 16, "Level 1 (Fastest) should default to 16 MB dictionary")
        
        // Normal Level (5 / 6) -> 64 MB
        session.compressionLevel = .level6
        XCTAssertEqual(session.effectiveDictionarySizeMB, 64, "Level 6 (Normal) should default to 64 MB dictionary")
        
        // Ultra Level (9) -> Scales according to Apple Silicon unified memory (>= 128 MB)
        session.compressionLevel = .level9
        let ultraDict = session.effectiveDictionarySizeMB
        XCTAssertTrue([128, 256, 512, 1024].contains(ultraDict), "Ultra Level 9 should be 128MB, 256MB, 512MB, or 1024MB depending on RAM (was: \(ultraDict) MB)")
    }
    
    // MARK: - 3. Custom Dictionary Override
    
    @MainActor
    func testCustomDictionaryOverride() {
        let session = CompressFormSession()
        session.compressionLevel = .level6
        XCTAssertEqual(session.effectiveDictionarySizeMB, 64)
        
        // Explicitly override with 512 MB
        session.customDictionarySizeMB = 512
        XCTAssertEqual(session.effectiveDictionarySizeMB, 512, "Explicit custom dictionary must override level default")
        
        // Explicitly override with 1024 MB (1 GB)
        session.customDictionarySizeMB = 1024
        XCTAssertEqual(session.effectiveDictionarySizeMB, 1024, "1GB custom dictionary must be accepted")
        
        // Reset to automatic
        session.customDictionarySizeMB = nil
        XCTAssertEqual(session.effectiveDictionarySizeMB, 64, "Setting customDictionarySizeMB to nil must restore level-driven automatic calculation")
    }
    
    // MARK: - 4. 7-Zip Safety Limits for Ultra Dictionaries
    
    @MainActor
    func testUltraLargeDictionarySafetyBounds() {
        let exportedSizes = CompressFormSession.supportedDictionarySizesMB
        XCTAssertEqual(exportedSizes, [16, 32, 64, 128, 256, 512, 1024, 1536])
        
        let session = CompressFormSession()
        for size in exportedSizes {
            XCTAssertLessThanOrEqual(size, 1536, "Dictionary size \(size) MB must not exceed 7-Zip LZMA2 1536 MB architecture limit")
            XCTAssertGreaterThan(size, 0, "Dictionary size \(size) MB must be positive")
            
            session.customDictionarySizeMB = size
            XCTAssertEqual(session.effectiveDictionarySizeMB, size, "Session effective dictionary size must reflect custom override \(size) MB")
        }
    }
    
    // MARK: - 5. Format Level Compatibility
    
    @MainActor
    func testFormatSupportedLevelsValidation() {
        // TAR, DMG, ISO, AAR strictly support .store only
        let pureContainers: [ArchiveCompressionFormat] = [.tar, .dmg, .iso, .aar]
        for fmt in pureContainers {
            XCTAssertEqual(fmt.supportedLevels, [.store], "Pure container format \(fmt.rawValue) must only support .store")
        }
        
        // 7Z and ZSTD support multi-level (.store, .level1, .level6, .level9)
        XCTAssertTrue(ArchiveCompressionFormat.sevenZip.supportedLevels.contains(.store))
        XCTAssertTrue(ArchiveCompressionFormat.sevenZip.supportedLevels.contains(.level9))
        XCTAssertTrue(ArchiveCompressionFormat.zst.supportedLevels.contains(.store))
        XCTAssertTrue(ArchiveCompressionFormat.zst.supportedLevels.contains(.level9))
    }
    
    // MARK: - 6. i18n Completeness for All New Keys Across 7 Locales
    
    func testI18nCompletenessAcrossAll7Locales() {
        let manager = TTZipLocalizationManager.shared
        let allLanguages: [AppLanguage] = [.en, .zhHans, .zhHant, .ja, .de, .fr, .es]
        
        let newKeys: [any LocaleKeyProtocol] = [
            L10n.Compress.algorithm,
            L10n.Compress.dictAutoFormat,
            L10n.Compress.dictSpeedUnit,
            L10n.Compress.dictStandardUnit,
            L10n.Compress.dictLargeMemoryUnit,
            L10n.Compress.dictUltraUnit,
            L10n.Compress.dictPhysicalLimitUnit,
            L10n.Compress.solidArchiveDesc,
            L10n.Compress.encryptFileNames7z,
            L10n.Compress.zipMethod,
            L10n.Compress.zipMethodAes,
            L10n.Compress.zipMethodZipCrypto,
            L10n.Compress.zstdLevel,
            L10n.Compress.zstdLdm
        ]
        
        for lang in allLanguages {
            for key in newKeys {
                let localizedStr = manager.string(for: key, language: lang)
                XCTAssertFalse(
                    localizedStr.isEmpty,
                    "Key '\(key.rawKey)' must have a non-empty translation for language '\(lang.bcp47)'"
                )
            }
        }
    }

    // MARK: - 7. Full-Speed Hardware Concurrency & Split Volume Resolution

    @MainActor
    func testDefaultFullSpeedHardwareConcurrencyAndSplitVolume() {
        let session = CompressFormSession()
        XCTAssertEqual(session.cpuThreadsOption, "all", "CompressFormSession must default cpuThreadsOption to full-speed 'all'")
        XCTAssertEqual(session.cachedTotalCores, AppleSiliconTuner.shared.topology.totalCores)

        session.customVolumeValueString = "20"
        session.customVolumeUnit = "GB"
        session.calculateCustomVolume()
        XCTAssertEqual(session.splitVolumeOption, 20 * 1024 * 1024 * 1024)
        XCTAssertTrue(session.isCustomVolumeValid)

        // CW-02: Decimal custom volume, overflow protection, and invalid input gating
        session.customVolumeValueString = "1.5"
        session.customVolumeUnit = "GB"
        XCTAssertTrue(session.isCustomVolumeValid)
        XCTAssertEqual(session.splitVolumeOption, 1536 * 1024 * 1024)

        session.customVolumeValueString = "9999999999"
        session.customVolumeUnit = "GB"
        XCTAssertFalse(session.isCustomVolumeValid, "CW-02: Overflowing custom volume must be flagged invalid without crashing")
        XCTAssertNil(session.splitVolumeOption)

        session.customVolumeValueString = "0"
        XCTAssertFalse(session.isCustomVolumeValid, "CW-02: Zero custom volume must be invalid")
        XCTAssertNil(session.splitVolumeOption)
    }

    // MARK: - 8. C3 Per-Operation Outcome Delivery Across Writer, Pipeline, Command & Concurrent Targets

    func testC3PerOperationOutcomeAcrossWriterPipelineFacadeCommandAndConcurrentTargets() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_c3_outcome_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let srcFile = tmpRoot.appendingPathComponent("input.txt")
        try Data("C3_SOURCE_PAYLOAD".utf8).write(to: srcFile)

        let writer = ArchiveWriter()
        let pipeline = ArchiveOperationPipeline(writer: writer)

        let targetNormal = tmpRoot.appendingPathComponent("normal.zip")
        let targetWarn = tmpRoot.appendingPathComponent("warn.zip")
        let targetFail = tmpRoot.appendingPathComponent("fail.zip")

        let warningOutcome = ExtractionOutcome(
            status: .completedWithFailures,
            extracted: 1,
            replaced: 0,
            keptBoth: 0,
            skipped: 0,
            failed: [
                FailedItem(
                    relativePath: "/tmp/.ttzip_create_txn_1001",
                    reason: .permissionDenied,
                    errno: 13
                )
            ]
        )

        writer._createArchiveExecutorOverride = { config, _, _, _ in
            if config.outputPath == targetFail.path {
                throw TtZipError.Cancelled
            }
            try Data("COMMITTED_\(URL(fileURLWithPath: config.outputPath).lastPathComponent)".utf8)
                .write(to: URL(fileURLWithPath: config.outputPath))
            let isWarn = config.outputPath == targetWarn.path
            return CompressionReport(
                uncompressedBytes: 17,
                compressedBytes: 17,
                elapsedNanos: 1_000,
                throughputMbs: 15.0,
                spaceSavingsPct: 0.0,
                engineProvenance: "c3-test",
                outcome: isWarn ? warningOutcome : nil
            )
        }

        // 1. Concurrent creations to two different targets on the SAME ArchiveWriter & Pipeline
        async let resWarnTask = pipeline.createArchive(
            outputPath: targetWarn.path, format: .zip, inputPaths: [srcFile.path]
        )
        async let resNormalTask = pipeline.createArchive(
            outputPath: targetNormal.path, format: .zip, inputPaths: [srcFile.path]
        )
        let (resWarn, resNormal) = try await (resWarnTask, resNormalTask)

        XCTAssertEqual(resWarn.status, .completedWithFailures)
        XCTAssertEqual(resWarn.outcome?.failed.count, 1)
        XCTAssertEqual(resNormal.status, .completed)
        XCTAssertNil(resNormal.outcome, "Clean concurrent creation must not inherit another target's CompletedWithFailures outcome")
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetWarn.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetNormal.path))

        // 2. CompressCommand with post-commit cleanup warning keeps committed archive (no rollback) and records metadata
        let cmdWarn = CompressCommand(
            inputs: [srcFile.path],
            outputPath: targetWarn.path,
            format: .zip,
            archiveWriter: writer
        )
        let cmdWarnResult = try await cmdWarn.execute()
        XCTAssertTrue(cmdWarnResult.success)
        XCTAssertEqual(cmdWarnResult.metadata["outcomeStatus"], "completedWithFailures")
        XCTAssertEqual(cmdWarnResult.metadata["cleanupFailureCount"], "1")
        XCTAssertTrue(cmdWarnResult.message.contains("post-commit cleanup warning(s)"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetWarn.path))

        // 3. Pre-commit failure / cancellation throws and rolls back
        do {
            _ = try await pipeline.createArchive(
                outputPath: targetFail.path, format: .zip, inputPaths: [srcFile.path]
            )
            XCTFail("Pre-commit cancellation must throw")
        } catch let error as ArchiveError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    // MARK: - 9. C3 CompressFormSession & ArchiveOperationsQueueCenter Outcome Consumption

    @MainActor
    func testC3CompressFormSessionAndQueueCenterConsumeCompletedWithFailures() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_c3_session_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let srcFile = tmpRoot.appendingPathComponent("session_src.txt")
        try Data("SESSION_PAYLOAD".utf8).write(to: srcFile)

        let warningOutcome = ExtractionOutcome(
            status: .completedWithFailures,
            extracted: 1,
            replaced: 0,
            keptBoth: 0,
            skipped: 0,
            failed: [
                FailedItem(
                    relativePath: tmpRoot.appendingPathComponent(".ttzip_create_bak_99").path,
                    reason: .permissionDenied,
                    errno: 66
                )
            ]
        )

        let completedExpectation = expectation(description: "session compression finished")
        let session = CompressFormSession()
        session.loadInputPaths([srcFile.path])
        session.targetDirectory = tmpRoot.path
        session.outputName = "session_warn_out"
        session.selectedFormat = .zip
        session.openFinderAfterCompress = false
        session.deleteSourceAfterCompress = false
        session.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .completed && receipt.accepted {
                completedExpectation.fulfill()
            }
        }
        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            try Data("COMMITTED_SESSION_ZIP".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath,
                originalBytes: 15,
                compressedBytes: 21,
                durationSeconds: 0.01,
                throughputMBs: 10.0,
                outcome: warningOutcome
            )
        }

        session.startCompression()
        await fulfillment(of: [completedExpectation], timeout: 5.0)

        let expectedCleanupWarning = try XCTUnwrap(
            CompressionCompletedSummary.makeCleanupWarningMessage(outcome: warningOutcome)
        )
        let summary = try XCTUnwrap(session.completedSummary)
        XCTAssertEqual(summary.outcome?.status, .completedWithFailures)
        XCTAssertEqual(summary.outcome?.failed.count, 1)
        XCTAssertEqual(
            summary.cleanupWarningMessage,
            expectedCleanupWarning
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.archivePath))

        let queueRecord = try XCTUnwrap(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.name == "session_warn_out.zip" })
        )
        XCTAssertEqual(queueRecord.state, .completed)
        XCTAssertEqual(
            queueRecord.warningMessage,
            expectedCleanupWarning
        )
    }

    // MARK: - 10. Source Preservation & Result Consumption Remediation Matrix (D-03a + U1)

    @MainActor
    func testD03aPreservesSourceFilesWhenDeleteSourceAfterCompressEnabled() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_d03a_preserve_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let srcFile = tmpRoot.appendingPathComponent("precious_source.txt")
        let subDir = tmpRoot.appendingPathComponent("folder_input", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let nestedFile = subDir.appendingPathComponent("nested_doc.txt")
        try Data("PRECIOUS_FILE_BYTES".utf8).write(to: srcFile)
        try Data("NESTED_DIR_BYTES".utf8).write(to: nestedFile)

        let completedExp = expectation(description: "compression with deleteSourceAfterCompress completed")
        let session = CompressFormSession()
        session.loadInputPaths([srcFile.path, subDir.path])
        session.targetDirectory = tmpRoot.path
        session.outputName = "preserved_bundle"
        session.selectedFormat = .zip
        session.openFinderAfterCompress = false
        session.deleteSourceAfterCompress = true
        session.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .completed && receipt.accepted {
                completedExp.fulfill()
            }
        }
        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            try Data("ARCHIVE_BYTES".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath,
                originalBytes: 35,
                compressedBytes: 13,
                durationSeconds: 0.01,
                throughputMBs: 12.0
            )
        }

        session.startCompression()
        await fulfillment(of: [completedExp], timeout: 5.0)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: srcFile.path),
            "D-03a: Source file must be preserved when per-object safety proof is unavailable"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nestedFile.path),
            "D-03a: Source directory contents must be preserved when per-object safety proof is unavailable"
        )
        let summary = try XCTUnwrap(session.completedSummary)
        XCTAssertNotNil(summary.sourcePreservationNotice)
        XCTAssertNil(summary.cleanupWarningMessage)
        let queueRecord = try XCTUnwrap(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.name == "preserved_bundle.zip" })
        )
        XCTAssertEqual(queueRecord.sourcePreservationNotice, summary.sourcePreservationNotice)
        XCTAssertEqual(
            queueRecord.warningMessage,
            summary.sourcePreservationNotice,
            "D-03a: Queue record must surface source preservation notice when deleteSourceAfterCompress was requested"
        )

        // Verify CompressionSummarySheetView wiring for sourcePreservationNotice only
        let sheetWithPreservation = CompressionSummarySheetView(
            archivePath: summary.archivePath,
            originalSizeBytes: summary.originalBytes,
            compressedSizeBytes: summary.compressedBytes,
            elapsedSeconds: summary.elapsedSeconds,
            throughputMBs: summary.throughputMBs,
            format: summary.format,
            isEncrypted: summary.isEncrypted,
            cleanupWarningMessage: summary.cleanupWarningMessage,
            sourcePreservationNotice: summary.sourcePreservationNotice,
            onCloseAndExplore: {}
        )
        XCTAssertTrue(sheetWithPreservation.hasNotices)
        XCTAssertEqual(sheetWithPreservation.renderedNotices, [try XCTUnwrap(summary.sourcePreservationNotice)])
    }

    @MainActor
    func testD03aExternalIntentAndCombinedCleanupWarningAndDefaultNoNotice() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_d03a_matrix_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let srcFile = tmpRoot.appendingPathComponent("intent_src.txt")
        try Data("INTENT_SOURCE_DATA".utf8).write(to: srcFile)

        let warningOutcome = ExtractionOutcome(
            status: .completedWithFailures,
            extracted: 1,
            replaced: 0,
            keptBoth: 0,
            skipped: 0,
            failed: [
                FailedItem(
                    relativePath: tmpRoot.appendingPathComponent(".ttzip_create_txn_77").path,
                    reason: .permissionDenied,
                    errno: 13
                )
            ]
        )

        // Case 1: External intent with deleteSourceAfterCompression=true + post-commit cleanup warning + openFinderAfterCompress=true
        let intentDone = expectation(description: "intent compression completed")
        var revealedPaths: [String] = []
        let session = CompressFormSession()
        session.loadInputPaths([srcFile.path])
        session.applyIntentOptions(
            CompressIntentOptions(
                presetID: nil,
                targetFormat: .zip,
                separateArchives: false,
                deleteSourceAfterCompression: true,
                customOutputPath: tmpRoot.appendingPathComponent("intent_out.zip").path,
                password: nil
            )
        )
        session.openFinderAfterCompress = true
        session.revealCompletedArchive = { out, _ in revealedPaths.append(out) }
        session.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .completed && receipt.accepted {
                intentDone.fulfill()
            }
        }
        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            try Data("INTENT_ZIP".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath,
                originalBytes: 18,
                compressedBytes: 10,
                durationSeconds: 0.01,
                throughputMBs: 15.0,
                outcome: warningOutcome
            )
        }

        session.startCompression()
        await fulfillment(of: [intentDone], timeout: 5.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: srcFile.path), "External intent must also preserve source file")
        XCTAssertEqual(revealedPaths.count, 1, "openFinderAfterCompress=true must reveal archive")
        XCTAssertTrue(session.isSummarySheetPresented, "openFinderAfterCompress=true must still present summary sheet")
        let expectedCleanupWarning = try XCTUnwrap(
            CompressionCompletedSummary.makeCleanupWarningMessage(outcome: warningOutcome)
        )
        let summaryBoth = try XCTUnwrap(session.completedSummary)
        XCTAssertNotNil(summaryBoth.sourcePreservationNotice)
        XCTAssertEqual(summaryBoth.cleanupWarningMessage, expectedCleanupWarning)

        let queueBoth = try XCTUnwrap(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.name == "intent_out.zip" })
        )
        XCTAssertEqual(queueBoth.sourcePreservationNotice, summaryBoth.sourcePreservationNotice)
        XCTAssertEqual(queueBoth.cleanupWarningMessage, summaryBoth.cleanupWarningMessage)
        XCTAssertTrue(queueBoth.warningMessage?.contains(expectedCleanupWarning) == true)

        let sheetBoth = CompressionSummarySheetView(
            archivePath: summaryBoth.archivePath,
            originalSizeBytes: summaryBoth.originalBytes,
            compressedSizeBytes: summaryBoth.compressedBytes,
            elapsedSeconds: summaryBoth.elapsedSeconds,
            throughputMBs: summaryBoth.throughputMBs,
            format: summaryBoth.format,
            isEncrypted: summaryBoth.isEncrypted,
            cleanupWarningMessage: summaryBoth.cleanupWarningMessage,
            sourcePreservationNotice: summaryBoth.sourcePreservationNotice,
            onCloseAndExplore: {}
        )
        XCTAssertTrue(sheetBoth.hasNotices)
        XCTAssertEqual(sheetBoth.renderedNotices.count, 2, "Both source preservation notice and cleanup warning must be rendered together")

        // Case 2: Default deleteSourceAfterCompress=false without cleanup warnings -> no notices
        let cleanDone = expectation(description: "clean compression completed")
        let cleanSession = CompressFormSession()
        cleanSession.loadInputPaths([srcFile.path])
        cleanSession.targetDirectory = tmpRoot.path
        cleanSession.outputName = "clean_default_out"
        cleanSession.selectedFormat = .zip
        cleanSession.openFinderAfterCompress = false
        cleanSession.deleteSourceAfterCompress = false
        cleanSession.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .completed && receipt.accepted {
                cleanDone.fulfill()
            }
        }
        cleanSession.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            try Data("CLEAN_ZIP".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath,
                originalBytes: 18,
                compressedBytes: 9,
                durationSeconds: 0.01,
                throughputMBs: 15.0
            )
        }
        cleanSession.startCompression()
        await fulfillment(of: [cleanDone], timeout: 5.0)

        let cleanSummary = try XCTUnwrap(cleanSession.completedSummary)
        XCTAssertNil(cleanSummary.sourcePreservationNotice, "Default deleteSourceAfterCompress=false must not emit source preservation notice")
        XCTAssertNil(cleanSummary.cleanupWarningMessage)
        let cleanSheet = CompressionSummarySheetView(
            archivePath: cleanSummary.archivePath,
            originalSizeBytes: cleanSummary.originalBytes,
            compressedSizeBytes: cleanSummary.compressedBytes,
            elapsedSeconds: cleanSummary.elapsedSeconds,
            throughputMBs: cleanSummary.throughputMBs,
            format: cleanSummary.format,
            isEncrypted: cleanSummary.isEncrypted,
            cleanupWarningMessage: cleanSummary.cleanupWarningMessage,
            sourcePreservationNotice: cleanSummary.sourcePreservationNotice,
            onCloseAndExplore: {}
        )
        XCTAssertFalse(cleanSheet.hasNotices)
        XCTAssertTrue(cleanSheet.renderedNotices.isEmpty)
    }

    // MARK: - 11. Intent Compression Level Wiring & Format Clamping (#417 / 4501520929)

    @MainActor
    func testApplyIntentOptionsWiresAndClampsCompressionLevel() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_intent_level_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let srcFile = tmpRoot.appendingPathComponent("payload.txt")
        try Data("LEVEL_WIRING_PAYLOAD".utf8).write(to: srcFile)

        let session = CompressFormSession()
        session.loadInputPaths([srcFile.path])

        // 1. Valid level 9 on .sevenZip takes effect on session and reaches executor
        session.applyIntentOptions(
            CompressIntentOptions(
                targetFormat: .sevenZip,
                compressionLevel: 9,
                destinationDirectoryPath: tmpRoot.path
            )
        )
        XCTAssertEqual(session.selectedFormat, .sevenZip)
        XCTAssertEqual(session.compressionLevel, .level9)
        XCTAssertEqual(session.targetDirectory, tmpRoot.path)
        XCTAssertEqual(session.outputName, "payload")

        let doneExp = expectation(description: "level 9 compression executed")
        session.openFinderAfterCompress = false
        session.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .completed && receipt.accepted {
                doneExp.fulfill()
            }
        }
        session.quickCompressExecutor = { _, outputPath, _, level, _, _, _, _, _, _ in
            try Data("level=\(level)".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath,
                originalBytes: 20,
                compressedBytes: 6,
                durationSeconds: 0.01,
                throughputMBs: 10.0
            )
        }
        session.startCompression()
        await fulfillment(of: [doneExp], timeout: 5.0)
        let summaryPath = try XCTUnwrap(session.completedSummary?.archivePath)
        let recordedMarker = try String(contentsOfFile: summaryPath, encoding: .utf8)
        XCTAssertEqual(recordedMarker, "level=\(ArchiveCompressionLevel.level9)", "Parsed intent compressionLevel must be used when creating the archive")

        // 2. Out-of-range level on store-only format (.tar) clamps to .store (0)
        session.applyIntentOptions(
            CompressIntentOptions(
                targetFormat: .tar,
                compressionLevel: 9
            )
        )
        XCTAssertEqual(session.selectedFormat, .tar)
        XCTAssertEqual(session.compressionLevel, .store)

        // 3. Excessive level on .sevenZip clamps to format's maxCompressionLevel (9)
        session.applyIntentOptions(
            CompressIntentOptions(
                targetFormat: .sevenZip,
                compressionLevel: 22
            )
        )
        XCTAssertEqual(session.selectedFormat, .sevenZip)
        XCTAssertEqual(session.compressionLevel, .level9)
    }

    @MainActor
    func testSingleFileOutputAvoidsInputCollisionAndMultiItemReportsExecutorOutputPath() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_collision_and_multi_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let gzInput = tmpRoot.appendingPathComponent("payload.gz")
        try Data("EXISTING_GZ".utf8).write(to: gzInput)

        let collisionSession = CompressFormSession()
        collisionSession.loadInputPaths([gzInput.path])
        collisionSession.targetDirectory = tmpRoot.path
        collisionSession.selectedFormat = .gz
        collisionSession.outputName = "payload.gz"

        XCTAssertEqual(collisionSession.resolvedOutputFileName, "payload.gz.gz")
        XCTAssertNotEqual(collisionSession.resolvedExecutionJobs().first?.outputPath, gzInput.path)

        let alpha = tmpRoot.appendingPathComponent("alpha.txt")
        let beta = tmpRoot.appendingPathComponent("beta.txt")
        try Data("ALPHA".utf8).write(to: alpha)
        try Data("BETA".utf8).write(to: beta)

        let doneExp = expectation(description: "multi-item compression completed")
        let multiSession = CompressFormSession()
        multiSession.loadInputPaths([alpha.path, beta.path])
        multiSession.targetDirectory = tmpRoot.path
        multiSession.selectedFormat = .sevenZip
        multiSession.createSeparateArchives = true
        multiSession.openFinderAfterCompress = false
        multiSession.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .completed && receipt.accepted {
                doneExp.fulfill()
            }
        }
        multiSession.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            let splitPath = outputPath + ".001"
            try Data("SPLIT_BYTES".utf8).write(to: URL(fileURLWithPath: splitPath))
            return ArchiveOperationResult(
                outputPath: splitPath,
                originalBytes: 5,
                compressedBytes: 5,
                durationSeconds: 0.01,
                throughputMBs: 1.0
            )
        }

        multiSession.startCompression()
        await fulfillment(of: [doneExp], timeout: 5.0)
        XCTAssertEqual(
            multiSession.completedSummary?.archivePath,
            tmpRoot.appendingPathComponent("alpha.7z.001").path
        )
    }
}
