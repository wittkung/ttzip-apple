// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import Observation
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit

extension CompressionCompletedSummary {
    @MainActor
    public static func makeCleanupWarningMessage(outcome: ExtractionOutcome?) -> String? {
        guard let outcome, outcome.status == .completedWithFailures else { return nil }
        let count = outcome.failed.count
        return AppLocalizationState.shared.uiString(
            zh: "归档已创建，但有 \(count) 项提交后清理警告",
            en: "Archive created with \(count) post-commit cleanup warning(s)",
            zhHant: "歸檔已建立，但有 \(count) 項提交後清理警告",
            ja: "アーカイブを作成しましたが、コミット後のクリーンアップ警告が \(count) 件あります",
            ko: "아카이브가 생성되었으나 커밋 후 정리 경고 \(count)건이 발생했습니다",
            de: "Archiv erstellt mit \(count) Bereinigungswarnung(en) nach dem Commit",
            fr: "Archive créée avec \(count) avertissement(s) de nettoyage après validation",
            es: "Archivo creado con \(count) advertencia(s) de limpieza tras la confirmación"
        )
    }

    @MainActor
    public static func makeSourcePreservationNotice(shouldDeleteSource: Bool) -> String? {
        guard shouldDeleteSource else { return nil }
        return AppLocalizationState.shared.uiString(
            zh: "归档已创建；本次未自动删除源文件",
            en: "Archive created; source files were not automatically deleted",
            zhHant: "歸檔已建立；本次未自動刪除來源檔案",
            ja: "アーカイブを作成しました。元のファイルは自動削除されませんでした",
            ko: "아카이브가 생성되었으며 원본 파일은 자동으로 삭제되지 않았습니다",
            de: "Archiv erstellt; Quelldateien wurden nicht automatisch gelöscht",
            fr: "Archive créée ; les fichiers sources n'ont pas été supprimés automatiquement",
            es: "Archivo creado; los archivos de origen no se eliminaron automáticamente"
        )
    }
}

/// Comprehensive form session state and business logic container for compression workspace.
@Observable
@MainActor
public final class CompressFormSession {
    // MARK: - 1. Input Sources & Selection
    public var itemsList: [CompressFileItem] = []
    public var selectedItemIDs: Set<CompressFileItem.ID> = []
    
    public var totalSizeBytes: Int64 {
        itemsList.reduce(0) { $0 + $1.size }
    }
    
    // MARK: - 2. Output & Format Configuration
    public var outputName: String = "Archive"
    public var targetDirectory: String = NSHomeDirectory()
    public var selectedFormat: ArchiveCompressionFormat = .sevenZip
    public var compressionLevel: ArchiveCompressionLevel = .normal
    public var selectedPresetID: UUID? = nil
    
    // MARK: - 3. Split Volumes
    public var splitVolumeOption: Int64? = nil
    public var isCustomVolumeSelected: Bool = false
    public var customVolumeValueString: String = "100"
    public var customVolumeUnit: String = "MB"
    
    // MARK: - 4. Encryption & Password
    public var enableEncryption: Bool = false
    public var password: String = ""
    public var encryptFileNames: Bool = true
    public var zipEncryptionMethod: String = "AES-256"
    
    // MARK: - 5. Format-Specific & Engine Parameters
    public static let supportedDictionarySizesMB: [Int] = [16, 32, 64, 128, 256, 512, 1024, 1536]
    public var cpuThreadsOption: String = "all"
    public var customDictionarySizeMB: Int? = nil // nil means "Auto (Follows Level & RAM)"
    public var compressionAlgorithm: String = "LZMA2"
    public var zipEncodingUTF8: Bool = true
    public var zstdLevel: Int = 3
    public var zstdEnableLDM: Bool = false
    public var preservePosixAttributes: Bool = true
    public var enableSolidArchive: Bool = true
    
    /// Automatic optimal dictionary size calculation based on compression level and Apple Silicon unified memory.
    public var effectiveDictionarySizeMB: Int {
        if let custom = customDictionarySizeMB {
            return custom
        }
        switch compressionLevel {
        case .store:
            return 0
        case .fast5, .fast4, .fast3, .fast2, .fast1, .level1:
            return 16
        case .level2, .level3, .level4:
            return 32
        case .level5, .level6, .level7:
            return 64
        case .level8, .level9, .level10, .level11, .level12, .level13, .level14, .level15, .level16, .level17, .level18, .level19, .level20, .level21, .level22:
            let ramBytes = ProcessInfo.processInfo.physicalMemory
            let ramGB = Double(ramBytes) / 1024.0 / 1024.0 / 1024.0
            if ramGB >= 64.0 {
                return 1024 // 1 GB on 64GB+ Apple Silicon
            } else if ramGB >= 32.0 {
                return 512  // 512 MB on 32GB/36GB/48GB
            } else if ramGB >= 16.0 {
                return 256  // 256 MB on 16GB/18GB/24GB
            } else {
                return 128  // 128 MB on 8GB
            }
        }
    }
    
    // MARK: - 6. Automation & Cleanup Policies
    public var createSeparateArchives: Bool = false
    public var deleteSourceAfterCompress: Bool = false
    public var openFinderAfterCompress: Bool = true
    public var skipMacJunk: Bool = true
    
    // MARK: - 7. Sheets & Popovers Presentation
    public var isAlgorithmMatrixPresented: Bool = false
    public var isCompressionGuidePresented: Bool = false
    public var isPasswordVaultPresented: Bool = false
    
    // MARK: - 8. Execution State & Metrics
    public var isProcessing: Bool = false
    public private(set) var isCancellationRequested: Bool = false
    public var isProgressModalPresented: Bool = false
    public var currentProgress: ArchiveProgress = .zero
    public var activeCompressionTask: Task<Void, Never>? = nil
    public var activeSessionTaskId: UUID? = nil
    
    public var isSummarySheetPresented: Bool = false
    public var completedSummary: CompressionCompletedSummary? = nil
    
    public let cachedTotalCores = AppleSiliconTuner.shared.topology.totalCores

    package enum CompressionTaskBoundaryEventKind: String, Sendable, Equatable {
        case progress
        case completed
        case failed
    }

    package struct CompressionTaskBoundaryReceipt: Sendable, Equatable {
        package let taskId: UUID
        package let kind: CompressionTaskBoundaryEventKind
        package let accepted: Bool
        package let currentFileName: String?
    }

    package var onBoundaryEventEvaluated: ((CompressionTaskBoundaryReceipt) -> Void)? = nil

    package var revealCompletedArchive: (String, String) -> Void = { outputPath, targetDirectory in
        NSWorkspace.shared.selectFile(outputPath, inFileViewerRootedAtPath: targetDirectory)
    }

    package typealias QuickCompressExecutor = @Sendable (
        _ inputs: [String],
        _ outputPath: String,
        _ format: ArchiveCompressionFormat,
        _ level: ArchiveCompressionLevel,
        _ password: String?,
        _ splitSize: Int64?,
        _ filterOptions: ArchiveFilterOptions,
        _ advancedOptions: ArchiveAdvancedOptions?,
        _ progress: (@Sendable (ArchiveProgress) -> Void)?,
        _ token: CancellationToken?
    ) async throws -> ArchiveOperationResult

    package var quickCompressExecutor: QuickCompressExecutor = { inputs, outputPath, format, level, password, splitSize, filterOptions, advancedOptions, progress, token in
        try await TTZipEngineFacade.shared.quickCompress(
            inputs: inputs,
            outputPath: outputPath,
            format: format,
            level: level,
            password: password,
            splitSize: splitSize,
            filterOptions: filterOptions,
            advancedOptions: advancedOptions,
            progress: progress,
            token: token
        )
    }
    
    public init(initialInputPaths: [String] = []) {
        if !initialInputPaths.isEmpty {
            loadInputPaths(initialInputPaths)
        }
    }

    /// Detaches the form UI observer from any currently active background task without cancelling or unbinding
    /// the operation in `ArchiveOperationsQueueCenter.shared`.
    public func detachActiveTaskToBackground() {
        self.activeSessionTaskId = nil
        self.activeCompressionTask = nil
        self.isProcessing = false
        self.isCancellationRequested = false
        self.isProgressModalPresented = false
        self.currentProgress = .zero
    }
    
    public func loadInputPaths(_ paths: [String]) {
        let validPaths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !validPaths.isEmpty else { return }
        detachActiveTaskToBackground()
        self.isSummarySheetPresented = false
        self.completedSummary = nil
        self.itemsList = validPaths.map { CompressFileItem(path: $0) }
        for item in self.itemsList where item.isDirectory && item.isCalculating {
            calculateDirectorySizeAsync(for: item.id, path: item.path)
        }
        if let first = validPaths.first {
            let parent = (first as NSString).deletingLastPathComponent
            if !parent.isEmpty { self.targetDirectory = parent }
            let name = (first as NSString).lastPathComponent
            let baseName = (name as NSString).deletingPathExtension
            self.outputName = baseName.isEmpty ? name : baseName
        }
        reconcileSelectedFormatWithInputs()
    }

    /// Returns `true` when the compression session contains a single regular file (or when no items are loaded yet).
    public var isSingleRegularFileInput: Bool {
        if itemsList.isEmpty {
            return true
        }
        return itemsList.count == 1 && !itemsList[0].isDirectory
    }

    /// Reconciles `selectedFormat`, output filename stem, encryption, and split-volume state with the current input items and format capabilities.
    public func reconcileSelectedFormatWithInputs() {
        if selectedFormat.isReadOnly {
            selectedFormat = .sevenZip
        } else if selectedFormat.isSingleStreamFormat && !isSingleRegularFileInput {
            selectedFormat = selectedFormat.correspondingTarCompositeFormat ?? .tarZst
        }
        if itemsList.count == 1 && !itemsList[0].isDirectory {
            let fullName = itemsList[0].name
            let baseName = (fullName as NSString).deletingPathExtension
            if !baseName.isEmpty && baseName != fullName {
                if selectedFormat.isSingleStreamFormat && outputName == baseName {
                    outputName = fullName
                } else if !selectedFormat.isSingleStreamFormat && outputName == fullName {
                    outputName = baseName
                }
            }
        }
        if !selectedFormat.supportsPasswordEncryption {
            enableEncryption = false
        }
        if !selectedFormat.supportsSplitVolume {
            splitVolumeOption = nil
            isCustomVolumeSelected = false
        }
    }
    
    // MARK: - Actions
    
    public func addPaths(_ paths: [String]) {
        for path in paths where !itemsList.contains(where: { $0.path == path }) {
            let item = CompressFileItem(path: path)
            itemsList.append(item)
            if item.isDirectory && item.isCalculating {
                calculateDirectorySizeAsync(for: item.id, path: item.path)
            }
        }
        reconcileSelectedFormatWithInputs()
    }
    
    private func calculateDirectorySizeAsync(for id: UUID, path: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let comp = ArchiveComponentTreeBuilder.buildTree(fromDiskPath: path)
            let computedSize = comp.sizeBytes
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let idx = self.itemsList.firstIndex(where: { $0.id == id }) {
                    self.itemsList[idx].size = computedSize
                    self.itemsList[idx].component = comp
                    self.itemsList[idx].isCalculating = false
                }
            }
        }
    }
    
    public func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            addPaths(panel.urls.map(\.path))
        }
    }
    
    public func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            addPaths(panel.urls.map(\.path))
        }
    }

    public func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            targetDirectory = url.path
        }
    }
    
    public func removeSelectedItems() {
        itemsList.removeAll { selectedItemIDs.contains($0.id) }
        selectedItemIDs.removeAll()
        reconcileSelectedFormatWithInputs()
    }
    
    public func removeItem(id: UUID) {
        itemsList.removeAll { $0.id == id }
        reconcileSelectedFormatWithInputs()
    }
    
    public func removeItems(at offsets: IndexSet) {
        itemsList.remove(atOffsets: offsets)
        reconcileSelectedFormatWithInputs()
    }
    
    public func clearAllItems() {
        itemsList.removeAll()
        reconcileSelectedFormatWithInputs()
    }
    
    public func updateCustomVolume() {
        guard isCustomVolumeSelected, let val = Int64(customVolumeValueString), val > 0 else {
            splitVolumeOption = nil
            return
        }
        let multiplier: Int64 = (customVolumeUnit == "GB") ? 1024 * 1024 * 1024 : 1024 * 1024
        splitVolumeOption = val * multiplier
    }

    public func calculateCustomVolume() {
        self.isCustomVolumeSelected = true
        updateCustomVolume()
    }
    
    public func applyPreset(id: UUID) {
        guard let preset = PresetManager.shared.presets.first(where: { $0.id == id }) else { return }
        let snapshot = preset.clone()
        self.selectedFormat = snapshot.format
        self.compressionLevel = snapshot.level
        self.splitVolumeOption = snapshot.splitVolumeSizeBytes
        if let pwd = snapshot.defaultPassword, !pwd.isEmpty {
            self.enableEncryption = true
            self.password = pwd
        }
        self.skipMacJunk = snapshot.skipMacJunk
        reconcileSelectedFormatWithInputs()
    }

    public func applyIntentOptions(_ options: CompressIntentOptions) {
        self.selectedPresetID = options.presetID
        if let presetID = options.presetID {
            applyPreset(id: presetID)
        }
        if let targetFormat = options.targetFormat {
            self.selectedFormat = targetFormat
        }
        self.createSeparateArchives = options.separateArchives
        self.deleteSourceAfterCompress = options.deleteSourceAfterCompression
        if let customOutputPath = options.customOutputPath, !customOutputPath.isEmpty {
            let nsPath = customOutputPath as NSString
            let parent = nsPath.deletingLastPathComponent
            if !parent.isEmpty {
                self.targetDirectory = parent
            }
            let fileName = nsPath.lastPathComponent
            if !fileName.isEmpty {
                let knownExtensionSuffix = "." + self.selectedFormat.fileExtension
                let stem: String
                if fileName.lowercased().hasSuffix(knownExtensionSuffix.lowercased()),
                   fileName.count > knownExtensionSuffix.count {
                    stem = String(fileName.dropLast(knownExtensionSuffix.count))
                } else {
                    let deletedExt = (fileName as NSString).deletingPathExtension
                    stem = deletedExt.isEmpty ? fileName : deletedExt
                }
                if !stem.isEmpty {
                    self.outputName = stem
                }
            }
        }
        if let password = options.password {
            self.enableEncryption = !password.isEmpty
            self.password = password
        }
        reconcileSelectedFormatWithInputs()
    }

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

    private func makeAdvancedOptions() -> ArchiveAdvancedOptions {
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
        if payload.openFinderAfterCompress && !payload.isCancelled {
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
        if isCancelled {
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
        guard !isProcessing && !itemsList.isEmpty && !outputName.isEmpty else { return }
        if enableEncryption && password.isEmpty {
            AppErrorReporter.shared.reportError(ArchiveError.passwordRequired, contextTitle: "Compression Error")
            return
        }
        let ext = selectedFormat.fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let inputPaths = itemsList.map { $0.path }
        guard !inputPaths.isEmpty else { return }
        let fullOutputPath = (targetDirectory as NSString).appendingPathComponent("\(outputName).\(ext)")
        let outURL = URL(fileURLWithPath: fullOutputPath)

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
            currentFileName: itemsList.first?.name ?? outURL.lastPathComponent,
            throughputMBs: 0.0
        )
        ArchiveOperationsQueueCenter.shared.enqueue(operation: QueuedArchiveOperation(
            id: taskId,
            name: "\(outputName).\(ext)",
            operationType: .compress,
            state: .running,
            totalBytes: totalInputBytes
        ))

        let advOpts = makeAdvancedOptions()
        let capturedFormat = selectedFormat
        let capturedLevel = compressionLevel
        let capturedPassword = enableEncryption ? password : nil
        let capturedEncrypted = enableEncryption
        let capturedSplit = splitVolumeOption
        let capturedFilter = ArchiveFilterOptions(skipMacJunk: skipMacJunk)
        let capturedTargetDir = targetDirectory
        let shouldDeleteSource = deleteSourceAfterCompress
        let shouldOpenFinder = openFinderAfterCompress
        isProcessing = true
        isProgressModalPresented = true

        let throttler = ThrottledProgressPublisher(maxFrequencyHz: 60.0)
        let executor = quickCompressExecutor
        let compressionTask = Task { [weak self] in
            do {
                let result = try await executor(
                    inputPaths,
                    fullOutputPath,
                    capturedFormat,
                    capturedLevel,
                    capturedPassword,
                    capturedSplit,
                    capturedFilter,
                    advOpts,
                    { [weak self] prog in
                        let isTerminal = (prog.state == .completed || prog.state == .cancelled) || {
                            if case .failed = prog.state { return true }
                            return false
                        }()
                        if isTerminal || throttler.shouldEmit() {
                            Task { @MainActor [weak self] in
                                self?.acceptCompressionTaskEvent(
                                    .progress(prog, totalInputBytes: totalInputBytes),
                                    for: taskId
                                )
                            }
                        }
                    },
                    handle.uniffiToken
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
                let archiveError = error as? ArchiveError
                let isCleanCancel: Bool
                if case .createTransactionIncomplete = archiveError {
                    isCleanCancel = false
                } else {
                    isCleanCancel = error is CancellationError || archiveError == .cancelled
                }
                Self.settleFailedOperationInQueue(error: error, isCancelled: isCleanCancel, taskId: taskId)
                self?.acceptCompressionTaskEvent(.failed(error, isCancelled: isCleanCancel), for: taskId)
            }
        }
        self.activeCompressionTask = compressionTask
        ArchiveOperationsQueueCenter.shared.bind(id: taskId, handle: handle, task: compressionTask)
    }
}
