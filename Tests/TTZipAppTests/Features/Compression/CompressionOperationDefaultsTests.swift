// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
@testable import TTZipApp
import TTZipCore
import TTZipTaskKit

@MainActor
final class CompressionOperationDefaultsTests: XCTestCase {
    private var suiteName: String!
    private var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.metastudyline.ttzip.tests.compression.defaults.\(UUID().uuidString)"
        isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        isolatedDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        if let suiteName, let isolatedDefaults {
            isolatedDefaults.removePersistentDomain(forName: suiteName)
        }
        isolatedDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testCompressionDefaultsReloadAtNewOperationBoundaryPreservingActiveOverridesAndOngoingTask() async throws {
        let paths = try makeBoundaryOperationPaths()
        let preset = try nonSplittingBuiltInPreset()
        let session = makeSessionWithOverriddenFirstOperationAndUpdatedDefaults(
            paths: paths,
            preset: preset
        )
        let probe = wireBoundaryOperationProbe(for: session, firstOutputPath: paths.firstOutput.path)
        defer { probe.harness.releaseFirst() }

        session.startCompression()
        let firstTaskId = try XCTUnwrap(session.activeSessionTaskId)
        probe.firstTaskId = firstTaskId
        let firstEntered = await probe.harness.waitUntilFirstEntered(timeoutSeconds: 5.0)
        XCTAssertTrue(firstEntered, "First compression operation did not enter executor before timeout")
        guard firstEntered else { return }

        session.loadInputPaths([paths.secondInput.path])
        session.targetDirectory = paths.directory.path
        session.outputName = "second_op"
        XCTAssertNil(session.selectedPresetID)
        XCTAssertEqual(session.selectedFormat, .tarZst)
        XCTAssertEqual(
            session.compressionLevel,
            CompressionDefaultsSnapshot.clampedLevel(.level9, for: .tarZst)
        )
        XCTAssertEqual(session.zstdLevel, ZstdFormatOptions().zstdLevel)
        XCTAssertEqual(session.makeAdvancedOptions().zstdLevel, ZstdFormatOptions().zstdLevel)
        XCTAssertFalse(session.skipMacJunk)
        XCTAssertTrue(session.openFinderAfterCompress)
        XCTAssertFalse(session.hasUserOverriddenRecommendation)

        session.startCompression()
        let secondTaskId = try XCTUnwrap(session.activeSessionTaskId)
        probe.secondTaskId = secondTaskId
        await fulfillment(of: [probe.secondSettled], timeout: 5.0)
        probe.harness.releaseFirst()
        await fulfillment(of: [probe.firstSettled], timeout: 5.0)

        try assertSequentialBoundaryResults(
            probe: probe,
            paths: paths,
            firstTaskId: firstTaskId,
            secondTaskId: secondTaskId
        )
    }

    func testCompressionDefaultsReloadWhenPopulatingEmptySessionViaAddPathsOrAfterClear() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipCompressionDefaultsClear-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let firstInput = tempDir.appendingPathComponent("one.txt")
        let secondInput = tempDir.appendingPathComponent("two.txt")
        try Data("one".utf8).write(to: firstInput)
        try Data("two".utf8).write(to: secondInput)

        let fallbackOpenFinder = !RootFolderAccessManager.isIsolatedVerificationProcess
        let defaultsStore = CompressionDefaultsStore(
            defaults: isolatedDefaults,
            defaultOpenFinder: fallbackOpenFinder
        )
        let session = CompressFormSession(defaults: isolatedDefaults)
        let preset = try nonSplittingBuiltInPreset()

        defaultsStore.defaultFormat = .zip
        defaultsStore.defaultTier = .maximum
        defaultsStore.skipMacJunk = false
        defaultsStore.openFinderAfterCompress = false

        session.addPaths([firstInput.path])
        XCTAssertEqual(session.selectedFormat, .zip)
        XCTAssertEqual(
            session.compressionLevel,
            CompressionDefaultsSnapshot.clampedLevel(.level7, for: .zip)
        )
        XCTAssertFalse(session.skipMacJunk)
        XCTAssertFalse(session.openFinderAfterCompress)
        XCTAssertFalse(session.hasUserOverriddenRecommendation)

        selectPresetThroughMenuChange(preset.id, on: session)
        session.selectedFormat = .sevenZip
        session.compressionLevel = .store
        session.zstdLevel = 19
        session.skipMacJunk = true
        session.openFinderAfterCompress = false

        session.clearAllItems()
        defaultsStore.defaultFormat = .tarGz
        defaultsStore.defaultTier = .fastest
        defaultsStore.skipMacJunk = false
        defaultsStore.openFinderAfterCompress = true

        session.addPaths([secondInput.path])
        XCTAssertEqual(session.selectedFormat, .tarGz)
        XCTAssertEqual(
            session.compressionLevel,
            CompressionDefaultsSnapshot.clampedLevel(.level1, for: .tarGz)
        )
        XCTAssertFalse(session.skipMacJunk)
        XCTAssertTrue(session.openFinderAfterCompress)
        XCTAssertFalse(session.hasUserOverriddenRecommendation)

        assertPresetReapplicationAndFastestTarZstReset(
            session: session,
            defaultsStore: defaultsStore,
            inputPath: firstInput.path,
            preset: preset
        )
    }

    func testCompressionDefaultsSequentialHarnessBoundsMissingArrivalAndReleasesGateOnEarlyExit() async {
        let unenteredHarness = SequentialCompressHarness()
        let arrived = await unenteredHarness.waitUntilFirstEntered(timeoutSeconds: 0.03)
        XCTAssertFalse(arrived)

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await Task.yield()
                    return await unenteredHarness.waitUntilFirstEntered(timeoutSeconds: 0.001)
                }
            }
            for await childArrived in group {
                XCTAssertFalse(childArrived)
            }
        }

        let cancelledWait = Task {
            await unenteredHarness.waitUntilFirstEntered(timeoutSeconds: 5.0)
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        cancelledWait.cancel()
        let cancelledResult = await cancelledWait.value
        XCTAssertFalse(cancelledResult)

        let earlyExitHarness = SequentialCompressHarness()
        let workerTask = Task.detached {
            earlyExitHarness.beginExecution()
            defer { earlyExitHarness.endExecution() }
            await earlyExitHarness.recordAndGateFirstIfNeeded(
                RecordedCompressExecution(
                    outputPath: "/tmp/early-exit.zip",
                    format: .zip,
                    level: .store,
                    skipMacJunk: true
                ),
                holdOutputPath: "/tmp/early-exit.zip",
                releaseTimeoutSeconds: 5.0
            )
        }
        let entered = await earlyExitHarness.waitUntilFirstEntered(timeoutSeconds: 2.0)
        XCTAssertTrue(entered)

        struct SimulatedEarlyThrow: Error {}
        do throws(SimulatedEarlyThrow) {
            defer { earlyExitHarness.releaseFirst() }
            throw SimulatedEarlyThrow()
        } catch {}

        await workerTask.value
        let drained = await earlyExitHarness.waitUntilIdle(timeoutSeconds: 2.0)
        XCTAssertTrue(drained)
        XCTAssertFalse(earlyExitHarness.didReleaseTimeOut())

        let unreleasedHarness = SequentialCompressHarness()
        await unreleasedHarness.recordAndGateFirstIfNeeded(
            RecordedCompressExecution(
                outputPath: "/tmp/unreleased.zip",
                format: .zip,
                level: .store,
                skipMacJunk: false
            ),
            holdOutputPath: "/tmp/unreleased.zip",
            releaseTimeoutSeconds: 0.03
        )
        XCTAssertTrue(unreleasedHarness.didReleaseTimeOut())
    }

    private struct BoundaryOperationPaths {
        let directory: URL
        let firstInput: URL
        let extraInput: URL
        let secondInput: URL
        let firstOutput: URL
        let secondOutput: URL
    }

    @MainActor
    private final class BoundaryOperationProbe {
        let harness = SequentialCompressHarness()
        let firstSettled: XCTestExpectation
        let secondSettled: XCTestExpectation
        var firstTaskId: UUID?
        var secondTaskId: UUID?
        var revealedPaths: [String] = []

        init(firstSettled: XCTestExpectation, secondSettled: XCTestExpectation) {
            self.firstSettled = firstSettled
            self.secondSettled = secondSettled
        }
    }

    private func makeBoundaryOperationPaths() throws -> BoundaryOperationPaths {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipCompressionDefaultsBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock { @MainActor in
            ArchiveOperationsQueueCenter.shared.acknowledgeAllPendingResults()
            ArchiveOperationsQueueCenter.shared.clearFinishedTasks()
            try? FileManager.default.removeItem(at: tempDir)
        }

        let firstInput = tempDir.appendingPathComponent("alpha.txt")
        let extraInput = tempDir.appendingPathComponent("alpha_extra.txt")
        let secondInput = tempDir.appendingPathComponent("beta.txt")
        try Data("alpha".utf8).write(to: firstInput)
        try Data("extra".utf8).write(to: extraInput)
        try Data("beta".utf8).write(to: secondInput)

        return BoundaryOperationPaths(
            directory: tempDir,
            firstInput: firstInput,
            extraInput: extraInput,
            secondInput: secondInput,
            firstOutput: tempDir.appendingPathComponent("first_op.zip"),
            secondOutput: tempDir.appendingPathComponent("second_op.tar.zst")
        )
    }

    private func nonSplittingBuiltInPreset() throws -> CompressionPreset {
        let presets = PresetManager.shared.presets
        let candidate = presets.first(where: {
            $0.splitVolumeSizeBytes == nil && $0.defaultPassword == nil && $0.format != .tarGz
        }) ?? presets.first
        return try XCTUnwrap(candidate)
    }

    private func selectPresetThroughMenuChange(
        _ presetID: UUID,
        on session: CompressFormSession
    ) {
        let previousPresetID = session.selectedPresetID
        session.selectedPresetID = presetID
        if previousPresetID != presetID {
            session.applyPreset(id: presetID)
        }
    }

    private func makeSessionWithOverriddenFirstOperationAndUpdatedDefaults(
        paths: BoundaryOperationPaths,
        preset: CompressionPreset
    ) -> CompressFormSession {
        let fallbackOpenFinder = !RootFolderAccessManager.isIsolatedVerificationProcess
        let defaultsStore = CompressionDefaultsStore(
            defaults: isolatedDefaults,
            defaultOpenFinder: fallbackOpenFinder
        )
        defaultsStore.defaultFormat = .sevenZip
        defaultsStore.defaultTier = .normal
        defaultsStore.skipMacJunk = true
        defaultsStore.openFinderAfterCompress = false

        let session = CompressFormSession(defaults: isolatedDefaults)
        XCTAssertNil(session.selectedPresetID)
        XCTAssertEqual(session.selectedFormat, .sevenZip)
        XCTAssertEqual(session.compressionLevel, .level6)
        XCTAssertEqual(session.zstdLevel, ZstdFormatOptions().zstdLevel)
        XCTAssertTrue(session.skipMacJunk)
        XCTAssertFalse(session.openFinderAfterCompress)

        session.loadInputPaths([paths.firstInput.path])
        session.targetDirectory = paths.directory.path
        session.outputName = "first_op"
        selectPresetThroughMenuChange(preset.id, on: session)
        session.selectedFormat = .zip
        session.compressionLevel = .store
        session.zstdLevel = 19
        session.skipMacJunk = true
        session.openFinderAfterCompress = false

        defaultsStore.defaultFormat = .tarZst
        defaultsStore.defaultTier = .ultra
        defaultsStore.skipMacJunk = false
        defaultsStore.openFinderAfterCompress = true

        session.addPaths([paths.extraInput.path])
        XCTAssertEqual(session.selectedPresetID, preset.id)
        XCTAssertEqual(session.selectedFormat, .zip)
        XCTAssertEqual(session.compressionLevel, .store)
        XCTAssertEqual(session.zstdLevel, 19)
        XCTAssertTrue(session.skipMacJunk)
        XCTAssertFalse(session.openFinderAfterCompress)
        return session
    }

    private func wireBoundaryOperationProbe(
        for session: CompressFormSession,
        firstOutputPath: String
    ) -> BoundaryOperationProbe {
        let firstSettled = expectation(description: "ongoing first operation settled")
        firstSettled.assertForOverFulfill = false
        let secondSettled = expectation(description: "second operation settled")
        secondSettled.assertForOverFulfill = false
        let probe = BoundaryOperationProbe(firstSettled: firstSettled, secondSettled: secondSettled)
        let harness = probe.harness

        addTeardownBlock { @MainActor in
            harness.releaseFirst()
            if session.isProcessing {
                session.cancelCompression()
            }
            _ = await harness.waitUntilIdle(timeoutSeconds: 5.0)
            let settleDeadline = Date().addingTimeInterval(1.0)
            while ArchiveOperationsQueueCenter.shared.activeTasksCount > 0 && Date() < settleDeadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        session.revealCompletedArchive = { outputPath, _ in
            probe.revealedPaths.append(outputPath)
        }
        session.quickCompressExecutor = { _, outputPath, format, level, _, _, filterOptions, advancedOptions, _, _ in
            harness.beginExecution()
            defer { harness.endExecution() }
            await harness.recordAndGateFirstIfNeeded(
                RecordedCompressExecution(
                    outputPath: outputPath,
                    format: format,
                    level: level,
                    skipMacJunk: filterOptions.skipMacJunk,
                    advancedZstdLevel: advancedOptions?.zstdLevel
                ),
                holdOutputPath: firstOutputPath
            )
            try Data("archive".utf8).write(to: URL(fileURLWithPath: outputPath))
            return ArchiveOperationResult(
                outputPath: outputPath,
                originalBytes: 10,
                compressedBytes: 7,
                durationSeconds: 0.01,
                throughputMBs: 12.0
            )
        }
        session.onBoundaryEventEvaluated = { receipt in
            guard receipt.kind == .completed || receipt.kind == .failed else { return }
            if receipt.taskId == probe.firstTaskId {
                probe.firstSettled.fulfill()
            } else if receipt.taskId == probe.secondTaskId && receipt.accepted {
                probe.secondSettled.fulfill()
            }
        }
        return probe
    }

    private func assertSequentialBoundaryResults(
        probe: BoundaryOperationProbe,
        paths: BoundaryOperationPaths,
        firstTaskId: UUID,
        secondTaskId: UUID
    ) throws {
        XCTAssertFalse(probe.harness.didReleaseTimeOut())

        let executions = probe.harness.executions()
        XCTAssertTrue(
            executions.contains(
                RecordedCompressExecution(
                    outputPath: paths.firstOutput.path,
                    format: .zip,
                    level: .store,
                    skipMacJunk: true,
                    advancedZstdLevel: 19
                )
            )
        )
        XCTAssertTrue(
            executions.contains(
                RecordedCompressExecution(
                    outputPath: paths.secondOutput.path,
                    format: .tarZst,
                    level: .level9,
                    skipMacJunk: false,
                    advancedZstdLevel: ZstdFormatOptions().zstdLevel
                )
            )
        )

        let firstQueued = try XCTUnwrap(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == firstTaskId })
        )
        let secondQueued = try XCTUnwrap(
            ArchiveOperationsQueueCenter.shared.tasks.first(where: { $0.id == secondTaskId })
        )
        XCTAssertEqual(firstQueued.state, .completed)
        XCTAssertEqual(firstQueued.completedSummary?.format, .zip)
        XCTAssertEqual(secondQueued.state, .completed)
        XCTAssertEqual(secondQueued.completedSummary?.format, .tarZst)
        if !RootFolderAccessManager.isIsolatedVerificationProcess {
            XCTAssertEqual(probe.revealedPaths, [paths.secondOutput.path])
        }
    }

    private func assertPresetReapplicationAndFastestTarZstReset(
        session: CompressFormSession,
        defaultsStore: CompressionDefaultsStore,
        inputPath: String,
        preset: CompressionPreset
    ) {
        XCTAssertNil(session.selectedPresetID)
        XCTAssertEqual(session.zstdLevel, ZstdFormatOptions().zstdLevel)
        XCTAssertEqual(session.makeAdvancedOptions().zstdLevel, ZstdFormatOptions().zstdLevel)

        selectPresetThroughMenuChange(preset.id, on: session)
        XCTAssertEqual(session.selectedPresetID, preset.id)
        XCTAssertEqual(session.selectedFormat, preset.format)
        XCTAssertEqual(session.compressionLevel, preset.level)
        XCTAssertEqual(session.skipMacJunk, preset.skipMacJunk)

        session.zstdLevel = 19
        session.clearAllItems()
        defaultsStore.defaultFormat = .tarZst
        defaultsStore.defaultTier = .fastest

        session.addPaths([inputPath])
        XCTAssertNil(session.selectedPresetID)
        XCTAssertEqual(session.selectedFormat, .tarZst)
        XCTAssertEqual(session.compressionLevel, .level1)
        XCTAssertEqual(session.zstdLevel, ZstdFormatOptions().zstdLevel)
        XCTAssertEqual(session.makeAdvancedOptions().zstdLevel, ZstdFormatOptions().zstdLevel)

        session.clearAllItems()
        session.zstdLevel = 19
        session.addPaths([inputPath])
        XCTAssertEqual(session.zstdLevel, 19)
        XCTAssertEqual(session.makeAdvancedOptions().zstdLevel, 19)

        session.clearAllItems()
        defaultsStore.defaultFormat = preset.format
        defaultsStore.defaultTier = .normal
        defaultsStore.skipMacJunk = preset.skipMacJunk
        session.addPaths([inputPath])
        XCTAssertEqual(session.zstdLevel, ZstdFormatOptions().zstdLevel)
        session.clearAllItems()
        selectPresetThroughMenuChange(preset.id, on: session)
        session.addPaths([inputPath])
        XCTAssertEqual(session.selectedPresetID, preset.id)
    }
}
