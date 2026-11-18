// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// ADB atomic commit policy, refusal classification and staged-file cleanup observability.
///
/// The commit entry point runs exactly one deterministic pipeline:
///
/// 1. **receipt classification** — `commitRefusalReason` maps the device receipt to a refusal
///    category (or `nil` when the device reported a committed transfer);
/// 2. **cleanup execution and observation** — `cleanupStagedRemoteFile` removes the staging path
///    owned by this task and observes what actually happened to it;
/// 3. **error presentation** — the refusal reason and the cleanup conclusion are composed once,
///    at the single place where the refusal error is raised.
///
/// The contract these three steps implement lives in `android-interconnect.md` §4.6.
extension AdbSmartSocketClient {
    /// Observable outcome of the staged-file cleanup performed for a deterministic refusal.
    ///
    /// The four states map one-to-one onto the contract's
    /// confirmed absence, observed residue, unverified outcome, and no attempt. Only `confirmedAbsent` asserts that
    /// the staging path is gone; the other three states never claim a successful cleanup.
    private enum StagedCleanupOutcome {
        case confirmedAbsent
        case residualObserved
        case attemptedUnverified
        case notAttempted

        /// Renders the cleanup conclusion into the refusal reason without weakening its meaning.
        func presentation(stagedRemotePath: String) -> String {
            switch self {
            case .confirmedAbsent:
                return ""
            case .residualObserved:
                return "; remote staging file still present at '\(stagedRemotePath)'"
            case .attemptedUnverified:
                return "; remote staging cleanup could not be confirmed for '\(stagedRemotePath)'"
            case .notAttempted:
                return "; remote staging cleanup was not attempted for '\(stagedRemotePath)'"
            }
        }
    }

    /// Builds the atomic commit shell command for the requested conflict policy.
    ///
    /// The in-band `rm -f` of the staging path is the device-side best effort that survives a
    /// dropped connection. The observable conclusion about that path is produced exactly once,
    /// by `cleanupStagedRemoteFile`, and never inferred from this command's text.
    private static func buildCommitShellCommand(stagedPath: String, finalPath: String, conflictPolicy: AndroidTransferConflictPolicy) -> String {
        let escStage = shellSingleQuote(stagedPath), escFinal = shellSingleQuote(finalPath)
        switch conflictPolicy {
        case .overwrite:
            return "if [ -d \(escFinal) ]; then rm -f \(escStage); echo 'TTZIP_TARGET_IS_DIRECTORY'; else err=$(mv -f -T \(escStage) \(escFinal) 2>&1); res=$?; if [ $res -eq 0 ]; then echo 'TTZIP_COMMIT_OK'; elif [ -d \(escFinal) ]; then rm -f \(escStage); echo 'TTZIP_TARGET_IS_DIRECTORY'; elif echo \"$err\" | grep -Eq 'invalid option|illegal option|unrecognized'; then rm -f \(escStage); echo 'TTZIP_TOOL_OPTION_UNSUPPORTED'; else rm -f \(escStage); echo 'TTZIP_COMMIT_FAILED'; fi; fi"
        case .skip, .keepBoth:
            return "if [ -d \(escFinal) ]; then rm -f \(escStage); echo 'TTZIP_TARGET_IS_DIRECTORY'; elif [ -e \(escFinal) ] || [ -L \(escFinal) ]; then rm -f \(escStage); echo 'TTZIP_CONFLICT_TARGET_EXISTS'; else err=$(ln -T \(escStage) \(escFinal) 2>&1); res=$?; rm -f \(escStage); if [ $res -eq 0 ]; then echo 'TTZIP_COMMIT_OK'; elif [ -d \(escFinal) ]; then echo 'TTZIP_TARGET_IS_DIRECTORY'; elif [ -e \(escFinal) ] || [ -L \(escFinal) ]; then echo 'TTZIP_CONFLICT_TARGET_EXISTS'; elif echo \"$err\" | grep -Eq 'invalid option|illegal option|unrecognized'; then echo 'TTZIP_TOOL_OPTION_UNSUPPORTED'; elif echo \"$err\" | grep -Eq 'Permitted|permitted|cross-device|link|EPERM|EXDEV'; then echo 'TTZIP_HARDLINK_UNSUPPORTED'; else echo 'TTZIP_COMMIT_FAILED'; fi; fi"
        }
    }

    /// Classifies a commit receipt into a refusal reason, or `nil` when the receipt reports success.
    ///
    /// Marker precedence follows the device-side emission order, so a receipt that carries several
    /// markers keeps resolving to the same category as before.
    private static func commitRefusalReason(trimmedOut: String, finalRemotePath: String) -> String? {
        if trimmedOut.contains("TTZIP_TARGET_IS_DIRECTORY") {
            return "Target path '\(finalRemotePath)' is a directory on remote device; cannot commit file to directory"
        }
        if trimmedOut.contains("TTZIP_CONFLICT_TARGET_EXISTS") {
            return "Target file '\(finalRemotePath)' already exists or appeared concurrently under non-overwrite policy"
        }
        if trimmedOut.contains("TTZIP_TOOL_OPTION_UNSUPPORTED") {
            return "Remote tool option -T unsupported for atomic commit to '\(finalRemotePath)'"
        }
        if trimmedOut.contains("TTZIP_HARDLINK_UNSUPPORTED") || trimmedOut.contains("TTZIP_NOCLOBBER_UNSUPPORTED") {
            return "Remote filesystem does not support atomic hardlink commit for '\(finalRemotePath)'"
        }
        if !trimmedOut.contains("TTZIP_COMMIT_OK") {
            return trimmedOut.isEmpty ? "Remote commit failed without TTZIP_COMMIT_OK" : trimmedOut
        }
        return nil
    }

    /// Removes the staging path owned by this task and observes whether it is gone.
    ///
    /// The delete and the observation run inside one shell command, so the emitted marker reflects
    /// the real operation result instead of an unconditional success echo:
    ///
    /// - `rm` exits successfully → the path was unlinked or never existed → **confirmed absent**;
    /// - `rm` fails and the path is still observable → **residual observed** (direct positive
    ///   evidence);
    /// - `rm` fails and the path cannot be observed → **unverified**; absence is *not* claimed,
    ///   because a failed delete plus an unobservable path cannot distinguish "gone" from
    ///   "not observable" (unreadable parent directory, permission or I/O failure).
    ///
    /// A remote `STAT` is deliberately not consulted: `mode == 0` only means `lstat` did not
    /// succeed and therefore cannot prove absence.
    private static func cleanupStagedRemoteFile(
        serial: String, stagedRemotePath: String, daemonHost: String, daemonPort: UInt16, timeoutMs: Int32
    ) -> StagedCleanupOutcome {
        // A per-call token binds the terminal record to this cleanup attempt. The staged path is
        // derived from a user file name and the device quotes it verbatim in its diagnostics, so no
        // content of that path may ever be able to impersonate this call's record.
        let token = UUID().uuidString
        let escaped = shellSingleQuote(stagedRemotePath)
        let command = "rm -f \(escaped); rc=$?; if [ $rc -eq 0 ]; then echo 'TTZIP_STAGE_CLEARED:\(token)'; elif [ -e \(escaped) ] || [ -L \(escaped) ]; then echo 'TTZIP_STAGE_RESIDUAL:\(token)'; else echo 'TTZIP_STAGE_UNVERIFIED:\(token)'; fi"
        do {
            let receipt = try executeShellCommand(
                serial: serial, command: command, daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs
            )
            return classifyCleanupReceipt(receipt, token: token)
        } catch let error as AdbSmartSocketError {
            // Only a failure to establish the connection proves the command never left this host.
            // Every other failure may have happened after the delete was sent, so it must not be
            // reported as "not attempted".
            switch error {
            case .daemonUnreachable, .invalidEndpoint:
                return .notAttempted
            default:
                return .attemptedUnverified
            }
        } catch {
            return .attemptedUnverified
        }
    }

    /// Parses the cleanup receipt under one strict boundary.
    ///
    /// Only a record that carries **this call's token** counts. The token is generated for this
    /// attempt alone, so a record from an older call, or any text that merely quotes a record
    /// constant (the device repeats the staged path verbatim in its diagnostics), can never prove
    /// anything about this attempt.
    ///
    /// The receipt must resolve to exactly one terminal state: no record at all, an unknown state
    /// carrying this token, or two conflicting states carrying this token all degrade to
    /// `attemptedUnverified`. The same state repeated is idempotent and is accepted.
    ///
    /// The position of the record is not relied upon: the device forwards stdout and stderr over one
    /// stream and does not guarantee their relative order.
    private static func classifyCleanupReceipt(_ receipt: String, token: String) -> StagedCleanupOutcome {
        var states: Set<StagedCleanupOutcome> = []
        for line in receipt.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let record = cleanupRecord(forLine: trimmed) else { continue }
            guard record.token == token else { continue }
            guard let state = record.state else { return .attemptedUnverified }
            states.insert(state)
        }
        guard states.count == 1, let outcome = states.first else { return .attemptedUnverified }
        return outcome
    }

    /// Splits one receipt line into the terminal state it names and the call token it carries.
    ///
    /// Returns `nil` for lines that are not records at all (device diagnostics, unrelated output).
    /// The state is `nil` when the line carries a record prefix this build does not know.
    private static func cleanupRecord(forLine line: String) -> (state: StagedCleanupOutcome?, token: String)? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let prefix = String(line[line.startIndex..<separator])
        let token = String(line[line.index(after: separator)...])
        guard prefix.hasPrefix("TTZIP_STAGE_") else { return nil }
        let state: StagedCleanupOutcome?
        switch prefix {
        case "TTZIP_STAGE_CLEARED": state = .confirmedAbsent
        case "TTZIP_STAGE_RESIDUAL": state = .residualObserved
        case "TTZIP_STAGE_UNVERIFIED": state = .attemptedUnverified
        default: state = nil
        }
        return (state, token)
    }

    /// Raises the refusal error for a commit receipt, running the staged cleanup exactly once.
    ///
    /// The cleanup conclusion is appended to the refusal reason so the caller can tell a refusal
    /// whose staging file is gone from one whose staging file may still sit on the device.
    private static func verifyRemoteCommitOutput(
        trimmedOut: String, finalRemotePath: String, stagedRemotePath: String,
        serial: String, daemonHost: String, daemonPort: UInt16, timeoutMs: Int32
    ) throws {
        guard let reason = commitRefusalReason(trimmedOut: trimmedOut, finalRemotePath: finalRemotePath) else { return }
        let cleanup = cleanupStagedRemoteFile(
            serial: serial, stagedRemotePath: stagedRemotePath,
            daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs
        )
        throw AdbSmartSocketError.syncProtocolError(
            reason: reason + cleanup.presentation(stagedRemotePath: stagedRemotePath)
        )
    }

    private static func statAndVerifyPostCommit(
        serial: String, finalRemotePath: String, expectedU32: UInt32,
        daemonHost: String, daemonPort: UInt16, timeoutMs: Int32
    ) throws {
        let statAfter: (exists: Bool, mode: UInt32, size: UInt32, mtime: UInt32)
        do {
            statAfter = try statRemoteFile(serial: serial, remotePath: finalRemotePath, daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs)
        } catch {
            throw AdbSmartSocketError.commitStatusUnknown(
                reason: "Remote post-commit STAT failed for '\(finalRemotePath)': \(error.localizedDescription); target file preserved on device"
            )
        }
        guard statAfter.exists, (statAfter.mode & 0o170000) == 0o100000, statAfter.size == expectedU32 else {
            throw AdbSmartSocketError.commitStatusUnknown(
                reason: "Remote post-commit STAT reported invalid metadata for '\(finalRemotePath)' (exists=\(statAfter.exists), size=\(statAfter.size)); target file preserved on device"
            )
        }
    }

    /// Commits a verified remote staging file to its final destination path and verifies via `STAT`.
    /// Rejects 32-bit overflow (`expectedBytes > UInt64(UInt32.max)`) and prevents `.skip`/`.keepBoth`
    /// from overwriting an existing or concurrently created target file.
    ///
    /// Every deterministic refusal cleans up the staging path owned by this task and reports what
    /// could be observed about it. A connection lost **after** the commit command was sent is not a
    /// refusal: it stays `.unknown` and the device-side target file is preserved untouched.
    public static func commitStagedRemoteFile(
        serial: String,
        stagedRemotePath: String,
        finalRemotePath: String,
        expectedBytes: UInt64,
        conflictPolicy: AndroidTransferConflictPolicy = .overwrite,
        daemonHost: String = defaultDaemonHost,
        daemonPort: UInt16 = defaultDaemonPort,
        timeoutMs: Int32 = 5_000
    ) throws {
        guard expectedBytes <= UInt64(UInt32.max) else {
            let cleanup = cleanupStagedRemoteFile(
                serial: serial, stagedRemotePath: stagedRemotePath,
                daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs
            )
            throw AdbSmartSocketError.syncProtocolError(
                reason: "Cannot commit remote file exceeding 32-bit STAT limit (\(expectedBytes) bytes)"
                    + cleanup.presentation(stagedRemotePath: stagedRemotePath)
            )
        }
        let expectedU32 = UInt32(expectedBytes)
        let statBefore = try statRemoteFile(serial: serial, remotePath: stagedRemotePath, daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs)
        guard statBefore.exists, statBefore.size == expectedU32 else {
            let cleanup = cleanupStagedRemoteFile(
                serial: serial, stagedRemotePath: stagedRemotePath,
                daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs
            )
            throw AdbSmartSocketError.syncProtocolError(
                reason: "Remote staging verification failed for '\(stagedRemotePath)': expected \(expectedU32) bytes, STAT reported \(statBefore.size) bytes"
                    + cleanup.presentation(stagedRemotePath: stagedRemotePath)
            )
        }

        let commitCommand = buildCommitShellCommand(stagedPath: stagedRemotePath, finalPath: finalRemotePath, conflictPolicy: conflictPolicy)
        let out: String
        do {
            out = try executeShellCommand(serial: serial, command: commitCommand, daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs)
        } catch {
            throw AdbSmartSocketError.commitStatusUnknown(reason: "Connection dropped or timeout during commit command for '\(finalRemotePath)': \(error.localizedDescription)")
        }
        let trimmedOut = out.trimmingCharacters(in: .whitespacesAndNewlines)
        try verifyRemoteCommitOutput(trimmedOut: trimmedOut, finalRemotePath: finalRemotePath, stagedRemotePath: stagedRemotePath, serial: serial, daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs)
        try statAndVerifyPostCommit(serial: serial, finalRemotePath: finalRemotePath, expectedU32: expectedU32, daemonHost: daemonHost, daemonPort: daemonPort, timeoutMs: timeoutMs)
    }
}
