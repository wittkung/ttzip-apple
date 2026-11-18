// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import TTZipApp

@MainActor
final class AndroidDeviceViewModelTransferTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        await AndroidDeviceManager.shared.removeAllDevices(); await TransferJobCoordinator.shared.clearFinishedJobs()
    }

    override func tearDown() async throws {
        await AndroidDeviceManager.shared.removeAllDevices(); await TransferJobCoordinator.shared.clearFinishedJobs()
        try await super.tearDown()
    }

    private func waitForTerminalJob(_ jobId: String, timeoutMs: Int = 3_000) async -> AndroidTransferJob? {
        for _ in 0..<max(1, timeoutMs / 20) {
            if let job = await TransferJobCoordinator.shared.getJob(jobId: jobId), job.status.isTerminal { return job }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await TransferJobCoordinator.shared.getJob(jobId: jobId)
    }

    private func runDownloadJob(_ jobId: String, deviceId: String, remotePath: String, localPath: String, totalBytes: UInt64, conflictPolicy: AndroidTransferConflictPolicy = .overwrite) async -> AndroidTransferJob? {
        await TransferJobCoordinator.shared.enqueueJob(AndroidTransferJob(jobId: jobId, deviceId: deviceId, direction: .androidToMac, sourcePath: remotePath, destinationPath: localPath, totalBytes: totalBytes, status: .transferring, conflictPolicy: conflictPolicy))
        await TransferJobCoordinator.shared.executeDownload(jobId: jobId, deviceId: deviceId, remotePath: remotePath, localPath: localPath, conflictPolicy: conflictPolicy)
        return await waitForTerminalJob(jobId)
    }

    private func runUploadJob(_ jobId: String, deviceId: String, localPath: String, remoteDir: String, destPath: String, totalBytes: UInt64, conflictPolicy: AndroidTransferConflictPolicy = .overwrite, maxCandidates: Int = 100) async -> AndroidTransferJob? {
        await TransferJobCoordinator.shared.enqueueJob(AndroidTransferJob(jobId: jobId, deviceId: deviceId, direction: .macToAndroid, sourcePath: localPath, destinationPath: destPath, totalBytes: totalBytes, status: .transferring, conflictPolicy: conflictPolicy, maxKeepBothCandidates: maxCandidates))
        await TransferJobCoordinator.shared.executeUpload(jobId: jobId, deviceId: deviceId, localPath: localPath, remoteDir: remoteDir, conflictPolicy: conflictPolicy)
        return await waitForTerminalJob(jobId)
    }

    func testDownloadIntegrityAndZeroByteBoundaryGuards() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipQ3Download_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            MtpNativeClient.registerBridgeProvider(nil)
            Task { await TransferJobCoordinator.shared.configureTransport() }
            try? FileManager.default.removeItem(at: tempDir)
        }

        let neighborURL = tempDir.appendingPathComponent("neighbor.txt")
        let neighborData = Data("Preserved neighbor".utf8); try neighborData.write(to: neighborURL)
        let sourceURL = tempDir.appendingPathComponent("source.bin")
        let sourceData = Data((0..<131_072).map { UInt8(($0 * 73 + 19) & 0xFF) }); try sourceData.write(to: sourceURL)

        let destURL = tempDir.appendingPathComponent("downloaded.bin")
        let okJob = await runDownloadJob("job-ok", deviceId: "local-dev", remotePath: sourceURL.path, localPath: destURL.path, totalBytes: UInt64(sourceData.count))
        XCTAssertEqual(okJob?.status, .completed); XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: destURL)), SHA256.hash(data: sourceData))

        let emptySrc = tempDir.appendingPathComponent("empty.txt"); try Data().write(to: emptySrc)
        let emptyDst = tempDir.appendingPathComponent("downloaded_empty.txt")
        let emptyJob = await runDownloadJob("job-empty", deviceId: "local-dev", remotePath: emptySrc.path, localPath: emptyDst.path, totalBytes: 0)
        XCTAssertEqual(emptyJob?.status, .completed); XCTAssertEqual(try Data(contentsOf: emptyDst).count, 0)

        let adbServer = try EphemeralAdbDaemonServer(syncRecvHandler: { _ in Data("UNEXPECTED_STREAM".utf8) })
        defer { adbServer.shutdown() }
        await TransferJobCoordinator.shared.configureTransport(adbDaemonPort: adbServer.port)

        let localAdbTarget = tempDir.appendingPathComponent("adb_target.txt")
        let origAdbData = Data("ORIGINAL_ADB_INTACT".utf8); try origAdbData.write(to: localAdbTarget)
        let adbRejected = await runDownloadJob("job-adb-zero", deviceId: "adb://DEV1", remotePath: "/sdcard/s.bin", localPath: localAdbTarget.path, totalBytes: 0)
        XCTAssertEqual(adbRejected?.status, .failed); XCTAssertEqual(try Data(contentsOf: localAdbTarget), origAdbData)

        MtpNativeClient.registerBridgeProvider(MockMtpBridgeProvider(onPull: { _, _, _, _, stagedURL in
            let b = Data("MTP_SURPRISE".utf8); try b.write(to: stagedURL)
            return MtpDownloadBridgeOutcome(bytesTransferred: UInt64(b.count), sha256Hex: SHA256.hash(data: b).map { String(format: "%02x", $0) }.joined())
        }))
        let localMtpTarget = tempDir.appendingPathComponent("mtp_target.txt")
        let origMtpData = Data("ORIGINAL_MTP_INTACT".utf8); try origMtpData.write(to: localMtpTarget)
        let mtpRejected = await runDownloadJob("job-mtp-zero", deviceId: "mtp://DEV2", remotePath: "/Download/s.bin", localPath: localMtpTarget.path, totalBytes: 0)
        XCTAssertEqual(mtpRejected?.status, .failed); XCTAssertEqual(try Data(contentsOf: localMtpTarget), origMtpData)
        XCTAssertEqual(try Data(contentsOf: neighborURL), neighborData)
    }

    func testApplicationMtpBidirectionalTransferThroughCoordinator() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipQ3MtpLoop_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            Task { await TransferJobCoordinator.shared.configureTransport() }
            try? FileManager.default.removeItem(at: tempDir)
        }

        final class SafeMtpStore: @unchecked Sendable {
            private let lock = NSLock(); private var store: [String: Data]
            init(_ initData: [String: Data]) { self.store = initData }
            func get(_ k: String) -> Data? { lock.lock(); defer { lock.unlock() }; return store[k] }
            func append(_ k: String, offset: UInt64, chunk: Data) {
                lock.lock(); defer { lock.unlock() }
                var b = offset == 0 ? Data() : (store[k] ?? Data()); b.append(chunk); store[k] = b
            }
        }
        let mtpStore = SafeMtpStore(["/Download/ebook.epub": Data((0..<98_304).map { UInt8(($0 * 31 + 7) & 0xFF) })])
        await TransferJobCoordinator.shared.configureTransport(
            remoteReader: { dev, path, off, len in
                XCTAssertTrue(dev.hasPrefix("mtp://"))
                guard let d = mtpStore.get(path) else { return Data() }
                return d.subdata(in: min(Int(off), d.count)..<min(Int(off) + len, d.count))
            },
            remoteWriter: { dev, dir, file, off, chunk, _ in
                XCTAssertTrue(dev.hasPrefix("mtp://"))
                mtpStore.append(dir == "/" ? "/\(file)" : "\(dir)/\(file)", offset: off, chunk: chunk)
            }
        )

        let vm = AndroidDeviceViewModel()
        let dev = AndroidDevice(deviceId: "mtp://XFDXT", displayName: "AiNote", vendorId: 0x0E8D, productId: 0x201D, serialNumber: "XFDXT", connectionType: .usbMtp, status: .connected, storagePartitions: [AndroidStoragePartition(partitionId: "0x00010001", displayName: "Int", totalBytes: 64_000_000_000, availableBytes: 32_000_000_000, rootPath: "/")])
        vm.registerDevice(dev); vm.selectDevice(dev)

        let remoteNode = AndroidStorageNode(path: "/Download/ebook.epub", name: "ebook.epub", entryType: .file, sizeBytes: 98_304, objectHandle: 0x42)
        let dlURL = tempDir.appendingPathComponent("ebook.epub")
        let doneDl = await waitForTerminalJob(try XCTUnwrap(vm.downloadNode(remoteNode, to: dlURL)))
        XCTAssertEqual(doneDl?.status, .completed); XCTAssertEqual(try Data(contentsOf: dlURL), mtpStore.get("/Download/ebook.epub"))

        let upSourceURL = tempDir.appendingPathComponent("upload.pdf")
        let upPayload = Data((0..<131_072).map { UInt8(($0 * 17 + 3) & 0xFF) }); try upPayload.write(to: upSourceURL)
        let doneUp = await waitForTerminalJob(try XCTUnwrap(vm.uploadLocalFile(upSourceURL, to: "/Download")))
        XCTAssertEqual(doneUp?.status, .completed); XCTAssertEqual(doneUp?.verificationLevel, .sourceStreamAndRemoteSizeVerified)
        XCTAssertTrue(doneUp?.sourceStreamSha256Verified ?? false); XCTAssertTrue(doneUp?.remoteSizeVerified ?? false)
        XCTAssertEqual(mtpStore.get("/Download/upload.pdf"), upPayload)
    }

    func testSameNameTargetProtectionAndConflictPolicies() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipQ3ConflictPolicies_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            Task { await TransferJobCoordinator.shared.configureTransport() }
            try? FileManager.default.removeItem(at: tempDir)
        }

        let targetURL = tempDir.appendingPathComponent("report.bin")
        let origData = Data("ORIGINAL_CONTENT".utf8); try origData.write(to: targetURL)
        let origSha = SHA256.hash(data: origData)
        let newPayload = Data((0..<131_072).map { UInt8(($0 * 41 + 9) & 0xFF) })
        let newSourceURL = tempDir.appendingPathComponent("new.bin"); try newPayload.write(to: newSourceURL)

        await TransferJobCoordinator.shared.configureTransport(remoteReader: { _, _, off, len in
            if off > 0 { throw AdbSmartSocketError.syncProtocolError(reason: "unplug") }
            return newPayload.subdata(in: 0..<min(len, newPayload.count))
        })
        let failedJob = await runDownloadJob("job-fail", deviceId: "mtp://XFDXT", remotePath: "/report.bin", localPath: targetURL.path, totalBytes: UInt64(newPayload.count), conflictPolicy: .overwrite)
        XCTAssertEqual(failedJob?.status, .failed); XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: targetURL)), origSha)

        await TransferJobCoordinator.shared.configureTransport()
        let skippedJob = await runDownloadJob("job-skip", deviceId: "local-dev", remotePath: newSourceURL.path, localPath: targetURL.path, totalBytes: UInt64(newPayload.count), conflictPolicy: .skip)
        XCTAssertEqual(skippedJob?.status, .completed); XCTAssertTrue(skippedJob?.isSkipped ?? false); XCTAssertEqual(skippedJob?.transferredBytes, 0)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: targetURL)), origSha)

        let keepBothJob = await runDownloadJob("job-keep", deviceId: "local-dev", remotePath: newSourceURL.path, localPath: targetURL.path, totalBytes: UInt64(newPayload.count), conflictPolicy: .keepBoth)
        XCTAssertEqual(keepBothJob?.status, .completed); XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: targetURL)), origSha)
        XCTAssertEqual(try Data(contentsOf: tempDir.appendingPathComponent("report (1).bin")), newPayload)
    }

    func testUploadSameLengthSourceMutationAbortsBeforeCommit() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipQ3Mutation_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            MtpNativeClient.registerBridgeProvider(nil)
            Task { await TransferJobCoordinator.shared.configureTransport() }
            try? FileManager.default.removeItem(at: tempDir)
        }

        let sourceURL = tempDir.appendingPathComponent("mut.bin")
        let initData = Data((0..<131_072).map { UInt8(($0 * 13 + 5) & 0xFF) }); try initData.write(to: sourceURL)
        let existTarget = tempDir.appendingPathComponent("dest/mut.bin")
        try FileManager.default.createDirectory(at: existTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existBytes = Data("INTACT".utf8); try existBytes.write(to: existTarget)

        await TransferJobCoordinator.shared.configureTransport(remoteWriter: { _, _, _, off, _, _ in
            if off == 0 { var m = initData; m[90_000] ^= 0xFF; try m.write(to: sourceURL) }
        })
        let finished = await runUploadJob("job-mutate", deviceId: "adb://SN-MUT", localPath: sourceURL.path, remoteDir: "/sdcard", destPath: "/sdcard/mut.bin", totalBytes: UInt64(initData.count), conflictPolicy: .overwrite)
        XCTAssertEqual(finished?.status, .failed); XCTAssertNil(finished?.verifiedSha256Hex); XCTAssertFalse(finished?.sourceStreamSha256Verified ?? true)

        try initData.write(to: sourceURL)
        await TransferJobCoordinator.shared.configureTransport()
        MtpNativeClient.registerBridgeProvider(MockMtpBridgeProvider(onPush: { _, _, _, name, _, _, _, _ in
            MtpUploadBridgeOutcome(createdHandle: 77, finalFilename: name, bytesTransferred: 131_072, sha256Hex: String(repeating: "0", count: 64), sourceStreamSha256Verified: false, remoteSizeVerified: true, skipped: false)
        }))
        let mtpFailed = await runUploadJob("job-mtp-fail", deviceId: "mtp://XFDXT", localPath: sourceURL.path, remoteDir: "/Download", destPath: "/Download/mut.bin", totalBytes: UInt64(initData.count), conflictPolicy: .overwrite)
        XCTAssertEqual(mtpFailed?.status, .failed); XCTAssertNil(mtpFailed?.verifiedSha256Hex); XCTAssertEqual(try Data(contentsOf: existTarget), existBytes)

        MtpNativeClient.registerBridgeProvider(nil)
        let skipSubdir = tempDir.appendingPathComponent("skip_src_dir")
        try FileManager.default.createDirectory(at: skipSubdir, withIntermediateDirectories: true)
        let skipSrc = skipSubdir.appendingPathComponent("mut.bin"); try Data("NEW".utf8).write(to: skipSrc)
        let skipJob = await runUploadJob("job-up-skip", deviceId: "local-dev", localPath: skipSrc.path, remoteDir: existTarget.deletingLastPathComponent().path, destPath: existTarget.path, totalBytes: UInt64(3), conflictPolicy: .skip)
        XCTAssertEqual(skipJob?.status, .completed); XCTAssertTrue(skipJob?.isSkipped ?? false); XCTAssertEqual(skipJob?.transferredBytes, 0)
        XCTAssertEqual(try Data(contentsOf: existTarget), existBytes)
    }

    func testAdbConflictProbeFailureAndKeepBothExhaustion() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipQ3Conflict_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            Task { await TransferJobCoordinator.shared.configureTransport() }
            try? FileManager.default.removeItem(at: tempDir)
        }

        let sourceURL = tempDir.appendingPathComponent("doc.bin")
        let sourceData = Data("NEW_UPLOAD_PAYLOAD_DATA".utf8); try sourceData.write(to: sourceURL)

        let unreachableServer = try EphemeralAdbDaemonServer { cmd in
            cmd.hasPrefix("host:transport:") ? ("FAIL", "transport error") : ("FAIL", "unexpected")
        }
        defer { unreachableServer.shutdown() }
        await TransferJobCoordinator.shared.configureTransport(adbDaemonPort: unreachableServer.port)

        let statFailed = await runUploadJob("job-stat-fail", deviceId: "adb://SN-FAIL", localPath: sourceURL.path, remoteDir: "/sdcard", destPath: "/sdcard/doc.bin", totalBytes: UInt64(sourceData.count), conflictPolicy: .keepBoth)
        XCTAssertEqual(statFailed?.status, .failed); XCTAssertNil(statFailed?.verifiedSha256Hex)

        let remoteFsServer = try AndroidDeviceViewModelTests.makePosixAdbServer()
        defer { remoteFsServer.shutdown() }
        await TransferJobCoordinator.shared.configureTransport(adbDaemonPort: remoteFsServer.port)

        let destDir = tempDir.appendingPathComponent("exhaust")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let origTarget = destDir.appendingPathComponent("doc.bin"), cand2 = destDir.appendingPathComponent("doc (2).bin"), neighbor = destDir.appendingPathComponent("neighbor.txt")
        let origBytes = Data("ORIG_DOC".utf8), neighborBytes = Data("NEIGHBOR_SAFE".utf8)
        try origBytes.write(to: origTarget); try Data("CAND_1".utf8).write(to: destDir.appendingPathComponent("doc (1).bin"))
        XCTAssertEqual(Darwin.symlink("/nonexistent/dangling_cand2", cand2.path), 0); try neighborBytes.write(to: neighbor)

        for (jobId, devId) in [("job-adb-keepboth-exhaust", "adb://SN-REMOTE"), ("job-local-keepboth-exhaust", "local-dev")] {
            let exhaustedJob = await runUploadJob(jobId, deviceId: devId, localPath: sourceURL.path, remoteDir: destDir.path, destPath: origTarget.path, totalBytes: UInt64(sourceData.count), conflictPolicy: .keepBoth, maxCandidates: 2)
            XCTAssertEqual(exhaustedJob?.status, .failed); XCTAssertNil(exhaustedJob?.verifiedSha256Hex)
        }
        XCTAssertEqual(try Data(contentsOf: origTarget), origBytes); XCTAssertEqual(try Data(contentsOf: neighbor), neighborBytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: cand2.path), "/nonexistent/dangling_cand2")
    }

    func testConcurrentTargetProtectionAndDirectoryCommitRefusal() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipQ3Race_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let remoteFsServer = try AndroidDeviceViewModelTests.makePosixAdbServer()
        defer { remoteFsServer.shutdown() }

        let sourceData = Data("NEW_UPLOAD_PAYLOAD_DATA".utf8)
        let raceDir = tempDir.appendingPathComponent("race")
        try FileManager.default.createDirectory(at: raceDir, withIntermediateDirectories: true)
        let stagedRaceURL = raceDir.appendingPathComponent("staged.part"), finalRaceURL = raceDir.appendingPathComponent("concurrent.bin")
        let concurrentWinnerBytes = Data("CONCURRENT_WINNER_MUST_NOT_BE_OVERWRITTEN".utf8)
        try sourceData.write(to: stagedRaceURL); try concurrentWinnerBytes.write(to: finalRaceURL)

        XCTAssertThrowsError(try AdbSmartSocketClient.commitStagedRemoteFile(
            serial: "SN-REMOTE", stagedRemotePath: stagedRaceURL.path, finalRemotePath: finalRaceURL.path,
            expectedBytes: UInt64(sourceData.count), conflictPolicy: .keepBoth, daemonPort: remoteFsServer.port
        ))
        XCTAssertEqual(try Data(contentsOf: finalRaceURL), concurrentWinnerBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedRaceURL.path))

        let danglingFinalURL = raceDir.appendingPathComponent("dangling_target.bin")
        XCTAssertEqual(Darwin.symlink("/nonexistent/broken_target", danglingFinalURL.path), 0)
        try sourceData.write(to: stagedRaceURL)
        XCTAssertThrowsError(try AdbSmartSocketClient.commitStagedRemoteFile(
            serial: "SN-REMOTE", stagedRemotePath: stagedRaceURL.path, finalRemotePath: danglingFinalURL.path,
            expectedBytes: UInt64(sourceData.count), conflictPolicy: .skip, daemonPort: remoteFsServer.port
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedRaceURL.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: danglingFinalURL.path), "/nonexistent/broken_target")

        let dirFinalURL = tempDir.appendingPathComponent("existing_target_dir")
        try FileManager.default.createDirectory(at: dirFinalURL, withIntermediateDirectories: true)
        let canaryURL = dirFinalURL.appendingPathComponent("canary.txt"); try Data("CANARY_SAFE".utf8).write(to: canaryURL)
        let dirStageURL = tempDir.appendingPathComponent("stage_for_dir.stage"); try sourceData.write(to: dirStageURL)
        XCTAssertThrowsError(try AdbSmartSocketClient.commitStagedRemoteFile(
            serial: "SN-REMOTE", stagedRemotePath: dirStageURL.path, finalRemotePath: dirFinalURL.path,
            expectedBytes: UInt64(sourceData.count), conflictPolicy: .overwrite, daemonPort: remoteFsServer.port
        )) { err in
            XCTAssertTrue("\(err)".contains("is a directory on remote device"), "Error: \(err)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirStageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirFinalURL.appendingPathComponent("stage_for_dir.stage").path))
        XCTAssertEqual(try Data(contentsOf: canaryURL), Data("CANARY_SAFE".utf8))

        try sourceData.write(to: stagedRaceURL)
        XCTAssertThrowsError(try TransferJobCoordinator.atomicCommitLocalFile(from: stagedRaceURL.path, to: finalRaceURL.path, allowOverwrite: false))
        XCTAssertEqual(try Data(contentsOf: finalRaceURL), concurrentWinnerBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedRaceURL.path))
    }

    func testAtomicCommitRefusalOnUnsupportedToolAndFilesystem() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipQ3ToolCheck_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceData = Data("TEST_SOURCE_PAYLOAD".utf8)
        let failServer = try EphemeralAdbDaemonServer(
            syncStatHandler: { _ in (0o100644, UInt32(sourceData.count), 1_700_000_000) },
            shellHandler: { cmd in
                if cmd.contains("ln -T") { return AndroidDeviceViewModelTests.runLocalPosixShell("ln() { echo \"Operation not permitted\" >&2; return 1; }; " + cmd) }
                return cmd.contains("mv -f") ? "TTZIP_COMMIT_FAILED\n" : "TTZIP_TOOL_OPTION_UNSUPPORTED\n"
            }
        )
        defer { failServer.shutdown() }
        let stage1 = tempDir.appendingPathComponent("stage1.bin"), final1 = tempDir.appendingPathComponent("final1.bin")
        try sourceData.write(to: stage1)
        do {
            try AdbSmartSocketClient.commitStagedRemoteFile(serial: "SN-FUSE", stagedRemotePath: stage1.path, finalRemotePath: final1.path, expectedBytes: UInt64(sourceData.count), conflictPolicy: .keepBoth, daemonPort: failServer.port)
            XCTFail("Must refuse commit on filesystem without hardlink support")
        } catch { XCTAssertTrue("\(error)".contains("does not support atomic hardlink commit"), "Error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage1.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: final1.path))

        let stage2 = tempDir.appendingPathComponent("stage2.bin"), final2 = tempDir.appendingPathComponent("final2.bin")
        try sourceData.write(to: stage2)
        let toolServer = try EphemeralAdbDaemonServer(
            syncStatHandler: { _ in (0o100644, UInt32(sourceData.count), 1_700_000_000) },
            shellHandler: { $0.hasPrefix("rm -f") ? AndroidDeviceViewModelTests.runLocalPosixShell($0) : "TTZIP_TOOL_OPTION_UNSUPPORTED\n" }
        )
        defer { toolServer.shutdown() }
        do {
            try AdbSmartSocketClient.commitStagedRemoteFile(serial: "SN-TOOL", stagedRemotePath: stage2.path, finalRemotePath: final2.path, expectedBytes: UInt64(sourceData.count), conflictPolicy: .overwrite, daemonPort: toolServer.port)
            XCTFail("Must refuse commit when tool option -T is unsupported")
        } catch { XCTAssertTrue("\(error)".contains("tool option -T unsupported"), "Error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage2.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: final2.path))
    }

    func testProductionAdbPostCommitStatFailureTransitionsToUnknown() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipQ3PostCommit_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            Task { await TransferJobCoordinator.shared.configureTransport() }
            try? FileManager.default.removeItem(at: tempDir)
        }

        let sourceURL = tempDir.appendingPathComponent("source_doc.bin")
        let payload = Data("PRODUCTION_PAYLOAD_FOR_UNKNOWN_STATE".utf8); try payload.write(to: sourceURL)
        let expectedSha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let server = try EphemeralAdbDaemonServer(
            syncStatHandler: { path in
                if path.hasSuffix("source_doc.bin") && !path.contains(".ttzip_part_") { return (0, 0, 0) }
                if path.contains(".ttzip_part_") { return (0o100644, UInt32(payload.count), 1_700_000_000) }
                return (0, 0, 0)
            },
            syncSendHandler: { _, _ in true },
            shellHandler: { cmd in (cmd.contains("mv -f") || cmd.contains("ln -T")) ? "TTZIP_COMMIT_OK\n" : "" }
        )
        defer { server.shutdown() }
        await TransferJobCoordinator.shared.configureTransport(adbDaemonPort: server.port)

        let vm = AndroidDeviceViewModel(autoStartHardwareMonitoring: false); vm.adbDaemonPort = server.port
        let dev = AndroidDevice(deviceId: "adb://SN-UNKNOWN-DEV", displayName: "Test Dev", vendorId: 0x18D1, productId: 0x4EE2, serialNumber: "SN-UNKNOWN-DEV", connectionType: .usbAdb, status: .connected)
        vm.registerDevice(dev); vm.selectDevice(dev)

        let jobId = try XCTUnwrap(vm.uploadLocalFile(sourceURL, to: "/sdcard", conflictPolicy: .overwrite))
        let finalJob = await waitForTerminalJob(jobId)

        XCTAssertEqual(finalJob?.status, .failed); XCTAssertEqual(finalJob?.commitPhase, .unknown)
        XCTAssertEqual(finalJob?.verifiedSha256Hex, expectedSha); XCTAssertTrue(finalJob?.sourceStreamSha256Verified ?? false)
        XCTAssertFalse(finalJob?.remoteSizeVerified ?? true); XCTAssertFalse(finalJob?.remoteReadbackSha256Verified ?? true)
        XCTAssertEqual(finalJob?.verificationLevel, AndroidTransferVerificationLevel.none); XCTAssertTrue(finalJob?.errorMessage?.contains("Commit status unknown") ?? false)

        XCTAssertEqual(vm.activeTransfer?.commitPhase, .unknown); XCTAssertEqual(vm.activeTransfer?.status, .failed)
        XCTAssertTrue(vm.activeTransfer?.sourceStreamSha256Verified ?? false); XCTAssertFalse(vm.activeTransfer?.remoteSizeVerified ?? true)
    }

    func testThreePhaseCancellationAndPostCommitBarrier() async throws {
        let coord = TransferJobCoordinator.shared
        let j1 = AndroidTransferJob(jobId: "c-p1", deviceId: "d1", direction: .macToAndroid, sourcePath: "/s", destinationPath: "/d", totalBytes: 10, status: .transferring)
        await coord.enqueueJob(j1); let c1 = await coord.cancelJob(jobId: "c-p1"); XCTAssertTrue(c1)
        let s1 = await coord.getJob(jobId: "c-p1"); XCTAssertEqual(s1?.status, .cancelling)

        let j2 = AndroidTransferJob(jobId: "c-p2", deviceId: "d1", direction: .macToAndroid, sourcePath: "/s", destinationPath: "/d", totalBytes: 10, status: .transferring)
        await coord.enqueueJob(j2); await coord.markJobCommitted(jobId: "c-p2")
        let c2 = await coord.cancelJob(jobId: "c-p2"); XCTAssertFalse(c2)
        await coord.finalizeJob(jobId: "c-p2", status: .failed, errorMessage: "Cancelled by user")
        let s2 = await coord.getJob(jobId: "c-p2"); XCTAssertNotEqual(s2?.status, .failed)
        await coord.recordVerifiedDigest(jobId: "c-p2", sha256Hex: "feedbeef", verificationLevel: .remoteReadbackSha256Verified, sourceStreamSha256Verified: true, remoteSizeVerified: true, remoteReadbackSha256Verified: true)
        await coord.finalizeJob(jobId: "c-p2", status: .completed)
        let s2Done = await coord.getJob(jobId: "c-p2")
        XCTAssertEqual(s2Done?.status, .completed); XCTAssertEqual(s2Done?.verifiedSha256Hex, "feedbeef")

        let cancelledAfterDone = await coord.cancelJob(jobId: "c-p2")
        XCTAssertFalse(cancelledAfterDone)
    }

    func testRealDeviceApplicationMtpCoordinatorClosedLoopWhenExplicitlyEnabled() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TTZIP_ENABLE_REAL_DEVICE_TESTS"] == "1", let targetSerial = env["TTZIP_TEST_MTP_SERIAL"],
              !targetSerial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, MtpNativeClient.currentBridgeProvider() != nil else { return }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipQ3RealMtpApp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        await TransferJobCoordinator.shared.configureTransport()

        let remoteFileName = "TTZip_Q3_SwiftCoord_\(UUID().uuidString.prefix(8)).bin"
        let remotePath = "/\(remoteFileName)"
        defer {
            try? MtpNativeClient.deleteObject(serial: targetSerial, storageId: 0, objectHandle: 0, remotePath: remotePath)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let vm = AndroidDeviceViewModel(autoStartHardwareMonitoring: false)
        let realMtpDevice = AndroidDevice(deviceId: "mtp://\(targetSerial)", displayName: "Physical MTP Device (\(targetSerial))", vendorId: 0x0E8D, productId: 0x201D, serialNumber: targetSerial, connectionType: .usbMtp, status: .connected, storagePartitions: [AndroidStoragePartition(partitionId: "0x00010001", displayName: "Internal", totalBytes: 64_000_000_000, availableBytes: 32_000_000_000, rootPath: "/")])
        vm.registerDevice(realMtpDevice); vm.selectDevice(realMtpDevice)

        let sourceURL = tempDir.appendingPathComponent(remoteFileName)
        let payload = Data((0..<262_144).map { UInt8(($0 * 53 + 19) & 0xFF) })
        try payload.write(to: sourceURL)
        let finishedUpload = await waitForTerminalJob(try XCTUnwrap(vm.uploadLocalFile(sourceURL, to: "/", conflictPolicy: .overwrite)))
        XCTAssertEqual(finishedUpload?.status, .completed)

        let remoteNode = AndroidStorageNode(
            path: remotePath,
            name: remoteFileName,
            entryType: .file,
            sizeBytes: UInt64(payload.count),
            objectHandle: finishedUpload?.objectHandle
        )
        let downloadedURL = tempDir.appendingPathComponent("downloaded_\(remoteFileName)")
        let finishedDownload = await waitForTerminalJob(try XCTUnwrap(vm.downloadNode(remoteNode, to: downloadedURL, conflictPolicy: .overwrite)))
        XCTAssertEqual(finishedDownload?.status, .completed)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: downloadedURL)), SHA256.hash(data: payload))
    }
}
