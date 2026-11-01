// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
@testable import TTZipApp
@testable import TTZipCore
import TTZipUI

@MainActor
final class MockArchivePasswordDriver: ArchivePasswordOperationsDriver {
    struct CallRecord: Equatable {
        enum Kind: Equatable {
            case inspect(path: String, password: String?, autoVault: Bool)
            case verifyPayload(path: String, entryPath: String, password: String)
            case quickExtract(path: String, destDir: String, password: String?, autoVault: Bool)
            case extractEntries(path: String, entryPaths: [String], destDir: String, password: String?)
        }
        let kind: Kind
    }

    var calls: [CallRecord] = []
    var inspectHandler: ((String, String?, Bool) async throws -> InspectResult)?
    var verifyPayloadHandler: ((String, String, String) async throws -> Data?)?
    var quickExtractHandler: ((String, String, String?, Bool) async throws -> ExtractResult)?
    var extractEntriesHandler: ((String, [String], String, String?) async throws -> ExtractionOutcome)?

    var verifyPayloadCallCount: Int {
        calls.reduce(into: 0) { count, record in
            if case .verifyPayload = record.kind { count += 1 }
        }
    }

    func inspectArchive(
        archivePath: String,
        password: String?,
        autoVaultUnlock: Bool
    ) async throws -> InspectResult {
        calls.append(CallRecord(kind: .inspect(path: archivePath, password: password, autoVault: autoVaultUnlock)))
        if let inspectHandler {
            return try await inspectHandler(archivePath, password, autoVaultUnlock)
        }
        throw ArchiveError.fileNotFound
    }

    func verifyEncryptedEntryPayload(
        archivePath: String,
        entryPath: String,
        password: String
    ) async throws -> Data? {
        calls.append(CallRecord(kind: .verifyPayload(path: archivePath, entryPath: entryPath, password: password)))
        if let verifyPayloadHandler {
            return try await verifyPayloadHandler(archivePath, entryPath, password)
        }
        return Data("verified-payload".utf8)
    }

    func quickExtract(
        archivePath: String,
        destinationDir: String,
        password: String?,
        autoVaultUnlock: Bool,
        handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)? = nil,
        token: CancellationToken? = nil
    ) async throws -> ExtractResult {
        calls.append(CallRecord(kind: .quickExtract(
            path: archivePath,
            destDir: destinationDir,
            password: password,
            autoVault: autoVaultUnlock
        )))
        if let quickExtractHandler {
            return try await quickExtractHandler(archivePath, destinationDir, password, autoVaultUnlock)
        }
        return ExtractResult(
            archivePath: archivePath,
            destinationDir: destinationDir,
            durationSeconds: 0.005,
            unlockedPassword: password,
            isVaultUnlocked: false
        )
    }

    func extractEntries(
        archivePath: String,
        entryPaths: [String],
        destinationDir: String,
        password: String?,
        handling: CollisionHandling,
        progress: (@Sendable (ArchiveProgress) -> Void)? = nil
    ) async throws -> ExtractionOutcome {
        calls.append(CallRecord(kind: .extractEntries(
            path: archivePath,
            entryPaths: entryPaths,
            destDir: destinationDir,
            password: password
        )))
        if let extractEntriesHandler {
            return try await extractEntriesHandler(archivePath, entryPaths, destinationDir, password)
        }
        return ExtractionOutcome(
            status: .completed,
            extracted: UInt64(entryPaths.count),
            replaced: 0,
            keptBoth: 0,
            skipped: 0,
            failed: []
        )
    }
}

@MainActor
final class ArchivePasswordOperationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            BrowserWindowRegistry.shared.resetForTesting()
            BrowserWindowRouter.shared.resetForTesting()
            ArchivePasswordStore.shared.clearAll()
            VFSLz4CachePool.shared.clearSession(sessionId: "test")
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            BrowserWindowRegistry.shared.resetForTesting()
            BrowserWindowRouter.shared.resetForTesting()
            ArchivePasswordStore.shared.clearAll()
            VFSLz4CachePool.shared.clearSession(sessionId: "test")
        }
        super.tearDown()
    }

    private func makeEntry(
        path: String,
        size: Int64,
        isDirectory: Bool = false,
        isEncrypted: Bool = true
    ) -> ArchiveEntry {
        ArchiveEntry(
            path: path,
            uncompressedSize: size,
            isDirectory: isDirectory,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isEncrypted: isEncrypted,
            compressedSize: max(0, size),
            crc32: 0x12345678
        )
    }

    private func makeInspectResult(path: String, entries: [ArchiveEntry], unlockedPassword: String? = nil) -> InspectResult {
        InspectResult(
            archivePath: path,
            format: "zip",
            entries: entries,
            totalUncompressedBytes: entries.reduce(0) { $0 + max(0, $1.uncompressedSize) },
            totalCompressedBytes: entries.reduce(0) { $0 + max(0, $1.compressedSize ?? 0) },
            unlockedPassword: unlockedPassword
        )
    }

    // MARK: - 1. Plaintext Catalog Browsing vs. Wrong Password Rejection

    func testPlaintextCatalogRecordsDirectoryBrowsableUnverifiedAndRejectsWrongPasswordDuringBrowseSubmit() async {
        let archivePath = "/tmp/plaintext-catalog-\(UUID().uuidString).zip"
        let driver = MockArchivePasswordDriver()
        let entry = makeEntry(path: "secret.txt", size: 128)
        let fixture = makeInspectResult(path: archivePath, entries: [entry])

        driver.inspectHandler = { _, _, _ in fixture }
        driver.verifyPayloadHandler = { _, _, pwd in
            if pwd == "correct-secret" {
                return Data("decrypted".utf8)
            }
            throw ArchiveError.wrongPassword(archivePath: archivePath)
        }

        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)

        let loaded = await state.loadArchive(path: archivePath, password: nil)
        XCTAssertTrue(loaded)
        XCTAssertEqual(state.passwordEvidenceState, .directoryBrowsableUnverified)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archivePath))
        XCTAssertEqual(driver.verifyPayloadCallCount, 0)

        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)
        let wrongResult = await state.submitArchivePassword("wrong-pass")
        if case .wrongPassword = wrongResult {
            // Expected: wrong password rejected even though inspectArchive succeeded
        } else {
            XCTFail("Expected wrongPassword result, got \(wrongResult)")
        }
        XCTAssertTrue(state.showPasswordPrompt)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archivePath))
        XCTAssertEqual(state.passwordEvidenceState, .directoryBrowsableUnverified)
        XCTAssertEqual(driver.verifyPayloadCallCount, 1)

        let rightResult = await state.submitArchivePassword("correct-secret")
        XCTAssertEqual(rightResult, .verifiedAndResumed)
        XCTAssertFalse(state.showPasswordPrompt)
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: archivePath), "correct-secret")
        XCTAssertEqual(state.passwordEvidenceState, .verified(.selectedEntries(["secret.txt"])))
        XCTAssertEqual(driver.verifyPayloadCallCount, 2)
    }

    // MARK: - 2. Probe Selection & No-Evidence Guards (Oversized, Empty, Mixed, Nil Return)

    func testProbeSelectionWhenAllEntriesExceedBudgetOrAreEmptyPreservesUnverifiedAndDoesNotCachePassword() async {
        let oversizedArchive = "/tmp/oversized-only-\(UUID().uuidString).zip"
        let emptyOnlyArchive = "/tmp/empty-only-\(UUID().uuidString).zip"
        let driver = MockArchivePasswordDriver()

        let oversizedEntries = [
            makeEntry(path: "huge-a.bin", size: ArchivePasswordProbePolicy.maxProbeEntryBytes + 1),
            makeEntry(path: "huge-b.bin", size: ArchivePasswordProbePolicy.maxProbeEntryBytes * 2)
        ]
        let emptyEntries = [
            makeEntry(path: "dir/", size: 0, isDirectory: true),
            makeEntry(path: "empty-1.txt", size: 0),
            makeEntry(path: "plain.txt", size: 64, isEncrypted: false)
        ]

        driver.inspectHandler = { path, _, _ in
            if path == oversizedArchive {
                return self.makeInspectResult(path: path, entries: oversizedEntries)
            }
            return self.makeInspectResult(path: path, entries: emptyEntries)
        }

        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)

        // Case A: All encrypted entries exceed 64 MiB budget
        let loadedOversized = await state.loadArchive(path: oversizedArchive, password: "candidate-oversized")
        XCTAssertTrue(loadedOversized)
        XCTAssertEqual(driver.verifyPayloadCallCount, 0, "Must not invoke probe extraction when all entries exceed budget")
        XCTAssertEqual(state.passwordEvidenceState, .directoryBrowsableUnverified)
        XCTAssertNil(state.activePassword)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: oversizedArchive))

        // Also test via submitArchivePassword(.browse)
        state.stagePasswordPromptContext(archivePath: oversizedArchive, kind: .browse)
        let submitOversized = await state.submitArchivePassword("candidate-oversized")
        XCTAssertEqual(submitOversized, .verifiedAndResumed)
        XCTAssertEqual(driver.verifyPayloadCallCount, 0)
        XCTAssertEqual(state.passwordEvidenceState, .directoryBrowsableUnverified)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: oversizedArchive))

        // Case B: Only 0-byte encrypted entries and unencrypted entries
        let loadedEmpty = await state.loadArchive(path: emptyOnlyArchive, password: "candidate-empty")
        XCTAssertTrue(loadedEmpty)
        XCTAssertEqual(driver.verifyPayloadCallCount, 0, "Must not probe 0-byte or unencrypted entries")
        XCTAssertEqual(state.passwordEvidenceState, .directoryBrowsableUnverified)
        XCTAssertNil(state.activePassword)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: emptyOnlyArchive))
    }

    func testProbeSelectionChoosesSmallestNonEmptyCompliantEntryFromMixedEntries() async {
        let archivePath = "/tmp/mixed-entries-\(UUID().uuidString).zip"
        let driver = MockArchivePasswordDriver()
        let mixedEntries = [
            makeEntry(path: "00_empty.txt", size: 0),
            makeEntry(path: "01_oversized.mov", size: ArchivePasswordProbePolicy.maxProbeEntryBytes + 4096),
            makeEntry(path: "02_medium.dat", size: 4096),
            makeEntry(path: "03_smallest_valid.txt", size: 128),
            makeEntry(path: "04_unencrypted_tiny.txt", size: 16, isEncrypted: false)
        ]

        var probedEntryPaths: [String] = []
        driver.inspectHandler = { path, _, _ in
            self.makeInspectResult(path: path, entries: mixedEntries)
        }
        driver.verifyPayloadHandler = { _, entryPath, pwd in
            probedEntryPaths.append(entryPath)
            guard pwd == "mixed-right" else {
                throw ArchiveError.wrongPassword(archivePath: archivePath)
            }
            return Data(repeating: 0x41, count: 128)
        }

        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)

        let wrongOut = await state.submitArchivePassword("mixed-wrong")
        if case .wrongPassword = wrongOut {} else {
            XCTFail("Expected wrongPassword, got \(wrongOut)")
        }
        XCTAssertEqual(probedEntryPaths, ["03_smallest_valid.txt"])
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archivePath))

        let rightOut = await state.submitArchivePassword("mixed-right")
        XCTAssertEqual(rightOut, .verifiedAndResumed)
        XCTAssertEqual(probedEntryPaths, ["03_smallest_valid.txt", "03_smallest_valid.txt"])
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: archivePath), "mixed-right")
        XCTAssertEqual(state.passwordEvidenceState, .verified(.selectedEntries(["03_smallest_valid.txt"])))
    }

    func testProbeReturningNilDoesNotMarkVerifiedAndDoesNotWritePasswordCache() async {
        let archivePath = "/tmp/nil-probe-\(UUID().uuidString).zip"
        let driver = MockArchivePasswordDriver()
        let entries = [makeEntry(path: "probe.txt", size: 64)]

        driver.inspectHandler = { path, _, _ in
            self.makeInspectResult(path: path, entries: entries)
        }
        driver.verifyPayloadHandler = { _, _, _ in
            nil
        }

        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        let outcome = await state.verifyPlaintextCatalogPassword(
            archivePath: archivePath,
            entries: entries,
            password: "any-password"
        )
        XCTAssertEqual(outcome, .noAvailableEvidence)
        XCTAssertEqual(driver.verifyPayloadCallCount, 1)

        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)
        let submitResult = await state.submitArchivePassword("any-password")
        XCTAssertEqual(submitResult, .verifiedAndResumed)
        XCTAssertEqual(driver.verifyPayloadCallCount, 2)
        XCTAssertEqual(state.passwordEvidenceState, .directoryBrowsableUnverified)
        XCTAssertNil(state.activePassword)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archivePath))
    }

    // MARK: - 3. Real Encrypted Archive + Preview Cache Poisoning Regression

    func testRealEncryptedArchiveProbeBypassesPreviewCacheAndRejectsWrongPasswordAfterCacheWarmup() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipProbeCacheRegression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleFile = tempDir.appendingPathComponent("secret_notes.txt")
        let expectedPlaintext = "Real encrypted probe payload that must not be bypassed by VFSLz4CachePool"
        try expectedPlaintext.write(to: sampleFile, atomically: true, encoding: .utf8)

        let zipURL = tempDir.appendingPathComponent("locked_probe.zip")
        let correctPassword = "RealRightPassword!2026"
        let writer = ArchiveWriter()
        try await writer.createArchive(
            outputPath: zipURL.path,
            format: .zip,
            level: .fast,
            inputPaths: [sampleFile.path],
            password: correctPassword
        )

        // Step 1: Populate the shared preview cache using the correct password
        let warmData = try? await ArchiveSelectiveExtractor.shared.extractSingleEntryData(
            archivePath: zipURL.path,
            entryPath: "secret_notes.txt",
            password: correctPassword
        )
        XCTAssertEqual(warmData.flatMap { String(data: $0, encoding: .utf8) }, expectedPlaintext)
        XCTAssertNotNil(
            VFSLz4CachePool.shared.getCachedEntry(archivePath: zipURL.path, entryPath: "secret_notes.txt"),
            "Preview cache must be populated before testing wrong-password probe"
        )

        // Step 2: Clear password store and verify that a wrong password is STILL rejected by the real probe
        ArchivePasswordStore.shared.clearAll()
        let state = AppViewState(fileViewer: NoOpFileViewer())
        let loadedUnauth = await state.loadArchive(path: zipURL.path, password: nil)
        XCTAssertTrue(loadedUnauth)
        XCTAssertEqual(state.passwordEvidenceState, .directoryBrowsableUnverified)

        state.stagePasswordPromptContext(archivePath: zipURL.path, kind: .browse)
        let wrongSubmission = await state.submitArchivePassword("WrongCandidatePassword!999")
        if case .wrongPassword = wrongSubmission {
            // Expected: bypassed VFSLz4CachePool and caught wrong password via real stream decryption
        } else {
            XCTFail("Expected wrongPassword despite warmed preview cache, got \(wrongSubmission)")
        }
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: zipURL.path))
        XCTAssertEqual(state.passwordEvidenceState, .directoryBrowsableUnverified)
        XCTAssertTrue(state.showPasswordPrompt)

        // Step 3: Submitting the right password succeeds and records verified evidence
        let rightSubmission = await state.submitArchivePassword(correctPassword)
        XCTAssertEqual(rightSubmission, .verifiedAndResumed)
        XCTAssertFalse(state.showPasswordPrompt)
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: zipURL.path), correctPassword)
        XCTAssertEqual(state.passwordEvidenceState, .verified(.selectedEntries(["secret_notes.txt"])))
    }

    // MARK: - 4. Underlying Budget, Corruption & I/O Failure Classification

    func testProbeBudgetAndCorruptionErrorsAreClassifiedAsNonPasswordFailures() async {
        let archivePath = "/tmp/probe-errors-\(UUID().uuidString).zip"
        let driver = MockArchivePasswordDriver()
        let entries = [makeEntry(path: "entry.bin", size: 1024)]
        driver.inspectHandler = { path, _, _ in
            self.makeInspectResult(path: path, entries: entries)
        }

        let state = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)

        // 1. Unsupported encryption / out-of-memory budget limit exceeded
        driver.verifyPayloadHandler = { _, _, _ in
            throw ArchiveError.unsupportedEncryptionMethod(archivePath: archivePath, method: "Budget limit exceeded")
        }
        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)
        let oomResult = await state.submitArchivePassword("pass-1")
        XCTAssertEqual(
            oomResult,
            .nonPasswordFailure(
                category: .unsupportedFormatOrEncryption,
                message: ArchivePasswordLocaleKey.unsupportedFormatOrEncryption.localized()
            )
        )
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archivePath))

        // 2. Corrupt header / truncated archive
        driver.verifyPayloadHandler = { _, _, _ in
            throw ArchiveError.corruptHeader
        }
        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)
        let corruptResult = await state.submitArchivePassword("pass-2")
        XCTAssertEqual(
            corruptResult,
            .nonPasswordFailure(
                category: .corruptedArchive,
                message: ArchivePasswordLocaleKey.archiveCorrupted.localized()
            )
        )

        // 3. Permission denied / I/O error
        driver.verifyPayloadHandler = { _, _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: "Permission denied"])
        }
        state.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)
        let ioResult = await state.submitArchivePassword("pass-3")
        XCTAssertEqual(
            ioResult,
            .nonPasswordFailure(
                category: .permissionDenied,
                message: ArchivePasswordLocaleKey.permissionDenied.localized()
            )
        )
    }

    // MARK: - 5. Original Operation Resumption & Multi-Window Isolation

    func testQuickExtractAndSelectedEntriesResumeOnceAndPreserveMultiWindowIsolation() async {
        let archivePath = "/tmp/quick-extract-\(UUID().uuidString).zip"
        let driver = MockArchivePasswordDriver()
        var quickExtractSuccessCount = 0

        driver.quickExtractHandler = { path, destDir, pwd, _ in
            guard pwd == "unlock-123" else {
                throw ArchiveError.wrongPassword(archivePath: path)
            }
            quickExtractSuccessCount += 1
            return ExtractResult(
                archivePath: path,
                destinationDir: destDir,
                durationSeconds: 0.010,
                unlockedPassword: pwd,
                isVaultUnlocked: false
            )
        }

        let windowA = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: driver)
        let windowB = AppViewState(fileViewer: NoOpFileViewer(), passwordDriver: MockArchivePasswordDriver())

        await windowA.quickExtractArchive(path: archivePath)
        XCTAssertTrue(windowA.showPasswordPrompt)
        XCTAssertFalse(windowB.showPasswordPrompt)

        let wrongAttempt = await windowA.submitArchivePassword("bad-pass")
        if case .wrongPassword = wrongAttempt {} else {
            XCTFail("Expected wrongPassword, got \(wrongAttempt)")
        }
        XCTAssertTrue(windowA.showPasswordPrompt)
        XCTAssertEqual(quickExtractSuccessCount, 0)
        XCTAssertNil(ArchivePasswordStore.shared.getPassword(for: archivePath))

        let rightAttempt = await windowA.submitArchivePassword("unlock-123")
        XCTAssertEqual(rightAttempt, .verifiedAndResumed)
        XCTAssertFalse(windowA.showPasswordPrompt)
        XCTAssertEqual(quickExtractSuccessCount, 1)
        XCTAssertEqual(ArchivePasswordStore.shared.getPassword(for: archivePath), "unlock-123")
        XCTAssertEqual(windowA.passwordEvidenceState, .verified(.fullArchive))

        // Selected entries resumption + window isolation
        let archiveB = "/tmp/selected-extract-\(UUID().uuidString).7z"
        let destDir = "/tmp/extracted-out-\(UUID().uuidString)"
        let targetEntries = ["docs/readme.md", "docs/spec.md"]
        let driverB = MockArchivePasswordDriver()
        var resumedEntries: [String] = []
        var resumedDest: String = ""

        driverB.extractEntriesHandler = { path, entries, dest, pwd in
            guard pwd == "entry-pass" else {
                throw ArchiveError.wrongPassword(archivePath: path)
            }
            resumedEntries = entries
            resumedDest = dest
            return ExtractionOutcome(
                status: .completed,
                extracted: UInt64(entries.count),
                replaced: 0,
                keptBoth: 0,
                skipped: 0,
                failed: []
            )
        }
        windowB.passwordDriver = driverB
        windowB.stagePasswordPromptContext(
            archivePath: archiveB,
            kind: .extractEntries(entryPaths: targetEntries, destinationDir: destDir, collisionHandling: .policy(.replace))
        )
        windowA.stagePasswordPromptContext(archivePath: archivePath, kind: .browse)

        windowA.cancelPasswordPrompt()
        XCTAssertFalse(windowA.showPasswordPrompt)
        XCTAssertTrue(windowB.showPasswordPrompt)

        let entryResult = await windowB.submitArchivePassword("entry-pass")
        XCTAssertEqual(entryResult, .verifiedAndResumed)
        XCTAssertEqual(resumedEntries, targetEntries)
        XCTAssertEqual(resumedDest, destDir)
        XCTAssertEqual(windowB.passwordEvidenceState, .verified(.selectedEntries(Set(targetEntries))))

        windowB.prepareForWindowClose()
        XCTAssertFalse(windowB.showPasswordPrompt)
        XCTAssertNil(windowB.pendingPasswordContext)
    }
}
