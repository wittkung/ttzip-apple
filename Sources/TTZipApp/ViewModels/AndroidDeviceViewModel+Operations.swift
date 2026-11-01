// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipAppCore
import TTZipCore

public typealias AndroidNode = AndroidStorageNode

extension AndroidDevice {
    /// Alias for serialNumber matching device subsystem conventions.
    public var serial: String {
        serialNumber
    }
}

extension AndroidDeviceViewModel {
    /// Alias for selectedDevice matching device subsystem conventions.
    public var currentDevice: AndroidDevice? {
        selectedDevice
    }

    /// Current entries in the active Miller column directory view.
    public var currentEntries: [AndroidStorageNode] {
        get {
            let activePath = columnPaths.last ?? selectedPartition?.rootPath ?? "/"
            return cachedNodes(forPath: activePath, windowID: nil) ?? []
        }
        set {
            let activePath = columnPaths.last ?? selectedPartition?.rootPath ?? "/"
            storeCachedNodes(newValue, forPath: activePath, windowID: nil)
        }
    }

    // MARK: - Directory Loading

    /// Asynchronously loads children for a normalized VFS path from the active Android device.
    ///
    /// Queries the native AppCoreEngine via real ADB or MTP transport and populates
    /// cached Miller column directory entries with canonical VFS metadata descriptors.
    public func loadDirectoryContents(path: String, forceReload: Bool = false, windowID: UUID? = nil) async {
        let normalizedPath = normalizeDirectoryPath(path)
        guard let device = resolveListingDevice(normalizedPath: normalizedPath, windowID: windowID) else {
            return
        }

        let requestKey = resolveListingRequestKey(device: device, normalizedPath: normalizedPath, windowID: windowID)
        guard !loadingRequestKeys.contains(requestKey) else { return }
        loadingRequestKeys.insert(requestKey)
        loadingPaths.insert(normalizedPath)
        defer {
            loadingRequestKeys.remove(requestKey)
            loadingPaths.remove(normalizedPath)
            isLoading = !loadingRequestKeys.isEmpty
        }

        if checkCachedDirectory(key: requestKey, path: path, normalizedPath: normalizedPath, forceReload: forceReload, windowID: windowID) {
            return
        }

        let initialGeneration = currentGeneration(forWindow: windowID)
        setDirectoryState(.loading, forPath: normalizedPath, windowID: windowID)
        isLoading = true

        let queryPath = resolveListingQueryPath(device: device, normalizedPath: normalizedPath, windowID: windowID)
        do {
            let rawNodes = try await fetchRawDirectoryNodes(device: device, queryPath: queryPath)
            if isValidListingResult(requestKey: requestKey, initialGeneration: initialGeneration, windowID: windowID) {
                applyLoadedNodes(rawNodes, normalizedPath: normalizedPath, windowID: windowID)
            }
        } catch {
            if isValidListingResult(requestKey: requestKey, initialGeneration: initialGeneration, windowID: windowID) {
                handleDirectoryListingError(error, forPath: normalizedPath, windowID: windowID)
            }
        }
    }

    private func normalizeDirectoryPath(_ path: String) -> String {
        (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
    }

    private func resolveListingDevice(normalizedPath: String, windowID: UUID?) -> AndroidDevice? {
        let device: AndroidDevice?
        if let windowID { device = activeDevice(forWindow: windowID) } else { device = currentDevice }
        guard let dev = device, dev.status == .connected else {
            setDirectoryState(.disconnected, forPath: normalizedPath, windowID: windowID)
            errorMessage = L10n.AndroidInterconnect.noActiveDevice.localized
            isLoading = false
            return nil
        }
        return dev
    }

    private func resolveListingRequestKey(device: AndroidDevice, normalizedPath: String, windowID: UUID?) -> AndroidDirectoryRequestKey {
        let partition = selectedPartition(forWindow: windowID)
            ?? device.storagePartitions.first
            ?? AndroidStoragePartition(partitionId: "default", displayName: "Default", totalBytes: 0, availableBytes: 0, rootPath: "/")
        return AndroidDirectoryRequestKey(deviceId: device.deviceId, partitionId: partition.partitionId, path: normalizedPath)
    }

    private func currentGeneration(forWindow windowID: UUID?) -> UInt64 {
        windowID.flatMap { windowBrowseStates[$0]?.requestGeneration } ?? legacyDirectoryRequestGeneration
    }

    private func isValidListingResult(requestKey: AndroidDirectoryRequestKey, initialGeneration: UInt64, windowID: UUID?) -> Bool {
        guard makeRequestKey(path: requestKey.path, windowID: windowID) == requestKey else { return false }
        let status: AndroidDeviceStatus?
        if let windowID { status = activeDevice(forWindow: windowID)?.status } else { status = currentDevice?.status }
        guard status == .connected else { return false }
        return currentGeneration(forWindow: windowID) == initialGeneration
    }

    private func fetchRawDirectoryNodes(device: AndroidDevice, queryPath: String) async throws -> [AndroidStorageNode] {
        if let customLister = directoryLister {
            return try await customLister(device.serial, queryPath)
        }
        let engine = appCoreEngine ?? AppCoreEngine.shared
        return try await HardwareIOActor.shared.listDeviceDirectory(
            engine: engine,
            serial: device.serial,
            path: queryPath
        )
    }

    private func applyLoadedNodes(_ rawNodes: [AndroidStorageNode], normalizedPath: String, windowID: UUID?) {
        let nodes = normalizeRawNodes(rawNodes, normalizedPath: normalizedPath)
        errorMessage = nil
        setDirectoryState(nodes.isEmpty ? .empty : .loaded(entries: nodes), forPath: normalizedPath, windowID: windowID)
    }

    private func checkCachedDirectory(key: AndroidDirectoryRequestKey, path: String, normalizedPath: String, forceReload: Bool, windowID: UUID?) -> Bool {
        if forceReload {
            removeCachedNodes(forPath: path, windowID: windowID)
            removeCachedNodes(forPath: normalizedPath, windowID: windowID)
            return false
        }
        guard let cached = cachedNodes(forPath: normalizedPath, windowID: windowID) else { return false }
        setDirectoryState(cached.isEmpty ? .empty : .loaded(entries: cached), forPath: normalizedPath, windowID: windowID)
        return true
    }

    private func resolveListingQueryPath(device: AndroidDevice, normalizedPath: String, windowID: UUID?) -> String {
        guard device.connectionType == .usbMtp && normalizedPath != "/" else { return normalizedPath }
        return resolveMtpObjectHandle(forPath: normalizedPath, windowID: windowID).map(String.init) ?? normalizedPath
    }

    private func normalizeRawNodes(_ rawNodes: [AndroidStorageNode], normalizedPath: String) -> [AndroidStorageNode] {
        let expectedPrefix = normalizedPath == "/" ? "/" : normalizedPath + "/"
        return rawNodes.map { node in
            if node.path.hasPrefix(expectedPrefix) { return node }
            let childPath = normalizedPath == "/" ? "/\(node.name)" : "\(normalizedPath)/\(node.name)"
            return AndroidStorageNode(
                path: childPath,
                name: node.name,
                entryType: node.entryType,
                sizeBytes: node.sizeBytes,
                modifiedTimestamp: node.modifiedTimestamp,
                objectHandle: node.objectHandle,
                isRestricted: node.isRestricted
            )
        }
    }

    private func isRestrictedError(_ err: String) -> Bool {
        err.contains("Access denied") || err.contains("insufficient permissions")
            || err.contains("ptpcamerad") || err.contains("Busy")
            || err.contains("Unauthorized") || err.contains("Permission denied")
    }

    private func isDisconnectedError(_ err: String) -> Bool {
        err.contains("disconnected") || err.contains("NoDevice") || err.contains("Broken pipe")
    }

    private func handleDirectoryListingError(_ error: Error, forPath normalizedPath: String, windowID: UUID?) {
        let errString = error.localizedDescription
        if isDisconnectedError(errString) {
            setDirectoryState(.disconnected, forPath: normalizedPath, windowID: windowID)
        } else if isRestrictedError(errString) {
            setDirectoryState(.permissionRestricted(reason: errString), forPath: normalizedPath, windowID: windowID)
        } else {
            setDirectoryState(.failed(error: errString), forPath: normalizedPath, windowID: windowID)
        }
        errorMessage = errString
    }

    /// Looks up the 32-bit MTP ObjectHandle for a cached directory path.
    public func resolveMtpObjectHandle(forPath normalizedPath: String, windowID: UUID? = nil) -> UInt32? {
        if let directHandle = UInt32(normalizedPath) {
            return directHandle
        }
        let candidates: [[AndroidStorageNode]]
        if let scope = makeRequestKey(path: normalizedPath, windowID: windowID) {
            candidates = directoryCacheByKey.compactMap { key, nodes in
                key.deviceId == scope.deviceId && key.partitionId == scope.partitionId ? nodes : nil
            }
        } else {
            candidates = windowID == nil ? Array(directoryCache.values) : []
        }
        for nodes in candidates {
            if let match = nodes.first(where: { $0.path == normalizedPath }),
               let handle = match.objectHandle {
                return handle
            }
        }
        return nil
    }

    /// Resolves the 32-bit MTP StorageID from the active `selectedPartition` (`0` uses primary storage).
    public func resolveActiveStorageId() -> UInt32 {
        guard let partitionId = selectedPartition?.partitionId.trimmingCharacters(in: .whitespacesAndNewlines),
              !partitionId.isEmpty else {
            return 0
        }
        if partitionId.lowercased().hasPrefix("0x"),
           let parsedHex = UInt32(partitionId.dropFirst(2), radix: 16) {
            return parsedHex
        }
        return UInt32(partitionId) ?? 0
    }

    // MARK: - Wireless Pairing & Reconnection

    /// Performs wireless pairing handshake with an Android 11+ device asynchronously
    /// using the real ADB Smart Socket `host:pair:<pin>:<host>:<port>` protocol.
    public func pairWirelessDevice(
        pin: String,
        host: String,
        port: UInt16,
        connectionPort: UInt16? = nil
    ) async throws {
        isLoading = true
        connectionState = .connecting
        errorMessage = nil
        defer { isLoading = false }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            connectionState = selectedDevice?.status ?? .error
            let err = AdbSmartSocketError.invalidPinLength
            errorMessage = err.localizedDescription
            throw err
        }
        guard !trimmedHost.isEmpty, port > 0 else {
            connectionState = selectedDevice?.status ?? .error
            let err = AdbSmartSocketError.invalidEndpoint
            errorMessage = err.localizedDescription
            throw err
        }

        let daemonPort = self.adbDaemonPort
        do {
            let newDevice = try await Task.detached(priority: .userInitiated) {
                try AdbSmartSocketClient.pairAndConnectWireless(
                    pin: pin,
                    host: trimmedHost,
                    pairingPort: port,
                    connectPort: connectionPort,
                    daemonPort: daemonPort
                )
            }.value

            connectionState = .connected
            errorMessage = nil
            self.registerDevice(newDevice)
            await AndroidDeviceManager.shared.registerDevice(newDevice)
            self.selectDevice(newDevice)
        } catch {
            connectionState = selectedDevice?.status ?? .error
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Connects to an already-paired wireless Android device on its Wireless Debugging transport port.
    public func connectPairedWirelessDevice(host: String, port: UInt16 = 5555) async throws {
        isLoading = true
        connectionState = .connecting
        errorMessage = nil
        defer { isLoading = false }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let daemonPort = self.adbDaemonPort
        do {
            let connectedDevice = try await Task.detached(priority: .userInitiated) {
                try AdbSmartSocketClient.connectWireless(
                    host: trimmedHost,
                    connectionPort: port,
                    daemonPort: daemonPort
                )
            }.value

            connectionState = .connected
            errorMessage = nil
            self.registerDevice(connectedDevice)
            await AndroidDeviceManager.shared.registerDevice(connectedDevice)
            self.selectDevice(connectedDevice)
        } catch {
            connectionState = selectedDevice?.status ?? .error
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
