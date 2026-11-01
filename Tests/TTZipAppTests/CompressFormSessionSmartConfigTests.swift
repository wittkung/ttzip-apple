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

    @MainActor
    func testU1CancelDoesNotMaskRealEngineOrCleanupErrorAndDetachedSessionSettlesInQueue() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_u1_err_detach_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let srcFile = tmpRoot.appendingPathComponent("u1_err.txt")
        try Data("U1_ERR".utf8).write(to: srcFile)

        // Part 1: Token cancellation followed by real engine/cleanup failure must NOT be masked as .cancelled
        let failedExp = expectation(description: "failed boundary")
        let session = CompressFormSession()
        session.loadInputPaths([srcFile.path])
        session.targetDirectory = tmpRoot.path
        session.outputName = "u1_real_err"
        session.selectedFormat = .zip
        session.openFinderAfterCompress = false
        session.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .failed {
                failedExp.fulfill()
            }
        }
        session.quickCompressExecutor = { _, _, _, _, _, _, _, _, _, token in
            token?.cancel()
            throw ArchiveError.engineFailure(code: -12, message: "Failed to clean up staging transaction after cancel")
        }

        session.startCompression()
        let errTaskId = try XCTUnwrap(session.activeSessionTaskId)
        await fulfillment(of: [failedExp], timeout: 5.0)

        let errQueueRecord = try XCTUnwrap(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == errTaskId })
        )
        XCTAssertEqual(
            errQueueRecord.state,
            .failed,
            "Real I/O or cleanup error after cancel token set must be recorded as .failed, not masked as .cancelled"
        )

        // Part 2: Form dismissal / deallocation (weak self == nil) must still settle terminal result in QueueCenter
        let workerEntered = expectation(description: "detached worker entered")
        let allowDetachedFinish = expectation(description: "allow detached finish")
        var detachedSession: CompressFormSession? = CompressFormSession()
        detachedSession?.loadInputPaths([srcFile.path])
        detachedSession?.targetDirectory = tmpRoot.path
        detachedSession?.outputName = "u1_detached_win"
        detachedSession?.selectedFormat = .zip
        detachedSession?.openFinderAfterCompress = false
        detachedSession?.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            workerEntered.fulfill()
            await XCTWaiter().fulfillment(of: [allowDetachedFinish], timeout: 5.0)
            try Data("DETACHED_OK".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath,
                originalBytes: 6,
                compressedBytes: 11,
                durationSeconds: 0.01,
                throughputMBs: 8.0
            )
        }

        detachedSession?.startCompression()
        let detachedTaskId = try XCTUnwrap(detachedSession?.activeSessionTaskId)
        weak let weakDetachedSession = detachedSession
        await fulfillment(of: [workerEntered], timeout: 5.0)

        // Simulate window/form closing by releasing the CompressFormSession reference
        detachedSession = nil
        allowDetachedFinish.fulfill()
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertNil(weakDetachedSession, "Detached CompressFormSession must not be leaked by retain cycles")
        let detachedRecord = try XCTUnwrap(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == detachedTaskId })
        )
        XCTAssertEqual(
            detachedRecord.state,
            .completed,
            "Operation owner (ArchiveOperationsQueueCenter) must settle terminal completion even if CompressFormSession was deallocated"
        )
        XCTAssertEqual(ArchiveOperationsQueueCenter.shared.bindingReleaseCount(for: detachedTaskId), 1)
    }

    @MainActor
    func testU1CancelRequestDoesNotPrematurelyReleaseResponsibilityOrOverwriteCommittedSuccess() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_u1_cancel_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let srcFile = tmpRoot.appendingPathComponent("u1_input.txt")
        try Data("U1_INPUT".utf8).write(to: srcFile)

        let workerEntered = expectation(description: "worker entered")
        let allowWorkerReturn = expectation(description: "allow worker return")
        let boundaryCompleted = expectation(description: "boundary completed")

        let session = CompressFormSession()
        session.loadInputPaths([srcFile.path])
        session.targetDirectory = tmpRoot.path
        session.outputName = "u1_committed"
        session.selectedFormat = .zip
        session.openFinderAfterCompress = false
        session.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .completed || receipt.kind == .failed {
                boundaryCompleted.fulfill()
            }
        }
        session.quickCompressExecutor = { _, outputPath, _, _, _, _, _, _, _, _ in
            workerEntered.fulfill()
            await XCTWaiter().fulfillment(of: [allowWorkerReturn], timeout: 5.0)
            try Data("COMMITTED_AFTER_CANCEL_REQ".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath,
                originalBytes: 8,
                compressedBytes: 26,
                durationSeconds: 0.02,
                throughputMBs: 5.0
            )
        }

        session.startCompression()
        await fulfillment(of: [workerEntered], timeout: 5.0)
        let taskId = try XCTUnwrap(session.activeSessionTaskId)

        // Request cancellation while worker is still active (including repeat call to verify idempotence)
        session.cancelCompression()
        session.cancelCompression()

        // Responsibility must NOT be prematurely released before worker exits
        XCTAssertTrue(session.isProcessing, "Session must stay busy until worker actually finishes")
        XCTAssertTrue(session.isCancellationRequested)
        XCTAssertEqual(session.activeSessionTaskId, taskId, "activeSessionTaskId must stay bound until terminal event")
        XCTAssertNotNil(ArchiveTaskCoordinator.shared.handle(for: taskId), "Coordinator registration must remain until worker finishes")

        // clearFinishedTasks must NOT remove an in-flight task that is still settling after cancel request
        ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
        XCTAssertNotNil(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == taskId }),
            "In-flight cancelling task must not be removed by clearFinishedTasks before worker finishes"
        )

        allowWorkerReturn.fulfill()
        await fulfillment(of: [boundaryCompleted], timeout: 5.0)

        // Committed archive completion must be preserved as completed, NOT overwritten as cancelled
        XCTAssertEqual(session.currentProgress.state, .completed)
        XCTAssertNotNil(session.completedSummary)
        XCTAssertEqual(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == taskId })?.state,
            .completed
        )
        XCTAssertEqual(ArchiveOperationsQueueCenter.shared.bindingReleaseCount(for: taskId), 1)
    }

    @MainActor
    func testD03aRealFilteredDirectoryCompressionPreservesExcludedAndIncludedSources() async throws {
        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_d03a_real_filter_\(UUID().uuidString)", isDirectory: true)
        let sourceDir = tmpRoot.appendingPathComponent("project_folder", isDirectory: true)
        let nestedDir = sourceDir.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tmpRoot)
        }

        let includedRootFile = sourceDir.appendingPathComponent("included_report.txt")
        let includedNestedFile = nestedDir.appendingPathComponent("nested_keep.txt")
        let excludedDsStore = sourceDir.appendingPathComponent(".DS_Store")
        let excludedAppleDouble = nestedDir.appendingPathComponent("._nested_keep.txt")
        try Data("INCLUDED_REPORT_CONTENT_2026".utf8).write(to: includedRootFile)
        try Data("NESTED_KEEP_CONTENT".utf8).write(to: includedNestedFile)
        try Data("FINDER_DS_STORE_METADATA_BYTES".utf8).write(to: excludedDsStore)
        try Data("APPLE_DOUBLE_RESOURCE_FORK_BYTES".utf8).write(to: excludedAppleDouble)

        let completedExp = expectation(description: "real filtered directory compression completed")
        let session = CompressFormSession(initialInputPaths: [sourceDir.path])
        session.targetDirectory = tmpRoot.path
        session.outputName = "real_filtered_archive"
        session.selectedFormat = .zip
        session.skipMacJunk = true
        session.deleteSourceAfterCompress = true
        session.openFinderAfterCompress = false
        session.onBoundaryEventEvaluated = { receipt in
            if receipt.kind == .completed && receipt.accepted {
                completedExp.fulfill()
            }
        }

        session.startCompression()
        let taskId = try XCTUnwrap(session.activeSessionTaskId)
        await fulfillment(of: [completedExp], timeout: 10.0)

        let summary = try XCTUnwrap(session.completedSummary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.archivePath))
        let inspection = try await TTZipEngineFacade.shared.inspectArchive(archivePath: summary.archivePath, password: nil)
        let entryPaths = inspection.entries.map(\.path)
        XCTAssertTrue(entryPaths.contains(where: { $0.hasSuffix("included_report.txt") }))
        XCTAssertTrue(entryPaths.contains(where: { $0.hasSuffix("subdir/nested_keep.txt") }))
        XCTAssertFalse(entryPaths.contains(where: { $0.contains(".DS_Store") }), "skipMacJunk must exclude .DS_Store from real archive")
        XCTAssertFalse(entryPaths.contains(where: { $0.contains("._nested_keep.txt") }), "skipMacJunk must exclude AppleDouble file from real archive")

        XCTAssertEqual(try Data(contentsOf: includedRootFile), Data("INCLUDED_REPORT_CONTENT_2026".utf8))
        XCTAssertEqual(try Data(contentsOf: includedNestedFile), Data("NESTED_KEEP_CONTENT".utf8))
        XCTAssertEqual(try Data(contentsOf: excludedDsStore), Data("FINDER_DS_STORE_METADATA_BYTES".utf8))
        XCTAssertEqual(try Data(contentsOf: excludedAppleDouble), Data("APPLE_DOUBLE_RESOURCE_FORK_BYTES".utf8))
        XCTAssertNotNil(summary.sourcePreservationNotice)
        XCTAssertEqual(ArchiveOperationsQueueCenter.shared.completedSummary(for: taskId), summary)
        XCTAssertTrue(ArchiveOperationsQueueCenter.shared.hasPendingResponsibility(for: taskId))
    }
}
