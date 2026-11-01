// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import XCTest
@testable import TTMediaKit
@testable import TTZipCore
@testable import TTZipPreviewKit

@MainActor
final class ReaderPersistenceBridgeTests: XCTestCase {
    func testRustAdapterPersistsZeroAnchorPreferencesNotesAndExports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try ReaderPersistenceBridge(directory: directory)
        let adapter = bridge.adapter
        XCTAssertFalse(try XCTUnwrap(adapter.hasStoredDocument)("book-a"))
        let position = EPUBReaderAnchor(chapterIndex: 0, blockIndex: 0, characterOffset: 0, chapterRatio: 0)
        try adapter.savePosition("book-a", position)
        let preferences = EPUBReaderPreferences(latinFont: "Georgia", cjkFont: "Songti SC", fontSize: 21,
                                                theme: "dark", layout: "paginated")
        try adapter.savePreferences("book-a", preferences)
        let annotation = try adapter.upsertAnnotation("book-a", EPUBReaderAnnotation(
            anchor: position, quote: "中英文 quotation", note: "A persisted note"))
        XCTAssertFalse(annotation.id.isEmpty)
        let reopened = try ReaderPersistenceBridge(directory: directory).adapter
        XCTAssertTrue(try XCTUnwrap(reopened.hasStoredDocument)("book-a"))
        let document = try reopened.load("book-a")
        XCTAssertEqual(document.position, position)
        XCTAssertEqual(document.preferences, preferences)
        XCTAssertEqual(document.annotations, [annotation])
        XCTAssertTrue(try reopened.exportAnnotations("book-a", "markdown").contains("A persisted note"))
        XCTAssertTrue(try reopened.exportAnnotations("book-a", "json").contains(annotation.id))
        XCTAssertTrue(try reopened.load("book-b").annotations.isEmpty)
        try reopened.deleteAnnotation("book-a", annotation.id)
        XCTAssertTrue(try reopened.load("book-a").annotations.isEmpty)
    }

    func testArchiveReaderIdentitySurvivesStagingChangesAndDistinguishesEntries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("books.zip")
        try Data("archive source fingerprint".utf8).write(to: archive)
        let first = TTPreviewResourceContext.archiveEntry(archiveURL: archive, entryPath: "a/book.epub",
                                                         stagedReadURL: directory.appendingPathComponent("staging-a.epub"))
        let second = TTPreviewResourceContext.archiveEntry(archiveURL: archive, entryPath: "a/book.epub",
                                                          stagedReadURL: directory.appendingPathComponent("staging-b.epub"))
        let other = TTPreviewResourceContext.archiveEntry(archiveURL: archive, entryPath: "b/book.epub", stagedReadURL: nil)
        let identity = try XCTUnwrap(PreviewReadingIdentity.resolve(context: first, fallbackURL: nil))
        XCTAssertEqual(identity, PreviewReadingIdentity.resolve(context: second, fallbackURL: nil))
        XCTAssertNotEqual(identity, PreviewReadingIdentity.resolve(context: other, fallbackURL: nil))
        XCTAssertFalse(identity.contains("staging-a"))
    }

    func testMissingArchiveNeverFallsBackToAReadableStagedCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("extracted.epub")
        try Data("readable staged book".utf8).write(to: staged)
        let context = TTPreviewResourceContext.archiveEntry(
            archiveURL: directory.appendingPathComponent("missing.zip"),
            entryPath: "book.epub", stagedReadURL: staged)
        XCTAssertNil(PreviewReadingIdentity.resolve(context: context, fallbackURL: staged))
        XCTAssertThrowsError(try ReaderPersistenceBridge.unidentifiedSourceAdapter.load(staged.path))
    }

    // MARK: - Unit B: Default PreviewLRUCacheManager & EPUB Spool Process Namespace Isolation

    func testCrossProcessEPUBSpoolHelperEntryIfRequested() async throws {
        guard let role = ProcessInfo.processInfo.environment["TTZIP_EPUB_SPOOL_HELPER_ROLE"], !role.isEmpty else {
            return
        }
        let env = ProcessInfo.processInfo.environment
        let faultMode = env["TTZIP_HELPER_FAULT_MODE"] ?? ""
        if faultMode == "never_ready" {
            for _ in 0..<200 { try? await Task.sleep(for: .milliseconds(20)) }
            return
        }
        EPUBArchiveUnpacker.register()
        let outerZipPath = try XCTUnwrap(env["TTZIP_HELPER_OUTER_ZIP"])
        let resultFile = URL(fileURLWithPath: try XCTUnwrap(env["TTZIP_HELPER_RESULT_FILE"]))
        let vfs = TTZipArchiveVfsProvider.shared
        let outerArchiveId = vfs.registerArchive(archivePath: outerZipPath, password: nil)
        defer { vfs.unregisterArchive(archiveId: outerArchiveId) }
        let innerVfsURL = vfs.makeVfsURL(archiveId: outerArchiveId, entryPath: "InnerSample.epub")

        let unpacked = await EPUBArchiveUnpacker.unpackAndParseEPUBAsync(at: innerVfsURL)
        let model = try XCTUnwrap(unpacked)
        let bookDigest: String = InteractiveEPUBReaderView.stableBookDigest(for: model.url.absoluteString)
        let innerArchiveId = try XCTUnwrap(vfs.parseVfsUri(model.extractDir.absoluteString)?.archiveId)

        if role == "owner_b_hold" {
            defer { EPUBArchiveUnpacker.cleanupTempDir(at: model.extractDir) }
            let readyFile = URL(fileURLWithPath: try XCTUnwrap(env["TTZIP_HELPER_READY_FILE"]))
            let resumeFile = URL(fileURLWithPath: try XCTUnwrap(env["TTZIP_HELPER_RESUME_FILE"]))
            let initialCSS = try? await vfs.readEntryData(archiveId: innerArchiveId, entryPath: "OEBPS/styles/book.css")
            let readyPayload: [String: String] = [
                "initialCSSLoaded": "\(initialCSS != nil)",
                "bookDigest": bookDigest
            ]
            try JSONEncoder().encode(readyPayload).write(to: readyFile, options: .atomic)

            if faultMode == "never_exit" {
                for _ in 0..<200 { try? await Task.sleep(for: .milliseconds(20)) }
                return
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while !FileManager.default.fileExists(atPath: resumeFile.path) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard FileManager.default.fileExists(atPath: resumeFile.path), faultMode != "missing_result" else {
                return
            }
            let extraCSS = try? await vfs.readEntryData(archiveId: innerArchiveId, entryPath: "OEBPS/styles/extra.css")
            let outPayload: [String: String] = [
                "extraCSSLoadedAfterPeerClose": "\(extraCSS != nil)",
                "bookDigest": bookDigest
            ]
            try JSONEncoder().encode(outPayload).write(to: resultFile, options: .atomic)
        } else if role == "owner_a_open_close" {
            EPUBArchiveUnpacker.cleanupTempDir(at: model.extractDir)
            let outPayload: [String: String] = ["bookDigest": bookDigest]
            try JSONEncoder().encode(outPayload).write(to: resultFile, options: .atomic)
        }
    }

    func testDefaultPreviewLRUCacheAndEPUBSpoolIsolateAcrossOwnersAndPreserveIdentity() async throws {
        guard ProcessInfo.processInfo.environment["TTZIP_EPUB_SPOOL_HELPER_ROLE"] == nil else {
            return
        }
        try await verifyPreviewLRUCacheOwnerIsolationAndRefCount()
        try await verifyCrossProcessEPUBSpoolIsolationAndLogicalIdentity()
    }

    private func verifyPreviewLRUCacheOwnerIsolationAndRefCount() async throws {
        let sharedRoot1 = PreviewLRUCacheManager.shared.getSessionRoot()
        let sharedRoot2 = PreviewLRUCacheManager.shared.getSessionRoot()
        XCTAssertEqual(sharedRoot1, sharedRoot2, "PreviewLRUCacheManager.shared must be stable within the same process")

        let ownerA = PreviewLRUCacheManager()
        let ownerB = PreviewLRUCacheManager()
        let rootA = ownerA.getSessionRoot()
        let rootB = ownerB.getSessionRoot()
        let customDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-custom-lru-\(UUID().uuidString)", isDirectory: true)
        let customManager = PreviewLRUCacheManager(customCacheDir: customDir)

        do {
            let c1 = UUID()
            let c2 = UUID()
            let urlB1 = try await ownerB.stageFile(
                data: Data("owner_b_content".utf8), key: "k1", suggestedFileName: "note.txt", consumerID: c1)
            let lease1 = await ownerB.acquireLease(forKey: "k1", consumerID: c1)
            let lease2 = await ownerB.acquireLease(forKey: "k1", consumerID: c2)
            let leaseCountBefore = await ownerB.activeLeaseCount(forKey: "k1")
            XCTAssertEqual(leaseCountBefore, 2)
            XCTAssertTrue(TTPreviewResourceContext.isManagedPreviewStagingURL(urlB1))
            XCTAssertNil(PreviewReadingIdentity.resolve(
                context: .diskFile(url: urlB1, fileName: "note.txt", allowsEditing: false, isTruncated: false),
                fallbackURL: urlB1))

            await ownerA.purgeAll()
            XCTAssertNotEqual(
                rootA.standardizedFileURL, rootB.standardizedFileURL,
                "Default-root PreviewLRUCacheManager owners must use isolated session directories"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: urlB1.path),
                "Owner A purgeAll() must not delete Owner B's actively leased default-root staged file"
            )

            await ownerB.releaseLease(lease1, reclaimImmediatelyIfIdle: true)
            let leaseCountMid = await ownerB.activeLeaseCount(forKey: "k1")
            XCTAssertEqual(leaseCountMid, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: urlB1.path))

            await ownerB.releaseLease(lease2, reclaimImmediatelyIfIdle: true)
            let leaseCountEnd = await ownerB.activeLeaseCount(forKey: "k1")
            XCTAssertEqual(leaseCountEnd, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: urlB1.path))

            let resolvedCustom = customManager.getSessionRoot()
            XCTAssertEqual(resolvedCustom.standardizedFileURL, customDir.standardizedFileURL)
        } catch {
            await ownerA.purgeAll()
            await ownerB.purgeAll()
            await customManager.purgeAll()
            throw error
        }
        await ownerA.purgeAll()
        await ownerB.purgeAll()
        await customManager.purgeAll()
    }

    private struct CrossProcessEPUBScenarioOutcome {
        var readyTimedOut = false
        var procATimedOut = false
        var procBTimedOut = false
        var procAExitedCleanly = false
        var procBExitedCleanly = false
        var allHelpersConfirmedExited = false
        var spawnAErrorDescription: String?
        var readyB: [String: String]?
        var resultA: [String: String]?
        var resultB: [String: String]?
        var preservedEvidenceDir: URL?
    }

    private func verifyCrossProcessEPUBSpoolIsolationAndLogicalIdentity() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-epub-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let outerZip = try await createNestedOuterZipWithMinimalEPUB(in: fixtureRoot)

        let outcome = try await runCrossProcessEPUBScenario(outerZip: outerZip, faultMode: nil, timeoutSeconds: 8.0)
        XCTAssertTrue(
            outcome.allHelpersConfirmedExited,
            "Owned EPUB helper did not confirm exit; preserved evidence at \(String(describing: outcome.preservedEvidenceDir?.path))"
        )
        XCTAssertNil(outcome.spawnAErrorDescription)
        XCTAssertFalse(outcome.readyTimedOut, "EPUB Helper B did not become ready")
        XCTAssertFalse(outcome.procATimedOut, "EPUB Helper A timed out")
        XCTAssertFalse(outcome.procBTimedOut, "EPUB Helper B timed out after resume")
        XCTAssertTrue(outcome.procAExitedCleanly, "EPUB Helper A exited with non-zero status")
        XCTAssertTrue(outcome.procBExitedCleanly, "EPUB Helper B exited with non-zero status")

        let readyB = try XCTUnwrap(outcome.readyB, "Missing EPUB Helper B ready payload")
        let resultA = try XCTUnwrap(outcome.resultA, "Missing EPUB Helper A result payload")
        let resultB = try XCTUnwrap(outcome.resultB, "Missing EPUB Helper B result payload")
        XCTAssertEqual(readyB["initialCSSLoaded"], "true")
        XCTAssertEqual(resultB["bookDigest"], resultA["bookDigest"], "Book logical identity must not change across processes")
        XCTAssertEqual(
            resultB["extraCSSLoadedAfterPeerClose"], "true",
            "Process B's nested EPUB spool must survive Process A closing the same nested EPUB"
        )

        try await verifyCrossProcessEPUBHelperFailurePaths(outerZip: outerZip)
    }

    private func verifyCrossProcessEPUBHelperFailurePaths(outerZip: URL) async throws {
        let neverReady = try await runCrossProcessEPUBScenario(outerZip: outerZip, faultMode: "never_ready", timeoutSeconds: 0.20)
        XCTAssertTrue(neverReady.readyTimedOut, "Expected never_ready EPUB fault to time out within budget")
        XCTAssertNil(neverReady.readyB)
        XCTAssertTrue(neverReady.allHelpersConfirmedExited, "Owned EPUB helper must be terminated and confirmed exited on ready timeout")
        XCTAssertNil(neverReady.preservedEvidenceDir)

        let neverExit = try await runCrossProcessEPUBScenario(outerZip: outerZip, faultMode: "never_exit", timeoutSeconds: 0.25)
        XCTAssertFalse(neverExit.readyTimedOut)
        XCTAssertTrue(neverExit.procBTimedOut, "Expected never_exit EPUB fault to time out waiting for normal exit")
        XCTAssertFalse(neverExit.procBExitedCleanly)
        XCTAssertTrue(neverExit.allHelpersConfirmedExited, "Owned EPUB helper must be terminated and confirmed exited on exit timeout")
        XCTAssertNil(neverExit.preservedEvidenceDir)

        let missingResult = try await runCrossProcessEPUBScenario(outerZip: outerZip, faultMode: "missing_result", timeoutSeconds: 2.0)
        XCTAssertFalse(missingResult.readyTimedOut)
        XCTAssertFalse(missingResult.procBTimedOut)
        XCTAssertNil(missingResult.resultB, "Expected missing_result EPUB fault to report nil resultB without throwing past cleanup")
        XCTAssertTrue(missingResult.allHelpersConfirmedExited)
        XCTAssertNil(missingResult.preservedEvidenceDir)

        let spawnAFailed = try await runCrossProcessEPUBScenario(outerZip: outerZip, faultMode: "spawn_a_fail", timeoutSeconds: 2.0)
        XCTAssertFalse(spawnAFailed.readyTimedOut)
        XCTAssertNotNil(spawnAFailed.readyB, "EPUB Helper B must be ready before Helper A spawn fault is injected")
        XCTAssertNotNil(spawnAFailed.spawnAErrorDescription, "Expected EPUB Helper A spawn error to be frozen and preserved")
        XCTAssertNil(spawnAFailed.resultA)
        XCTAssertTrue(spawnAFailed.allHelpersConfirmedExited, "EPUB Helper B must still be released and cleaned up when Helper A spawn throws")
        XCTAssertNil(spawnAFailed.preservedEvidenceDir)
    }

    private func runCrossProcessEPUBScenario(
        outerZip: URL,
        faultMode: String?,
        timeoutSeconds: Double
    ) async throws -> CrossProcessEPUBScenarioOutcome {
        let caseTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-epub-spool-iso-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: caseTmp, withIntermediateDirectories: true)

        let readyBFile = caseTmp.appendingPathComponent("epub_b_ready.json")
        let resumeBFile = caseTmp.appendingPathComponent("epub_b_resume.sig")
        let resultBFile = caseTmp.appendingPathComponent("epub_b_result.json")
        let resultAFile = caseTmp.appendingPathComponent("epub_a_result.json")

        var outcome = CrossProcessEPUBScenarioOutcome()
        var procA: Process?
        let procB = try spawnEPUBHelper(role: "owner_b_hold", sharedTmp: caseTmp, env: [
            "TTZIP_HELPER_OUTER_ZIP": outerZip.path,
            "TTZIP_HELPER_READY_FILE": readyBFile.path,
            "TTZIP_HELPER_RESUME_FILE": resumeBFile.path,
            "TTZIP_HELPER_RESULT_FILE": resultBFile.path,
            "TTZIP_HELPER_FAULT_MODE": faultMode ?? ""
        ])

        if await waitForEPUBFile(readyBFile, whileRunning: procB, timeoutSeconds: timeoutSeconds) {
            outcome.readyB = decodeEPUBJSONDictionaryIfPresent(at: readyBFile)
            let execOverrideA = (faultMode == "spawn_a_fail") ? caseTmp.appendingPathComponent("nonexistent-owned-epub-helper-a") : nil
            do {
                let spawnedA = try spawnEPUBHelper(role: "owner_a_open_close", sharedTmp: caseTmp, env: [
                    "TTZIP_HELPER_OUTER_ZIP": outerZip.path,
                    "TTZIP_HELPER_RESULT_FILE": resultAFile.path
                ], executableOverride: execOverrideA)
                procA = spawnedA
                if await waitForEPUBProcessExit(spawnedA, timeoutSeconds: timeoutSeconds), !spawnedA.isRunning {
                    outcome.procAExitedCleanly = (spawnedA.terminationStatus == 0)
                    outcome.resultA = decodeEPUBJSONDictionaryIfPresent(at: resultAFile)
                } else {
                    outcome.procATimedOut = true
                }
            } catch {
                outcome.spawnAErrorDescription = String(describing: error)
            }

            try? Data("go".utf8).write(to: resumeBFile, options: .atomic)
            if await waitForEPUBProcessExit(procB, timeoutSeconds: timeoutSeconds), !procB.isRunning {
                outcome.procBExitedCleanly = (procB.terminationStatus == 0)
                outcome.resultB = decodeEPUBJSONDictionaryIfPresent(at: resultBFile)
            } else {
                outcome.procBTimedOut = true
            }
        } else {
            outcome.readyTimedOut = true
        }

        let bExited = await cleanupOwnedEPUBHelper(procB, resumeFile: resumeBFile)
        let aExited = await cleanupOwnedEPUBHelper(procA, resumeFile: nil)
        outcome.allHelpersConfirmedExited = bExited && aExited
        if outcome.allHelpersConfirmedExited {
            try? FileManager.default.removeItem(at: caseTmp)
        } else {
            outcome.preservedEvidenceDir = caseTmp
        }
        return outcome
    }

    private func waitForEPUBFile(_ file: URL, whileRunning proc: Process, timeoutSeconds: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeoutSeconds * 1000)))
        while !FileManager.default.fileExists(atPath: file.path) && ContinuousClock.now < deadline {
            if !proc.isRunning { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return FileManager.default.fileExists(atPath: file.path)
    }

    private func waitForEPUBProcessExit(_ proc: Process, timeoutSeconds: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeoutSeconds * 1000)))
        while proc.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !proc.isRunning
    }

    private static let inheritedRunnerOutputEnvKeys: [String] = [
        "XML_OUTPUT_FILE",
        "TEST_UNDECLARED_OUTPUTS_DIR",
        "TEST_UNDECLARED_OUTPUTS_ANNOTATIONS_DIR",
        "TEST_SHARD_STATUS_FILE",
        "TEST_PREMATURE_EXIT_FILE",
        "TEST_WARNINGS_OUTPUT_FILE",
        "TEST_LOGSPLITTER_OUTPUT_FILE",
        "TEST_INFRASTRUCTURE_FAILURE_FILE",
        "LLVM_PROFILE_FILE",
        "XCTestSessionIdentifier",
        "XCTestConfigurationFilePath"
    ]

    private struct ParentReceiptSentinelFixture {
        let sentinelXML: URL
        let sentinelBytes: Data
        let undeclaredDir: URL
        let annotationsDir: URL
        let shardFile: URL
        let prematureFile: URL
        let warningsFile: URL
        let simulatedParentEnv: [String: String]
    }

    private func makeParentReceiptSentinelFixture(in tempRoot: URL) throws -> ParentReceiptSentinelFixture {
        let parentReceiptDir = tempRoot.appendingPathComponent("parent-receipts", isDirectory: true)
        let undeclaredDir = parentReceiptDir.appendingPathComponent("undeclared", isDirectory: true)
        let annotationsDir = parentReceiptDir.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: undeclaredDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)
        let sentinelXML = parentReceiptDir.appendingPathComponent("parent-test.xml")
        let sentinelBytes = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites tests="201" failures="0" errors="0">
              <testsuite name="UIPreviewKitTests" tests="201" failures="0" errors="0"/>
            </testsuites>
            """.utf8
        )
        try sentinelBytes.write(to: sentinelXML, options: .atomic)
        let shardFile = parentReceiptDir.appendingPathComponent("shard.status")
        let prematureFile = parentReceiptDir.appendingPathComponent("premature.exit")
        let warningsFile = parentReceiptDir.appendingPathComponent("warnings.log")
        var env = ProcessInfo.processInfo.environment
        env["XML_OUTPUT_FILE"] = sentinelXML.path
        env["TEST_UNDECLARED_OUTPUTS_DIR"] = undeclaredDir.path
        env["TEST_UNDECLARED_OUTPUTS_ANNOTATIONS_DIR"] = annotationsDir.path
        env["TEST_SHARD_STATUS_FILE"] = shardFile.path
        env["TEST_PREMATURE_EXIT_FILE"] = prematureFile.path
        env["TEST_WARNINGS_OUTPUT_FILE"] = warningsFile.path
        env["LLVM_PROFILE_FILE"] = parentReceiptDir.appendingPathComponent("parent.profraw").path
        env["XCTestSessionIdentifier"] = "parent-session-sentinel"
        return ParentReceiptSentinelFixture(
            sentinelXML: sentinelXML, sentinelBytes: sentinelBytes,
            undeclaredDir: undeclaredDir, annotationsDir: annotationsDir,
            shardFile: shardFile, prematureFile: prematureFile, warningsFile: warningsFile,
            simulatedParentEnv: env
        )
    }

    func testSpawnEPUBHelperIsolatesParentXMLAndUndeclaredOutputsReceiptEnv() async throws {
        guard ProcessInfo.processInfo.environment["TTZIP_EPUB_SPOOL_HELPER_ROLE"] == nil else { return }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-epub-receipt-iso-\(UUID().uuidString)", isDirectory: true)
        let sharedTmp = tempRoot.appendingPathComponent("shared-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fixture = try makeParentReceiptSentinelFixture(in: tempRoot)
        let outerZip = try await createNestedOuterZipWithMinimalEPUB(in: tempRoot)
        let resultAFile = sharedTmp.appendingPathComponent("isolated_a_result.json")
        let procA = try spawnEPUBHelper(
            role: "owner_a_open_close",
            sharedTmp: sharedTmp,
            env: ["TTZIP_HELPER_OUTER_ZIP": outerZip.path, "TTZIP_HELPER_RESULT_FILE": resultAFile.path],
            baseEnv: fixture.simulatedParentEnv
        )
        let childEnv = try XCTUnwrap(procA.environment)
        let childXMLPath = try XCTUnwrap(childEnv["XML_OUTPUT_FILE"])
        let childUndeclaredPath = try XCTUnwrap(childEnv["TEST_UNDECLARED_OUTPUTS_DIR"])
        let helperReceiptsPrefix = sharedTmp.appendingPathComponent("helper-receipts").path
        XCTAssertNotEqual(childXMLPath, fixture.sentinelXML.path)
        XCTAssertTrue(childXMLPath.hasPrefix(helperReceiptsPrefix))
        XCTAssertNotEqual(childUndeclaredPath, fixture.undeclaredDir.path)
        XCTAssertTrue(childUndeclaredPath.hasPrefix(helperReceiptsPrefix))
        for strippedKey in ["TEST_SHARD_STATUS_FILE", "TEST_PREMATURE_EXIT_FILE", "TEST_WARNINGS_OUTPUT_FILE",
                            "LLVM_PROFILE_FILE", "XCTestSessionIdentifier"] {
            XCTAssertNil(childEnv[strippedKey])
        }

        let exitedA = await waitForEPUBProcessExit(procA, timeoutSeconds: 8.0)
        let cleanedA = await cleanupOwnedEPUBHelper(procA, resumeFile: nil)
        XCTAssertTrue(exitedA && cleanedA)
        XCTAssertEqual(procA.terminationStatus, 0)
        XCTAssertNotNil(decodeEPUBJSONDictionaryIfPresent(at: resultAFile))

        let timedOutProc = try spawnEPUBHelper(
            role: "owner_b_hold", sharedTmp: sharedTmp,
            env: ["TTZIP_HELPER_FAULT_MODE": "never_ready"], baseEnv: fixture.simulatedParentEnv
        )
        let cleanedTimedOut = await cleanupOwnedEPUBHelper(timedOutProc, resumeFile: nil)
        XCTAssertTrue(cleanedTimedOut)
        XCTAssertEqual(try Data(contentsOf: fixture.sentinelXML), fixture.sentinelBytes)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: fixture.undeclaredDir.path)) ?? []).isEmpty)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: fixture.annotationsDir.path)) ?? []).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shardFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.prematureFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.warningsFile.path))
    }

    private func cleanupOwnedEPUBHelper(_ proc: Process?, resumeFile: URL?) async -> Bool {
        guard let proc else { return true }
        let pid = proc.processIdentifier
        guard pid > 0, pid != getpid() else { return !proc.isRunning }
        if !proc.isRunning { return true }
        if let resumeFile {
            try? Data("abort".utf8).write(to: resumeFile, options: .atomic)
            if await waitForEPUBProcessExit(proc, timeoutSeconds: 0.15) { return true }
        }
        proc.terminate()
        if await waitForEPUBProcessExit(proc, timeoutSeconds: 0.15) { return true }
        if proc.isRunning, pid > 0, pid != getpid() {
            _ = Darwin.kill(pid, SIGKILL)
        }
        return await waitForEPUBProcessExit(proc, timeoutSeconds: 0.50)
    }

    private func decodeEPUBJSONDictionaryIfPresent(at url: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    private func isolatedEPUBHelperEnvironment(
        baseEnv: [String: String],
        role: String,
        sharedTmp: URL,
        testFilter: String,
        extra: [String: String]
    ) throws -> [String: String] {
        let receiptDir = sharedTmp
            .appendingPathComponent("helper-receipts", isDirectory: true)
            .appendingPathComponent("\(role)-\(UUID().uuidString)", isDirectory: true)
        let undeclaredDir = receiptDir.appendingPathComponent("undeclared", isDirectory: true)
        let annotationsDir = receiptDir.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: undeclaredDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        var env = baseEnv
        for key in Self.inheritedRunnerOutputEnvKeys {
            env.removeValue(forKey: key)
        }
        env["TMPDIR"] = sharedTmp.path
        env["XML_OUTPUT_FILE"] = receiptDir.appendingPathComponent("test.xml").path
        env["TEST_UNDECLARED_OUTPUTS_DIR"] = undeclaredDir.path
        env["TEST_UNDECLARED_OUTPUTS_ANNOTATIONS_DIR"] = annotationsDir.path
        env["TTZIP_EPUB_SPOOL_HELPER_ROLE"] = role
        env["TESTBRIDGE_TEST_ONLY"] = testFilter
        for (k, v) in extra { env[k] = v }
        return env
    }

    private func spawnEPUBHelper(
        role: String,
        sharedTmp: URL,
        env extra: [String: String],
        baseEnv: [String: String] = ProcessInfo.processInfo.environment,
        executableOverride: URL? = nil
    ) throws -> Process {
        let proc = Process()
        proc.executableURL = executableOverride ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let testFilter = "ReaderPersistenceBridgeTests/testCrossProcessEPUBSpoolHelperEntryIfRequested"
        proc.arguments = ["-XCTest", testFilter]
        proc.environment = try isolatedEPUBHelperEnvironment(
            baseEnv: baseEnv, role: role, sharedTmp: sharedTmp, testFilter: testFilter, extra: extra
        )
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        return proc
    }

    private func createNestedOuterZipWithMinimalEPUB(in dir: URL) async throws -> URL {
        let epubBuildDir = dir.appendingPathComponent("epub_src", isDirectory: true)
        let metaInf = epubBuildDir.appendingPathComponent("META-INF", isDirectory: true)
        let oebps = epubBuildDir.appendingPathComponent("OEBPS", isDirectory: true)
        let textDir = oebps.appendingPathComponent("text", isDirectory: true)
        let stylesDir = oebps.appendingPathComponent("styles", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stylesDir, withIntermediateDirectories: true)

        try "application/epub+zip".write(to: epubBuildDir.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: metaInf.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" unique-identifier="pub-id" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">urn:uuid:spool-iso-test</dc:identifier>
            <dc:title>Spool Isolation Book</dc:title>
          </metadata>
          <manifest>
            <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="css1" href="styles/book.css" media-type="text/css"/>
            <item id="css2" href="styles/extra.css" media-type="text/css"/>
          </manifest>
          <spine><itemref idref="ch1" linear="yes"/></spine>
        </package>
        """.write(to: oebps.appendingPathComponent("package.opf"), atomically: true, encoding: .utf8)
        try "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Hello</p></body></html>"
            .write(to: textDir.appendingPathComponent("ch1.xhtml"), atomically: true, encoding: .utf8)
        try "body { color: #111; }".write(to: stylesDir.appendingPathComponent("book.css"), atomically: true, encoding: .utf8)
        try "p { margin: 0; }".write(to: stylesDir.appendingPathComponent("extra.css"), atomically: true, encoding: .utf8)

        let innerEpub = dir.appendingPathComponent("InnerSample.epub")
        try await ArchiveWriter().createArchive(
            outputPath: innerEpub.path, format: .zip, level: .fast,
            inputPaths: [
                epubBuildDir.appendingPathComponent("mimetype").path,
                metaInf.path,
                oebps.path
            ]
        )
        let outerZip = dir.appendingPathComponent("OuterBundle.zip")
        try await ArchiveWriter().createArchive(
            outputPath: outerZip.path, format: .zip, level: .fast, inputPaths: [innerEpub.path]
        )
        return outerZip
    }
}
