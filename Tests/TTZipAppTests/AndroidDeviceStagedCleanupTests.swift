// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import Darwin
@testable import TTZipApp

/// Observability of the staged-file cleanup performed on a deterministic ADB commit refusal.
///
/// The contract under test is `android-interconnect.md` §4.6.4: a refusal must state whether the
/// staging file owned by this task is gone, still present, or could not be confirmed, and it must
/// never claim a cleanup that was not observed.
///
/// Three concerns are kept apart on purpose:
///
/// - **path-aware `STAT`** answers from the real filesystem, so the remote state is never faked;
/// - **the delete command** is executed for real, so the cleanup is exercised end to end;
/// - **injected failures** are limited to the one behaviour each case is about.
///
/// The device's answer to the *commit* command and its behaviour on the *cleanup* command are two
/// independent knobs, so a case can reach exactly the production stage it claims to test.
@MainActor
final class AndroidDeviceStagedCleanupTests: XCTestCase {
    private static let payload = Data("STAGED_CLEANUP_PAYLOAD".utf8)

    /// What the device answers to the commit command.
    private enum CommitReply: Sendable {
        /// The commit is refused with an explicit conflict marker.
        case refusal
        /// The device reports a committed transfer.
        case committed
    }

    /// How the fake device answers the staged-cleanup command.
    private enum CleanupBehaviour: Sendable {
        /// The delete runs for real and the device returns its terminal record.
        case executeAndReport
        /// The device refuses the delete (permission denied) and still reports a terminal record.
        case deleteDenied
        /// The device refuses the delete and the shell exits before any terminal record.
        case deleteDeniedThenShellExit
        /// The delete runs for real, then the connection drops before any terminal record.
        case deleteThenConnectionDrop
        /// The device answers without any record at all.
        case noTerminalRecord
        /// The device answers with a record that carries a foreign (older) call token.
        case staleTokenRecord
        /// The device answers with a record whose state this build does not know.
        case unknownStateRecord
        /// The device answers with two conflicting records for this call.
        case contradictoryRecords
        /// The device answers with the same record twice.
        case duplicateIdenticalRecords
        /// The device answers with the record ahead of the diagnostic that normally precedes it.
        case recordBeforeDiagnostic
        /// The device retires its listener while answering the commit, before the cleanup connects.
        case deviceUnavailableBeforeCleanupConnect
    }

    /// Carries the running fake server so a shell handler can retire it mid-conversation.
    private final class ServerHandle: @unchecked Sendable {
        var server: EphemeralAdbDaemonServer?
    }

    override func setUp() async throws {
        try await super.setUp()
    }

    override func tearDown() async throws {
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// Builds a fake device whose `STAT` answers from the real filesystem.
    ///
    /// The commit reply and the cleanup behaviour are independent, so every case reaches exactly
    /// the production stage it claims to test.
    private static func makeCleanupServer(
        commitReply: CommitReply = .refusal,
        cleanupBehaviour: CleanupBehaviour
    ) throws -> EphemeralAdbDaemonServer {
        let handle = ServerHandle()
        let server = try EphemeralAdbDaemonServer(
            syncStatHandler: { path in
                var st = Darwin.stat()
                guard Darwin.lstat(path, &st) == 0 else { return (0, 0, 0) }
                let isSymlink = (UInt32(st.st_mode) & 0o170000) == 0o120000
                return (
                    UInt32(st.st_mode),
                    isSymlink ? 0 : UInt32(clamping: st.st_size),
                    UInt32(clamping: st.st_mtimespec.tv_sec)
                )
            },
            shellHandler: { command in
                // The cleanup command is the only one that starts with the delete verb; the commit
                // command starts with its own `if [ -d ... ]` guard.
                if command.hasPrefix("rm -f ") {
                    return Self.answerCleanup(command: command, behaviour: cleanupBehaviour)
                }
                if case .deviceUnavailableBeforeCleanupConnect = cleanupBehaviour {
                    // Retire the listener while the refusal answer is produced. The current
                    // connection still completes its answer, but the cleanup command can no longer
                    // establish a connection — a failure that provably happened before the send.
                    handle.server?.shutdown()
                }
                return commitReply == .committed ? "TTZIP_COMMIT_OK\n" : "TTZIP_CONFLICT_TARGET_EXISTS\n"
            }
        )
        handle.server = server
        return server
    }

    /// Produces the device's answer to the cleanup command for the requested behaviour.
    ///
    /// Pure command handling: it touches no actor state, so it is deliberately nonisolated and
    /// callable from the fake's nonisolated `@Sendable` shell handler.
    private nonisolated static func answerCleanup(command: String, behaviour: CleanupBehaviour) -> String {
        switch behaviour {
        case .executeAndReport:
            return AndroidDeviceViewModelTests.runLocalPosixShell(command)
        case .deleteDenied:
            // The refusal quotes the path, exactly like a real `rm` does.
            return AndroidDeviceViewModelTests.runLocalPosixShell(
                "rm() { echo \"rm: cannot remove '$*': Permission denied\" >&2; return 1; }; " + command
            )
        case .deleteDeniedThenShellExit:
            // The shell dies before it can emit the terminal record.
            return AndroidDeviceViewModelTests.runLocalPosixShell(
                "rm() { echo \"rm: cannot remove '$*': Permission denied\" >&2; exit 1; }; " + command
            )
        case .deleteThenConnectionDrop:
            _ = AndroidDeviceViewModelTests.runLocalPosixShell(command)
            return ""
        case .noTerminalRecord:
            return "TTZIP_TOOL_OPTION_UNSUPPORTED\n"
        case .staleTokenRecord:
            return "TTZIP_STAGE_CLEARED:\(UUID().uuidString)\n"
        case .unknownStateRecord:
            guard let token = cleanupToken(in: command) else { return "" }
            return "TTZIP_STAGE_UNKNOWN:\(token)\n"
        case .contradictoryRecords:
            guard let token = cleanupToken(in: command) else { return "" }
            return "TTZIP_STAGE_CLEARED:\(token)\nTTZIP_STAGE_RESIDUAL:\(token)\n"
        case .duplicateIdenticalRecords:
            guard let token = cleanupToken(in: command) else { return "" }
            return "TTZIP_STAGE_RESIDUAL:\(token)\nTTZIP_STAGE_RESIDUAL:\(token)\n"
        case .recordBeforeDiagnostic:
            guard let token = cleanupToken(in: command) else { return "" }
            return "TTZIP_STAGE_RESIDUAL:\(token)\nrm: cannot remove staging file: Permission denied\n"
        case .deviceUnavailableBeforeCleanupConnect:
            return ""
        }
    }

    /// Extracts the per-call cleanup token the production embedded in its own command.
    ///
    /// Pure string parsing over the command text, so it is deliberately nonisolated.
    private nonisolated static func cleanupToken(in command: String) -> String? {
        var cursor = command.startIndex
        while let echoRange = command.range(of: "echo '", range: cursor..<command.endIndex) {
            let payloadStart = echoRange.upperBound
            guard let end = command[payloadStart...].firstIndex(of: "'") else { return nil }
            let record = String(command[payloadStart..<end])
            if record.hasPrefix("TTZIP_STAGE_"), let colon = record.firstIndex(of: ":") {
                return String(record[record.index(after: colon)...])
            }
            cursor = command.index(after: end)
        }
        return nil
    }

    /// Creates the staging file, the target path and the neighbours that must stay untouched.
    private static func makeFixture(
        stagedName: String = ".ttzip_part_job-1_doc.bin"
    ) throws -> (dir: URL, staged: URL, finalTarget: URL, siblingStage: URL, canary: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipQ3Cleanup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent(stagedName)
        let finalTarget = dir.appendingPathComponent("doc.bin")
        let siblingStage = dir.appendingPathComponent(".ttzip_part_job-2_doc.bin")
        let canary = dir.appendingPathComponent("canary.txt")
        try Self.payload.write(to: staged)
        try Data("OTHER_TASK_PAYLOAD".utf8).write(to: siblingStage)
        try Data("CANARY_SAFE".utf8).write(to: canary)
        return (dir, staged, finalTarget, siblingStage, canary)
    }

    /// Commits with the given policy and returns the refusal error the production raised.
    ///
    /// The error is captured, never re-thrown: a refusal is the expected outcome here, so letting
    /// it escape would abort the case before any cleanup assertion runs. A commit that
    /// unexpectedly succeeds is reported as a failure instead of being masked by a synthesised
    /// error.
    private static func captureRefusal(
        server: EphemeralAdbDaemonServer,
        staged: URL,
        finalTarget: URL,
        policy: AndroidTransferConflictPolicy
    ) -> Error? {
        do {
            try AdbSmartSocketClient.commitStagedRemoteFile(
                serial: "SN-CLEANUP",
                stagedRemotePath: staged.path,
                finalRemotePath: finalTarget.path,
                expectedBytes: UInt64(Self.payload.count),
                conflictPolicy: policy,
                daemonPort: server.port
            )
        } catch {
            return error
        }
        XCTFail("commitStagedRemoteFile was expected to refuse the commit")
        return nil
    }

    // MARK: - Terminal states

    /// Confirmed absence: the delete command succeeded, so the staging path is gone and the
    /// refusal carries no cleanup complaint.
    func testStagedCleanupConfirmedAbsentWhenDeleteSucceeds() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Self.makeCleanupServer(cleanupBehaviour: .executeAndReport)
        defer { server.shutdown() }

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        XCTAssertTrue(message.contains("already exists or appeared concurrently"), "Error: \(error)")
        XCTAssertFalse(message.contains("still present at"), "Error: \(error)")
        XCTAssertFalse(message.contains("could not be confirmed"), "Error: \(error)")
        XCTAssertFalse(message.contains("was not attempted"), "Error: \(error)")
        // The delete really ran on the device side.
        XCTAssertTrue(
            server.receivedCommands.contains { $0.hasPrefix("shell:rm -f ") },
            "Expected a cleanup delete command, got \(server.receivedCommands)"
        )
        // Actual file state: only this task's staging path is gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    /// Observed residue: the delete command failed and the staging path is still observable, so
    /// the refusal must name the residual path and the file must really still be there.
    func testStagedCleanupResidualObservedWhenDeleteFails() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Self.makeCleanupServer(cleanupBehaviour: .deleteDenied)
        defer { server.shutdown() }

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        XCTAssertTrue(message.contains("already exists or appeared concurrently"), "Error: \(error)")
        XCTAssertTrue(message.contains("remote staging file still present at"), "Error: \(error)")
        XCTAssertTrue(message.contains(staged.path), "Error: \(error)")
        XCTAssertFalse(message.contains("could not be confirmed"), "Error: \(error)")
        // Actual file state: the residual is real, not only reported.
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    /// Unverified execution or result: the device answered without a record for this call, so absence
    /// must not be claimed and a residual must not be invented either.
    func testStagedCleanupUnverifiedWhenRecordMissing() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Self.makeCleanupServer(cleanupBehaviour: .noTerminalRecord)
        defer { server.shutdown() }

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        XCTAssertTrue(message.contains("already exists or appeared concurrently"), "Error: \(error)")
        XCTAssertTrue(message.contains("remote staging cleanup could not be confirmed"), "Error: \(error)")
        // An inconclusive receipt must not be turned into a residual claim.
        XCTAssertFalse(message.contains("still present at"), "Error: \(error)")
        XCTAssertFalse(message.contains("was not attempted"), "Error: \(error)")
        // Actual file state: nothing deleted it, and the refusal does not pretend otherwise.
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    // MARK: - Record boundary

    /// A staged path may contain record-looking text, and the device quotes that path in its own
    /// diagnostics. A diagnostic that merely *mentions* a record is not a record for this call.
    func testStagedCleanupIgnoresBareConstantQuotedByDevice() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture(
            stagedName: "TTZIP_STAGE_CLEARED.stage"
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Self.makeCleanupServer(cleanupBehaviour: .deleteDenied)
        defer { server.shutdown() }

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        // The diagnostic really does contain the bare constant, so a substring match would
        // mis-classify the live residual as a confirmed cleanup.
        XCTAssertTrue(message.contains("remote staging file still present at"), "Error: \(error)")
        XCTAssertTrue(message.contains(staged.path), "Error: \(error)")
        XCTAssertFalse(message.contains("could not be confirmed"), "Error: \(error)")
        XCTAssertFalse(message.contains("was not attempted"), "Error: \(error)")
        // Actual file state: the file is still there, so the refusal must not read as "cleaned".
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    /// A staged path may contain a newline, which lets the device's diagnostic span several lines
    /// and place a bare success constant on a line of its own. The record must still be bound to
    /// this call, so the outcome is unconfirmed and the file is still there.
    func testStagedCleanupUnverifiedWhenNewlinePathForgesBareConstant() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture(
            stagedName: "prefix\nTTZIP_STAGE_CLEARED\nsuffix.stage"
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        // The delete is refused and the shell dies before it can emit the terminal record.
        let server = try Self.makeCleanupServer(cleanupBehaviour: .deleteDeniedThenShellExit)
        defer { server.shutdown() }

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        // The forged constant must not be read as this call's record.
        XCTAssertTrue(message.contains("remote staging cleanup could not be confirmed"), "Error: \(error)")
        XCTAssertFalse(message.contains("still present at"), "Error: \(error)")
        XCTAssertFalse(message.contains("was not attempted"), "Error: \(error)")
        // Actual file state: the delete was refused, so the file is still there.
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    /// A record that carries a foreign call token belongs to another attempt and must not prove
    /// anything about this one.
    func testStagedCleanupUnverifiedOnStaleTokenRecord() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Self.makeCleanupServer(cleanupBehaviour: .staleTokenRecord)
        defer { server.shutdown() }

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        XCTAssertTrue(message.contains("remote staging cleanup could not be confirmed"), "Error: \(error)")
        XCTAssertFalse(message.contains("still present at"), "Error: \(error)")
        XCTAssertFalse(message.contains("was not attempted"), "Error: \(error)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    /// Two conflicting records for the same call are contradictory and must not be resolved by
    /// preferring one of them.
    func testStagedCleanupUnverifiedOnContradictoryRecords() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Self.makeCleanupServer(cleanupBehaviour: .contradictoryRecords)
        defer { server.shutdown() }

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        XCTAssertTrue(message.contains("remote staging cleanup could not be confirmed"), "Error: \(error)")
        XCTAssertFalse(message.contains("still present at"), "Error: \(error)")
        XCTAssertFalse(message.contains("was not attempted"), "Error: \(error)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    /// A record for this call whose state this build does not know is not a usable outcome.
    func testStagedCleanupUnverifiedOnUnknownStateRecord() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Self.makeCleanupServer(cleanupBehaviour: .unknownStateRecord)
        defer { server.shutdown() }

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        XCTAssertTrue(message.contains("remote staging cleanup could not be confirmed"), "Error: \(error)")
        XCTAssertFalse(message.contains("still present at"), "Error: \(error)")
        XCTAssertFalse(message.contains("was not attempted"), "Error: \(error)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    /// Repeating the same record is idempotent: it still resolves to that one state.
    func testStagedCleanupAcceptsRepeatedIdenticalRecord() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Self.makeCleanupServer(cleanupBehaviour: .duplicateIdenticalRecords)
        defer { server.shutdown() }

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        XCTAssertTrue(message.contains("remote staging file still present at"), "Error: \(error)")
        XCTAssertFalse(message.contains("could not be confirmed"), "Error: \(error)")
        XCTAssertFalse(message.contains("was not attempted"), "Error: \(error)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    /// The device forwards stdout and stderr over one stream without ordering them, so the record
    /// may arrive before the diagnostic that normally precedes it.
    func testStagedCleanupAcceptsRecordRegardlessOfPosition() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Self.makeCleanupServer(cleanupBehaviour: .recordBeforeDiagnostic)
        defer { server.shutdown() }

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        XCTAssertTrue(message.contains("remote staging file still present at"), "Error: \(error)")
        XCTAssertFalse(message.contains("could not be confirmed"), "Error: \(error)")
        XCTAssertFalse(message.contains("was not attempted"), "Error: \(error)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    // MARK: - Execution uncertainty

    /// The delete already ran and the connection dropped before any terminal record arrived. The
    /// staging file may be gone, but the refusal must report the outcome as unconfirmed and must
    /// not claim the cleanup was never attempted.
    func testStagedCleanupExecutedThenConnectionLostReportsUnconfirmed() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Self.makeCleanupServer(cleanupBehaviour: .deleteThenConnectionDrop)
        defer { server.shutdown() }

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        XCTAssertTrue(message.contains("remote staging cleanup could not be confirmed"), "Error: \(error)")
        XCTAssertFalse(message.contains("was not attempted"), "Error: \(error)")
        XCTAssertFalse(message.contains("still present at"), "Error: \(error)")
        // The delete did run, so the staging file is gone even though the outcome is unconfirmed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    /// The device retires its listener while answering the commit, so the cleanup command cannot
    /// establish a connection at all. That failure provably happened before the send, so the
    /// refusal may say the cleanup was not attempted — and the staging file must still be there.
    func testStagedCleanupNotAttemptedWhenDeviceUnavailableBeforeSend() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Self.makeCleanupServer(cleanupBehaviour: .deviceUnavailableBeforeCleanupConnect)

        let error = try XCTUnwrap(Self.captureRefusal(server: server, staged: staged, finalTarget: finalTarget, policy: .keepBoth))
        let message = "\(error)"

        XCTAssertTrue(message.contains("already exists or appeared concurrently"), "Error: \(error)")
        XCTAssertTrue(message.contains("remote staging cleanup was not attempted"), "Error: \(error)")
        XCTAssertFalse(message.contains("still present at"), "Error: \(error)")
        XCTAssertFalse(message.contains("could not be confirmed"), "Error: \(error)")
        // The cleanup command never reached the device, so nothing was deleted.
        XCTAssertFalse(
            server.receivedCommands.contains { $0.hasPrefix("shell:rm -f ") },
            "Cleanup must not have been sent, got \(server.receivedCommands)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalTarget.path))
    }

    // MARK: - Negative control

    /// Negative control: a commit whose result is unknown must not be treated as a refusal, so no
    /// cleanup runs and the device-side target file stays exactly as it is.
    func testUnknownCommitPreservesTargetAndSkipsCleanup() throws {
        let (dir, staged, finalTarget, siblingStage, canary) = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        // The device reports a committed transfer, but the target metadata does not match, so the
        // post-commit STAT is what turns this into an unknown commit.
        let winnerBytes = Data("CONCURRENT_WINNER_MUST_NOT_BE_OVERWRITTEN".utf8)
        try winnerBytes.write(to: finalTarget)
        let server = try Self.makeCleanupServer(commitReply: .committed, cleanupBehaviour: .executeAndReport)
        defer { server.shutdown() }

        var raised: Error?
        do {
            try AdbSmartSocketClient.commitStagedRemoteFile(
                serial: "SN-CLEANUP",
                stagedRemotePath: staged.path,
                finalRemotePath: finalTarget.path,
                expectedBytes: UInt64(Self.payload.count),
                conflictPolicy: .overwrite,
                daemonPort: server.port
            )
        } catch {
            raised = error
        }

        let error = try XCTUnwrap(raised, "commitStagedRemoteFile was expected to fail")
        guard let adbError = error as? AdbSmartSocketError, case .commitStatusUnknown = adbError else {
            XCTFail("Expected commitStatusUnknown, got \(error)")
            return
        }
        XCTAssertTrue("\(error)".contains("target file preserved on device"), "Error: \(error)")
        // No cleanup may run on the unknown path.
        XCTAssertFalse(
            server.receivedCommands.contains { $0.hasPrefix("shell:rm -f ") },
            "Unknown commit must not trigger a staging cleanup, got \(server.receivedCommands)"
        )
        // Actual file state: the target and the neighbours are untouched.
        XCTAssertEqual(try Data(contentsOf: finalTarget), winnerBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingStage.path))
        XCTAssertEqual(try Data(contentsOf: canary), Data("CANARY_SAFE".utf8))
    }
}
