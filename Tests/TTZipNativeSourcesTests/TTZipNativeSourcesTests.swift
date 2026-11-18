// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
@testable import TTZipNativeSources

final class TTZipNativeSourcesTests: XCTestCase {
    private final class StateBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T

        init(_ value: T) {
            self._value = value
        }

        var value: T {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }

        func mutate(_ transform: (inout T) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            transform(&_value)
        }
    }

    func testSecurityScopeLeaseRAIIAndIdempotentRelease() {
        let tempURL = URL(fileURLWithPath: "/tmp/ttzip_lease_test")
        let releaseCount = StateBox(0)
        let lease = SecurityScopeLease(url: tempURL) { _ in
            releaseCount.mutate { $0 += 1 }
        }

        XCTAssertEqual(lease.url, tempURL)
        XCTAssertFalse(lease.isReleased)
        XCTAssertEqual(releaseCount.value, 0)

        lease.release()
        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(releaseCount.value, 1)

        lease.release()
        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(releaseCount.value, 1)
    }

    func testSecurityScopeLeaseExplicitActivationConstructor() {
        let targetURL = URL(fileURLWithPath: "/tmp/ttzip_lease_target")
        let rootURL = URL(fileURLWithPath: "/tmp")
        let releasedKey = StateBox<String?>(nil)
        let lease = SecurityScopeLease(
            url: targetURL,
            activatedURL: rootURL,
            leaseKey: "/tmp/lease_key",
            ownsSecurityScope: true
        ) { key in
            releasedKey.mutate { $0 = key }
        }

        XCTAssertEqual(lease.leaseKey, "/tmp/lease_key")
        XCTAssertTrue(lease.ownsSecurityScope)
        XCTAssertFalse(lease.isReleased)

        lease.release()
        XCTAssertTrue(lease.isReleased)
        XCTAssertEqual(releasedKey.value, "/tmp/lease_key")
    }

    func testAndroidDeviceStatusAndOperationalFlags() {
        XCTAssertTrue(AndroidDeviceStatus.connected.isOperational)
        XCTAssertFalse(AndroidDeviceStatus.connected.isTerminal)

        XCTAssertFalse(AndroidDeviceStatus.connecting.isOperational)
        XCTAssertFalse(AndroidDeviceStatus.connecting.isTerminal)

        XCTAssertFalse(AndroidDeviceStatus.stalled.isOperational)
        XCTAssertFalse(AndroidDeviceStatus.stalled.isTerminal)

        XCTAssertFalse(AndroidDeviceStatus.disconnected.isOperational)
        XCTAssertTrue(AndroidDeviceStatus.disconnected.isTerminal)

        XCTAssertFalse(AndroidDeviceStatus.error.isOperational)
        XCTAssertTrue(AndroidDeviceStatus.error.isTerminal)
    }

    func testAndroidDeviceInitializationAndAggregates() {
        let part1 = AndroidStoragePartition(
            partitionId: "p1",
            displayName: "Internal",
            totalBytes: 64_000_000_000,
            availableBytes: 20_000_000_000,
            rootPath: "/storage/emulated/0",
            isRemovable: false
        )
        let part2 = AndroidStoragePartition(
            partitionId: "p2",
            displayName: "SD Card",
            totalBytes: 128_000_000_000,
            availableBytes: 80_000_000_000,
            rootPath: "/storage/sdcard1",
            isRemovable: true
        )

        XCTAssertEqual(part1.usedBytes, 44_000_000_000)
        XCTAssertEqual(part1.id, "p1")
        XCTAssertGreaterThan(part1.usageRatio, 0.68)
        XCTAssertLessThan(part1.usageRatio, 0.69)

        let device = AndroidDevice(
            deviceId: "adb://192.168.1.100:5555",
            displayName: "Test Device",
            vendorId: 0x18D1,
            productId: 0x4EE7,
            serialNumber: "192.168.1.100:5555",
            connectionType: .wirelessAdb,
            status: .connected,
            storagePartitions: [part1, part2]
        )

        XCTAssertEqual(device.id, "adb://192.168.1.100:5555")
        XCTAssertTrue(device.isConnected)
        XCTAssertEqual(device.totalCapacityBytes, 192_000_000_000)
        XCTAssertEqual(device.totalAvailableBytes, 100_000_000_000)
    }

    func testAndroidStorageNodePropertiesAndRestrictedPath() {
        XCTAssertTrue(AndroidStorageNode.isRestrictedPath("/Android/data"))
        XCTAssertTrue(AndroidStorageNode.isRestrictedPath("/Android/data/com.example.app"))
        XCTAssertTrue(AndroidStorageNode.isRestrictedPath("/Android/obb"))
        XCTAssertTrue(AndroidStorageNode.isRestrictedPath("/Android/obb/com.example.game"))
        XCTAssertFalse(AndroidStorageNode.isRestrictedPath("/Download"))
        XCTAssertFalse(AndroidStorageNode.isRestrictedPath("/DCIM/Camera"))

        let fileNode = AndroidStorageNode(
            path: "/Download/test.zip",
            name: "test.zip",
            entryType: .file,
            sizeBytes: 1024,
            modifiedTimestamp: 1_700_000_000
        )
        XCTAssertTrue(fileNode.isFile)
        XCTAssertFalse(fileNode.isDirectory)
        XCTAssertFalse(fileNode.isSymlink)
        XCTAssertFalse(fileNode.isRestricted)
        XCTAssertEqual(fileNode.id, "/Download/test.zip")
        XCTAssertEqual(fileNode.modifiedDate, Date(timeIntervalSince1970: 1_700_000_000))

        let restrictedNode = AndroidStorageNode(
            path: "/Android/data/com.app/cache",
            name: "cache",
            entryType: .directory
        )
        XCTAssertTrue(restrictedNode.isDirectory)
        XCTAssertTrue(restrictedNode.isRestricted)
    }

    func testAndroidTransferModelsEnums() {
        XCTAssertEqual(AndroidTransferDirection.macToAndroid.rawValue, "MacToAndroid")
        XCTAssertEqual(AndroidTransferDirection.androidToMac.rawValue, "AndroidToMac")
        XCTAssertEqual(AndroidTransferDirection.directPipelineExtract.rawValue, "DirectPipelineExtract")

        XCTAssertEqual(AndroidTransferStatus.queued.rawValue, "Queued")
        XCTAssertEqual(AndroidTransferStatus.transferring.rawValue, "Transferring")
        XCTAssertEqual(AndroidTransferStatus.completed.rawValue, "Completed")
        XCTAssertEqual(AndroidTransferStatus.failed.rawValue, "Failed")

        XCTAssertEqual(AndroidTransferConflictPolicy.overwrite.rawValue, 0)
        XCTAssertEqual(AndroidTransferConflictPolicy.skip.rawValue, 1)
        XCTAssertEqual(AndroidTransferConflictPolicy.keepBoth.rawValue, 2)

        XCTAssertEqual(AndroidTransferVerificationLevel.none.rawValue, "None")
        XCTAssertEqual(AndroidTransferVerificationLevel.sourceStreamAndRemoteSizeVerified.rawValue, "SourceStreamAndRemoteSizeVerified")
        XCTAssertEqual(AndroidTransferVerificationLevel.remoteReadbackSha256Verified.rawValue, "RemoteReadbackSha256Verified")

        XCTAssertEqual(AndroidTransferCommitPhase.uncommitted.rawValue, "Uncommitted")
        XCTAssertEqual(AndroidTransferCommitPhase.committed.rawValue, "Committed")
        XCTAssertEqual(AndroidTransferCommitPhase.unknown.rawValue, "Unknown")
    }
}
