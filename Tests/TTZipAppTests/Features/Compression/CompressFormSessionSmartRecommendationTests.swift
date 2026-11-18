// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import TTZipUI
@testable import TTZipCore
@testable import TTZipApp

final class CompressFormSessionSmartRecommendationTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_smart_rec_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.tempRoot = root
    }

    override func tearDownWithError() throws {
        if let root = tempRoot {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    private func writeCompressibleTextFile(name: String = "compressible.txt", repeatCount: Int = 1200) throws -> URL {
        let line = "The quick brown fox jumps over the lazy dog. TTZip structured compressible text payload.\n"
        let payload = String(repeating: line, count: repeatCount)
        let url = tempRoot.appendingPathComponent(name)
        try Data(payload.utf8).write(to: url)
        return url
    }

    private func writeHighEntropyFile(name: String = "random.bin", byteCount: Int = 65536) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var state: UInt64 = 0x853c_49e6_748f_ea9b
        for idx in 0..<byteCount {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[idx] = UInt8((state >> 32) & 0xFF)
        }
        let url = tempRoot.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: - 1. Compressible Text Payload Across Scenarios

    @MainActor
    func testCompressibleTextPayloadAcrossScenariosWithSevenZipAndZstd() async throws {
        let fileURL = try writeCompressibleTextFile()
        let session = CompressFormSession(initialInputPaths: [fileURL.path])
        session.selectedFormat = .sevenZip

        session.smartScenario = .instantTransfer
        let instantState = await session.evaluateSmartRecommendation()
        guard case .ready(let instantRec) = instantState else {
            return XCTFail("Expected .ready for instantTransfer, got \(instantState)")
        }
        XCTAssertEqual(instantRec.scenario, .instantTransfer)
        XCTAssertTrue(["Zstandard", "LZ4"].contains(instantRec.rawRecommendedCodec))
        XCTAssertLessThan(instantRec.measuredEntropy, 6.0)
        XCTAssertGreaterThan(instantRec.sampleBytesCount, 0)
        XCTAssertEqual(instantRec.recommendedFormat, .sevenZip)
        XCTAssertEqual(instantRec.recommendedLevel, .level1)
        XCTAssertEqual(instantRec.recommendedAlgorithm, "LZMA2")
        XCTAssertFalse(instantRec.summaryText.isEmpty)

        session.smartScenario = .balancedDaily
        let balancedState = await session.evaluateSmartRecommendation()
        guard case .ready(let balancedRec) = balancedState else {
            return XCTFail("Expected .ready for balancedDaily, got \(balancedState)")
        }
        XCTAssertEqual(balancedRec.scenario, .balancedDaily)
        XCTAssertTrue(["Zstandard", "ZIP-Deflate"].contains(balancedRec.rawRecommendedCodec))
        XCTAssertEqual(balancedRec.recommendedLevel, .level6)
        XCTAssertEqual(balancedRec.recommendedAlgorithm, "LZMA2")

        session.smartScenario = .coldStorage
        let coldState = await session.evaluateSmartRecommendation()
        guard case .ready(let coldRec) = coldState else {
            return XCTFail("Expected .ready for coldStorage, got \(coldState)")
        }
        XCTAssertEqual(coldRec.scenario, .coldStorage)
        XCTAssertEqual(coldRec.rawRecommendedCodec, "7Z-LZMA2")
        XCTAssertEqual(coldRec.recommendedLevel, .level9)
        XCTAssertEqual(coldRec.recommendedAlgorithm, "LZMA2")
    }

    @MainActor
    func testCompressibleTextPayloadZstdAndZipParameterMapping() async throws {
        let fileURL = try writeCompressibleTextFile()
        let session = CompressFormSession(initialInputPaths: [fileURL.path])
        session.selectedFormat = .tarZst

        session.smartScenario = .instantTransfer
        guard case .ready(let fastZst) = await session.evaluateSmartRecommendation() else {
            return XCTFail("Expected .ready for tarZst instantTransfer")
        }
        XCTAssertEqual(fastZst.recommendedLevel, .level1)
        XCTAssertEqual(fastZst.recommendedZstdLevel, 1)

        session.smartScenario = .balancedDaily
        guard case .ready(let balancedZst) = await session.evaluateSmartRecommendation() else {
            return XCTFail("Expected .ready for tarZst balancedDaily")
        }
        XCTAssertEqual(balancedZst.recommendedLevel, .level3)
        XCTAssertEqual(balancedZst.recommendedZstdLevel, 3)

        session.smartScenario = .coldStorage
        guard case .ready(let coldZst) = await session.evaluateSmartRecommendation() else {
            return XCTFail("Expected .ready for tarZst coldStorage")
        }
        XCTAssertEqual(coldZst.recommendedLevel, .level9)
        XCTAssertEqual(coldZst.recommendedZstdLevel, 19)

        session.selectedFormat = .zip
        session.smartScenario = .coldStorage
        guard case .ready(let coldZip) = await session.evaluateSmartRecommendation() else {
            return XCTFail("Expected .ready for zip coldStorage")
        }
        XCTAssertEqual(coldZip.recommendedFormat, .zip)
        XCTAssertEqual(coldZip.recommendedLevel, .level9)
    }

    // MARK: - 2. High-Entropy Incompressible Payload Recommends Store

    @MainActor
    func testHighEntropyPayloadRecommendsStoreAndZeroDictionary() async throws {
        let randomURL = try writeHighEntropyFile()
        let session = CompressFormSession(initialInputPaths: [randomURL.path])
        session.selectedFormat = .sevenZip
        session.compressionLevel = .level9
        session.smartScenario = .coldStorage

        let state = await session.evaluateSmartRecommendation()
        guard case .ready(let rec) = state else {
            return XCTFail("Expected .ready for high-entropy file, got \(state)")
        }
        XCTAssertEqual(rec.rawRecommendedCodec, "Store")
        XCTAssertGreaterThan(rec.measuredEntropy, 7.92)
        XCTAssertEqual(rec.recommendedLevel, .store)
        XCTAssertEqual(rec.recommendedAlgorithm, "Copy")

        XCTAssertEqual(session.compressionLevel, .level9)
        session.applySmartRecommendation()
        XCTAssertEqual(session.compressionLevel, .store)
        let resolved = session.resolvedAdvancedOptionsForCurrentState()
        XCTAssertEqual(resolved.algorithm, "Copy")
        XCTAssertEqual(resolved.dictionarySizeMB, 0)
        XCTAssertFalse(resolved.enableSolidArchive)
    }

    // MARK: - 3. Pure-Container & Multi-Level Format Clamping

    @MainActor
    func testPureContainerFormatsClampToStoreAndNeverProduceInvalidCombinations() async throws {
        let fileURL = try writeCompressibleTextFile()
        let session = CompressFormSession(initialInputPaths: [fileURL.path])
        session.smartScenario = .coldStorage

        for pureFormat in [ArchiveCompressionFormat.tar, .iso, .aar] {
            session.selectedFormat = pureFormat
            session.compressionLevel = .level9
            session.compressionAlgorithm = "LZMA2"

            guard case .ready(let rec) = await session.evaluateSmartRecommendation() else {
                return XCTFail("Expected .ready for pure container \(pureFormat.rawValue)")
            }
            XCTAssertEqual(rec.recommendedFormat, pureFormat)
            XCTAssertEqual(rec.recommendedLevel, .store)
            XCTAssertEqual(rec.recommendedAlgorithm, "Copy")

            session.applySmartRecommendation()
            XCTAssertEqual(session.compressionLevel, .store)
            XCTAssertEqual(session.compressionAlgorithm, "Copy")
            XCTAssertEqual(session.resolvedAdvancedOptionsForCurrentState().algorithm, "Copy")
        }

        for multiFormat in [ArchiveCompressionFormat.tarGz, .tarBz2, .tarXz] {
            session.selectedFormat = multiFormat
            guard case .ready(let rec) = await session.evaluateSmartRecommendation() else {
                return XCTFail("Expected .ready for \(multiFormat.rawValue)")
            }
            XCTAssertTrue(multiFormat.supportedLevels.contains(rec.recommendedLevel))
        }
    }

    // MARK: - 4. User Override Preservation After Applying Recommendation

    @MainActor
    func testUserOverrideAfterApplyingRecommendationPreservesExplicitParameters() async throws {
        ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
        ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
        defer {
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
        }

        let fileURL = try writeCompressibleTextFile()
        let session = CompressFormSession(initialInputPaths: [fileURL.path])
        session.targetDirectory = tempRoot.path
        session.outputName = "OverrideCheck"
        session.selectedFormat = .sevenZip
        session.compressionLevel = .level6
        session.compressionAlgorithm = "LZMA2"
        session.smartScenario = .coldStorage

        _ = await session.evaluateSmartRecommendation()
        XCTAssertEqual(session.compressionLevel, .level6)
        XCTAssertFalse(session.hasUserOverriddenRecommendation)

        session.applySmartRecommendation()
        XCTAssertEqual(session.compressionLevel, .level9)
        XCTAssertEqual(session.compressionAlgorithm, "LZMA2")
        XCTAssertFalse(session.hasUserOverriddenRecommendation)

        session.compressionLevel = .level1
        session.compressionAlgorithm = "BZip2"
        session.zstdLevel = 9
        XCTAssertTrue(session.hasUserOverriddenRecommendation)

        let resolved = session.resolvedAdvancedOptionsForCurrentState()
        XCTAssertEqual(resolved.algorithm, "BZip2")
        XCTAssertEqual(resolved.zstdLevel, 9)

        let capture = QuickCompressCaptureActor()
        session.revealCompletedArchive = { _, _ in }
        session.quickCompressExecutor = { _, outPath, _, level, _, _, _, adv, _, _ in
            await capture.record(level: level, advanced: adv)
            return ArchiveOperationResult(
                outputPath: outPath,
                originalBytes: 1024,
                compressedBytes: 512,
                durationSeconds: 0.01,
                throughputMBs: 100.0
            )
        }

        session.startCompression()
        await session.activeCompressionTask?.value

        let capturedLevel = await capture.capturedLevel
        let capturedAdvanced = await capture.capturedAdvanced
        XCTAssertEqual(capturedLevel, .level1)
        XCTAssertEqual(capturedAdvanced?.algorithm, "BZip2")
        XCTAssertEqual(capturedAdvanced?.zstdLevel, 9)
    }

    // MARK: - 5. Bounded Sampling, Error Handling, Cancellation & Stale Discard

    @MainActor
    func testBoundedSamplingReadsAtMost256KBFromLargeFile() async throws {
        let largeURL = tempRoot.appendingPathComponent("large.txt")
        let chunk = Data(repeating: 0x41, count: 1024)
        FileManager.default.createFile(atPath: largeURL.path, contents: nil)
        let writer = try FileHandle(forWritingTo: largeURL)
        for _ in 0..<(1024) {
            try writer.write(contentsOf: chunk)
        }
        try writer.close()

        let session = CompressFormSession(initialInputPaths: [largeURL.path])
        guard case .ready(let rec) = await session.evaluateSmartRecommendation() else {
            return XCTFail("Expected .ready for 1MB file")
        }
        XCTAssertEqual(rec.sampleBytesCount, CompressFormSession.maxRecommendationSampleBytes)
    }

    @MainActor
    func testEmptyAndUnreadableInputTransitionsToFailedState() async throws {
        let emptyURL = tempRoot.appendingPathComponent("empty.txt")
        try Data().write(to: emptyURL)

        let session = CompressFormSession(initialInputPaths: [emptyURL.path])
        let emptyState = await session.evaluateSmartRecommendation()
        guard case .failed(let emptyMsg) = emptyState else {
            return XCTFail("Expected .failed for empty file, got \(emptyState)")
        }
        XCTAssertFalse(emptyMsg.isEmpty)

        let missingPath = tempRoot.appendingPathComponent("missing.bin").path
        session.sampleDataProviderOverride = { paths, _ in
            throw SmartRecommendationSampleError.unreadableInput(paths.first ?? missingPath)
        }
        let unreadableState = await session.evaluateSmartRecommendation()
        guard case .failed(let unreadableMsg) = unreadableState else {
            return XCTFail("Expected .failed for unreadable file, got \(unreadableState)")
        }
        XCTAssertFalse(unreadableMsg.isEmpty)
    }

    @MainActor
    func testCancellationAndStaleGenerationDiscardWhenInputsChangeMidProbe() async throws {
        let fileA = try writeCompressibleTextFile(name: "fileA.txt")
        let fileB = try writeHighEntropyFile(name: "fileB.bin")

        let session = CompressFormSession(initialInputPaths: [fileA.path])
        let gate = AsyncProbeGate()
        session.sampleDataProviderOverride = { _, _ in
            await gate.waitForRelease()
            return Data(repeating: 0x42, count: 65536)
        }

        let probeTask = session.requestSmartRecommendation()
        guard case .sampling(let gen1) = session.smartRecommendationState else {
            return XCTFail("Expected .sampling state immediately after requestSmartRecommendation()")
        }

        session.cancelSmartRecommendation()
        XCTAssertEqual(session.smartRecommendationState, .idle)
        XCTAssertGreaterThan(session.recommendationGeneration, gen1)
        await gate.release()
        await probeTask?.value
        XCTAssertEqual(session.smartRecommendationState, .idle)

        let gate2 = AsyncProbeGate()
        session.sampleDataProviderOverride = { _, _ in
            await gate2.waitForRelease()
            return Data(repeating: 0x42, count: 65536)
        }
        let staleTask = session.requestSmartRecommendation()
        guard case .sampling(let gen2) = session.smartRecommendationState else {
            return XCTFail("Expected second .sampling state")
        }

        session.sampleDataProviderOverride = nil
        session.loadInputPaths([fileB.path])
        XCTAssertGreaterThan(session.recommendationGeneration, gen2)
        XCTAssertEqual(session.smartRecommendationState, .idle)

        await gate2.release()
        await staleTask?.value
        XCTAssertEqual(session.smartRecommendationState, .idle)
    }

    // MARK: - 6. Issue #178 Recovery Record Eligibility, State & Pipeline Tests

    @MainActor
    func testRecoveryRecordFormatEligibilityAndSessionStateReset() throws {
        let inputURL = try writeCompressibleTextFile(name: "recovery_input.txt")
        XCTAssertTrue(ArchiveCompressionFormat.zip.supportsRecoveryRecord)
        XCTAssertTrue(ArchiveCompressionFormat.sevenZip.supportsRecoveryRecord)
        XCTAssertTrue(ArchiveCompressionFormat.tar.supportsRecoveryRecord)
        XCTAssertFalse(ArchiveCompressionFormat.tarGz.supportsRecoveryRecord)
        XCTAssertFalse(ArchiveCompressionFormat.gz.supportsRecoveryRecord)

        let session = CompressFormSession(initialInputPaths: [inputURL.path])
        session.selectedFormat = .zip
        XCTAssertEqual(session.recoveryRecordRedundancyPercent, 0)
        XCTAssertTrue(session.canEnableRecoveryRecord)
        XCTAssertEqual(CompressFormSession.supportedRecoveryRedundancyPercents, [0, 3, 5, 10, 20])

        session.recoveryRecordRedundancyPercent = 5
        XCTAssertEqual(session.makeAdvancedOptions().recoveryRecordRedundancyPercent, 5)

        session.selectedFormat = .tarGz
        session.reconcileSelectedFormatWithInputs()
        XCTAssertFalse(session.canEnableRecoveryRecord)
        XCTAssertEqual(session.recoveryRecordRedundancyPercent, 0)
        XCTAssertEqual(session.makeAdvancedOptions().recoveryRecordRedundancyPercent, 0)

        session.selectedFormat = .sevenZip
        session.reconcileSelectedFormatWithInputs()
        XCTAssertTrue(session.canEnableRecoveryRecord)
        session.recoveryRecordRedundancyPercent = 3
        XCTAssertEqual(session.makeAdvancedOptions().recoveryRecordRedundancyPercent, 3)

        session.splitVolumeOption = 100 * 1024 * 1024
        XCTAssertFalse(session.canEnableRecoveryRecord)
        XCTAssertEqual(session.recoveryRecordRedundancyPercent, 0)
        session.splitVolumeOption = nil
        session.recoveryRecordRedundancyPercent = 10
        session.isCustomVolumeSelected = true
        XCTAssertFalse(session.canEnableRecoveryRecord)
        XCTAssertEqual(session.recoveryRecordRedundancyPercent, 0)
    }

    @MainActor
    func testCancelSmartRecommendationPropagatesIntoDetachedSampler() async throws {
        let inputURL = tempRoot.appendingPathComponent("cancel-detached.txt")
        try Data(repeating: 0x41, count: 1024).write(to: inputURL)
        let session = CompressFormSession()
        session.loadInputPaths([inputURL.path])

        let enteredSampler = expectation(description: "Detached sampler started")
        let observedCancel = expectation(description: "Detached sampler observed Task.isCancelled")
        session.sampleDataProviderOverride = { _, _ in
            enteredSampler.fulfill()
            for _ in 0..<200 {
                if Task.isCancelled {
                    observedCancel.fulfill()
                    throw CancellationError()
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return Data(repeating: 0x41, count: 64)
        }

        let task = try XCTUnwrap(session.requestSmartRecommendation())
        await fulfillment(of: [enteredSampler], timeout: 2.0)
        session.cancelSmartRecommendation()
        await fulfillment(of: [observedCancel], timeout: 2.0)
        await task.value
        XCTAssertEqual(session.smartRecommendationState, .idle)
    }
}

private actor QuickCompressCaptureActor {
    private(set) var capturedLevel: ArchiveCompressionLevel?
    private(set) var capturedAdvanced: ArchiveAdvancedOptions?

    func record(level: ArchiveCompressionLevel, advanced: ArchiveAdvancedOptions?) {
        self.capturedLevel = level
        self.capturedAdvanced = advanced
    }
}

private actor AsyncProbeGate {
    private var isReleased = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
