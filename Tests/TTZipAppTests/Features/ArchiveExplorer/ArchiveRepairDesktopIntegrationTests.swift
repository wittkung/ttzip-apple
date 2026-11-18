// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
@testable import TTZipApp
@testable import TTZipCore

@MainActor
final class ArchiveRepairDesktopIntegrationTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveRepairDesktopTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempDir = base
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    func testRepairIntentParsingAndDispatcherOpensIntegrityModal() throws {
        let archivePath = tempDir.appendingPathComponent("corrupt_sample.zip").path
        FileManager.default.createFile(atPath: archivePath, contents: Data("PK\u{03}\u{04}broken".utf8))

        let cliEnvelope = try XCTUnwrap(
            AppIntentParser.parse(arguments: ["TTZip", "--repair", archivePath])
        )
        XCTAssertEqual(cliEnvelope.intent, .repairArchive(archivePath: archivePath, outputPath: nil))

        let encodedPath = archivePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? archivePath
        let url = try XCTUnwrap(URL(string: "ttzip://action?type=repair_archive&path=\(encodedPath)"))
        let urlEnvelope = try XCTUnwrap(AppIntentParser.parse(url: url))
        XCTAssertEqual(urlEnvelope.intent, .repairArchive(archivePath: archivePath, outputPath: nil))

        let state = AppViewState()
        AppIntentDispatcher.shared.bind(state: state)
        defer { AppIntentDispatcher.shared.unregister(windowID: state.windowID) }

        let dispatchResult = AppIntentDispatcher.shared.dispatch(cliEnvelope, targetWindowID: state.windowID)
        XCTAssertEqual(dispatchResult, .success)
        XCTAssertEqual(state.overlayState.integrityArchivePath, archivePath)
        XCTAssertTrue(state.overlayState.showArchiveIntegrityModal)
    }

    func testDamagedZipFullAndPartialRecoveryThroughViewModel() async throws {
        let fullDamagedZip = try await makeTruncatedCentralDirectoryZip(
            named: "truncated_cd.zip",
            entries: [
                ("alpha.txt", "Alpha intact payload content"),
                ("beta.txt", "Beta intact payload content")
            ]
        )
        let originalFullBytes = try Data(contentsOf: fullDamagedZip)
        let vm = ArchiveIntegrityViewModel()
        await vm.runIntegrityCheck(archivePath: fullDamagedZip.path)
        XCTAssertTrue(vm.canRepairArchive)

        let fullOutcome = try await vm.repairArchive(damagedPath: fullDamagedZip.path)
        let expectedFullOut = ArchiveIntegrityViewModel.defaultRepairedOutputPath(for: fullDamagedZip.path)
        guard case .fullSuccess(let outPath, let count, let entries, _) = fullOutcome else {
            return XCTFail("Expected .fullSuccess for truncated central directory ZIP, got \(fullOutcome)")
        }
        XCTAssertEqual(outPath, expectedFullOut)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Set(entries), Set(["alpha.txt", "beta.txt"]))
        XCTAssertEqual(try Data(contentsOf: fullDamagedZip), originalFullBytes)

        let extractDir = tempDir.appendingPathComponent("extracted_full_zip", isDirectory: true)
        _ = try await TTZipEngineFacade.shared.quickExtract(archivePath: outPath, destinationDir: extractDir.path)
        XCTAssertEqual(try readExtractedFile(in: extractDir, named: "alpha.txt"), "Alpha intact payload content")
        XCTAssertEqual(try readExtractedFile(in: extractDir, named: "beta.txt"), "Beta intact payload content")

        let partialDamagedZip = try await makeSingleEntryPayloadCorruptedZip(
            named: "partial_corrupt.zip",
            intactEntry: ("intact.txt", "Surviving payload text"),
            corruptedEntry: ("damaged.txt", "Payload that will be corrupted in place")
        )
        let originalPartialBytes = try Data(contentsOf: partialDamagedZip)
        let partialOutcome = try await vm.repairArchive(damagedPath: partialDamagedZip.path)
        guard case .partialRecovery(let partialOutPath, let recCount, let unrecovered, _) = partialOutcome else {
            return XCTFail("Expected .partialRecovery for single-entry payload corruption, got \(partialOutcome)")
        }
        XCTAssertEqual(recCount, 1)
        XCTAssertEqual(unrecovered, ["damaged.txt"])
        XCTAssertEqual(try Data(contentsOf: partialDamagedZip), originalPartialBytes)

        let partialExtractDir = tempDir.appendingPathComponent("extracted_partial_zip", isDirectory: true)
        _ = try await TTZipEngineFacade.shared.quickExtract(
            archivePath: partialOutPath,
            destinationDir: partialExtractDir.path
        )
        XCTAssertEqual(try readExtractedFile(in: partialExtractDir, named: "intact.txt"), "Surviving payload text")
    }

    func testDamagedTarFullAndPartialRecoveryThroughViewModel() async throws {
        let fullDamagedTar = try makeDamagedTarArchive(
            named: "damaged_full.tar",
            entries: [
                ("first.txt", "First TAR file content"),
                ("second.txt", "Second TAR file content")
            ],
            corruptSecondHeaderChecksum: false,
            appendTrailingGarbageBlock: true
        )
        let originalTarBytes = try Data(contentsOf: fullDamagedTar)
        let vm = ArchiveIntegrityViewModel()

        let fullOutcome = try await vm.repairArchive(damagedPath: fullDamagedTar.path)
        let expectedTarOut = ArchiveIntegrityViewModel.defaultRepairedOutputPath(for: fullDamagedTar.path)
        guard case .fullSuccess(let outPath, let count, let entries, _) = fullOutcome else {
            return XCTFail("Expected .fullSuccess for TAR with trailing garbage block, got \(fullOutcome)")
        }
        XCTAssertEqual(outPath, expectedTarOut)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Set(entries), Set(["first.txt", "second.txt"]))
        XCTAssertEqual(try Data(contentsOf: fullDamagedTar), originalTarBytes)

        let tarExtractDir = tempDir.appendingPathComponent("extracted_full_tar", isDirectory: true)
        _ = try await TTZipEngineFacade.shared.quickExtract(archivePath: outPath, destinationDir: tarExtractDir.path)
        XCTAssertEqual(try readExtractedFile(in: tarExtractDir, named: "first.txt"), "First TAR file content")
        XCTAssertEqual(try readExtractedFile(in: tarExtractDir, named: "second.txt"), "Second TAR file content")

        let partialDamagedTar = try makeDamagedTarArchive(
            named: "damaged_partial.tar",
            entries: [
                ("first.txt", "First TAR surviving payload"),
                ("corrupt_second.txt", "Second TAR payload with broken header checksum")
            ],
            corruptSecondHeaderChecksum: true,
            appendTrailingGarbageBlock: false
        )
        let partialOutcome = try await vm.repairArchive(damagedPath: partialDamagedTar.path)
        guard case .partialRecovery(let partialOut, let recCount, let unrecovered, _) = partialOutcome else {
            return XCTFail("Expected .partialRecovery for TAR with broken second header, got \(partialOutcome)")
        }
        XCTAssertEqual(recCount, 1)
        XCTAssertEqual(unrecovered, ["corrupt_second.txt"])

        let partialExtractDir = tempDir.appendingPathComponent("extracted_partial_tar", isDirectory: true)
        _ = try await TTZipEngineFacade.shared.quickExtract(
            archivePath: partialOut,
            destinationDir: partialExtractDir.path
        )
        XCTAssertEqual(try readExtractedFile(in: partialExtractDir, named: "first.txt"), "First TAR surviving payload")
    }

    func testSourceProtectionRejectsSameOutputPathWithoutModifyingSource() async throws {
        let damagedZip = try await makeTruncatedCentralDirectoryZip(
            named: "source_guard.zip",
            entries: [("only.txt", "Do not overwrite source")]
        )
        let originalBytes = try Data(contentsOf: damagedZip)
        let vm = ArchiveIntegrityViewModel()

        do {
            _ = try await vm.repairArchive(damagedPath: damagedZip.path, outputPath: damagedZip.path)
            XCTFail("Expected outputMatchesSource error when outputPath equals damagedPath")
        } catch let error as ArchiveRepairError {
            XCTAssertEqual(error, .outputMatchesSource)
        }

        let nonNormalizedSamePath = damagedZip.deletingLastPathComponent()
            .appendingPathComponent("./source_guard.zip").path
        do {
            _ = try await vm.repairArchive(damagedPath: damagedZip.path, outputPath: nonNormalizedSamePath)
            XCTFail("Expected outputMatchesSource error for non-normalized equivalent path")
        } catch let error as ArchiveRepairError {
            XCTAssertEqual(error, .outputMatchesSource)
        }

        XCTAssertEqual(try Data(contentsOf: damagedZip), originalBytes)
    }

    func testExistingTargetProtectionRequiresConfirmationAndPreservesOnCancel() async throws {
        let damagedZip = try await makeTruncatedCentralDirectoryZip(
            named: "needs_confirm.zip",
            entries: [("recovered.txt", "Recovered content after confirmation")]
        )
        let existingTarget = tempDir.appendingPathComponent("needs_confirm_repaired.zip")
        let sentinelBytes = Data("Pre-existing user target file".utf8)
        try sentinelBytes.write(to: existingTarget, options: .atomic)

        let vm = ArchiveIntegrityViewModel()
        do {
            _ = try await vm.repairArchive(
                damagedPath: damagedZip.path,
                outputPath: existingTarget.path,
                policy: .requireConfirmation
            )
            XCTFail("Expected overwriteConfirmationRequired when destination exists")
        } catch let error as ArchiveRepairError {
            XCTAssertEqual(error, .overwriteConfirmationRequired(existingOutputPath: existingTarget.path))
        }

        XCTAssertEqual(
            vm.repairPhase,
            .awaitingOverwriteConfirmation(existingOutputPath: existingTarget.path)
        )
        XCTAssertEqual(try Data(contentsOf: existingTarget), sentinelBytes)

        vm.cancelRepair()
        XCTAssertEqual(vm.repairPhase, .cancelled)
        XCTAssertEqual(try Data(contentsOf: existingTarget), sentinelBytes)

        _ = try? await vm.repairArchive(
            damagedPath: damagedZip.path,
            outputPath: existingTarget.path,
            policy: .requireConfirmation
        )
        XCTAssertEqual(
            vm.repairPhase,
            .awaitingOverwriteConfirmation(existingOutputPath: existingTarget.path)
        )

        let confirmedOutcome = try await vm.confirmOverwriteAndRepair()
        guard case .fullSuccess(let outPath, let count, _, _) = confirmedOutcome else {
            return XCTFail("Expected .fullSuccess after overwrite confirmation, got \(confirmedOutcome)")
        }
        XCTAssertEqual(outPath, existingTarget.path)
        XCTAssertEqual(count, 1)
        XCTAssertNotEqual(try Data(contentsOf: existingTarget), sentinelBytes)
    }

    func testFailureAndMidFlightCancellationPreserveExistingTargetAndCleanStaging() async throws {
        let unrecoverableFile = tempDir.appendingPathComponent("unrecoverable.tar")
        let unrecoverableBytes = Data(repeating: 0xAB, count: 2048)
        try unrecoverableBytes.write(to: unrecoverableFile, options: .atomic)

        let existingTarget = tempDir.appendingPathComponent("protected_target.tar")
        let sentinelBytes = Data("Protected pre-existing archive bytes".utf8)
        try sentinelBytes.write(to: existingTarget, options: .atomic)

        let vm = ArchiveIntegrityViewModel()
        let failedOutcome = try await vm.repairArchive(
            damagedPath: unrecoverableFile.path,
            outputPath: existingTarget.path,
            policy: .overwriteConfirmed
        )
        guard case .failed = failedOutcome else {
            return XCTFail("Expected .failed outcome for unrecoverable archive, got \(failedOutcome)")
        }
        XCTAssertEqual(try Data(contentsOf: existingTarget), sentinelBytes)
        XCTAssertEqual(try Data(contentsOf: unrecoverableFile), unrecoverableBytes)

        let freshOutput = tempDir.appendingPathComponent("should_not_exist.tar")
        let freshFailedOutcome = try await vm.repairArchive(
            damagedPath: unrecoverableFile.path,
            outputPath: freshOutput.path,
            policy: .overwriteConfirmed
        )
        guard case .failed = freshFailedOutcome else {
            return XCTFail("Expected .failed outcome for fresh output path")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshOutput.path))

        let slowFacade = SlowStagingRepairFacadeStub()
        let cancelVM = ArchiveIntegrityViewModel(engineFacade: slowFacade)
        let cancelTask = Task {
            try await cancelVM.repairArchive(
                damagedPath: unrecoverableFile.path,
                outputPath: existingTarget.path,
                policy: .overwriteConfirmed
            )
        }
        await slowFacade.waitForRepairStart()
        cancelVM.cancelRepair()
        await slowFacade.resumeRepair()

        do {
            _ = try await cancelTask.value
            XCTFail("Expected repairArchive to throw repairCancelled when cancelled mid-flight")
        } catch let error as ArchiveRepairError {
            XCTAssertEqual(error, .repairCancelled)
        }
        XCTAssertEqual(cancelVM.repairPhase, .cancelled)
        XCTAssertEqual(try Data(contentsOf: existingTarget), sentinelBytes)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.contains(".ttzip-repair-staging-") }
        XCTAssertTrue(leftovers.isEmpty, "Expected no staging files left behind, found \(leftovers)")
    }

    private func makeTruncatedCentralDirectoryZip(
        named fileName: String,
        entries: [(String, String)]
    ) async throws -> URL {
        let srcDir = tempDir.appendingPathComponent("src_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        var inputPaths: [String] = []
        for (name, content) in entries {
            let fileURL = srcDir.appendingPathComponent(name)
            try Data(content.utf8).write(to: fileURL, options: .atomic)
            inputPaths.append(fileURL.path)
        }
        let zipURL = tempDir.appendingPathComponent(fileName)
        _ = try await TTZipEngineFacade.shared.quickCompress(
            inputs: inputPaths,
            outputPath: zipURL.path,
            format: .zip,
            level: .store
        )
        var bytes = try Data(contentsOf: zipURL)
        let cdSig = Data([0x50, 0x4B, 0x01, 0x02])
        if let cdRange = bytes.range(of: cdSig) {
            bytes.replaceSubrange(cdRange.lowerBound..<bytes.count, with: Data([0x00, 0x00, 0x00, 0x00]))
        }
        try bytes.write(to: zipURL, options: .atomic)
        return zipURL
    }

    private func makeSingleEntryPayloadCorruptedZip(
        named fileName: String,
        intactEntry: (String, String),
        corruptedEntry: (String, String)
    ) async throws -> URL {
        let srcDir = tempDir.appendingPathComponent("src_partial_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let intactURL = srcDir.appendingPathComponent(intactEntry.0)
        let corruptURL = srcDir.appendingPathComponent(corruptedEntry.0)
        try Data(intactEntry.1.utf8).write(to: intactURL, options: .atomic)
        try Data(corruptedEntry.1.utf8).write(to: corruptURL, options: .atomic)

        let zipURL = tempDir.appendingPathComponent(fileName)
        _ = try await TTZipEngineFacade.shared.quickCompress(
            inputs: [intactURL.path, corruptURL.path],
            outputPath: zipURL.path,
            format: .zip,
            level: .store
        )
        var bytes = try Data(contentsOf: zipURL)
        let targetPayload = Data(corruptedEntry.1.utf8)
        let range = try XCTUnwrap(bytes.range(of: targetPayload))
        bytes[range.lowerBound] ^= 0xFF
        bytes[range.lowerBound + 1] ^= 0xFF
        try bytes.write(to: zipURL, options: .atomic)
        return zipURL
    }

    private func makeDamagedTarArchive(
        named fileName: String,
        entries: [(String, String)],
        corruptSecondHeaderChecksum: Bool,
        appendTrailingGarbageBlock: Bool
    ) throws -> URL {
        var tarData = Data()
        for (idx, (name, content)) in entries.enumerated() {
            let payload = Data(content.utf8)
            var header = makePosixTarHeader(name: name, size: payload.count)
            if idx == 1 && corruptSecondHeaderChecksum {
                header[148] = UInt8(ascii: "9")
                header[149] = UInt8(ascii: "9")
            }
            tarData.append(header)
            tarData.append(payload)
            let pad = (512 - (payload.count % 512)) % 512
            if pad > 0 {
                tarData.append(Data(repeating: 0, count: pad))
            }
        }
        if appendTrailingGarbageBlock {
            tarData.append(Data(repeating: 0x7F, count: 512))
        }
        tarData.append(Data(repeating: 0, count: 1024))
        let tarURL = tempDir.appendingPathComponent(fileName)
        try tarData.write(to: tarURL, options: .atomic)
        return tarURL
    }

    private func makePosixTarHeader(name: String, size: Int) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        let nameBytes = Array(name.utf8.prefix(99))
        block.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        writeOctal(0o644, into: &block, offset: 100, length: 8)
        writeOctal(0, into: &block, offset: 108, length: 8)
        writeOctal(0, into: &block, offset: 116, length: 8)
        writeOctal(size, into: &block, offset: 124, length: 12)
        writeOctal(1_700_000_000, into: &block, offset: 136, length: 12)
        for i in 148..<156 {
            block[i] = 0x20
        }
        block[156] = UInt8(ascii: "0")
        let magic = Array("ustar\000".utf8)
        block.replaceSubrange(257..<(257 + magic.count), with: magic)
        let checksum = block.reduce(0) { $0 + Int($1) }
        let chkStr = String(format: "%06o\0 ", checksum)
        let chkBytes = Array(chkStr.utf8.prefix(8))
        block.replaceSubrange(148..<(148 + chkBytes.count), with: chkBytes)
        return Data(block)
    }

    private func writeOctal(_ value: Int, into block: inout [UInt8], offset: Int, length: Int) {
        let digits = max(1, length - 1)
        let formatted = String(format: "%0*o", digits, value)
        let bytes = Array(formatted.utf8.prefix(digits))
        block.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private func readExtractedFile(in directory: URL, named fileName: String) throws -> String {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == fileName {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        throw NSError(domain: "ArchiveRepairDesktopIntegrationTests", code: 404)
    }
}

private actor SlowRepairSignal {
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func markStartedAndWait() async {
        hasStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            resumeContinuation = cont
        }
    }

    func waitForStart() async {
        if hasStarted { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            startedContinuation = cont
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private final class SlowStagingRepairFacadeStub: TTZipEngineFacading, @unchecked Sendable {
    private let base = TTZipEngineFacade.shared
    private let signal = SlowRepairSignal()

    func waitForRepairStart() async {
        await signal.waitForStart()
    }

    func resumeRepair() async {
        await signal.resume()
    }

    func repairArchive(damagedPath: String, outputPath: String) async throws -> Int {
        FileManager.default.createFile(atPath: outputPath, contents: Data("partial-staging-bytes".utf8))
        await signal.markStartedAndWait()
        return 1
    }

    func quickCompress(
        inputs: [String],
        outputPath: String,
        format: ArchiveCompressionFormat,
        level: ArchiveCompressionLevel,
        password: String?,
        splitSize: Int64?,
        filterOptions: ArchiveFilterOptions,
        advancedOptions: ArchiveAdvancedOptions?,
        progress: (@Sendable (ArchiveProgress) -> Void)?,
        token: CancellationToken?
    ) async throws -> ArchiveOperationResult {
        try await base.quickCompress(
            inputs: inputs, outputPath: outputPath, format: format, level: level,
            password: password, splitSize: splitSize, filterOptions: filterOptions,
            advancedOptions: advancedOptions, progress: progress, token: token
        )
    }

    func quickExtract(
        archivePath: String,
        destinationDir: String,
        password: String?,
        autoVaultUnlock: Bool,
        handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)?,
        token: CancellationToken?
    ) async throws -> ExtractResult {
        try await base.quickExtract(
            archivePath: archivePath, destinationDir: destinationDir, password: password,
            autoVaultUnlock: autoVaultUnlock, handling: handling, progress: progress, token: token
        )
    }

    func extractSingleEntry(
        archivePath: String,
        entryPath: String,
        destinationDir: String,
        password: String?,
        handling: CollisionHandling
    ) async throws -> ExtractionOutcome {
        try await base.extractSingleEntry(
            archivePath: archivePath, entryPath: entryPath,
            destinationDir: destinationDir, password: password, handling: handling
        )
    }

    func inspectArchive(
        archivePath: String,
        password: String?,
        autoVaultUnlock: Bool
    ) async throws -> ArchiveInspectionResult {
        try await base.inspectArchive(
            archivePath: archivePath, password: password, autoVaultUnlock: autoVaultUnlock
        )
    }

    func verifyIntegrity(archivePath: String) async throws -> HashVerificationResult {
        try await base.verifyIntegrity(archivePath: archivePath)
    }

    func openVfsSnapshot(archivePath: String, password: String?) async throws -> Any {
        try await base.openVfsSnapshot(archivePath: archivePath, password: password)
    }
}
