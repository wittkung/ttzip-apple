// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import TTZipAppCore
@testable import TTZipApp

@MainActor
final class AndroidDeviceBrowsingTests: XCTestCase {

    func testDirectoryLoadingProductionPathWithControlledTransportFake() async {
        let partition = AndroidStoragePartition(
            partitionId: "p1", displayName: "Internal Shared Storage",
            totalBytes: 64_000_000_000, availableBytes: 32_000_000_000, rootPath: "/"
        )
        let (vm, winId) = makeWindowFixture(partition: partition, path: "/Download")

        // 1. Permission error (e.g. MTP interface claim conflict): must map to .permissionRestricted and NOT mask as .empty
        vm.directoryLister = { _, _ in
            throw NSError(
                domain: "MTP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Access denied (insufficient permissions)"]
            )
        }
        await vm.loadDirectoryContents(path: "/Download", forceReload: true, windowID: winId)

        guard case .permissionRestricted(let reason) = vm.directoryState(forPath: "/Download", windowID: winId) else {
            XCTFail("Expected .permissionRestricted")
            return
        }
        XCTAssertTrue(reason.contains("insufficient permissions"))
        XCTAssertNotEqual(vm.directoryState(forPath: "/Download", windowID: winId), .empty)
        XCTAssertTrue(currentWindowEntries(vm, windowID: winId).isEmpty)

        // 2. Generic I/O error: must map to .failed and NOT mask as .empty
        vm.directoryLister = { _, _ in
            throw NSError(
                domain: "IO",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Input/output error during directory listing"]
            )
        }
        await vm.loadDirectoryContents(path: "/Download", forceReload: true, windowID: winId)

        guard case .failed(let err) = vm.directoryState(forPath: "/Download", windowID: winId) else {
            XCTFail("Expected .failed")
            return
        }
        XCTAssertEqual(err, "Input/output error during directory listing")
        XCTAssertNotEqual(vm.directoryState(forPath: "/Download", windowID: winId), .empty)

        // 3. Retry success: correctly loads entries
        let node = AndroidStorageNode(
            path: "/Download/photo.jpg",
            name: "photo.jpg",
            entryType: .file,
            sizeBytes: 2048
        )
        vm.directoryLister = { _, _ in [node] }
        await vm.loadDirectoryContents(path: "/Download", forceReload: true, windowID: winId)

        guard case .loaded(let entries) = vm.directoryState(forPath: "/Download", windowID: winId) else {
            XCTFail("Expected .loaded")
            return
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(currentWindowEntries(vm, windowID: winId).first?.name, "photo.jpg")
    }

    func testMultiWindowCrossDeviceAndPartitionIsolationWithGenerationSafety() async {
        let vm = AndroidDeviceViewModel(autoStartHardwareMonitoring: false)
        vm.directoryLister = { _, _ in [] }
        let winA = UUID()
        let winB = UUID()

        let partA = AndroidStoragePartition(
            partitionId: "pA",
            displayName: "Internal A",
            totalBytes: 100,
            availableBytes: 50,
            rootPath: "/"
        )
        let devA = makeDevice(id: "mtp://devA", serial: "devA", name: "Device A", productId: 0x01,
                              connection: .usbMtp, partition: partA)

        let partB = AndroidStoragePartition(
            partitionId: "pB",
            displayName: "Internal B",
            totalBytes: 100,
            availableBytes: 50,
            rootPath: "/"
        )
        let devB = makeDevice(id: "adb://devB", serial: "devB", name: "Device B", productId: 0x02,
                              connection: .usbAdb, partition: partB)

        vm.registerDevice(devA)
        vm.registerDevice(devB)
        vm.bindWindow(winA, toDevice: devA)
        vm.bindWindow(winB, toDevice: devB)
        vm.selectPartition(partA, forWindow: winA)
        vm.setColumnPaths(["/", "/Download"], forWindow: winA)
        vm.selectPartition(partB, forWindow: winB)
        vm.setColumnPaths(["/", "/Download"], forWindow: winB)

        let firstListing = DirectoryListingGate()
        vm.directoryLister = { devId, path in
            guard path == "/Download" else { return [] }
            if devId.contains("devA") { return await firstListing.load() }
            return [AndroidStorageNode(path: "/Download/fileB.txt", name: "fileB.txt", entryType: .file, sizeBytes: 20)]
        }
        let loadA = Task { await vm.loadDirectoryContents(path: "/Download", windowID: winA) }
        await fulfillment(of: [firstListing.started], timeout: 3)
        await vm.loadDirectoryContents(path: "/Download", windowID: winB)
        await firstListing.finish([AndroidStorageNode(path: "/Download/fileA.txt", name: "fileA.txt", entryType: .file, sizeBytes: 10)])
        await loadA.value

        // Verify window isolation & cache isolation on identical path "/Download"
        XCTAssertEqual(currentWindowEntries(vm, windowID: winA).map(\.name), ["fileA.txt"])
        XCTAssertEqual(currentWindowEntries(vm, windowID: winB).map(\.name), ["fileB.txt"])
        XCTAssertEqual(vm.cachedNodes(forPath: "/Download", windowID: winA)?.map(\.name), ["fileA.txt"])
        XCTAssertEqual(vm.cachedNodes(forPath: "/Download", windowID: winB)?.map(\.name), ["fileB.txt"])

        // Release an already-started old request only after navigation changes its generation.
        let staleListing = DirectoryListingGate()
        vm.directoryLister = { _, path in
            guard path == "/Stale" else { return [] }
            return await staleListing.load()
        }
        vm.setColumnPaths(["/", "/Stale"], forWindow: winA)
        let staleTask = Task { await vm.loadDirectoryContents(path: "/Stale", windowID: winA) }
        await fulfillment(of: [staleListing.started], timeout: 3)
        vm.setColumnPaths(["/", "/Fresh"], forWindow: winA)
        await staleListing.finish([AndroidStorageNode(path: "/Stale/stale.txt", name: "stale.txt", entryType: .file, sizeBytes: 1)])
        await staleTask.value

        // Active window should NOT be overwritten by stale path entries
        XCTAssertTrue(currentWindowEntries(vm, windowID: winA).isEmpty)
        XCTAssertNil(vm.cachedNodes(forPath: "/Stale", windowID: winA))
    }

    func testAndroidLocationDescriptorAndInspectorHandoff() {
        let vm = AndroidDeviceViewModel(autoStartHardwareMonitoring: false)
        vm.directoryLister = { _, _ in [] }
        let win = UUID()
        let partition = AndroidStoragePartition(
            partitionId: "0x00010001",
            displayName: "Internal Storage",
            totalBytes: 100_000,
            availableBytes: 25_000,
            rootPath: "/"
        )
        let dev = AndroidDevice(
            deviceId: "mtp://8360cf22",
            displayName: "Mi 10",
            vendorId: 0x2717,
            productId: 0xFF48,
            serialNumber: "8360cf22",
            connectionType: .usbMtp,
            status: .connected,
            storagePartitions: [partition]
        )
        vm.registerDevice(dev)
        vm.bindWindow(win, toDevice: dev)
        vm.selectPartition(partition, forWindow: win)
        vm.setColumnPaths(["/", "/DCIM"], forWindow: win)

        let node = AndroidStorageNode(
            path: "/DCIM/img.jpg",
            name: "img.jpg",
            entryType: .file,
            sizeBytes: 500
        )
        vm.selectNode(node, atColumn: 1, forWindow: win)

        let loc = vm.currentLocation(forWindow: win)
        XCTAssertEqual(loc?.deviceDisplayName, "Mi 10")
        XCTAssertEqual(loc?.partitionDisplayName, "Internal Storage")
        XCTAssertEqual(loc?.currentDirectoryPath, "/DCIM")
        XCTAssertEqual(loc?.freeSpacePercentage, 25.0)

        guard case .single(let meta) = vm.inspectorSurfaceMode(forWindow: win) else {
            XCTFail("Expected .single")
            return
        }
        XCTAssertEqual(meta.name, "img.jpg")
        XCTAssertEqual(loc?.deviceName, "Mi 10")
        XCTAssertEqual(loc?.partitionId, "0x00010001")
    }
    func testExplicitDisconnectRemainsDistinctFromGenericIOFailure() async {
        let partition = AndroidStoragePartition(
            partitionId: "primary", displayName: "Internal Shared Storage",
            totalBytes: 100, availableBytes: 50, rootPath: "/"
        )
        let (vm, windowID) = makeWindowFixture(partition: partition, path: "/Download")
        vm.directoryLister = { _, _ in
            throw NSError(domain: "IO", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Device disconnected during listing"])
        }
        await vm.loadDirectoryContents(path: "/Download", forceReload: true, windowID: windowID)
        XCTAssertEqual(vm.directoryState(forPath: "/Download", windowID: windowID), .disconnected)
        XCTAssertNotEqual(vm.directoryState(forPath: "/Download", windowID: windowID), .empty)
        XCTAssertTrue(currentWindowEntries(vm, windowID: windowID).isEmpty)
    }

    func testAndroidInspectorCountsOnlyCompletedDirectoryListings() {
        let unconfirmed: [AndroidDirectoryState] = [
            .idle, .loading, .permissionRestricted(reason: "Denied"),
            .failed(error: "USB timeout"), .disconnected
        ]
        for state in unconfirmed {
            XCTAssertNil(AndroidLocationInspectorView.loadedEntryCount(for: state))
        }
        XCTAssertEqual(AndroidLocationInspectorView.loadedEntryCount(for: .empty), 0)
        let nodes = [AndroidStorageNode(path: "/DCIM/photo.jpg", name: "photo.jpg", entryType: .file, sizeBytes: 19)]
        XCTAssertEqual(AndroidLocationInspectorView.loadedEntryCount(for: .loaded(entries: nodes)), 1)
    }

    func testRootCompletionDoesNotPopulateUnrequestedLeafCache() async {
        let partition = AndroidStoragePartition(
            partitionId: "root-test", displayName: "Internal", totalBytes: 100, availableBytes: 50, rootPath: "/"
        )
        let (vm, windowID) = makeWindowFixture(partition: partition, path: "/New")
        await vm.loadDirectoryContents(path: "/", windowID: windowID)
        XCTAssertEqual(vm.cachedNodes(forPath: "/", windowID: windowID), [])
        XCTAssertNil(vm.cachedNodes(forPath: "/New", windowID: windowID))
        XCTAssertEqual(vm.directoryState(forPath: "/New", windowID: windowID), .idle)
        let requestedLeaf = expectation(description: "Cold leaf performs real listing without forceReload")
        let node = AndroidStorageNode(path: "/New/child.txt", name: "child.txt", entryType: .file, sizeBytes: 1)
        vm.directoryLister = { _, path in
            guard path == "/New" else { return [] }
            requestedLeaf.fulfill()
            return [node]
        }
        await vm.loadDirectoryContents(path: "/New", windowID: windowID)
        await fulfillment(of: [requestedLeaf], timeout: 3)
        XCTAssertEqual(currentWindowEntries(vm, windowID: windowID), [node])
        XCTAssertEqual(vm.cachedNodes(forPath: "/", windowID: windowID), [])
    }

    func testOtherWindowNeverInheritsPermissionOrDisconnectedState() async {
        await assertDirectoryFailureIsolation(
            message: "Access denied (insufficient permissions)",
            expected: .permissionRestricted(reason: "Access denied (insufficient permissions)")
        )
        await assertDirectoryFailureIsolation(message: "Device disconnected during listing", expected: .disconnected)
    }

    private func assertDirectoryFailureIsolation(message: String, expected: AndroidDirectoryState) async {
        let partition = AndroidStoragePartition(
            partitionId: "internal", displayName: "Internal", totalBytes: 100, availableBytes: 50, rootPath: "/"
        )
        let (vm, windowA) = makeWindowFixture(partition: partition, path: "/Download")
        let windowB = UUID()
        let deviceB = makeDevice(id: "adb://other", serial: "other", name: "Other", productId: 2,
                                 connection: .usbAdb, partition: partition)
        vm.registerDevice(deviceB)
        vm.bindWindow(windowB, toDevice: deviceB)
        vm.setColumnPaths(["/", "/Download"], forWindow: windowB)
        vm.directoryLister = { serial, path in
            guard path == "/Download" else { return [] }
            if serial == "8360cf22" {
                throw NSError(domain: "IO", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            return [AndroidStorageNode(path: "/Download/other.txt", name: "other.txt", entryType: .file, sizeBytes: 1)]
        }
        await vm.loadDirectoryContents(path: "/Download", windowID: windowA)
        XCTAssertEqual(vm.directoryState(forPath: "/Download", windowID: windowA), expected)
        XCTAssertEqual(vm.directoryState(forPath: "/Download", windowID: windowB), .idle)
        XCTAssertNil(vm.cachedNodes(forPath: "/Download", windowID: windowB))
        await vm.loadDirectoryContents(path: "/Download", windowID: windowB)
        XCTAssertEqual(currentWindowEntries(vm, windowID: windowB).map(\.name), ["other.txt"])
        XCTAssertEqual(vm.directoryState(forPath: "/Download", windowID: windowA), expected)
    }

    func testDeviceRebindingRejectsLateReplyAfterReturningToSameScope() async {
        let partition = AndroidStoragePartition(
            partitionId: "aba-device", displayName: "Internal", totalBytes: 100, availableBytes: 50, rootPath: "/"
        )
        let (vm, windowID) = makeWindowFixture(partition: partition, path: "/Pending")
        let originalDevice = vm.activeDevice(forWindow: windowID)
        let otherDevice = makeDevice(id: "adb://other", serial: "other", name: "Other", productId: 2,
                                     connection: .usbAdb, partition: partition)
        vm.registerDevice(otherDevice)
        let gate = DirectoryListingGate()
        vm.directoryLister = { _, path in path == "/Pending" ? await gate.load() : [] }
        let pending = Task { await vm.loadDirectoryContents(path: "/Pending", windowID: windowID) }
        await fulfillment(of: [gate.started], timeout: 3)
        vm.bindWindow(windowID, toDevice: otherDevice)
        vm.bindWindow(windowID, toDevice: originalDevice)
        vm.setColumnPaths(["/", "/Pending"], forWindow: windowID)
        await gate.finish([AndroidStorageNode(path: "/Pending/old.txt", name: "old.txt", entryType: .file, sizeBytes: 1)])
        await pending.value
        XCTAssertNil(vm.cachedNodes(forPath: "/Pending", windowID: windowID))
        XCTAssertEqual(vm.directoryState(forPath: "/Pending", windowID: windowID), .idle)
    }

    func testPartitionRebindingRejectsLateReplyAfterReturningToSameScope() async {
        let partitionA = AndroidStoragePartition(
            partitionId: "a", displayName: "Internal A", totalBytes: 100, availableBytes: 50, rootPath: "/"
        )
        let partitionB = AndroidStoragePartition(
            partitionId: "b", displayName: "Internal B", totalBytes: 100, availableBytes: 50, rootPath: "/"
        )
        let (vm, windowID) = makeWindowFixture(partition: partitionA, path: "/Pending", additionalPartitions: [partitionB])
        let gate = DirectoryListingGate()
        vm.directoryLister = { _, path in path == "/Pending" ? await gate.load() : [] }
        let pending = Task { await vm.loadDirectoryContents(path: "/Pending", windowID: windowID) }
        await fulfillment(of: [gate.started], timeout: 3)
        vm.selectPartition(partitionB, forWindow: windowID)
        vm.selectPartition(partitionA, forWindow: windowID)
        vm.setColumnPaths(["/", "/Pending"], forWindow: windowID)
        await gate.finish([AndroidStorageNode(path: "/Pending/old.txt", name: "old.txt", entryType: .file, sizeBytes: 1)])
        await pending.value
        XCTAssertNil(vm.cachedNodes(forPath: "/Pending", windowID: windowID))
        XCTAssertEqual(vm.directoryState(forPath: "/Pending", windowID: windowID), .idle)
    }

    func testMtpHandlesAreResolvedOnlyWithinDeviceAndPartitionScope() async {
        let partition = AndroidStoragePartition(
            partitionId: "mtp-handles", displayName: "Internal", totalBytes: 100, availableBytes: 50, rootPath: "/"
        )
        let (vm, windowA) = makeWindowFixture(partition: partition, path: "/")
        let windowB = UUID()
        let deviceB = makeDevice(id: "mtp://other", serial: "other", name: "Other", productId: 2,
                                 connection: .usbMtp, partition: partition)
        vm.registerDevice(deviceB)
        vm.bindWindow(windowB, toDevice: deviceB)
        vm.storeCachedNodes([AndroidStorageNode(path: "/DCIM", name: "DCIM", entryType: .directory,
                                               sizeBytes: 0, objectHandle: 17)], forPath: "/", windowID: windowA)
        vm.storeCachedNodes([AndroidStorageNode(path: "/DCIM", name: "DCIM", entryType: .directory,
                                               sizeBytes: 0, objectHandle: 99)], forPath: "/", windowID: windowB)
        XCTAssertEqual(vm.resolveMtpObjectHandle(forPath: "/DCIM", windowID: windowA), 17)
        XCTAssertEqual(vm.resolveMtpObjectHandle(forPath: "/DCIM", windowID: windowB), 99)
    }

    func testLegacyNoWindowRequestRejectsDeviceABALateReply() async {
        let partition = AndroidStoragePartition(
            partitionId: "legacy", displayName: "Internal", totalBytes: 100, availableBytes: 50, rootPath: "/"
        )
        let vm = AndroidDeviceViewModel(autoStartHardwareMonitoring: false)
        vm.directoryLister = { _, _ in [] }
        let deviceA = makeDevice(id: "mtp://legacyA", serial: "legacyA", name: "A", productId: 1,
                                 connection: .usbMtp, partition: partition)
        let deviceB = makeDevice(id: "mtp://legacyB", serial: "legacyB", name: "B", productId: 2,
                                 connection: .usbMtp, partition: partition)
        vm.registerDevice(deviceA)
        vm.registerDevice(deviceB)
        vm.selectDevice(deviceA)
        vm.setColumnPaths(["/", "/Pending"])
        let gate = DirectoryListingGate()
        vm.directoryLister = { _, path in path == "/Pending" ? await gate.load() : [] }
        let pending = Task { await vm.loadDirectoryContents(path: "/Pending") }
        await fulfillment(of: [gate.started], timeout: 3)
        vm.selectDevice(deviceB)
        vm.selectDevice(deviceA)
        vm.setColumnPaths(["/", "/Pending"])
        await gate.finish([AndroidStorageNode(path: "/Pending/old.txt", name: "old.txt", entryType: .file, sizeBytes: 1)])
        await pending.value
        XCTAssertNil(vm.cachedNodes(forPath: "/Pending", windowID: nil))
        XCTAssertEqual(vm.directoryState(forPath: "/Pending"), .idle)
    }

    func testHardwareDiscoveryDoesNotSelectOrBindAWindow() {
        let partition = AndroidStoragePartition(
            partitionId: "discovery", displayName: "Internal", totalBytes: 100, availableBytes: 50, rootPath: "/"
        )
        let vm = AndroidDeviceViewModel(autoStartHardwareMonitoring: false)
        let windowID = UUID()
        let device = makeDevice(id: "mtp://discovered", serial: "discovered", name: "Mi 10", productId: 1,
                                connection: .usbMtp, partition: partition)
        vm.registerDevice(device)
        XCTAssertEqual(vm.connectedDevices.map(\.deviceId), [device.deviceId])
        XCTAssertNil(vm.selectedDevice)
        XCTAssertNil(vm.activeDevice(forWindow: windowID))
        vm.bindWindow(windowID, toDevice: device)
        XCTAssertEqual(vm.activeDevice(forWindow: windowID)?.deviceId, device.deviceId)
        vm.bindWindow(windowID, toDevice: nil)
        XCTAssertNil(vm.activeDevice(forWindow: windowID))
    }

    func testHardwareEntryMappingRetainsTheMtpObjectHandle() {
        let entry = DeviceEntry(path: "/Books", name: "Books", size: 0, isDir: true,
                                mtime: 123, objectId: 42, posixMode: nil)
        let node = HardwareIOActor.storageNode(from: entry)
        XCTAssertEqual(node.path, "/Books")
        XCTAssertEqual(node.objectHandle, 42)
        XCTAssertEqual(node.modifiedTimestamp, 123)
        XCTAssertEqual(node.entryType, .directory)
    }

    private func currentWindowEntries(_ vm: AndroidDeviceViewModel, windowID: UUID) -> [AndroidStorageNode] {
        let path = vm.currentDirectoryPath(forWindow: windowID)
        guard case .loaded(let entries) = vm.directoryState(forPath: path, windowID: windowID) else { return [] }
        return entries
    }

    private func makeDevice(
        id: String, serial: String, name: String, productId: UInt16,
        connection: AndroidConnectionType, partition: AndroidStoragePartition
    ) -> AndroidDevice {
        AndroidDevice(deviceId: id, displayName: name, vendorId: 0x2717, productId: productId,
                      serialNumber: serial, connectionType: connection, status: .connected,
                      storagePartitions: [partition])
    }

    private func makeWindowFixture(
        partition: AndroidStoragePartition, path: String, additionalPartitions: [AndroidStoragePartition] = []
    ) -> (AndroidDeviceViewModel, UUID) {
        let vm = AndroidDeviceViewModel(autoStartHardwareMonitoring: false)
        vm.directoryLister = { _, _ in [] }
        let windowID = UUID()
        var device = makeDevice(id: "mtp://8360cf22", serial: "8360cf22", name: "Mi 10", productId: 0xFF48,
                                connection: .usbMtp, partition: partition)
        device.storagePartitions.append(contentsOf: additionalPartitions)
        vm.registerDevice(device)
        vm.bindWindow(windowID, toDevice: device)
        vm.selectPartition(partition, forWindow: windowID)
        vm.setColumnPaths(["/", path], forWindow: windowID)
        return (vm, windowID)
    }

}


/// Deterministically holds a real directoryLister invocation until the test releases its reply.
private actor DirectoryListingGate {
    nonisolated let started = XCTestExpectation(description: "Directory lister entered")
    private var reply: CheckedContinuation<[AndroidStorageNode], Never>?

    func load() async -> [AndroidStorageNode] {
        await withCheckedContinuation { continuation in
            reply = continuation
            started.fulfill()
        }
    }

    func finish(_ nodes: [AndroidStorageNode]) {
        reply?.resume(returning: nodes)
        reply = nil
    }
}
