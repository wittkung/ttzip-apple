// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation


extension AndroidDeviceViewModel {
    // MARK: - Transfer Coordination & Progress HUD
    
    /// Initiates download of a remote file to local Mac storage via native UniFFI / Smart Socket / MTP streaming driver.
    @discardableResult
    public func downloadNode(
        _ node: AndroidStorageNode,
        to localURL: URL,
        conflictPolicy: AndroidTransferConflictPolicy = .overwrite
    ) -> String? {
        guard let device = selectedDevice else { return nil }
        let totalBytes = node.sizeBytes
        let storageId = resolveActiveStorageId()
        let objectHandle = node.objectHandle ?? resolveMtpObjectHandle(forPath: node.path) ?? 0
        let jobId = UUID().uuidString
        let coreJob = AndroidTransferJob(
            jobId: jobId,
            deviceId: device.deviceId,
            direction: .androidToMac,
            sourcePath: node.path,
            destinationPath: localURL.path,
            totalBytes: totalBytes,
            status: .transferring,
            storageId: storageId,
            objectHandle: objectHandle,
            conflictPolicy: conflictPolicy
        )
        
        startTrackedJob(coreJob, fileName: node.name) {
            await TransferJobCoordinator.shared.executeDownload(
                jobId: jobId,
                deviceId: device.deviceId,
                remotePath: node.path,
                localPath: localURL.path,
                storageId: storageId,
                objectHandle: objectHandle,
                conflictPolicy: conflictPolicy
            )
        }
        return jobId
    }
    
    /// Initiates upload from local Mac file to remote Android directory via native streaming driver.
    @discardableResult
    public func uploadLocalFile(
        _ localURL: URL,
        to remoteDir: String,
        conflictPolicy: AndroidTransferConflictPolicy = .overwrite
    ) -> String? {
        guard let device = selectedDevice else { return nil }
        let fileName = localURL.lastPathComponent
        let cleanRemoteDir = (remoteDir.hasSuffix("/") && remoteDir.count > 1) ? String(remoteDir.dropLast()) : remoteDir
        let targetPath = cleanRemoteDir == "/" ? "/\(fileName)" : "\(cleanRemoteDir)/\(fileName)"
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
        let storageId = resolveActiveStorageId()
        let jobId = UUID().uuidString
        let coreJob = AndroidTransferJob(
            jobId: jobId,
            deviceId: device.deviceId,
            direction: .macToAndroid,
            sourcePath: localURL.path,
            destinationPath: targetPath,
            totalBytes: size,
            status: .transferring,
            storageId: storageId,
            conflictPolicy: conflictPolicy
        )
        
        startTrackedJob(coreJob, fileName: fileName) {
            await TransferJobCoordinator.shared.executeUpload(
                jobId: jobId,
                deviceId: device.deviceId,
                localPath: localURL.path,
                remoteDir: cleanRemoteDir,
                storageId: storageId,
                conflictPolicy: conflictPolicy
            )
        }
        return jobId
    }
    
    /// Extracts a local archive directly into a remote Android destination directory via zero-temp streaming.
    @discardableResult
    public func extractArchiveToDevice(
        archiveURL: URL,
        destinationDir: String,
        selectedEntries: [String]? = nil,
        password: String? = nil
    ) -> String? {
        extractArchiveToDevice(
            archivePath: archiveURL.path,
            destinationDir: destinationDir,
            selectedEntries: selectedEntries,
            password: password
        )
    }

    /// Extracts a local archive directly into a remote Android destination directory via zero-temp streaming.
    @discardableResult
    public func extractArchiveToDevice(
        archivePath: String,
        destinationDir: String,
        selectedEntries: [String]? = nil,
        password: String? = nil
    ) -> String? {
        guard let device = selectedDevice else { return nil }
        let fileName = (archivePath as NSString).lastPathComponent
        let targetDir = (destinationDir.hasSuffix("/") && destinationDir.count > 1) ? String(destinationDir.dropLast()) : destinationDir
        let totalBytes = (try? FileManager.default.attributesOfItem(atPath: archivePath)[.size] as? UInt64) ?? 0
        let jobId = UUID().uuidString
        
        let coreJob = AndroidTransferJob(
            jobId: jobId,
            deviceId: device.deviceId,
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
        return jobId
    }

    /// Cancels a specific transfer job by ID without disturbing jobs on other devices.
    public func cancelTransfer(jobId: String) {
        Task {
            await TransferJobCoordinator.shared.cancelJob(jobId: jobId)
        }
        transferTasksByJobId[jobId]?.cancel()
        transferTasksByJobId.removeValue(forKey: jobId)
        
        for (deviceId, var deviceJobs) in activeTransferJobsByDevice {
            if var job = deviceJobs[jobId] {
                job.status = .cancelling
                deviceJobs.removeValue(forKey: jobId)
                activeTransferJobsByDevice[deviceId] = deviceJobs
            }
        }
        if var job = activeTransfer, job.id == jobId {
            job.status = .cancelling
            activeTransfer = job
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    if self.activeTransfer?.id == jobId {
                        self.activeTransfer = nil
                    }
                }
            }
        }
    }

    /// Cancels active transfer job for the currently selected device.
    public func cancelActiveTransfer() {
        guard let job = activeTransfer else { return }
        cancelTransfer(jobId: job.id)
    }
    
    func startTrackedJob(
        _ coreJob: AndroidTransferJob,
        fileName: String,
        executionBlock: @escaping @Sendable () async -> Void
    ) {
        let jobDeviceId = coreJob.deviceId
        let jobId = coreJob.jobId
        let initialSpeed: UInt64 = (selectedDevice?.connectionType == .usbAdb) ? 75_000_000 : 32_000_000
        
        let jobInfo = AndroidTransferJobInfo(
            id: jobId,
            deviceId: jobDeviceId,
            direction: AndroidTransferDirection(rawValue: coreJob.direction.rawValue) ?? .macToAndroid,
            fileName: fileName,
            sourcePath: coreJob.sourcePath,
            destinationPath: coreJob.destinationPath,
            totalBytes: coreJob.totalBytes,
            transferredBytes: 0,
            currentSpeedBps: initialSpeed,
            status: .transferring,
            storageId: coreJob.storageId,
            objectHandle: coreJob.objectHandle,
            conflictPolicy: coreJob.conflictPolicy
        )
        
        var deviceJobs = activeTransferJobsByDevice[jobDeviceId] ?? [:]
        deviceJobs[jobId] = jobInfo
        activeTransferJobsByDevice[jobDeviceId] = deviceJobs
        
        if selectedDevice?.deviceId == jobDeviceId {
            self.activeTransfer = jobInfo
        }
        
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await TransferJobCoordinator.shared.enqueueJob(coreJob)
            
            let observerTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let stream = await TransferJobCoordinator.shared.jobUpdates
                for await jobs in stream {
                    guard !Task.isCancelled else { break }
                    guard let updated = jobs.first(where: { $0.jobId == jobId }) else { continue }
                    guard var current = self.activeTransferJobsByDevice[jobDeviceId]?[jobId] else { break }
                    
                    current.transferredBytes = updated.transferredBytes
                    current.currentSpeedBps = updated.currentSpeedBps
                    if let mappedStatus = AndroidTransferStatus(rawValue: updated.status.rawValue) {
                        current.status = mappedStatus
                    }
                    current.errorMessage = updated.errorMessage
                    current.verifiedSha256Hex = updated.verifiedSha256Hex
                    current.verificationLevel = updated.verificationLevel
                    current.sourceStreamSha256Verified = updated.sourceStreamSha256Verified
                    current.remoteSizeVerified = updated.remoteSizeVerified
                    current.remoteReadbackSha256Verified = updated.remoteReadbackSha256Verified
                    current.isSkipped = updated.isSkipped
                    current.commitPhase = updated.commitPhase
                    self.activeTransferJobsByDevice[jobDeviceId]?[jobId] = current
                    
                    if self.selectedDevice?.deviceId == jobDeviceId,
                       (self.activeTransfer == nil || self.activeTransfer?.id == jobId) {
                        self.activeTransfer = current
                    }
                    
                    if updated.status.isTerminal {
                        break
                    }
                }
            }
            
            await executionBlock()
            await observerTask.value
            
            // Fetch final job state from coordinator
            if let finalJob = await TransferJobCoordinator.shared.getJob(jobId: jobId),
               var current = self.activeTransferJobsByDevice[jobDeviceId]?[jobId] {
                current.transferredBytes = finalJob.transferredBytes
                current.currentSpeedBps = finalJob.currentSpeedBps
                if let mappedStatus = AndroidTransferStatus(rawValue: finalJob.status.rawValue) {
                    current.status = mappedStatus
                }
                current.errorMessage = finalJob.errorMessage
                current.verifiedSha256Hex = finalJob.verifiedSha256Hex
                current.verificationLevel = finalJob.verificationLevel
                current.sourceStreamSha256Verified = finalJob.sourceStreamSha256Verified
                current.remoteSizeVerified = finalJob.remoteSizeVerified
                current.remoteReadbackSha256Verified = finalJob.remoteReadbackSha256Verified
                current.isSkipped = finalJob.isSkipped
                current.commitPhase = finalJob.commitPhase
                self.activeTransferJobsByDevice[jobDeviceId]?[jobId] = current
                if self.selectedDevice?.deviceId == jobDeviceId,
                   (self.activeTransfer == nil || self.activeTransfer?.id == jobId) {
                    self.activeTransfer = current
                }
                
                if finalJob.status == .completed {
                    let destDir: String?
                    if coreJob.direction == .macToAndroid {
                        let parent = (coreJob.destinationPath as NSString).deletingLastPathComponent
                        destDir = parent.isEmpty ? "/" : parent
                    } else if coreJob.direction == .directPipelineExtract {
                        destDir = coreJob.destinationPath
                    } else {
                        destDir = nil
                    }
                    
                    if let dir = destDir, self.selectedDevice?.deviceId == jobDeviceId {
                        self.directoryCache.removeValue(forKey: dir)
                        await self.loadDirectoryContents(path: dir)
                    }
                    
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.activeTransferJobsByDevice[jobDeviceId]?.removeValue(forKey: jobId)
                    if self.activeTransfer?.id == jobId && self.activeTransfer?.status == .completed {
                        self.activeTransfer = nil
                    }
                } else if finalJob.status.isTerminal {
                    self.activeTransferJobsByDevice[jobDeviceId]?.removeValue(forKey: jobId)
                }
            }
            
            self.transferTasksByJobId.removeValue(forKey: jobId)
        }
        
        transferTasksByJobId[jobId] = task
        transferSimulationTask = task
    }
}
