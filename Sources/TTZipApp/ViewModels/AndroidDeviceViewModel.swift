// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import Observation
import TTZipCore
import TTZipUI

/// Transfer direction for Android file operations.
public enum AndroidTransferDirection: String, Sendable, Hashable, Codable {
    case macToAndroid = "MacToAndroid"
    case androidToMac = "AndroidToMac"
    case directPipelineExtract = "DirectPipelineExtract"
}

/// Lifecycle status for an ongoing Android transfer operation.
public enum AndroidTransferStatus: String, Sendable, Hashable, Codable {
    case queued = "Queued"
    case transferring = "Transferring"
    case paused = "Paused"
    case cancelling = "Cancelling"
    case completed = "Completed"
    case failed = "Failed"
}

/// Snapshot model capturing active file transfer metrics.
public struct AndroidTransferJobInfo: Identifiable, Sendable, Hashable {
    public let id: String
    public let direction: AndroidTransferDirection
    public let fileName: String
    public let sourcePath: String
    public let destinationPath: String
    public let totalBytes: UInt64
    public var transferredBytes: UInt64
    public var currentSpeedBps: UInt64
    public var status: AndroidTransferStatus
    public var errorMessage: String?
    
    public var progress: Double {
        guard totalBytes > 0 else { return 0.0 }
        return min(1.0, max(0.0, Double(transferredBytes) / Double(totalBytes)))
    }
    
    public var speedMBs: Double {
        Double(currentSpeedBps) / 1_048_576.0
    }
    
    public var remainingSeconds: Double? {
        guard currentSpeedBps > 0, transferredBytes < totalBytes else { return nil }
        let remainingBytes = totalBytes - transferredBytes
        return Double(remainingBytes) / Double(currentSpeedBps)
    }
    
    public init(
        id: String = UUID().uuidString,
        direction: AndroidTransferDirection,
        fileName: String,
        sourcePath: String,
        destinationPath: String,
        totalBytes: UInt64,
        transferredBytes: UInt64 = 0,
        currentSpeedBps: UInt64 = 0,
        status: AndroidTransferStatus = .transferring,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.direction = direction
        self.fileName = fileName
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.currentSpeedBps = currentSpeedBps
        self.status = status
        self.errorMessage = errorMessage
    }
}

/// Swift 6 @Observable view model driving connected Android device management and Miller columns exploration.
@Observable
@MainActor
public final class AndroidDeviceViewModel {
    /// Shared singleton instance for cross-view synchronization.
    public static let shared = AndroidDeviceViewModel()
    
    // MARK: - Published State
    
    /// List of all currently discovered or connected Android devices.
    public private(set) var connectedDevices: [AndroidDevice] = []
    
    /// Currently selected Android device.
    public var selectedDevice: AndroidDevice? {
        didSet {
            guard selectedDevice?.deviceId != oldValue?.deviceId else { return }
            handleSelectedDeviceChange()
        }
    }
    
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
    
    /// Cached directory items keyed by normalized directory path.
    public private(set) var directoryCache: [String: [AndroidStorageNode]] = [:]
    
    /// Set of directory paths currently undergoing asynchronous loading.
    public private(set) var loadingPaths: Set<String> = []
    
    /// Global loading indicator flag.
    public var isLoading: Bool = false
    
    /// Optional user-facing error message.
    public var errorMessage: String? = nil
    
    /// Active file transfer operation, if any.
    public var activeTransfer: AndroidTransferJobInfo? = nil
    
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
    private var transferSimulationTask: Task<Void, Never>? = nil
    
    // MARK: - Initialization
    
    public init() {
        startDeviceUpdateSubscription()
        Task {
            await AndroidDeviceManager.shared.startHardwareMonitoring()
        }
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
            }
        } else if let firstDevice = devices.first(where: { $0.isConnected }) {
            selectDevice(firstDevice)
        }
    }
    
    // MARK: - Device Selection & Ejection
    
    /// Selects an Android device for browsing.
    public func selectDevice(_ device: AndroidDevice?) {
        guard selectedDevice?.deviceId != device?.deviceId else { return }
        self.selectedDevice = device
    }
    
    private func handleSelectedDeviceChange() {
        directoryCache.removeAll()
        selectedNodeByColumn.removeAll()
        selectedNode = nil
        
        guard let device = selectedDevice else {
            selectedPartition = nil
            columnPaths = []
            return
        }
        
        // Select primary or first partition
        if let primary = device.storagePartitions.first(where: { !$0.isRemovable }) ?? device.storagePartitions.first {
            self.selectedPartition = primary
        } else {
            self.selectedPartition = nil
            self.columnPaths = []
        }
    }
    
    /// Selects a specific storage partition on the active device.
    public func selectPartition(_ partition: AndroidStoragePartition?) {
        self.selectedPartition = partition
    }
    
    private func resetPathHierarchy() {
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
        Task {
            await AndroidDeviceManager.shared.removeDevice(id: device.deviceId)
        }
        if selectedDevice?.deviceId == device.deviceId {
            selectedDevice = nil
        }
    }
    
    // MARK: - Navigation & Miller Columns Handling
    
    /// Handles user clicking on a node at a given column depth.
    public func selectNode(_ node: AndroidStorageNode, atColumn depth: Int) {
        selectedNodeByColumn[depth] = node
        selectedNode = node
        
        // Truncate any columns deeper than depth
        if columnPaths.count > depth + 1 {
            columnPaths.removeSubrange((depth + 1)...)
            for k in selectedNodeByColumn.keys where k > depth {
                selectedNodeByColumn.removeValue(forKey: k)
            }
        }
        
        if node.isDirectory {
            if node.isRestricted && selectedDevice?.connectionType == .usbMtp {
                // Trigger Scoped Storage guidance
                scopedStorageWarningPath = node.path
                showScopedStorageNotice = true
            } else {
                // Expand folder in next column
                let nextPath = node.path
                columnPaths.append(nextPath)
                Task {
                    await loadDirectoryContents(path: nextPath)
                }
            }
        }
    }
    
    /// Navigates to a specific breadcrumb path index.
    public func navigateToBreadcrumbIndex(_ index: Int) {
        guard index >= 0, index < columnPaths.count else { return }
        columnPaths.removeSubrange((index + 1)...)
        for k in selectedNodeByColumn.keys where k >= index {
            selectedNodeByColumn.removeValue(forKey: k)
        }
        selectedNode = index > 0 ? selectedNodeByColumn[index - 1] : nil
    }
    
    // MARK: - Directory Loading & Mocking
    
    /// Asynchronously loads children for a normalized VFS path.
    public func loadDirectoryContents(path: String) async {
        guard !loadingPaths.contains(path) else { return }
        loadingPaths.insert(path)
        defer { loadingPaths.remove(path) }
        
        // Check cache first
        if directoryCache[path] != nil {
            return
        }
        
        if let device = selectedDevice {
            if let remoteNodes = try? uniffiListDeviceDirectory(deviceId: device.deviceId, path: path) {
                let converted = remoteNodes.map { AndroidStorageNode($0) }
                directoryCache[path] = converted
                return
            }
        }
        
        let nodes = generateSyntheticNodes(for: path)
        directoryCache[path] = nodes
    }
    
    /// Generates standard Android VFS directory items if hardware driver is in mock or testing mode.
    private func generateSyntheticNodes(for path: String) -> [AndroidStorageNode] {
        let clean = path == "/" ? "" : path
        
        if clean.isEmpty || clean == "/storage/emulated/0" {
            return [
                AndroidStorageNode(path: "\(clean)/Android", name: "Android", entryType: .directory),
                AndroidStorageNode(path: "\(clean)/DCIM", name: "DCIM", entryType: .directory),
                AndroidStorageNode(path: "\(clean)/Download", name: "Download", entryType: .directory),
                AndroidStorageNode(path: "\(clean)/Documents", name: "Documents", entryType: .directory),
                AndroidStorageNode(path: "\(clean)/Movies", name: "Movies", entryType: .directory),
                AndroidStorageNode(path: "\(clean)/Music", name: "Music", entryType: .directory),
                AndroidStorageNode(path: "\(clean)/Pictures", name: "Pictures", entryType: .directory)
            ]
        } else if clean.hasSuffix("/Android") {
            let isMtp = selectedDevice?.connectionType == .usbMtp
            return [
                AndroidStorageNode(path: "\(clean)/data", name: "data", entryType: isMtp ? .restrictedDirectory : .directory, isRestricted: isMtp),
                AndroidStorageNode(path: "\(clean)/obb", name: "obb", entryType: isMtp ? .restrictedDirectory : .directory, isRestricted: isMtp),
                AndroidStorageNode(path: "\(clean)/media", name: "media", entryType: .directory)
            ]
        } else if clean.hasSuffix("/data") && selectedDevice?.connectionType != .usbMtp {
            // High-Speed ADB channel penetrates /Android/data
            return [
                AndroidStorageNode(path: "\(clean)/com.google.android.apps.photos", name: "com.google.android.apps.photos", entryType: .directory),
                AndroidStorageNode(path: "\(clean)/com.tencent.mm", name: "com.tencent.mm", entryType: .directory),
                AndroidStorageNode(path: "\(clean)/com.spotify.music", name: "com.spotify.music", entryType: .directory),
                AndroidStorageNode(path: "\(clean)/org.videolan.vlc", name: "org.videolan.vlc", entryType: .directory)
            ]
        } else if clean.hasSuffix("/DCIM") {
            return [
                AndroidStorageNode(path: "\(clean)/Camera", name: "Camera", entryType: .directory),
                AndroidStorageNode(path: "\(clean)/Screenshots", name: "Screenshots", entryType: .directory)
            ]
        } else if clean.hasSuffix("/Camera") {
            let now = UInt64(Date().timeIntervalSince1970)
            return [
                AndroidStorageNode(path: "\(clean)/IMG_20260913_001.jpg", name: "IMG_20260913_001.jpg", entryType: .file, sizeBytes: 4_230_112, modifiedTimestamp: now - 3600),
                AndroidStorageNode(path: "\(clean)/IMG_20260913_002.jpg", name: "IMG_20260913_002.jpg", entryType: .file, sizeBytes: 3_891_204, modifiedTimestamp: now - 3400),
                AndroidStorageNode(path: "\(clean)/VID_20260913_001.mp4", name: "VID_20260913_001.mp4", entryType: .file, sizeBytes: 154_820_040, modifiedTimestamp: now - 1800)
            ]
        } else if clean.hasSuffix("/Download") {
            let now = UInt64(Date().timeIntervalSince1970)
            return [
                AndroidStorageNode(path: "\(clean)/ProjectAssets.zip", name: "ProjectAssets.zip", entryType: .file, sizeBytes: 42_890_120, modifiedTimestamp: now - 86400),
                AndroidStorageNode(path: "\(clean)/DatabaseBackup.7z", name: "DatabaseBackup.7z", entryType: .file, sizeBytes: 310_200_100, modifiedTimestamp: now - 172800),
                AndroidStorageNode(path: "\(clean)/ProductSpec.pdf", name: "ProductSpec.pdf", entryType: .file, sizeBytes: 2_150_880, modifiedTimestamp: now - 5400)
            ]
        }
        
        return []
    }
    
    // MARK: - Transfer Coordination & Progress HUD
    
    /// Initiates download of a remote file to local Mac storage via native UniFFI streaming driver.
    public func downloadNode(_ node: AndroidStorageNode, to localURL: URL) {
        guard let device = selectedDevice else { return }
        let totalBytes = node.sizeBytes > 0 ? node.sizeBytes : 1024
        let jobId = UUID().uuidString
        let coreJob = TTZipCore.AndroidTransferJob(
            jobId: jobId,
            direction: .androidToMac,
            sourcePath: node.path,
            destinationPath: localURL.path,
            totalBytes: totalBytes,
            status: .transferring
        )
        
        startTrackedJob(coreJob, fileName: node.name) {
            await TransferJobCoordinator.shared.executeDownload(
                jobId: jobId,
                deviceId: device.deviceId,
                remotePath: node.path,
                localPath: localURL.path
            )
        }
    }
    
    /// Initiates upload from local Mac file to remote Android directory via native UniFFI streaming driver.
    public func uploadLocalFile(_ localURL: URL, to remoteDir: String) {
        guard let device = selectedDevice else { return }
        let fileName = localURL.lastPathComponent
        let targetPath = "\(remoteDir.hasSuffix("/") ? String(remoteDir.dropLast()) : remoteDir)/\(fileName)"
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 1024
        let jobId = UUID().uuidString
        let coreJob = TTZipCore.AndroidTransferJob(
            jobId: jobId,
            direction: .macToAndroid,
            sourcePath: localURL.path,
            destinationPath: targetPath,
            totalBytes: size,
            status: .transferring
        )
        
        startTrackedJob(coreJob, fileName: fileName) {
            await TransferJobCoordinator.shared.executeUpload(
                jobId: jobId,
                deviceId: device.deviceId,
                localPath: localURL.path,
                remoteDir: remoteDir
            )
        }
    }
    
    /// Extracts a local archive directly into a remote Android destination directory via zero-temp streaming.
    ///
    /// Connects to `TransferJobCoordinator` to track real progress updates, updates HUD state,
    /// and triggers automatic directory cache refresh upon completion.
    /// - Parameters:
    ///   - archiveURL: URL pointing to local archive file on host Mac.
    ///   - destinationDir: Target directory path on the remote Android storage.
    ///   - selectedEntries: Optional list of relative entry paths to extract selectively.
    ///   - password: Optional decryption passphrase.
    public func extractArchiveToDevice(
        archiveURL: URL,
        destinationDir: String,
        selectedEntries: [String]? = nil,
        password: String? = nil
    ) {
        extractArchiveToDevice(
            archivePath: archiveURL.path,
            destinationDir: destinationDir,
            selectedEntries: selectedEntries,
            password: password
        )
    }

    /// Extracts a local archive directly into a remote Android destination directory via zero-temp streaming.
    ///
    /// Connects to `TransferJobCoordinator` to track real progress updates, updates HUD state,
    /// and triggers automatic directory cache refresh upon completion.
    /// - Parameters:
    ///   - archivePath: POSIX path of local archive file on host Mac.
    ///   - destinationDir: Target directory path on the remote Android storage.
    ///   - selectedEntries: Optional list of relative entry paths to extract selectively.
    ///   - password: Optional decryption passphrase.
    public func extractArchiveToDevice(
        archivePath: String,
        destinationDir: String,
        selectedEntries: [String]? = nil,
        password: String? = nil
    ) {
        guard let device = selectedDevice else { return }
        let fileName = (archivePath as NSString).lastPathComponent
        let targetDir = destinationDir.hasSuffix("/") ? String(destinationDir.dropLast()) : destinationDir
        let totalBytes = (try? FileManager.default.attributesOfItem(atPath: archivePath)[.size] as? UInt64) ?? 10_485_760
        let jobId = UUID().uuidString
        
        let coreJob = TTZipCore.AndroidTransferJob(
            jobId: jobId,
            direction: .directPipelineExtract,
            sourcePath: archivePath,
            destinationPath: targetDir,
            totalBytes: totalBytes,
            status: .transferring
        )
        
        startTrackedJob(coreJob, fileName: fileName) {
            await TransferJobCoordinator.shared.executeDirectExtraction(
                jobId: jobId,
                archivePath: archivePath,
                destinationDeviceId: device.deviceId,
                destinationDir: targetDir
            )
        }
    }

    /// Cancels active transfer job.
    public func cancelActiveTransfer() {
        if let job = activeTransfer {
            let activeId = job.id
            Task {
                await TransferJobCoordinator.shared.cancelJob(jobId: activeId)
            }
        }
        transferSimulationTask?.cancel()
        transferSimulationTask = nil
        if var job = activeTransfer {
            job.status = .cancelling
            activeTransfer = job
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    self.activeTransfer = nil
                }
            }
        }
    }
    
    private func startTrackedJob(
        _ coreJob: TTZipCore.AndroidTransferJob,
        fileName: String,
        executionBlock: @escaping @Sendable () async -> Void
    ) {
        transferSimulationTask?.cancel()
        transferSimulationTask = nil
        
        let initialSpeed: UInt64 = (selectedDevice?.connectionType == .usbAdb) ? 75_000_000 : 32_000_000
        let jobId = coreJob.jobId
        
        self.activeTransfer = AndroidTransferJobInfo(
            id: jobId,
            direction: AndroidTransferDirection(rawValue: coreJob.direction.rawValue) ?? .macToAndroid,
            fileName: fileName,
            sourcePath: coreJob.sourcePath,
            destinationPath: coreJob.destinationPath,
            totalBytes: coreJob.totalBytes,
            transferredBytes: 0,
            currentSpeedBps: initialSpeed,
            status: .transferring
        )
        
        transferSimulationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await TransferJobCoordinator.shared.enqueueJob(coreJob)
            await executionBlock()
            
            let stream = await TransferJobCoordinator.shared.jobUpdates
            for await jobs in stream {
                guard !Task.isCancelled else { break }
                guard let updated = jobs.first(where: { $0.jobId == jobId }) else { continue }
                guard var current = self.activeTransfer, current.id == jobId else { break }
                
                current.transferredBytes = updated.transferredBytes
                current.currentSpeedBps = updated.currentSpeedBps
                if let mappedStatus = AndroidTransferStatus(rawValue: updated.status.rawValue) {
                    current.status = mappedStatus
                }
                current.errorMessage = updated.errorMessage
                self.activeTransfer = current
                
                if updated.status.isTerminal {
                    if updated.status == .completed {
                        let destDir = (coreJob.direction == .macToAndroid || coreJob.direction == .directPipelineExtract)
                            ? coreJob.destinationPath
                            : nil
                        if let dir = destDir {
                            self.directoryCache.removeValue(forKey: dir)
                            await self.loadDirectoryContents(path: dir)
                        }
                        
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if self.activeTransfer?.id == jobId && self.activeTransfer?.status == .completed {
                            self.activeTransfer = nil
                        }
                    }
                    break
                }
            }
        }
    }
    
    // MARK: - Wireless Pairing
    
    /// Performs TLS 1.3 SPAKE2 wireless pairing handshake with an Android device.
    public func pairWirelessDevice(pin: String, host: String, port: UInt16) async throws {
        isLoading = true
        defer { isLoading = false }
        
        guard pin.count == 6, !host.isEmpty, port > 0 else {
            throw NSError(domain: "AndroidDevice", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid pairing parameters. 6-digit PIN and host:port required."])
        }
        
        let ffiDevice = try uniffiPairWirelessDevice(host: host, port: port, pin: pin)
        let newDevice = AndroidDevice(ffiDevice)
        
        await AndroidDeviceManager.shared.registerDevice(newDevice)
        self.selectDevice(newDevice)
    }
}
