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
        let jobInfo = makeInitialTransferJobInfo(coreJob: coreJob, fileName: fileName)
        var deviceJobs = activeTransferJobsByDevice[jobDeviceId] ?? [:]
        deviceJobs[jobId] = jobInfo
        activeTransferJobsByDevice[jobDeviceId] = deviceJobs
        if selectedDevice?.deviceId == jobDeviceId {
            self.activeTransfer = jobInfo
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await TransferJobCoordinator.shared.enqueueJob(coreJob)
            let observerTask = self.makeTransferObserverTask(jobDeviceId: jobDeviceId, jobId: jobId)
            await executionBlock()
            await observerTask.value
            await self.settleCompletedTransferJob(coreJob: coreJob)
            self.transferTasksByJobId.removeValue(forKey: jobId)
        }
        transferTasksByJobId[jobId] = task
        transferSimulationTask = task
    }

    private func makeInitialTransferJobInfo(
        coreJob: AndroidTransferJob,
        fileName: String
    ) -> AndroidTransferJobInfo {
        let initialSpeed: UInt64 = (selectedDevice?.connectionType == .usbAdb) ? 75_000_000 : 32_000_000
        return AndroidTransferJobInfo(
            id: coreJob.jobId,
            deviceId: coreJob.deviceId,
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
    }

    private func makeTransferObserverTask(jobDeviceId: String, jobId: String) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await TransferJobCoordinator.shared.jobUpdates
            for await jobs in stream {
                guard !Task.isCancelled else { break }
                guard let updated = jobs.first(where: { $0.jobId == jobId }) else { continue }
                guard self.applyCoordinatorJobSnapshot(updated, jobDeviceId: jobDeviceId, jobId: jobId) else { break }
                if updated.status.isTerminal { break }
            }
        }
    }

    @discardableResult
    private func applyCoordinatorJobSnapshot(
        _ snapshot: AndroidTransferJob,
        jobDeviceId: String,
        jobId: String
    ) -> Bool {
        guard var current = activeTransferJobsByDevice[jobDeviceId]?[jobId] else { return false }
        current.transferredBytes = snapshot.transferredBytes
        current.currentSpeedBps = snapshot.currentSpeedBps
        if let mappedStatus = AndroidTransferStatus(rawValue: snapshot.status.rawValue) {
            current.status = mappedStatus
        }
        current.errorMessage = snapshot.errorMessage
        current.verifiedSha256Hex = snapshot.verifiedSha256Hex
        current.verificationLevel = snapshot.verificationLevel
        current.sourceStreamSha256Verified = snapshot.sourceStreamSha256Verified
        current.remoteSizeVerified = snapshot.remoteSizeVerified
        current.remoteReadbackSha256Verified = snapshot.remoteReadbackSha256Verified
        current.isSkipped = snapshot.isSkipped
        current.commitPhase = snapshot.commitPhase
        activeTransferJobsByDevice[jobDeviceId]?[jobId] = current
        if selectedDevice?.deviceId == jobDeviceId,
           (activeTransfer == nil || activeTransfer?.id == jobId) {
            activeTransfer = current
        }
        return true
    }

    private func settleCompletedTransferJob(coreJob: AndroidTransferJob) async {
        let jobDeviceId = coreJob.deviceId
        let jobId = coreJob.jobId
        guard let finalJob = await TransferJobCoordinator.shared.getJob(jobId: jobId),
              applyCoordinatorJobSnapshot(finalJob, jobDeviceId: jobDeviceId, jobId: jobId) else {
            return
        }
        if finalJob.status == .completed {
            if let dir = Self.refreshDestinationDirectory(for: coreJob),
               selectedDevice?.deviceId == jobDeviceId {
                directoryCache.removeValue(forKey: dir)
                await loadDirectoryContents(path: dir)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            activeTransferJobsByDevice[jobDeviceId]?.removeValue(forKey: jobId)
            if activeTransfer?.id == jobId && activeTransfer?.status == .completed {
                activeTransfer = nil
            }
        } else if finalJob.status.isTerminal {
            activeTransferJobsByDevice[jobDeviceId]?.removeValue(forKey: jobId)
        }
    }

    private static func refreshDestinationDirectory(for coreJob: AndroidTransferJob) -> String? {
        switch coreJob.direction {
        case .macToAndroid:
            let parent = (coreJob.destinationPath as NSString).deletingLastPathComponent
            return parent.isEmpty ? "/" : parent
        case .directPipelineExtract:
            return coreJob.destinationPath
        default:
            return nil
        }
    }
}
