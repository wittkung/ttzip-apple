// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import TTZipApp

struct MockMtpBridgeProvider: MtpTransferBridgeProvider {
    var onPull: (@Sendable (String, UInt32, UInt32, String, URL) throws -> MtpDownloadBridgeOutcome)? = nil
    var onPush: (@Sendable (String, UInt32, String, String, URL, String, AndroidTransferConflictPolicy, Int) throws -> MtpUploadBridgeOutcome)? = nil
    func pullFileToLocalStaged(serialOrId: String, storageId: UInt32, objectHandle: UInt32, remotePath: String, stagedLocalURL: URL, onProgress: @escaping @Sendable (UInt64, UInt64) -> Bool) throws -> MtpDownloadBridgeOutcome {
        try onPull?(serialOrId, storageId, objectHandle, remotePath, stagedLocalURL) ?? MtpDownloadBridgeOutcome(bytesTransferred: 0, sha256Hex: "")
    }
    func pushLocalFileVerified(serialOrId: String, storageId: UInt32, parentDirOrHandle: String, fileName: String, localSourceURL: URL, expectedSha256Hex: String, conflictPolicy: AndroidTransferConflictPolicy, maxKeepBothCandidates: Int, onProgress: @escaping @Sendable (UInt64, UInt64) -> Bool) throws -> MtpUploadBridgeOutcome {
        try onPush?(serialOrId, storageId, parentDirOrHandle, fileName, localSourceURL, expectedSha256Hex, conflictPolicy, maxKeepBothCandidates) ?? MtpUploadBridgeOutcome(createdHandle: 0, finalFilename: fileName, bytesTransferred: 0, sha256Hex: "", sourceStreamSha256Verified: false, remoteSizeVerified: false, skipped: false)
    }
    func deleteRemoteObject(serialOrId: String, storageId: UInt32, objectHandle: UInt32, remotePath: String) throws {}
}

/// Ephemeral local TCP Smart Socket server speaking AOSP `host:pair`, `host:connect`, `host:devices-l`, and `SYNC`.
final class EphemeralAdbDaemonServer: @unchecked Sendable {
    let port: UInt16
    private let listenFd: Int32
    private let lock = NSLock()
    private let closeLock = NSLock()
    private var isShutDown = false
    private(set) var receivedCommands: [String] = []
    private let handler: @Sendable (String) -> (status: String, payload: String)
    private let syncStatHandler: (@Sendable (String) -> (mode: UInt32, size: UInt32, mtime: UInt32))?
    private let syncRecvHandler: (@Sendable (String) -> Data?)?
    private let syncSendHandler: (@Sendable (String, Data) -> Bool)?
    private let shellHandler: (@Sendable (String) -> String)?

    init(
        handler: @escaping @Sendable (String) -> (status: String, payload: String) = { _ in ("OKAY", "") },
        syncStatHandler: (@Sendable (String) -> (mode: UInt32, size: UInt32, mtime: UInt32))? = nil,
        syncRecvHandler: (@Sendable (String) -> Data?)? = nil,
        syncSendHandler: (@Sendable (String, Data) -> Bool)? = nil,
        shellHandler: (@Sendable (String) -> String)? = nil
    ) throws {
        self.handler = handler
        self.syncStatHandler = syncStatHandler
        self.syncRecvHandler = syncRecvHandler
        self.syncSendHandler = syncSendHandler
        self.shellHandler = shellHandler

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "EphemeralAdbDaemonServer", code: Int(errno)) }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: 0,
            sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard bound, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "EphemeralAdbDaemonServer", code: Int(errno))
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.listenFd = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
    }

    deinit { shutdown() }
    /// Closes the listening socket. Idempotent on purpose: the fake can be retired from inside a
    /// shell handler and then released, and closing an already closed descriptor twice could hit a
    /// descriptor number that another thread has since reused.
    func shutdown() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isShutDown else { return }
        isShutDown = true
        Darwin.close(listenFd)
    }

    private func acceptLoop() {
        while true {
            var clientAddr = sockaddr_in(), clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenFd, $0, &clientLen) }
            }
            if clientFd < 0 { break }
            handleClient(clientFd)
        }
    }

    private func readSmartCommand(_ fd: Int32) -> String? {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        guard Darwin.recv(fd, &lenBuf, 4, MSG_WAITALL) == 4,
              let hexStr = String(bytes: lenBuf, encoding: .utf8),
              let cmdLen = Int(hexStr, radix: 16) else { return nil }
        var cmdBuf = [UInt8](repeating: 0, count: cmdLen)
        guard Darwin.recv(fd, &cmdBuf, cmdLen, MSG_WAITALL) == cmdLen,
              let cmd = String(bytes: cmdBuf, encoding: .utf8) else { return nil }
        lock.lock(); receivedCommands.append(cmd); lock.unlock()
        return cmd
    }

    private func handleClient(_ fd: Int32) {
        defer { Darwin.close(fd) }
        guard let cmd = readSmartCommand(fd) else { return }
        if cmd.hasPrefix("host:transport:") {
            let tResp = handler(cmd)
            guard tResp.status == "OKAY" else {
                let failBytes = Array((tResp.status + String(format: "%04x", tResp.payload.utf8.count) + tResp.payload).utf8)
                _ = failBytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, failBytes.count, 0) }
                return
            }
            _ = "OKAY".withCString { Darwin.send(fd, $0, 4, 0) }
            guard let subCmd = readSmartCommand(fd) else { return }
            if subCmd == "sync:" {
                _ = "OKAY".withCString { Darwin.send(fd, $0, 4, 0) }
                handleSyncLoop(fd)
            } else if subCmd.hasPrefix("shell:"), let shFn = shellHandler {
                _ = "OKAY".withCString { Darwin.send(fd, $0, 4, 0) }
                let out = Array(shFn(String(subCmd.dropFirst("shell:".count))).utf8)
                if !out.isEmpty { _ = out.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, out.count, 0) } }
            }
            return
        }
        let response = handler(cmd)
        let framed = response.status + String(format: "%04x", response.payload.utf8.count) + response.payload
        let bytes = Array(framed.utf8)
        _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, bytes.count, 0) }
    }

    private func handleSyncLoop(_ fd: Int32) {
        while true {
            var hdr = [UInt8](repeating: 0, count: 8)
            guard Darwin.recv(fd, &hdr, 8, MSG_WAITALL) == 8 else { break }
            let tag = String(decoding: hdr[0..<4], as: UTF8.self)
            let val = Int(UInt32(hdr[4]) | (UInt32(hdr[5]) << 8) | (UInt32(hdr[6]) << 16) | (UInt32(hdr[7]) << 24))
            if tag == "QUIT" { break }
            var pBuf = [UInt8](repeating: 0, count: val)
            if val > 0 { guard Darwin.recv(fd, &pBuf, val, MSG_WAITALL) == val else { break } }
            let path = String(decoding: pBuf, as: UTF8.self)
            lock.lock(); receivedCommands.append("\(tag):\(path)"); lock.unlock()
            if tag == "STAT", let st = syncStatHandler?(path) {
                var r = Array("STAT".utf8)
                for v in [st.mode.littleEndian, st.size.littleEndian, st.mtime.littleEndian] { withUnsafeBytes(of: v) { r.append(contentsOf: $0) } }
                _ = r.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, r.count, 0) }
            } else if tag == "RECV", let data = syncRecvHandler?(path) {
                if !data.isEmpty {
                    var chk = Array("DATA".utf8); withUnsafeBytes(of: UInt32(data.count).littleEndian) { chk.append(contentsOf: $0) }
                    _ = chk.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, chk.count, 0) }
                    _ = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, data.count, 0) }
                }
                let done = Array("DONE\0\0\0\0".utf8); _ = done.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, done.count, 0) }
            } else if tag == "SEND" {
                var payload = Data()
                while true {
                    var f = [UInt8](repeating: 0, count: 8)
                    guard Darwin.recv(fd, &f, 8, MSG_WAITALL) == 8 else { break }
                    let fTag = String(decoding: f[0..<4], as: UTF8.self)
                    let fLen = Int(UInt32(f[4]) | (UInt32(f[5]) << 8) | (UInt32(f[6]) << 16) | (UInt32(f[7]) << 24))
                    if fTag == "DATA" {
                        var chunk = [UInt8](repeating: 0, count: fLen)
                        guard Darwin.recv(fd, &chunk, fLen, MSG_WAITALL) == fLen else { break }
                        payload.append(contentsOf: chunk)
                    } else if fTag == "DONE" { break }
                }
                _ = syncSendHandler?(path, payload)
                let ok = Array("OKAY\0\0\0\0".utf8); _ = ok.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!, ok.count, 0) }
            }
        }
    }
}

@MainActor
final class AndroidDeviceViewModelTests: XCTestCase {
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

    func testInitialViewModelState() {
        let vm = AndroidDeviceViewModel()
        XCTAssertFalse(vm.isScanning); XCTAssertFalse(vm.isLoading); XCTAssertEqual(vm.connectionState, .disconnected)
        XCTAssertEqual(vm.devices.count, 0); XCTAssertEqual(vm.connectedDevices.count, 0)
        XCTAssertNil(vm.selectedDevice); XCTAssertNil(vm.selectedPartition)
    }

    func testRefreshHardwareDevicesNonBlockingExecution() async {
        let vm = AndroidDeviceViewModel()
        XCTAssertFalse(vm.isScanning); await vm.refreshHardwareDevices(); XCTAssertFalse(vm.isScanning)
    }

    func testPairWirelessDeviceSuccessAndStateProgression() async throws {
        let server = try EphemeralAdbDaemonServer { cmd in
            switch cmd {
            case "host:pair:123456:192.168.1.100:37123": return ("OKAY", "Successfully paired to 192.168.1.100:37123 [guid=adb-pixel8]\n")
            case "host:connect:192.168.1.100:5555": return ("OKAY", "connected to 192.168.1.100:5555\n")
            case "host:devices-l": return ("OKAY", "192.168.1.100:5555 device product:husky model:Pixel_8_Pro device:husky transport_id:4\n")
            default: return ("FAIL", "unexpected command: \(cmd)")
            }
        }
        defer { server.shutdown() }
        let vm = AndroidDeviceViewModel(); vm.adbDaemonPort = server.port
        try await vm.pairWirelessDevice(pin: "123456", host: "192.168.1.100", port: 37123, connectionPort: 5555)
        XCTAssertTrue(server.receivedCommands.contains("host:pair:123456:192.168.1.100:37123"))
        XCTAssertTrue(server.receivedCommands.contains("host:connect:192.168.1.100:5555"))
        XCTAssertTrue(server.receivedCommands.contains("host:devices-l"))
        XCTAssertFalse(vm.isLoading); XCTAssertEqual(vm.connectionState, .connected)
        XCTAssertEqual(vm.selectedDevice?.connectionType, .wirelessAdb); XCTAssertEqual(vm.selectedDevice?.status, .connected)
        XCTAssertEqual(vm.selectedDevice?.displayName, "Pixel 8 Pro")
        XCTAssertFalse(vm.selectedDevice?.storagePartitions.isEmpty ?? true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(vm.devices.contains(where: { $0.connectionType == .wirelessAdb }))
    }

    func testPairWirelessDeviceRejectsWrongOrExpiredPin() async throws {
        let server = try EphemeralAdbDaemonServer { $0.hasPrefix("host:pair:") ? ("OKAY", "Failed: Wrong password or connection was dropped.\n") : ("FAIL", "unexpected") }
        defer { server.shutdown() }
        let vm = AndroidDeviceViewModel(); vm.adbDaemonPort = server.port
        do {
            try await vm.pairWirelessDevice(pin: "999999", host: "192.168.1.100", port: 37123); XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(vm.connectionState, .error); XCTAssertNil(vm.selectedDevice)
            XCTAssertTrue(vm.devices.isEmpty); XCTAssertEqual(server.receivedCommands, ["host:pair:999999:192.168.1.100:37123"])
        }
    }

    func testPairWirelessDeviceRejectsUnauthorizedDeviceSession() async throws {
        let server = try EphemeralAdbDaemonServer { cmd in
            switch cmd {
            case "host:pair:654321:192.168.1.100:37123": return ("OKAY", "Successfully paired to 192.168.1.100:37123\n")
            case "host:connect:192.168.1.100:5555": return ("OKAY", "connected to 192.168.1.100:5555\n")
            case "host:devices-l": return ("OKAY", "192.168.1.100:5555 unauthorized transport_id:7\n")
            default: return ("FAIL", "unexpected command")
            }
        }
        defer { server.shutdown() }
        let vm = AndroidDeviceViewModel(); vm.adbDaemonPort = server.port
        do {
            try await vm.pairWirelessDevice(pin: "654321", host: "192.168.1.100", port: 37123, connectionPort: 5555); XCTFail("Expected throw")
        } catch {
            XCTAssertEqual(vm.connectionState, .error); XCTAssertNil(vm.selectedDevice); XCTAssertTrue(vm.devices.isEmpty)
        }
    }

    func testPairWirelessDeviceParameterValidationFailure() async {
        let vm = AndroidDeviceViewModel()
        for (pin, host, port) in [("123", "192.168.1.100", UInt16(5555)), ("12ab56", "192.168.1.100", 5555), ("123456", "", 5555), ("123456", "192.168.1.100", 0)] {
            do { try await vm.pairWirelessDevice(pin: pin, host: host, port: port); XCTFail("Expected invalid params to throw") }
            catch { XCTAssertEqual(vm.connectionState, .error); XCTAssertFalse(vm.isLoading) }
        }
    }

    func testDeviceSelectionAndEjectionStateLifecycle() async {
        let vm = AndroidDeviceViewModel()
        let partition = AndroidStoragePartition(partitionId: "internal", displayName: "Internal", totalBytes: 256_000_000_000, availableBytes: 128_000_000_000, rootPath: "/storage/emulated/0")
        let testDevice = AndroidDevice(deviceId: "test-device-001", displayName: "Pixel 9 Pro", vendorId: 0x18d1, productId: 0x4ee2, serialNumber: "SN123456", connectionType: .usbAdb, status: .connected, storagePartitions: [partition])
        await AndroidDeviceManager.shared.registerDevice(testDevice)
        try? await Task.sleep(nanoseconds: 50_000_000)
        vm.selectDevice(testDevice)
        XCTAssertEqual(vm.selectedDevice?.deviceId, testDevice.deviceId); XCTAssertEqual(vm.connectionState, .connected); XCTAssertEqual(vm.selectedPartition?.partitionId, "internal")
        vm.ejectDevice(testDevice)
        XCTAssertNil(vm.selectedDevice); XCTAssertEqual(vm.connectionState, .disconnected)
    }

    func testMultiDeviceIsolationAndMtpObjectHandleResolution() async throws {
        let vm = AndroidDeviceViewModel(autoStartHardwareMonitoring: false)
        vm.directoryLister = { _, _ in [] }
        let devA = AndroidDevice(deviceId: "mtp://3725:8221:XFDXT", displayName: "AiNote X5", vendorId: 0x0E8D, productId: 0x201D, serialNumber: "XFDXT", connectionType: .usbMtp, status: .connected)
        let devB = AndroidDevice(deviceId: "adb://192.168.1.88:5555", displayName: "Pixel", vendorId: 0x18D1, productId: 0x4EE7, serialNumber: "192.168.1.88:5555", connectionType: .wirelessAdb, status: .connected)
        vm.registerDevice(devA); vm.registerDevice(devB); vm.selectDevice(devA)

        let node = AndroidStorageNode(path: "/Books", name: "Books", entryType: .directory, objectHandle: 42)
        vm.storeCachedNodes([node], forPath: "/", windowID: nil)
        vm.directoryCache["/Unscoped"] = [AndroidStorageNode(path: "/Leak", name: "Leak", entryType: .directory, objectHandle: 99)]
        XCTAssertNil(vm.resolveMtpObjectHandle(forPath: "/Leak"))
        XCTAssertEqual(vm.resolveMtpObjectHandle(forPath: "/Books"), 42)
        vm.selectDevice(devB)
        XCTAssertTrue(vm.directoryCache.isEmpty); XCTAssertNil(vm.resolveMtpObjectHandle(forPath: "/Books"))
    }

    func testPairWirelessDeviceNeverDefaultsConnectPortToPairingPort() async throws {
        let server = try EphemeralAdbDaemonServer { cmd in
            switch cmd {
            case "host:pair:123456:192.168.1.100:37123": return ("OKAY", "Successfully paired to 192.168.1.100:37123 [guid=adb-pixel8]\n")
            case "host:devices-l": return ("OKAY", "List of devices attached\n")
            default: return ("FAIL", "unexpected command: \(cmd)")
            }
        }
        defer { server.shutdown() }
        let vm = AndroidDeviceViewModel(); vm.adbDaemonPort = server.port
        for p in [nil as UInt16?, UInt16(37123)] {
            do {
                try await vm.pairWirelessDevice(pin: "123456", host: "192.168.1.100", port: 37123, connectionPort: p)
                XCTFail("Expected throw")
            } catch let err as AdbSmartSocketError {
                XCTAssertEqual(err, .connectPortUnresolved(host: "192.168.1.100"))
            }
        }
        XCTAssertFalse(server.receivedCommands.contains("host:connect:192.168.1.100:37123"))
    }

    nonisolated static func runLocalPosixShell(_ command: String) -> String {
        let wrapper = "mv() { has_T=0; dest=\"\"; for a in \"$@\"; do [ \"$a\" = \"-T\" ] && has_T=1; dest=\"$a\"; done; [ \"$has_T\" = \"1\" ] && [ -d \"$dest\" ] && return 1; args=\"\"; for a in \"$@\"; do [ \"$a\" != \"-T\" ] && args=\"$args \\\"$a\\\"\"; done; eval /bin/mv $args; }; ln() { has_T=0; dest=\"\"; for a in \"$@\"; do [ \"$a\" = \"-T\" ] && has_T=1; dest=\"$a\"; done; [ \"$has_T\" = \"1\" ] && [ -d \"$dest\" ] && return 1; args=\"\"; for a in \"$@\"; do [ \"$a\" != \"-T\" ] && args=\"$args \\\"$a\\\"\"; done; eval /bin/ln $args; }; " + command
        let proc = Process(); proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", wrapper]
        let pipe = Pipe(); proc.standardOutput = pipe; proc.standardError = pipe
        try? proc.run(); proc.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    static func makePosixAdbServer() throws -> EphemeralAdbDaemonServer {
        try EphemeralAdbDaemonServer(
            syncStatHandler: { path in
                var st = Darwin.stat(); guard Darwin.lstat(path, &st) == 0 else { return (0, 0, 0) }
                let isSym = (UInt32(st.st_mode) & 0o170000) == 0o120000
                return (UInt32(st.st_mode), isSym ? 0 : UInt32(clamping: st.st_size), UInt32(clamping: st.st_mtimespec.tv_sec))
            },
            shellHandler: { cmd in Self.runLocalPosixShell(cmd) }
        )
    }

    func testSameModelMultiDeviceSerialDisambiguationAndBounded64KiBOverflowGuards() throws {
        let dev1 = AndroidDevice(deviceId: "mtp://XFDXT510EF46P04061", displayName: "AiNote X5", vendorId: 0x0E8D, productId: 0x201D, serialNumber: "XFDXT510EF46P04061", connectionType: .usbMtp, status: .connected)
        let dev2 = AndroidDevice(deviceId: "mtp://XFDXT510EF46P99999", displayName: "AiNote X5", vendorId: 0x0E8D, productId: 0x201D, serialNumber: "XFDXT510EF46P99999", connectionType: .usbMtp, status: .connected)
        XCTAssertThrowsError(try AndroidDeviceManager.selectUniqueDevice(from: [dev1, dev2], matching: ""))
        XCTAssertThrowsError(try AndroidDeviceManager.selectUniqueDevice(from: [dev1, dev2], matching: "AiNote X5"))
        let res2 = try AndroidDeviceManager.selectUniqueDevice(from: [dev1, dev2], matching: "XFDXT510EF46P99999")
        XCTAssertEqual(res2.deviceId, "mtp://XFDXT510EF46P99999"); XCTAssertEqual(res2.serialNumber, "XFDXT510EF46P99999")

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("bounded_\(UUID().uuidString).bin")
        let payload = Data((0..<200_000).map { UInt8(($0 * 29 + 11) & 0xFF) }); try payload.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertThrowsError(try MtpNativeClient.streamLocalFileBounded64KiB(localURL: tempURL, declaredSize: kMaxMtpSendObjectBytes + 1) { _, _, _ in })

        var maxChunkObserved = 0, chunkCount = 0
        let (bytesRead, streamedSha) = try MtpNativeClient.streamLocalFileBounded64KiB(localURL: tempURL, declaredSize: UInt64(payload.count)) { chunk, _, _ in
            maxChunkObserved = max(maxChunkObserved, chunk.count); chunkCount += 1
        }
        XCTAssertEqual(bytesRead, UInt64(payload.count)); XCTAssertLessThanOrEqual(maxChunkObserved, 65_536); XCTAssertEqual(chunkCount, 4)
        XCTAssertEqual(streamedSha, SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
    }

    func testIssue312WirelessConnectWindowBindDisconnectEvictionAndPinInput() async throws {
        let ep = DiscoveredWirelessEndpoint(host: "192.168.1.77", port: 41555, deviceModel: "Pixel 9", isPaired: true)
        XCTAssertEqual(ep.asAndroidDevice().serialNumber, "192.168.1.77:41555")
        let server = try EphemeralAdbDaemonServer { cmd in
            cmd == "host:connect:192.168.1.77:41555" ? ("OKAY", "connected to 192.168.1.77:41555\n")
                : (cmd == "host:devices-l" ? ("OKAY", "192.168.1.77:41555 device model:Pixel_9 transport_id:9\n") : ("FAIL", cmd))
        }
        defer { server.shutdown() }
        let vm = AndroidDeviceViewModel(autoStartHardwareMonitoring: false)
        vm.adbDaemonPort = server.port
        let rootNode = AndroidStorageNode(path: "/storage/emulated/0/DCIM", name: "DCIM", entryType: .directory)
        vm.directoryLister = { _, path in path == "/storage/emulated/0" ? [rootNode] : [] }
        try await vm.connectPairedWirelessDevice(host: ep.host, port: ep.port)
        let connected = try XCTUnwrap(vm.selectedDevice)
        XCTAssertEqual(connected.serialNumber, "192.168.1.77:41555")
        let winID = UUID()
        vm.bindWindow(winID, toDevice: connected)
        vm.bindWindow(winID, toDevice: nil)
        vm.directoryCacheByKey.removeAll()
        vm.bindWindow(winID, toDevice: connected)
        for _ in 0..<20 where vm.directoryState(forPath: "/storage/emulated/0", windowID: winID) == .idle {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(vm.directoryState(forPath: "/storage/emulated/0", windowID: winID), .loaded(entries: [rootNode]))
        vm.removeDevice(id: connected.deviceId)
        XCTAssertNil(vm.activeDeviceByWindow[winID])
        XCTAssertNil(vm.windowBrowseStates[winID])
        var pins = ["1", "2", "3", "4", "5", "6"]
        let r1 = AndroidPairingPinInputView.applyDigitInput("49", at: 3, pinDigits: &pins)
        XCTAssertEqual(pins, ["1", "2", "3", "9", "5", "6"])
        XCTAssertEqual(r1.nextFocus, 4)
        let r2 = AndroidPairingPinInputView.applyDigitInput("", at: 3, pinDigits: &pins)
        XCTAssertEqual(r2.nextFocus, 2)
    }
}
