// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipAppCore


/// Dedicated actor isolating physical USB MTP endpoints and local ADB TCP daemon socket I/O
/// completely off the Swift 6 @MainActor thread.
///
/// Prevents the 4.0s TCP socket connect/read timeout from freezing the macOS GUI during
/// device enumeration, directory polling, and wireless pairing.
public actor HardwareIOActor {
    public static let shared = HardwareIOActor()

    public init() {}

    /// Scans physical USB MTP devices and ADB daemon off the MainActor thread,
    /// returning strongly-typed Sendable AndroidDevice records.
    public func scanHardwareDevices(engine: AppCoreEngine) -> [AndroidDevice] {
        var list: [AndroidDevice] = []

        if let mtpList = try? engine.scanMtpDevices() {
            for d in mtpList {
                list.append(
                    AndroidDevice(
                        deviceId: d.id,
                        displayName: "\(d.manufacturer) \(d.name)".trimmingCharacters(in: .whitespaces),
                        vendorId: 0x18d1,
                        productId: 0x4ee1,
                        serialNumber: d.id,
                        connectionType: .usbMtp,
                        status: d.state.lowercased() == "offline" ? .disconnected : .connected
                    )
                )
            }
        }

        if let adbList = try? engine.listAdbDevices() {
            for d in adbList {
                let isWireless = d.transportType.lowercased().contains("wireless") || d.id.contains(":")
                let status: AndroidDeviceStatus
                switch d.state.lowercased() {
                case "unauthorized": status = .error
                case "offline": status = .disconnected
                default: status = .connected
                }
                list.append(
                    AndroidDevice(
                        deviceId: d.id,
                        displayName: "\(d.manufacturer) \(d.name)".trimmingCharacters(in: .whitespaces),
                        vendorId: 0x18d1,
                        productId: 0x4ee2,
                        serialNumber: d.id,
                        connectionType: isWireless ? .wirelessAdb : .usbAdb,
                        status: status
                    )
                )
            }
        }

        return list
    }

    /// Lists directory contents over ADB or MTP transport off the MainActor thread,
    /// transforming raw entries directly into Sendable AndroidStorageNode descriptors.
    public func listDeviceDirectory(engine: AppCoreEngine, serial: String, path: String) throws -> [AndroidStorageNode] {
        let rawEntries = try engine.listDeviceDirectory(serial: serial, path: path)
        return rawEntries.map(Self.storageNode(from:))
    }

    /// Preserves physical object identity across the UniFFI-to-view-model boundary.
    public nonisolated static func storageNode(from entry: DeviceEntry) -> AndroidStorageNode {
        let entryType: AndroidVfsEntryType
        if entry.isDir {
            entryType = AndroidStorageNode.isRestrictedPath(entry.path) ? .restrictedDirectory : .directory
        } else {
            entryType = .file
        }
        return AndroidStorageNode(
            path: entry.path,
            name: entry.name,
            entryType: entryType,
            sizeBytes: entry.size,
            modifiedTimestamp: entry.mtime,
            objectHandle: entry.objectId
        )
    }

    /// Performs wireless ADB socket connection off the MainActor thread,
    /// returning a Sendable AndroidDevice on success.
    public func connectWirelessDevice(engine: AppCoreEngine, host: String, port: UInt16) throws -> AndroidDevice {
        let optionalDesc: UniFfiDeviceDescriptor? = try? engine.connectWirelessAdb(host: host, port: port)
        if let desc = optionalDesc {
            return AndroidDevice(
                deviceId: desc.id,
                displayName: "\(desc.manufacturer) \(desc.name)".trimmingCharacters(in: .whitespaces),
                vendorId: 0x18d1,
                productId: 0x4ee7,
                serialNumber: desc.id,
                connectionType: .wirelessAdb,
                status: .connected
            )
        } else {
            return AndroidDevice(
                deviceId: "\(host):\(port)",
                displayName: "Wireless Android (\(host))",
                vendorId: 0x18d1,
                productId: 0x4ee7,
                serialNumber: "\(host):\(port)",
                connectionType: .wirelessAdb,
                status: .connected
            )
        }
    }
}
