// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import XCTest
@testable import TTMediaKit

extension PreviewResourceLifecycleAuditTests {

    // MARK: - 1b. Cross-Process Ephemeral Media Owner Isolation & Complete Lease Contract

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

    func testCrossProcessEphemeralMediaHelperEntryIfRequested() throws {
        guard let role = ProcessInfo.processInfo.environment["TTMEDIA_EPHEMERAL_HELPER_ROLE"], !role.isEmpty else { return }
        let faultMode = ProcessInfo.processInfo.environment["TTMEDIA_HELPER_FAULT_MODE"] ?? ""
        if faultMode == "never_ready" {
            for _ in 0..<200 { Thread.sleep(forTimeInterval: 0.02) }
            return
        }
        let mp4Header = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x32, 0x00, 0x00, 0x00, 0x00])
        if role == "owner_b_hold" {
            try runOwnerBHoldHelperRole(mp4Header: mp4Header, faultMode: faultMode)
        } else if role == "owner_a_pruner" {
            try runOwnerAPrunerHelperRole(mp4Header: mp4Header)
        }
    }

    private func runOwnerBHoldHelperRole(mp4Header: Data, faultMode: String) throws {
        let env = ProcessInfo.processInfo.environment
        let readyFile = URL(fileURLWithPath: try XCTUnwrap(env["TTMEDIA_HELPER_READY_FILE"]))
        let resumeFile = URL(fileURLWithPath: try XCTUnwrap(env["TTMEDIA_HELPER_RESUME_FILE"]))
        let resultFile = URL(fileURLWithPath: try XCTUnwrap(env["TTMEDIA_HELPER_RESULT_FILE"]))
        defer { TTMediaDetector.purgeAllEphemeralMediaFiles() }

        var payloadB = mp4Header
        payloadB.append(contentsOf: "owner_b_live_video".utf8)
        let previewB = TTMediaDetector.detectTypeFromMemory(data: payloadB, suggestedName: "owner_b_active.mp4")
        guard case .video(let stagedURL) = previewB else {
            return XCTFail("Owner B failed to stage initial video: \(previewB)")
        }
        defer { TTMediaDetector.releaseEphemeralMediaFile(at: stagedURL) }

        let root1 = TTMediaDetector.ephemeralMediaRoot.standardizedFileURL.path
        let root2 = TTMediaDetector.ephemeralMediaRoot.standardizedFileURL.path
        let readyInfo: [String: String] = [
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "root1": root1, "root2": root2, "stagedPath": stagedURL.path,
            "initialExists": "\(FileManager.default.fileExists(atPath: stagedURL.path))",
            "initialLeaseCount": "\(TTMediaDetector.activeEphemeralLeaseCount(for: stagedURL))"
        ]
        try JSONEncoder().encode(readyInfo).write(to: readyFile, options: .atomic)
        if faultMode == "never_exit" {
            for _ in 0..<200 { Thread.sleep(forTimeInterval: 0.02) }
            return
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !FileManager.default.fileExists(atPath: resumeFile.path) && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard FileManager.default.fileExists(atPath: resumeFile.path), faultMode != "missing_result" else { return }

        var followUpPayload = mp4Header
        followUpPayload.append(contentsOf: "owner_b_followup".utf8)
        var followUpSucceeded = false
        if case .video(let followURL) = TTMediaDetector.detectTypeFromMemory(data: followUpPayload, suggestedName: "owner_b_followup.mp4") {
            followUpSucceeded = FileManager.default.fileExists(atPath: followURL.path)
            TTMediaDetector.releaseEphemeralMediaFile(at: followURL)
        }
        let outInfo: [String: String] = [
            "existsAfterPeerPruneAndPurge": "\(FileManager.default.fileExists(atPath: stagedURL.path))",
            "leaseCountAfterPeerPruneAndPurge": "\(TTMediaDetector.activeEphemeralLeaseCount(for: stagedURL))",
            "followUpSucceeded": "\(followUpSucceeded)",
            "rootStable": "\(root1 == root2)"
        ]
        try JSONEncoder().encode(outInfo).write(to: resultFile, options: .atomic)
    }

    private func runOwnerAPrunerHelperRole(mp4Header: Data) throws {
        let resultFile = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["TTMEDIA_HELPER_RESULT_FILE"]))
        defer { TTMediaDetector.purgeAllEphemeralMediaFiles() }
        let rootA1 = TTMediaDetector.ephemeralMediaRoot.standardizedFileURL.path
        let rootA2 = TTMediaDetector.ephemeralMediaRoot.standardizedFileURL.path
        var stagedInA: [URL] = []
        for idx in 0..<TTMediaDetector.maxStagedEphemeralFiles {
            var p = mp4Header
            p.append(contentsOf: "owner_a_slot_\(idx)".utf8)
            if case .video(let u) = TTMediaDetector.detectTypeFromMemory(data: p, suggestedName: "a_\(idx).mp4") {
                stagedInA.append(u)
            }
        }
        for u in stagedInA { TTMediaDetector.releaseEphemeralMediaFile(at: u) }
        TTMediaDetector.pruneOrphanedMediaFiles(maxRetained: 0)
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        let outInfo: [String: String] = [
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "root1": rootA1, "root2": rootA2, "stagedCount": "\(stagedInA.count)"
        ]
        try JSONEncoder().encode(outInfo).write(to: resultFile, options: .atomic)
    }

    private struct CrossProcessMediaScenarioOutcome {
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

    func testTwoHelperProcessesSharingTMPDIRIsolateEphemeralMediaRootsAndPreserveActiveLeases() throws {
        guard ProcessInfo.processInfo.environment["TTMEDIA_EPHEMERAL_HELPER_ROLE"] == nil else { return }
        let outcome = try runCrossProcessMediaScenario(faultMode: nil, timeoutSeconds: 8.0)
        XCTAssertTrue(outcome.allHelpersConfirmedExited, "Helper unconfirmed exit; evidence: \(String(describing: outcome.preservedEvidenceDir?.path))")
        XCTAssertNil(outcome.spawnAErrorDescription)
        XCTAssertFalse(outcome.readyTimedOut, "Helper B did not reach ready barrier")
        XCTAssertFalse(outcome.procATimedOut, "Helper A timed out")
        XCTAssertFalse(outcome.procBTimedOut, "Helper B timed out after resume")
        XCTAssertTrue(outcome.procAExitedCleanly, "Helper A exited with non-zero status")
        XCTAssertTrue(outcome.procBExitedCleanly, "Helper B exited with non-zero status")

        let readyB = try XCTUnwrap(outcome.readyB, "Missing Helper B ready payload")
        let resultA = try XCTUnwrap(outcome.resultA, "Missing Helper A result payload")
        let resultB = try XCTUnwrap(outcome.resultB, "Missing Helper B result payload")
        XCTAssertEqual(readyB["initialExists"], "true")
        XCTAssertEqual(readyB["initialLeaseCount"], "1")
        XCTAssertEqual(readyB["root1"], readyB["root2"], "Process ephemeralMediaRoot must be initialized once and remain immutable")
        let stagedBPath = try XCTUnwrap(readyB["stagedPath"])
        XCTAssertTrue(stagedBPath.contains("/TTMediaEphemeralStorage/"))
        XCTAssertTrue(TTPreviewResourceContext.isManagedPreviewStagingURL(URL(fileURLWithPath: stagedBPath)))
        XCTAssertEqual(resultA["root1"], resultA["root2"])
        XCTAssertNotEqual(readyB["root1"], resultA["root1"], "Distinct processes sharing TMPDIR must have isolated ephemeralMediaRoot namespaces")
        XCTAssertEqual(resultB["existsAfterPeerPruneAndPurge"], "true", "Process B's leased file must survive Process A's prune/purge")
        XCTAssertEqual(resultB["leaseCountAfterPeerPruneAndPurge"], "1")
        XCTAssertEqual(resultB["followUpSucceeded"], "true")
        XCTAssertEqual(resultB["rootStable"], "true")

        try verifyInProcessLeafLeaseContractTTLAndHandoff()
        try verifyCrossProcessMediaHelperFailurePaths()
    }

    private func verifyCrossProcessMediaHelperFailurePaths() throws {
        let neverReady = try runCrossProcessMediaScenario(faultMode: "never_ready", timeoutSeconds: 0.20)
        XCTAssertTrue(neverReady.readyTimedOut, "Expected never_ready fault to time out at ready barrier within budget")
        XCTAssertNil(neverReady.readyB)
        XCTAssertTrue(neverReady.allHelpersConfirmedExited, "Owned helper must be terminated and confirmed exited on ready timeout")
        XCTAssertNil(neverReady.preservedEvidenceDir)

        let neverExit = try runCrossProcessMediaScenario(faultMode: "never_exit", timeoutSeconds: 0.20)
        XCTAssertFalse(neverExit.readyTimedOut)
        XCTAssertTrue(neverExit.procBTimedOut, "Expected never_exit fault to time out waiting for normal exit")
        XCTAssertFalse(neverExit.procBExitedCleanly)
        XCTAssertTrue(neverExit.allHelpersConfirmedExited, "Owned helper must be terminated and confirmed exited on exit timeout")
        XCTAssertNil(neverExit.preservedEvidenceDir)

        let missingResult = try runCrossProcessMediaScenario(faultMode: "missing_result", timeoutSeconds: 2.0)
        XCTAssertFalse(missingResult.readyTimedOut)
        XCTAssertFalse(missingResult.procBTimedOut)
        XCTAssertNil(missingResult.resultB, "Expected missing_result fault to report nil resultB without throwing past cleanup")
        XCTAssertTrue(missingResult.allHelpersConfirmedExited)
        XCTAssertNil(missingResult.preservedEvidenceDir)

        let spawnAFailed = try runCrossProcessMediaScenario(faultMode: "spawn_a_fail", timeoutSeconds: 2.0)
        XCTAssertFalse(spawnAFailed.readyTimedOut)
        XCTAssertNotNil(spawnAFailed.readyB, "Helper B must be ready before Helper A spawn fault is injected")
        XCTAssertNotNil(spawnAFailed.spawnAErrorDescription, "Expected Helper A spawn error to be frozen and preserved")
        XCTAssertNil(spawnAFailed.resultA)
        XCTAssertTrue(spawnAFailed.allHelpersConfirmedExited, "Helper B must still be released and cleaned up when Helper A spawn throws")
        XCTAssertNil(spawnAFailed.preservedEvidenceDir)
    }

    private func runCrossProcessMediaScenario(faultMode: String?, timeoutSeconds: Double) throws -> CrossProcessMediaScenarioOutcome {
        let sharedTmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-two-proc-isolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedTmpRoot, withIntermediateDirectories: true)
        let readyBFile = sharedTmpRoot.appendingPathComponent("b_ready.json")
        let resumeBFile = sharedTmpRoot.appendingPathComponent("b_resume.sig")
        let resultBFile = sharedTmpRoot.appendingPathComponent("b_result.json")
        let resultAFile = sharedTmpRoot.appendingPathComponent("a_result.json")

        var outcome = CrossProcessMediaScenarioOutcome()
        var procA: Process?
        let procB = try spawnCurrentTestBinaryHelper(role: "owner_b_hold", sharedTmpDir: sharedTmpRoot, extraEnv: [
            "TTMEDIA_HELPER_READY_FILE": readyBFile.path,
            "TTMEDIA_HELPER_RESUME_FILE": resumeBFile.path,
            "TTMEDIA_HELPER_RESULT_FILE": resultBFile.path,
            "TTMEDIA_HELPER_FAULT_MODE": faultMode ?? ""
        ])

        if waitForFile(readyBFile, whileRunning: procB, timeoutSeconds: timeoutSeconds) {
            outcome.readyB = decodeJSONDictionaryIfPresent(at: readyBFile)
            let execOverrideA = (faultMode == "spawn_a_fail") ? sharedTmpRoot.appendingPathComponent("nonexistent-owned-helper-a") : nil
            do {
                let spawnedA = try spawnCurrentTestBinaryHelper(
                    role: "owner_a_pruner", sharedTmpDir: sharedTmpRoot,
                    extraEnv: ["TTMEDIA_HELPER_RESULT_FILE": resultAFile.path], executableOverride: execOverrideA
                )
                procA = spawnedA
                if waitForProcessExit(spawnedA, timeoutSeconds: timeoutSeconds), !spawnedA.isRunning {
                    outcome.procAExitedCleanly = (spawnedA.terminationStatus == 0)
                    outcome.resultA = decodeJSONDictionaryIfPresent(at: resultAFile)
                } else {
                    outcome.procATimedOut = true
                }
            } catch {
                outcome.spawnAErrorDescription = String(describing: error)
            }
            try? Data("go".utf8).write(to: resumeBFile, options: .atomic)
            if waitForProcessExit(procB, timeoutSeconds: timeoutSeconds), !procB.isRunning {
                outcome.procBExitedCleanly = (procB.terminationStatus == 0)
                outcome.resultB = decodeJSONDictionaryIfPresent(at: resultBFile)
            } else {
                outcome.procBTimedOut = true
            }
        } else {
            outcome.readyTimedOut = true
        }

        let bExited = cleanupOwnedHelperProcess(procB, resumeFile: resumeBFile)
        let aExited = cleanupOwnedHelperProcess(procA, resumeFile: nil)
        outcome.allHelpersConfirmedExited = bExited && aExited
        if outcome.allHelpersConfirmedExited {
            try? FileManager.default.removeItem(at: sharedTmpRoot)
        } else {
            outcome.preservedEvidenceDir = sharedTmpRoot
        }
        return outcome
    }

    private func verifyInProcessLeafLeaseContractTTLAndHandoff() throws {
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        defer { TTMediaDetector.purgeAllEphemeralMediaFiles() }
        let rootFirst = TTMediaDetector.ephemeralMediaRoot
        let rootSecond = TTMediaDetector.ephemeralMediaRoot
        XCTAssertEqual(rootFirst, rootSecond, "ephemeralMediaRoot getter must return stable process namespace without generating new UUIDs")
        XCTAssertTrue(rootFirst.path.contains("/TTMediaEphemeralStorage/"))

        let mp4Header = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x32, 0x00, 0x00, 0x00, 0x00])
        var idleExpiredPayload = mp4Header
        idleExpiredPayload.append(0xE1)
        var pinnedExpiredPayload = mp4Header
        pinnedExpiredPayload.append(0xE2)

        guard case .video(let idleURL) = TTMediaDetector.detectTypeFromMemory(data: idleExpiredPayload, suggestedName: "idle_ttl.mp4"),
              case .video(let pinnedURL) = TTMediaDetector.detectTypeFromMemory(data: pinnedExpiredPayload, suggestedName: "pinned_ttl.mp4") else {
            return XCTFail("Failed to stage TTL test payloads")
        }
        defer { TTMediaDetector.releaseEphemeralMediaFile(at: pinnedURL) }

        TTMediaDetector.releaseEphemeralMediaFile(at: idleURL)
        let idleDir = idleURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: idleDir, withIntermediateDirectories: true)
        try idleExpiredPayload.write(to: idleURL, options: .atomic)
        let expiredDate = Date().addingTimeInterval(-(TTMediaDetector.ephemeralFileLeaseDuration + 120))
        try FileManager.default.setAttributes([.modificationDate: expiredDate], ofItemAtPath: idleDir.path)
        try FileManager.default.setAttributes([.modificationDate: expiredDate], ofItemAtPath: pinnedURL.deletingLastPathComponent().path)

        TTMediaDetector.pruneOrphanedMediaFiles(maxRetained: TTMediaDetector.maxStagedEphemeralFiles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: idleURL.path), "Expired unpinned orphan must be reclaimed by TTL prune")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path), "Actively leased file must never be evicted even if modificationDate exceeds TTL")

        TTMediaDetector.beginFullscreenEphemeralHandoff(for: pinnedURL)
        TTMediaDetector.releaseEphemeralMediaFile(at: pinnedURL)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: pinnedURL), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path))
        TTMediaDetector.endFullscreenEphemeralHandoff(for: pinnedURL)
        XCTAssertEqual(TTMediaDetector.activeEphemeralLeaseCount(for: pinnedURL), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinnedURL.path))
    }

    private struct ParentMediaReceiptSentinelFixture {
        let sentinelXML: URL
        let sentinelBytes: Data
        let undeclaredDir: URL
        let annotationsDir: URL
        let shardFile: URL
        let prematureFile: URL
        let warningsFile: URL
        let simulatedParentEnv: [String: String]
    }

    private func makeParentMediaReceiptSentinelFixture(in tempRoot: URL) throws -> ParentMediaReceiptSentinelFixture {
        let parentReceiptDir = tempRoot.appendingPathComponent("parent-receipts", isDirectory: true)
        let undeclaredDir = parentReceiptDir.appendingPathComponent("undeclared", isDirectory: true)
        let annotationsDir = parentReceiptDir.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: undeclaredDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)
        let sentinelXML = parentReceiptDir.appendingPathComponent("parent-test.xml")
        let sentinelBytes = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <testsuites tests="462" failures="0" errors="0">
              <testsuite name="TTMediaKitTests" tests="462" failures="0" errors="0"/>
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
        env["XCTestSessionIdentifier"] = "parent-media-session-sentinel"
        return ParentMediaReceiptSentinelFixture(
            sentinelXML: sentinelXML, sentinelBytes: sentinelBytes,
            undeclaredDir: undeclaredDir, annotationsDir: annotationsDir,
            shardFile: shardFile, prematureFile: prematureFile, warningsFile: warningsFile,
            simulatedParentEnv: env
        )
    }

    func testSpawnCurrentTestBinaryHelperIsolatesParentXMLAndUndeclaredOutputsReceiptEnv() throws {
        guard ProcessInfo.processInfo.environment["TTMEDIA_EPHEMERAL_HELPER_ROLE"] == nil else { return }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-receipt-iso-\(UUID().uuidString)", isDirectory: true)
        let sharedTmp = tempRoot.appendingPathComponent("shared-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedTmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fixture = try makeParentMediaReceiptSentinelFixture(in: tempRoot)
        let resultAFile = sharedTmp.appendingPathComponent("isolated_a_result.json")
        let procA = try spawnCurrentTestBinaryHelper(
            role: "owner_a_pruner",
            sharedTmpDir: sharedTmp,
            extraEnv: ["TTMEDIA_HELPER_RESULT_FILE": resultAFile.path],
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

        let exitedA = waitForProcessExit(procA, timeoutSeconds: 8.0)
        let cleanedA = cleanupOwnedHelperProcess(procA, resumeFile: nil)
        XCTAssertTrue(exitedA && cleanedA)
        XCTAssertEqual(procA.terminationStatus, 0)
        XCTAssertNotNil(decodeJSONDictionaryIfPresent(at: resultAFile))

        let timedOutProc = try spawnCurrentTestBinaryHelper(
            role: "owner_b_hold", sharedTmpDir: sharedTmp,
            extraEnv: ["TTMEDIA_HELPER_FAULT_MODE": "never_ready"], baseEnv: fixture.simulatedParentEnv
        )
        XCTAssertTrue(cleanupOwnedHelperProcess(timedOutProc, resumeFile: nil))
        XCTAssertEqual(try Data(contentsOf: fixture.sentinelXML), fixture.sentinelBytes)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: fixture.undeclaredDir.path)) ?? []).isEmpty)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: fixture.annotationsDir.path)) ?? []).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.shardFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.prematureFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.warningsFile.path))
    }

    private func isolatedMediaHelperEnvironment(
        baseEnv: [String: String],
        role: String,
        sharedTmpDir: URL,
        filter: String,
        extraEnv: [String: String]
    ) throws -> [String: String] {
        let receiptDir = sharedTmpDir
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
        env["TMPDIR"] = sharedTmpDir.path
        env["XML_OUTPUT_FILE"] = receiptDir.appendingPathComponent("test.xml").path
        env["TEST_UNDECLARED_OUTPUTS_DIR"] = undeclaredDir.path
        env["TEST_UNDECLARED_OUTPUTS_ANNOTATIONS_DIR"] = annotationsDir.path
        env["TTMEDIA_EPHEMERAL_HELPER_ROLE"] = role
        env["TESTBRIDGE_TEST_ONLY"] = filter
        for (k, v) in extraEnv { env[k] = v }
        return env
    }

    private func spawnCurrentTestBinaryHelper(
        role: String,
        sharedTmpDir: URL,
        extraEnv: [String: String],
        baseEnv: [String: String] = ProcessInfo.processInfo.environment,
        executableOverride: URL? = nil
    ) throws -> Process {
        let proc = Process()
        proc.executableURL = executableOverride ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let filter = "PreviewResourceLifecycleAuditTests/testCrossProcessEphemeralMediaHelperEntryIfRequested"
        proc.arguments = ["-XCTest", filter]
        proc.environment = try isolatedMediaHelperEnvironment(
            baseEnv: baseEnv, role: role, sharedTmpDir: sharedTmpDir, filter: filter, extraEnv: extraEnv
        )
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        return proc
    }

    private func waitForFile(_ file: URL, whileRunning proc: Process, timeoutSeconds: Double) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeoutSeconds * 1000)))
        while !FileManager.default.fileExists(atPath: file.path) && ContinuousClock.now < deadline {
            if !proc.isRunning { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return FileManager.default.fileExists(atPath: file.path)
    }

    private func waitForProcessExit(_ proc: Process, timeoutSeconds: Double) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(timeoutSeconds * 1000)))
        while proc.isRunning && ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !proc.isRunning
    }

    private func cleanupOwnedHelperProcess(_ proc: Process?, resumeFile: URL?) -> Bool {
        guard let proc else { return true }
        let pid = proc.processIdentifier
        guard pid > 0, pid != getpid() else { return !proc.isRunning }
        if !proc.isRunning { return true }
        if let resumeFile {
            try? Data("abort".utf8).write(to: resumeFile, options: .atomic)
            if waitForProcessExit(proc, timeoutSeconds: 0.15) { return true }
        }
        proc.terminate()
        if waitForProcessExit(proc, timeoutSeconds: 0.15) { return true }
        if proc.isRunning, pid > 0, pid != getpid() {
            _ = Darwin.kill(pid, SIGKILL)
        }
        return waitForProcessExit(proc, timeoutSeconds: 0.50)
    }

    private func decodeJSONDictionaryIfPresent(at url: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }
}
