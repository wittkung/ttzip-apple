// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipTaskKit
import TTZipUI
import TTZipPreviewKit

extension CompressFormSession {
    public func cancelCompression() {
        guard let id = self.activeSessionTaskId, self.isProcessing else { return }
        self.isCancellationRequested = true
        ArchiveOperationsQueueCenter.shared.cancel(id: id)
        ArchiveTaskCoordinator.shared.cancelTask(id: id)
        activeCompressionTask?.cancel()
        let stoppingLabel = AppLocalizationState.shared.uiString(
            zh: "正在停止压缩...",
            en: "Stopping compression...",
            zhHant: "正在停止壓縮...",
            ja: "圧縮を停止しています...",
            ko: "압축 중지 중...",
            de: "Komprimierung wird gestoppt...",
            fr: "Arrêt de la compression...",
            es: "Deteniendo la compresión..."
        )
        self.currentProgress = ArchiveProgress(
            state: .processing,
            bytesProcessed: self.currentProgress.bytesProcessed,
            totalBytes: self.currentProgress.totalBytes,
            currentFileName: stoppingLabel,
            throughputMBs: 0.0
        )
    }

    private func resolvedCpuThreads() -> Int {
        switch cpuThreadsOption.lowercased() {
        case "single", "1 core":
            return 1
        case "half", "half cores":
            return max(1, cachedTotalCores / 2)
        default:
            return cachedTotalCores
        }
    }

    package func makeAdvancedOptions() -> ArchiveAdvancedOptions {
        let algo = (compressionLevel == .store)
            ? "Copy"
            : ((compressionAlgorithm == "Copy") ? "LZMA2" : compressionAlgorithm)
        let dictMB = (compressionLevel == .store) ? 0 : effectiveDictionarySizeMB
        let effectiveEncryptFileNames = enableEncryption && selectedFormat == .sevenZip && encryptFileNames
        return ArchiveAdvancedOptions.builder()
            .withAlgorithm(algo)
            .withDictionarySizeMB(dictMB)
            .withCpuThreads(resolvedCpuThreads())
            .withSolidArchive(compressionLevel == .store ? false : enableSolidArchive)
            .withEncryptFileNames(effectiveEncryptFileNames)
            .withZipEncryption(zipEncryptionMethod)
            .withZipEncodingUTF8(zipEncodingUTF8)
            .withZstdLevel(zstdLevel)
            .withZstdEnableLDM(zstdEnableLDM)
            .withPreservePosixAttributes(preservePosixAttributes)
            .withRecoveryRecordRedundancyPercent(canEnableRecoveryRecord ? recoveryRecordRedundancyPercent : 0)
            .build()
    }

    private struct CompletedTaskPayload {
        let result: ArchiveOperationResult
        let format: ArchiveCompressionFormat
        let isEncrypted: Bool
        let inputPaths: [String]
        let targetDirectory: String
        let shouldDeleteSource: Bool
        let openFinderAfterCompress: Bool
        let isCancelled: Bool
    }

    private enum CompressionTaskEvent {
        case progress(ArchiveProgress, totalInputBytes: Int64)
        case completed(CompletedTaskPayload, summary: CompressionCompletedSummary)
        case failed(Error, isCancelled: Bool)
    }

    /// Settles a completed compression operation in `ArchiveOperationsQueueCenter.shared` regardless of whether
    /// the originating form session is still presented or attached to `taskId`.
    private static func settleCompletedOperationInQueue(
        _ payload: CompletedTaskPayload,
        taskId: UUID
    ) -> CompressionCompletedSummary {
        let outcome = payload.result.outcome
        let cleanupWarning = CompressionCompletedSummary.makeCleanupWarningMessage(outcome: outcome)
        let preservationNotice = CompressionCompletedSummary.makeSourcePreservationNotice(
            shouldDeleteSource: payload.shouldDeleteSource && !payload.inputPaths.isEmpty
        )
        let summary = CompressionCompletedSummary(
            taskId: taskId,
            archivePath: payload.result.outputPath,
            originalBytes: payload.result.originalBytes,
            compressedBytes: payload.result.compressedBytes,
            elapsedSeconds: payload.result.durationSeconds,
            throughputMBs: payload.result.throughputMBs,
            format: payload.format,
            isEncrypted: payload.isEncrypted,
            outcome: outcome,
            cleanupWarningMessage: cleanupWarning,
            sourcePreservationNotice: preservationNotice
        )
        ArchiveOperationsQueueCenter.shared.markCompleted(
            id: taskId,
            summary: summary,
            warningMessage: cleanupWarning,
            sourcePreservationNotice: preservationNotice
        )
        return summary
    }

    /// Settles a failed or cancelled compression operation in `ArchiveOperationsQueueCenter.shared`.
    private static func settleFailedOperationInQueue(
        error: Error,
        isCancelled: Bool,
        taskId: UUID
    ) {
        if case let .createTransactionIncomplete(report) = error as? ArchiveError {
            ArchiveOperationsQueueCenter.shared.markFailed(
                id: taskId,
                message: report.summaryMessage,
                warningMessage: report.hasCleanupOrRecoveryIssues ? report.summaryMessage : nil,
                createFailureReport: report
            )
        } else if isCancelled {
            ArchiveOperationsQueueCenter.shared.markCancelled(id: taskId)
        } else {
            ArchiveOperationsQueueCenter.shared.markFailed(id: taskId, message: error.localizedDescription)
        }
    }

    /// Single task-identity arbitration boundary for all asynchronous compression form UI mutations.
    private func acceptCompressionTaskEvent(_ event: CompressionTaskEvent, for taskId: UUID) {
        let kind: CompressionTaskBoundaryEventKind
        let currentFileName: String?
        switch event {
        case .progress(let prog, _):
            kind = .progress
            currentFileName = prog.currentFileName
        case .completed:
            kind = .completed
            currentFileName = nil
        case .failed:
            kind = .failed
            currentFileName = nil
        }
        guard self.activeSessionTaskId == taskId else {
            onBoundaryEventEvaluated?(
                CompressionTaskBoundaryReceipt(
                    taskId: taskId,
                    kind: kind,
                    accepted: false,
                    currentFileName: currentFileName
                )
            )
            return
        }
        switch event {
        case .progress(let prog, let totalInputBytes):
            applyProgressUpdate(prog, taskId: taskId, totalInputBytes: totalInputBytes)
        case .completed(let payload, let summary):
            finishCompletedSessionTask(payload, summary: summary, taskId: taskId)
        case .failed(let error, let isCancelled):
            finishFailedSessionTask(error, isCancelled: isCancelled, taskId: taskId)
        }
        onBoundaryEventEvaluated?(
            CompressionTaskBoundaryReceipt(
                taskId: taskId,
                kind: kind,
                accepted: true,
                currentFileName: currentFileName
            )
        )
    }

    private func finishCompletedSessionTask(
        _ payload: CompletedTaskPayload,
        summary: CompressionCompletedSummary,
        taskId: UUID
    ) {
        // D-03a: Source files are preserved because per-object safety conditions are not proven.
        if payload.openFinderAfterCompress && !payload.isCancelled && !RootFolderAccessManager.isIsolatedVerificationProcess {
            revealCompletedArchive(payload.result.outputPath, payload.targetDirectory)
        }
        let statusNote = ArchiveOperationsQueueCenter.composeWarningMessage(
            cleanupWarning: summary.cleanupWarningMessage,
            sourcePreservationNotice: summary.sourcePreservationNotice
        ) ?? "Archive created"
        self.currentProgress = ArchiveProgress(
            state: .completed,
            bytesProcessed: payload.result.originalBytes,
            totalBytes: payload.result.originalBytes,
            currentFileName: statusNote,
            throughputMBs: payload.result.throughputMBs
        )
        self.completedSummary = summary
        self.isProgressModalPresented = false
        self.isSummarySheetPresented = true
        self.isProcessing = false
        self.isCancellationRequested = false
        self.activeSessionTaskId = nil
        self.activeCompressionTask = nil
    }

    private func finishFailedSessionTask(_ error: Error, isCancelled: Bool, taskId: UUID) {
        self.isProgressModalPresented = false
        self.isProcessing = false
        self.isCancellationRequested = false
        self.activeSessionTaskId = nil
        self.activeCompressionTask = nil
        if case let .createTransactionIncomplete(report) = error as? ArchiveError {
            presentCreateTransactionFailureInspection(report: report, taskId: taskId)
        } else if isCancelled {
            self.currentProgress = ArchiveProgress(state: .cancelled, currentFileName: "Compression cancelled")
        } else {
            self.currentProgress = ArchiveProgress(
                state: .failed(error: error.localizedDescription),
                currentFileName: error.localizedDescription
            )
            AppErrorReporter.shared.reportError(error, contextTitle: "Compression Error")
        }
    }

    private func applyProgressUpdate(
        _ prog: ArchiveProgress,
        taskId: UUID,
        totalInputBytes: Int64
    ) {
        let effectiveTotal = (prog.totalBytes <= 0 && totalInputBytes > 0)
            ? totalInputBytes
            : prog.totalBytes
        let resolvedProg = ArchiveProgress(
            state: prog.state,
            bytesProcessed: prog.bytesProcessed,
            totalBytes: effectiveTotal,
            currentFileName: prog.currentFileName,
            throughputMBs: prog.throughputMBs
        )
        self.currentProgress = resolvedProg
        ArchiveOperationsQueueCenter.shared.updateProgress(
            id: taskId,
            bytesProcessed: resolvedProg.bytesProcessed,
            totalBytes: resolvedProg.totalBytes,
            throughputMBs: resolvedProg.throughputMBs
        )
    }

    public func startCompression() {
        guard !isProcessing && !itemsList.isEmpty && !outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !hasValidEncryptionPassword {
            AppErrorReporter.shared.reportError(ArchiveError.passwordRequired, contextTitle: "Compression Error")
            return
        }
        if isCustomVolumeSelected && selectedFormat.supportsSplitVolume && !isCustomVolumeValid {
            return
        }
        if isCustomVolumeSelected && selectedFormat.supportsSplitVolume {
            updateCustomVolume()
        }
        let jobs = resolvedExecutionJobs()
        guard let firstJob = jobs.first else { return }
        let inputPaths = itemsList.map(\.path)
        let outputFileName = resolvedOutputFileName

        let taskId = UUID()
        self.activeSessionTaskId = taskId
        self.isCancellationRequested = false
        self.isSummarySheetPresented = false
        self.completedSummary = nil
        let handle = ArchiveTaskCoordinator.shared.registerTask(id: taskId)

        let totalInputBytes = itemsList.reduce(Int64(0)) { $0 + max(0, $1.size) }
        self.currentProgress = ArchiveProgress(
            state: .processing,
            bytesProcessed: 0,
            totalBytes: totalInputBytes,
            currentFileName: itemsList.first?.name ?? firstJob.outputFileName,
            throughputMBs: 0.0
        )
        ArchiveOperationsQueueCenter.shared.enqueue(operation: QueuedArchiveOperation(
            id: taskId,
            name: outputFileName,
            operationType: .compress,
            state: .running,
            totalBytes: totalInputBytes
        ))

        isProcessing = true
        isProgressModalPresented = true
        let compressionTask = spawnCompressionTask(
            taskId: taskId,
            handle: handle,
            jobs: jobs,
            inputPaths: inputPaths,
            totalInputBytes: totalInputBytes
        )
        self.activeCompressionTask = compressionTask
        ArchiveOperationsQueueCenter.shared.bind(id: taskId, handle: handle, task: compressionTask)
    }

    private func spawnCompressionTask(
        taskId: UUID,
        handle: TaskExecutionHandle,
        jobs: [CompressionExecutionJob],
        inputPaths: [String],
        totalInputBytes: Int64
    ) -> Task<Void, Never> {
        let advOpts = makeAdvancedOptions()
        let capturedFormat = selectedFormat
        let capturedLevel = compressionLevel
        let capturedPassword = enableEncryption ? trimmedPassword : nil
        let capturedEncrypted = enableEncryption
        let capturedSplit = splitVolumeOption
        let capturedFilter = ArchiveFilterOptions(skipMacJunk: skipMacJunk)
        let capturedTargetDir = targetDirectory
        let shouldDeleteSource = deleteSourceAfterCompress
        let shouldOpenFinder = openFinderAfterCompress
        let throttler = ThrottledProgressPublisher(maxFrequencyHz: 60.0)
        let executor = quickCompressExecutor

        return Task { [weak self] in
            do {
                let result = try await Self.executeCompressionJobs(
                    jobs: jobs,
                    format: capturedFormat,
                    level: capturedLevel,
                    password: capturedPassword,
                    splitSize: capturedSplit,
                    filterOptions: capturedFilter,
                    advancedOptions: advOpts,
                    token: handle.uniffiToken,
                    executor: executor,
                    onProgress: { [weak self] prog in
                        if Self.shouldPublishProgress(prog, throttler: throttler) {
                            Task { @MainActor [weak self] in
                                self?.acceptCompressionTaskEvent(
                                    .progress(prog, totalInputBytes: totalInputBytes),
                                    for: taskId
                                )
                            }
                        }
                    }
                )
                let payload = CompletedTaskPayload(
                    result: result,
                    format: capturedFormat,
                    isEncrypted: capturedEncrypted,
                    inputPaths: inputPaths,
                    targetDirectory: capturedTargetDir,
                    shouldDeleteSource: shouldDeleteSource,
                    openFinderAfterCompress: shouldOpenFinder,
                    isCancelled: handle.isCancelled || Task.isCancelled
                )
                let summary = Self.settleCompletedOperationInQueue(payload, taskId: taskId)
                self?.acceptCompressionTaskEvent(.completed(payload, summary: summary), for: taskId)
            } catch {
                let isCleanCancel = Self.isCleanCancellationError(error)
                Self.settleFailedOperationInQueue(error: error, isCancelled: isCleanCancel, taskId: taskId)
                self?.acceptCompressionTaskEvent(.failed(error, isCancelled: isCleanCancel), for: taskId)
            }
        }
    }

    nonisolated private static func shouldPublishProgress(
        _ prog: ArchiveProgress,
        throttler: ThrottledProgressPublisher
    ) -> Bool {
        if prog.state == .completed || prog.state == .cancelled {
            return true
        }
        if case .failed = prog.state {
            return true
        }
        return throttler.shouldEmit()
    }

    nonisolated private static func isCleanCancellationError(_ error: Error) -> Bool {
        let archiveError = error as? ArchiveError
        if case .createTransactionIncomplete = archiveError {
            return false
        }
        return error is CancellationError || archiveError == .cancelled
    }
}
