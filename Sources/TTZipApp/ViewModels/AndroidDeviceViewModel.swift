// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Observation
import TTZipAppCore
import TTZipCore
import TTZipUI

/// Swift 6 @Observable view model driving connected Android device management and Miller columns exploration.
@Observable
@MainActor
public final class AndroidDeviceViewModel {
    /// Shared singleton instance for cross-view synchronization.
    public static let shared = AndroidDeviceViewModel()
    
    /// Embedded native Rust application core microkernel instance.
    let appCoreEngine: AppCoreEngine? = {
        let configPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ttzip_app_core")
        try? FileManager.default.createDirectory(atPath: configPath, withIntermediateDirectories: true)
        return try? AppCoreEngine(configDir: configPath)
    }()
    
    /// Configurable local ADB Smart Socket daemon TCP port (defaults to 5037).
    public var adbDaemonPort: UInt16 = AdbSmartSocketClient.defaultDaemonPort

    // MARK: - Published State
    
    /// List of all currently discovered or connected Android devices.
    public private(set) var connectedDevices: [AndroidDevice] = []
    
    /// Convenience alias returning the current snapshot of connected devices.
    public var devices: [AndroidDevice] {
        connectedDevices
    }
    
    /// Currently selected Android device.
    public var selectedDevice: AndroidDevice? {
        didSet {
            connectionState = selectedDevice?.status ?? .disconnected
            guard selectedDevice?.deviceId != oldValue?.deviceId else { return }
            handleSelectedDeviceChange()
        }
    }
    
    /// Current connection lifecycle state for the active or pending device.
    public internal(set) var connectionState: AndroidDeviceStatus = .disconnected
    
    /// Indicates whether hardware or network device discovery is currently in progress.
    public internal(set) var isScanning: Bool = false
    
    /// Currently selected logical storage partition.
    public var selectedPartition: AndroidStoragePartition? {
        didSet {
            guard selectedPartition?.partitionId != oldValue?.partitionId else { return }
            resetPathHierarchy()
        }
    }
    
    /// Path hierarchy for each active column in the Miller columns view.
    /// Index 0 is root, index 1 is first subfolder, etc.
    public var columnPaths: [String] = []
    
    /// Selected node in each Miller column, keyed by column depth index.
    public var selectedNodeByColumn: [Int: AndroidStorageNode] = [:]
    
    /// Current leaf selected node (file or folder).
    public var selectedNode: AndroidStorageNode? {
        didSet {
            if let node = selectedNode, node.isRestricted {
                scopedStorageWarningPath = node.path
                showScopedStorageNotice = true
            }
        }
    }
    
    /// Invalidates legacy no-window requests across device or partition changes.
    var legacyDirectoryRequestGeneration: UInt64 = 0

    /// Scoped directory cache keyed by (deviceId, partitionId, normalizedPath).
    public internal(set) var directoryCacheByKey: [AndroidDirectoryRequestKey: [AndroidStorageNode]] = [:]

    /// Cached directory items keyed by normalized directory path (global compatibility view).
    public internal(set) var directoryCache: [String: [AndroidStorageNode]] = [:]

    /// Explicit directory states keyed by normalized directory path.
    public internal(set) var directoryStatesByPath: [String: AndroidDirectoryState] = [:]

    /// Window-isolated Android browsing states keyed by windowID.
    public internal(set) var windowBrowseStates: [UUID: AndroidWindowBrowseState] = [:]
    
    /// Set of directory paths currently undergoing asynchronous loading.
    public internal(set) var loadingPaths: Set<String> = []

    /// In-flight request keys preventing duplicate simultaneous I/O for the same scope.
    public internal(set) var loadingRequestKeys: Set<AndroidDirectoryRequestKey> = []

    /// Optional test-injected directory listing provider bypassing physical I/O.
    public var directoryLister: (@Sendable (_ serial: String, _ path: String) async throws -> [AndroidStorageNode])? = nil
    
    /// Global loading indicator flag.
    public var isLoading: Bool = false
    
    /// Optional user-facing error message.
    public var errorMessage: String? = nil
    
    /// Active file transfer operation for the currently selected device, if any.
    public var activeTransfer: AndroidTransferJobInfo? = nil
    
    /// Per-device active transfer jobs keyed by `[deviceId: [jobId: AndroidTransferJobInfo]]`.
    public internal(set) var activeTransferJobsByDevice: [String: [String: AndroidTransferJobInfo]] = [:]

    // MARK: - Presentation Sheet Triggers
    
    /// Controls presentation of the ADB High-Speed enablement guide sheet.
    public var showAdbGuideSheet: Bool = false
    
    /// Controls presentation of the wireless Wi-Fi pairing modal sheet.
    public var showPairingSheet: Bool = false
    
    /// Controls presentation of the Scoped Storage warning inline bubble/sheet.
    public var showScopedStorageNotice: Bool = false
    
    /// Path triggering the Scoped Storage notice.
    public var scopedStorageWarningPath: String? = nil
    
    /// Controls presentation of the wireless devices discovery popover/panel.
    public var showWirelessDiscovery: Bool = false
    
    // MARK: - Internal Tasks & Subscriptions
    
    private var deviceUpdateTask: Task<Void, Never>? = nil
    private var hardwareScannedDeviceIds: Set<String> = []
    var transferSimulationTask: Task<Void, Never>? = nil
    var transferTasksByJobId: [String: Task<Void, Never>] = [:]
    
    // MARK: - Initialization
    
    public init(autoStartHardwareMonitoring: Bool? = nil) {
        let env = ProcessInfo.processInfo.environment
        let isRunningUnderXCTest = env["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let shouldStartHardware = autoStartHardwareMonitoring ?? (!isRunningUnderXCTest)
        if shouldStartHardware {
            startDeviceUpdateSubscription()
            Task {
                await AndroidDeviceManager.shared.startHardwareMonitoring()
                await refreshHardwareDevices()
            }
        }
    }
    
    /// Refreshes devices by querying physical USB bus and local ADB daemon asynchronously
    /// via HardwareIOActor to prevent UI freezing from 4.0s TCP socket timeouts on MainActor.
    public func refreshHardwareDevices() async {
        guard !isScanning else { return }
        let engine = appCoreEngine ?? AppCoreEngine.shared
        
        isScanning = true
        defer { isScanning = false }
        
        // 1. Scan physical MTP USB devices and ADB daemon off the MainActor thread
        let rawList = await HardwareIOActor.shared.scanHardwareDevices(engine: engine)
        let list: [AndroidDevice] = rawList.map { dev in
            var normalized = dev
            if normalized.storagePartitions.isEmpty && normalized.isConnected {
                normalized.storagePartitions = AdbSmartSocketClient.defaultPartitions(for: normalized.connectionType)
            }
            return normalized
        }

        let discoveredIds = Set(list.map(\.deviceId))
        let unpluggedHardwareIds = hardwareScannedDeviceIds.subtracting(discoveredIds)
        hardwareScannedDeviceIds = discoveredIds

        for staleId in unpluggedHardwareIds {
            self.removeDevice(id: staleId)
            await AndroidDeviceManager.shared.removeDevice(id: staleId)
        }
        
        for dev in list {
            self.registerDevice(dev)
            await AndroidDeviceManager.shared.registerDevice(dev)
        }
    }
    
    // MARK: - Device Mutation
    
    /// Registers or updates an Android device within this view model.
    public func registerDevice(_ device: AndroidDevice) {
        var normalized = device
        if normalized.storagePartitions.isEmpty && normalized.isConnected {
            normalized.storagePartitions = AdbSmartSocketClient.defaultPartitions(for: normalized.connectionType)
        }
        if let idx = connectedDevices.firstIndex(where: { $0.deviceId == normalized.deviceId }) {
            connectedDevices[idx] = normalized
        } else {
            connectedDevices.append(normalized)
        }
        connectedDevices.sort { $0.deviceId < $1.deviceId }
        
        if selectedDevice?.deviceId == normalized.deviceId {
            selectedDevice = normalized
            connectionState = normalized.status
            if selectedPartition == nil,
               let primary = normalized.storagePartitions.first(where: { !$0.isRemovable }) ?? normalized.storagePartitions.first {
                selectedPartition = primary
            }
        }
    }
    
    /// Removes a device by its identifier and clears selection if appropriate.
    public func removeDevice(id: String) {
        if let jobs = activeTransferJobsByDevice.removeValue(forKey: id) {
            for jobId in jobs.keys {
                transferTasksByJobId[jobId]?.cancel()
                transferTasksByJobId.removeValue(forKey: jobId)
                Task {
                    await TransferJobCoordinator.shared.cancelJob(jobId: jobId)
                }
            }
        }
        connectedDevices.removeAll { $0.deviceId == id }
        if selectedDevice?.deviceId == id {
            selectedDevice = nil
            selectedPartition = nil
            columnPaths = []
            selectedNodeByColumn.removeAll()
            selectedNode = nil
            directoryCache.removeAll()
            activeTransfer = nil
            connectionState = .disconnected
        }
    }
    
    /// Clears all connected devices and resets presentation state.
    public func removeAllDevices() {
        for task in transferTasksByJobId.values {
            task.cancel()
        }
        transferTasksByJobId.removeAll()
        activeTransferJobsByDevice.removeAll()
        transferSimulationTask?.cancel()
        transferSimulationTask = nil
        activeTransfer = nil
        connectedDevices.removeAll()
        selectedDevice = nil
        selectedPartition = nil
        columnPaths = []
        selectedNodeByColumn.removeAll()
        selectedNode = nil
        directoryCache.removeAll()
        connectionState = .disconnected
    }
    
    // MARK: - Device Subscription
    
    /// Initiates continuous listening to AndroidDeviceManager device stream.
    public func startDeviceUpdateSubscription() {
        guard deviceUpdateTask == nil else { return }
        
        deviceUpdateTask = Task { @MainActor [weak self] in
            let stream = await AndroidDeviceManager.shared.deviceUpdates
            for await devices in stream {
                guard !Task.isCancelled, let self else { break }
                self.updateDevicesSnapshot(devices)
            }
        }
    }
    
    private func updateDevicesSnapshot(_ devices: [AndroidDevice]) {
        self.connectedDevices = devices
        
        if let current = selectedDevice {
            if let updated = devices.first(where: { $0.deviceId == current.deviceId }) {
                self.selectedDevice = updated
                self.connectionState = updated.status
                // Update partition if necessary
                if let part = selectedPartition,
                   !updated.storagePartitions.contains(where: { $0.partitionId == part.partitionId }) {
                    self.selectedPartition = updated.storagePartitions.first
                }
            } else {
                // Currently selected device was disconnected
                self.selectedDevice = nil
                self.selectedPartition = nil
                self.columnPaths = []
                self.selectedNodeByColumn = [:]
                self.selectedNode = nil
                self.directoryCache.removeAll()
                self.activeTransfer = nil
                self.connectionState = .disconnected
            }
        } else {
            self.activeTransfer = nil
            self.connectionState = .disconnected
        }
    }
    
    // MARK: - Device Selection & Ejection
    
    /// Per-window binding for active Android device browsing, guaranteeing multi-window isolation.
    public var activeDeviceByWindow: [UUID: String] = [:]

    /// Retrieves the device currently bound to a specific window.
    public func activeDevice(forWindow windowID: UUID) -> AndroidDevice? {
        guard let devId = activeDeviceByWindow[windowID] else { return nil }
        return connectedDevices.first(where: { $0.deviceId == devId })
    }

    /// Binds or unbinds a specific window to an Android device.
    public func bindWindow(_ windowID: UUID, toDevice device: AndroidDevice?) {
        if activeDeviceByWindow[windowID] != device?.deviceId {
            let previousGeneration = windowBrowseStates[windowID]?.requestGeneration ?? 0
            let partition = device?.storagePartitions.first(where: { !$0.isRemovable }) ?? device?.storagePartitions.first
            windowBrowseStates[windowID] = AndroidWindowBrowseState(
                selectedPartition: partition, columnPaths: partition.map { [$0.rootPath] } ?? [],
                requestGeneration: previousGeneration &+ 1
            )
        }
        if let device = device {
            activeDeviceByWindow[windowID] = device.deviceId
            if selectedDevice?.deviceId != device.deviceId {
                self.selectedDevice = device
            }
        } else {
            activeDeviceByWindow.removeValue(forKey: windowID)
        }
    }

    /// Selects an Android device for browsing.
    public func selectDevice(_ device: AndroidDevice?) {
        if let winID = BrowserWindowRegistry.shared.activeWindowID {
            bindWindow(winID, toDevice: device)
        }
        guard selectedDevice?.deviceId != device?.deviceId else { return }
        self.selectedDevice = device
    }
    
    private func handleSelectedDeviceChange() {
        legacyDirectoryRequestGeneration &+= 1
        directoryStatesByPath.removeAll()
        directoryCache.removeAll()
        selectedNodeByColumn.removeAll()
        selectedNode = nil
        errorMessage = nil
        
        guard let device = selectedDevice else {
            selectedPartition = nil
            columnPaths = []
            activeTransfer = nil
            return
        }
        
        activeTransfer = activeTransferJobsByDevice[device.deviceId]?.values.first(where: { !$0.status.isTerminal })
            ?? activeTransferJobsByDevice[device.deviceId]?.values.first

        // Select primary or first partition
        if let primary = device.storagePartitions.first(where: { !$0.isRemovable }) ?? device.storagePartitions.first {
            self.selectedPartition = primary
        } else {
            self.selectedPartition = nil
            self.columnPaths = []
        }
    }
    
    /// Selects a specific storage partition on the active device.
    public func selectPartition(_ partition: AndroidStoragePartition?, windowID: UUID? = nil) {
        if let winID = windowID {
            var state = windowBrowseStates[winID] ?? AndroidWindowBrowseState()
            if state.selectedPartition?.partitionId != partition?.partitionId {
                state.directoryStatesByPath.removeAll()
            }
            state.selectedPartition = partition
            state.requestGeneration &+= 1
            if let root = partition?.rootPath {
                state.columnPaths = [root]
                state.selectedNode = nil
                state.selectedNodeByColumn.removeAll()
                windowBrowseStates[winID] = state
                Task { await loadDirectoryContents(path: root, windowID: winID) }
            } else {
                windowBrowseStates[winID] = state
            }
        }
        self.selectedPartition = partition
    }

    /// Selects partition for a specific window.
    public func selectPartition(_ partition: AndroidStoragePartition?, forWindow windowID: UUID?) {
        selectPartition(partition, windowID: windowID)
    }

    /// Sets explicit column paths hierarchy for window navigation or testing.
    public func setColumnPaths(_ paths: [String], windowID: UUID? = nil) {
        if let winID = windowID {
            var state = windowBrowseStates[winID] ?? AndroidWindowBrowseState(selectedPartition: selectedPartition)
            state.columnPaths = paths
            state.requestGeneration &+= 1
            windowBrowseStates[winID] = state
        }
        if windowID == nil { legacyDirectoryRequestGeneration &+= 1 }
        self.columnPaths = paths
    }

    /// Sets explicit column paths hierarchy for a specific window.
    public func setColumnPaths(_ paths: [String], forWindow windowID: UUID?) {
        setColumnPaths(paths, windowID: windowID)
    }

    /// Retrieves partition for a window or shared fallback.
    public func selectedPartition(forWindow windowID: UUID?) -> AndroidStoragePartition? {
        if let winID = windowID {
            return windowBrowseStates[winID]?.selectedPartition ?? activeDevice(forWindow: winID)?.storagePartitions.first
        }
        return selectedPartition
    }

    /// Retrieves column paths hierarchy for a window or shared fallback.
    public func columnPaths(forWindow windowID: UUID?) -> [String] {
        if let winID = windowID { return windowBrowseStates[winID]?.columnPaths ?? [] }
        return columnPaths
    }

    /// Retrieves current leaf directory path for a window or shared fallback.
    public func currentDirectoryPath(forWindow windowID: UUID?) -> String {
        columnPaths(forWindow: windowID).last ?? selectedPartition(forWindow: windowID)?.rootPath ?? "/"
    }

    /// Retrieves selected node for a window or shared fallback.
    public func selectedNode(forWindow windowID: UUID?) -> AndroidStorageNode? {
        if let winID = windowID { return windowBrowseStates[winID]?.selectedNode }
        return selectedNode
    }

    /// Builds a canonical scoped request key for a device, partition, and path.
    public func makeRequestKey(path: String, windowID: UUID?) -> AndroidDirectoryRequestKey? {
        let device: AndroidDevice?
        if let windowID { device = activeDevice(forWindow: windowID) } else { device = currentDevice }
        guard let device = device else { return nil }
        let partition = selectedPartition(forWindow: windowID)
            ?? device.storagePartitions.first
            ?? AndroidStoragePartition(partitionId: "default", displayName: "Default", totalBytes: 0, availableBytes: 0, rootPath: "/")
        return AndroidDirectoryRequestKey(deviceId: device.deviceId, partitionId: partition.partitionId, path: path)
    }

    /// A scoped miss never reads another device's legacy path-only cache.
    public func cachedNodes(forPath path: String, windowID: UUID?) -> [AndroidStorageNode]? {
        if let key = makeRequestKey(path: path, windowID: windowID) { return directoryCacheByKey[key] }
        guard windowID == nil else { return nil }
        let normalized = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        return directoryCache[normalized] ?? directoryCache[path]
    }

    /// Stores the requested path; only the no-window compatibility surface has a global mirror.
    public func storeCachedNodes(_ nodes: [AndroidStorageNode], forPath path: String, windowID: UUID?) {
        let normalized = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        if let key = makeRequestKey(path: normalized, windowID: windowID) {
            directoryCacheByKey[key] = nodes
        }
        if windowID == nil {
            directoryCache[path] = nodes
            directoryCache[normalized] = nodes
        }
    }

    /// Evicts nodes from scoped cache and legacy global cache.
    public func removeCachedNodes(forPath path: String, windowID: UUID?) {
        let normalized = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        if let key = makeRequestKey(path: normalized, windowID: windowID) {
            directoryCacheByKey.removeValue(forKey: key)
        }
        if windowID == nil {
            directoryCache.removeValue(forKey: path)
            directoryCache.removeValue(forKey: normalized)
        }
    }

    /// Retrieves directory state for a path in a window.
    public func directoryState(forPath path: String, windowID: UUID? = nil) -> AndroidDirectoryState {
        if let windowID, activeDevice(forWindow: windowID)?.status != .connected { return .disconnected }
        let normalized = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        let explicit: AndroidDirectoryState?
        if let windowID {
            explicit = windowBrowseStates[windowID]?.directoryStatesByPath[normalized]
        } else {
            explicit = directoryStatesByPath[normalized]
        }
        if let explicit, explicit != .loading { return explicit }
        if let key = makeRequestKey(path: normalized, windowID: windowID), loadingRequestKeys.contains(key) {
            return .loading
        }
        if let cached = cachedNodes(forPath: normalized, windowID: windowID) {
            return cached.isEmpty ? .empty : .loaded(entries: cached)
        }
        return .idle
    }

    /// Records explicit directory state for a path.
    public func setDirectoryState(_ state: AndroidDirectoryState, forPath path: String, windowID: UUID? = nil) {
        let normalized = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
        if windowID == nil { directoryStatesByPath[normalized] = state }
        if let winID = windowID {
            var browseState = windowBrowseStates[winID] ?? AndroidWindowBrowseState(selectedPartition: selectedPartition)
            browseState.directoryStatesByPath[normalized] = state
            windowBrowseStates[winID] = browseState
        }
        if case .loaded(let nodes) = state {
            storeCachedNodes(nodes, forPath: normalized, windowID: windowID)
        } else if case .empty = state {
            storeCachedNodes([], forPath: normalized, windowID: windowID)
        }
    }
    
    private func resetPathHierarchy() {
        legacyDirectoryRequestGeneration &+= 1
        directoryStatesByPath.removeAll()
        directoryCache.removeAll()
        selectedNodeByColumn.removeAll()
        selectedNode = nil
        
        guard let partition = selectedPartition else {
            columnPaths = []
            return
        }
        
        let root = partition.rootPath
        columnPaths = [root]
        Task {
            await loadDirectoryContents(path: root)
        }
    }
    
    /// Ejects/disconnects an Android device cleanly.
    public func ejectDevice(_ device: AndroidDevice) {
        removeDevice(id: device.deviceId)
        Task {
            await AndroidDeviceManager.shared.removeDevice(id: device.deviceId)
        }
    }
    
    // MARK: - Navigation & Miller Columns Handling
    
    /// Handles user clicking on a node at a given column depth.
    public func selectNode(_ node: AndroidStorageNode, atColumn depth: Int = 0, windowID: UUID? = nil) {
        if let winID = windowID {
            var state = windowBrowseStates[winID] ?? AndroidWindowBrowseState(
                selectedPartition: selectedPartition,
                columnPaths: columnPaths
            )
            state.requestGeneration &+= 1
            state.selectedNodeByColumn[depth] = node
            state.selectedNode = node
            if state.columnPaths.count > depth + 1 {
                state.columnPaths.removeSubrange((depth + 1)...)
                for k in state.selectedNodeByColumn.keys where k > depth {
                    state.selectedNodeByColumn.removeValue(forKey: k)
                }
            }
            if node.isDirectory {
                if !(node.isRestricted && selectedDevice?.connectionType == .usbMtp) {
                    state.columnPaths.append(node.path)
                    windowBrowseStates[winID] = state
                    Task { await loadDirectoryContents(path: node.path, windowID: winID) }
                    return
                }
            }
            windowBrowseStates[winID] = state
        }

        selectedNodeByColumn[depth] = node
        selectedNode = node
        
        if columnPaths.count > depth + 1 {
            columnPaths.removeSubrange((depth + 1)...)
            for k in selectedNodeByColumn.keys where k > depth {
                selectedNodeByColumn.removeValue(forKey: k)
            }
        }
        
        if node.isDirectory {
            if node.isRestricted && selectedDevice?.connectionType == .usbMtp {
                scopedStorageWarningPath = node.path
                showScopedStorageNotice = true
            } else {
                let nextPath = node.path
                columnPaths.append(nextPath)
                Task {
                    await loadDirectoryContents(path: nextPath, windowID: windowID)
                }
            }
        }
    }

    /// Handles user clicking on a node at a given column depth for a specific window.
    public func selectNode(_ node: AndroidStorageNode, atColumn depth: Int = 0, forWindow windowID: UUID?) {
        selectNode(node, atColumn: depth, windowID: windowID)
    }
    
    /// Navigates to a specific breadcrumb path index.
    public func navigateToBreadcrumbIndex(_ index: Int, windowID: UUID? = nil) {
        if let winID = windowID, var state = windowBrowseStates[winID] {
            guard index >= 0, index < state.columnPaths.count else { return }
            state.requestGeneration &+= 1
            state.columnPaths.removeSubrange((index + 1)...)
            for k in state.selectedNodeByColumn.keys where k >= index {
                state.selectedNodeByColumn.removeValue(forKey: k)
            }
            state.selectedNode = index > 0 ? state.selectedNodeByColumn[index - 1] : nil
            windowBrowseStates[winID] = state
        }
        guard index >= 0, index < columnPaths.count else { return }
        columnPaths.removeSubrange((index + 1)...)
        for k in selectedNodeByColumn.keys where k >= index {
            selectedNodeByColumn.removeValue(forKey: k)
        }
        selectedNode = index > 0 ? selectedNodeByColumn[index - 1] : nil
    }

    /// Builds canonical location descriptor for window navigation / path bar handoff.
    public func currentLocation(forWindow windowID: UUID?) -> AndroidLocationDescriptor? {
        let device: AndroidDevice? = {
            if let winID = windowID {
                return activeDevice(forWindow: winID)
            }
            return selectedDevice
        }()
        guard let device = device else { return nil }

        let partition = selectedPartition(forWindow: windowID)
            ?? device.storagePartitions.first
            ?? AndroidStoragePartition(partitionId: "primary", displayName: "Internal Shared Storage", totalBytes: 0, availableBytes: 0, rootPath: "/")
        let path = currentDirectoryPath(forWindow: windowID)
        let breadcrumbs = columnPaths(forWindow: windowID)
        let selected = selectedNode(forWindow: windowID)
        let state = directoryState(forPath: path, windowID: windowID)
        let fsName = device.connectionType == .usbMtp ? "MTP 1.1 Storage" : "Android Shared Storage (FUSE)"

        return AndroidLocationDescriptor(
            deviceId: device.deviceId,
            deviceName: device.displayName,
            connectionType: device.connectionType,
            partitionId: partition.partitionId,
            partitionDisplayName: partition.displayName,
            currentPath: path,
            breadcrumbs: breadcrumbs,
            totalBytes: partition.totalBytes,
            availableBytes: partition.availableBytes,
            filesystemDisplayName: fsName,
            selectedNode: selected,
            directoryState: state
        )
    }

    /// Provides contextual inspector mode describing Android device / partition / selection attributes.
    public func inspectorSurfaceMode(forWindow windowID: UUID?) -> InspectorSurfaceMode {
        guard let location = currentLocation(forWindow: windowID) else { return .empty }

        if let node = location.selectedNode {
            let virtualURL = URL(string: "android://\(location.deviceId)\(node.path)")
                ?? URL(fileURLWithPath: node.path)
            let ext = (node.name as NSString).pathExtension.uppercased()
            let kind = node.isDirectory
                ? (node.isRestricted ? "Restricted Android Directory" : "Android Directory")
                : (ext.isEmpty ? "Android File" : "\(ext) File")
            let meta = FileSystemEntryMetadata(
                url: virtualURL,
                name: node.name,
                sizeInBytes: Int64(node.sizeBytes),
                isDirectory: node.isDirectory,
                modifiedDate: node.modifiedDate,
                mimeType: kind
            )
            return .single(metadata: meta)
        }

        let virtualURL = URL(string: "android://\(location.deviceId)\(location.currentPath)")
            ?? URL(fileURLWithPath: location.currentPath)
        let rootName = location.currentPath == "/"
            ? location.partitionDisplayName
            : (location.currentPath as NSString).lastPathComponent
        let meta = FileSystemEntryMetadata(
            url: virtualURL,
            name: rootName,
            sizeInBytes: Int64(location.totalBytes),
            isDirectory: true,
            modifiedDate: Date(),
            mimeType: location.filesystemDisplayName
        )
        return .single(metadata: meta)
    }
}
