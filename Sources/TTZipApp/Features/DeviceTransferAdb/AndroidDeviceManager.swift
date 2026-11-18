// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Presentation-tier actor managing registered Android devices and broadcast updates.
public actor AndroidDeviceManager {
    /// Shared singleton manager instance.
    public static let shared = AndroidDeviceManager()

    /// Registry of connected devices keyed by their unique deviceId.
    private var devices: [String: AndroidDevice] = [:]

    /// Active state stream subscriber continuations keyed by registration UUID.
    private var continuations: [UUID: AsyncStream<[AndroidDevice]>.Continuation] = [:]

    public init() {}

    /// Registers or updates an Android device within the manager.
    public func registerDevice(_ device: AndroidDevice) {
        devices[device.deviceId] = device
        broadcastUpdate()
    }

    /// Removes a device by its identifier and broadcasts the change.
    @discardableResult
    public func removeDevice(id: String) -> AndroidDevice? {
        guard let removed = devices.removeValue(forKey: id) else {
            return nil
        }
        broadcastUpdate()
        return removed
    }

    /// Retrieves an immutable snapshot array of all currently managed devices.
    public func getDevices() -> [AndroidDevice] {
        devices.values.sorted { $0.deviceId < $1.deviceId }
    }

    /// Retrieves a specific device by its unique identifier.
    public func getDevice(id: String) -> AndroidDevice? {
        devices[id]
    }

    /// Resolves a single target device by exact `deviceId` or `serialNumber`, rejecting ambiguous selectors
    /// when multiple connected devices share the same model or when no serial is specified across multiple devices.
    public func resolveUniqueDevice(matching selector: String) throws -> AndroidDevice {
        try Self.selectUniqueDevice(from: getDevices(), matching: selector)
    }

    /// Pure deterministic selector binding exact `deviceId` / `serialNumber` and rejecting multi-device ambiguity.
    public nonisolated static func selectUniqueDevice(
        from candidates: [AndroidDevice],
        matching selector: String
    ) throws -> AndroidDevice {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidates.isEmpty else {
            throw AdbSmartSocketError.syncProtocolError(reason: "No connected Android devices available")
        }
        guard !trimmed.isEmpty else {
            if candidates.count == 1 {
                return candidates[0]
            }
            let ids = candidates.map(\.deviceId).joined(separator: ", ")
            throw AdbSmartSocketError.syncProtocolError(
                reason: "Ambiguous empty device selector: \(candidates.count) devices connected (\(ids)); specify exact serialNumber"
            )
        }

        let cleanSerial = normalizedDeviceSerial(trimmed)

        let exactMatches = candidates.filter { dev in
            dev.deviceId == trimmed
                || dev.serialNumber == trimmed
                || dev.serialNumber == cleanSerial
                || dev.deviceId == "mtp://\(cleanSerial)"
                || dev.deviceId == "adb://\(cleanSerial)"
        }
        if exactMatches.count == 1 {
            return exactMatches[0]
        }
        if exactMatches.count > 1 {
            let ids = exactMatches.map(\.deviceId).joined(separator: ", ")
            throw AdbSmartSocketError.syncProtocolError(
                reason: "Ambiguous device identity '\(trimmed)': matched multiple records (\(ids))"
            )
        }

        let modelOrVidPidMatches = candidates.filter { dev in
            let vidPidHex = String(format: "%04X:%04X", dev.vendorId, dev.productId)
            return dev.displayName.caseInsensitiveCompare(trimmed) == .orderedSame
                || dev.displayName.localizedCaseInsensitiveContains(trimmed)
                || vidPidHex.caseInsensitiveCompare(cleanSerial) == .orderedSame
        }
        if modelOrVidPidMatches.count > 1 {
            let serials = modelOrVidPidMatches.map(\.serialNumber).joined(separator: ", ")
            throw AdbSmartSocketError.syncProtocolError(
                reason: "Ambiguous model/VID:PID selector '\(trimmed)': \(modelOrVidPidMatches.count) same-model devices connected (serials: \(serials)); bind by exact serialNumber"
            )
        }
        if modelOrVidPidMatches.count == 1 {
            return modelOrVidPidMatches[0]
        }

        let available = candidates.map { "\($0.deviceId) (\($0.displayName))" }.joined(separator: ", ")
        throw AdbSmartSocketError.syncProtocolError(
            reason: "Target Android device '\(trimmed)' not found among connected devices: [\(available)]"
        )
    }

    /// Updates the operational status of an existing registered device.
    @discardableResult
    public func updateDeviceStatus(id: String, status: AndroidDeviceStatus) -> Bool {
        guard var device = devices[id] else {
            return false
        }
        device.status = status
        devices[id] = device
        broadcastUpdate()
        return true
    }

    private nonisolated static func normalizedDeviceSerial(_ trimmed: String) -> String {
        if trimmed.hasPrefix("adb://") || trimmed.hasPrefix("mtp://") {
            return String(trimmed.dropFirst(6))
        } else if trimmed.hasPrefix("adb:") || trimmed.hasPrefix("mtp:") || trimmed.hasPrefix("usb:") {
            return String(trimmed.dropFirst(4))
        } else {
            return trimmed
        }
    }

    /// Updates the storage partitions of an existing registered device.
    @discardableResult
    public func updateDevicePartitions(id: String, partitions: [AndroidStoragePartition]) -> Bool {
        guard var device = devices[id] else {
            return false
        }
        device.storagePartitions = partitions
        devices[id] = device
        broadcastUpdate()
        return true
    }

    /// Clears all registered devices and notifies active stream observers.
    public func removeAllDevices() {
        guard !devices.isEmpty else { return }
        devices.removeAll()
        broadcastUpdate()
    }

    /// Asynchronous stream broadcasting device updates.
    public var deviceUpdates: AsyncStream<[AndroidDevice]> {
        let (stream, continuation) = AsyncStream<[AndroidDevice]>.makeStream()
        let id = UUID()
        continuations[id] = continuation
        continuation.yield(getDevices())
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { [weak self] in
                await self?.removeContinuation(id: id)
            }
        }
        return stream
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func broadcastUpdate() {
        let currentSnapshot = getDevices()
        for continuation in continuations.values {
            continuation.yield(currentSnapshot)
        }
    }

    /// Hotplug monitoring hook managed natively via AppCoreEngine.
    public func startHardwareMonitoring() {
    }

    /// Stops hotplug monitoring.
    public func stopHardwareMonitoring() {
    }

    /// Scans USB bus for attached Android devices.
    public func refreshUsbDevices() {
    }
}
