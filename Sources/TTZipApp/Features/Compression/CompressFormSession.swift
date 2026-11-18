// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import Observation
import AppKit
import TTZipCore
import TTZipTaskKit
import TTZipUI
import TTZipPreviewKit

/// Comprehensive form session state and business logic container for compression workspace.
@Observable
@MainActor
public final class CompressFormSession {
    // MARK: - 1. Input Sources & Selection
    public var itemsList: [CompressFileItem] = [] {
        didSet {
            if oldValue.map(\.path) != itemsList.map(\.path) {
                handleInputsChangedForSmartRecommendation()
            }
            handleItemsListChangedForOperationDefaults(wasEmpty: oldValue.isEmpty)
        }
    }
    public var selectedItemIDs: Set<CompressFileItem.ID> = []
    
    public var totalSizeBytes: Int64 {
        itemsList.reduce(0) { $0 + $1.size }
    }
    
    // MARK: - 2. Output & Format Configuration
    public var outputName: String = "Archive"
    public var targetDirectory: String = RootFolderAccessManager.defaultInitialDirectoryURL().path
    public var selectedFormat: ArchiveCompressionFormat = .sevenZip {
        didSet {
            if oldValue != selectedFormat {
                recordIdleDefaultOverrideIfNeeded()
                handleSelectedFormatChangedForSmartRecommendation()
            }
        }
    }
    public var compressionLevel: ArchiveCompressionLevel = .normal {
        didSet {
            if oldValue != compressionLevel {
                recordIdleDefaultOverrideIfNeeded()
                handleManualParameterChangeForSmartRecommendation()
            }
        }
    }
    public var selectedPresetID: UUID? = nil {
        didSet {
            if oldValue != selectedPresetID {
                recordIdleDefaultOverrideIfNeeded()
            }
        }
    }
    public var smartScenario: SmartCompressionScenario = .balancedDaily
    public var smartRecommendationState: SmartRecommendationState = .idle
    public var hasUserOverriddenRecommendation: Bool = false
    package var recommendationGeneration: UInt64 = 0
    package var activeRecommendationTask: Task<Void, Never>? = nil
    package var lastAppliedRecommendation: SmartCodecRecommendation? = nil
    package var isApplyingSmartRecommendation: Bool = false
    package var sampleDataProviderOverride: (@Sendable ([String], Int) async throws -> Data)? = nil
    
    // MARK: - 3. Split Volumes
    public var splitVolumeOption: Int64? = nil {
        didSet { reconcileRecoveryRecordEligibility() }
    }
    public var isCustomVolumeSelected: Bool = false {
        didSet { reconcileRecoveryRecordEligibility() }
    }
    public var customVolumeValueString: String = "100" {
        didSet { if isCustomVolumeSelected { updateCustomVolume() } }
    }
    public var customVolumeUnit: String = "MB" {
        didSet { if isCustomVolumeSelected { updateCustomVolume() } }
    }
    public var recoveryRecordRedundancyPercent: Int = 0
    
    // MARK: - 4. Encryption & Password
    public var enableEncryption: Bool = false
    public var password: String = ""
    public var isPasswordRevealed: Bool = false
    public var encryptFileNames: Bool = true
    public var zipEncryptionMethod: String = "AES-256"
    
    // MARK: - 5. Format-Specific & Engine Parameters
    public static let supportedDictionarySizesMB: [Int] = [16, 32, 64, 128, 256, 512, 1024, 1536]
    public var cpuThreadsOption: String = "all"
    public var customDictionarySizeMB: Int? = nil // nil means "Auto (Follows Level & RAM)"
    public var compressionAlgorithm: String = "LZMA2" {
        didSet { if oldValue != compressionAlgorithm { handleManualParameterChangeForSmartRecommendation() } }
    }
    public var zipEncodingUTF8: Bool = true
    public var zstdLevel: Int = 3 {
        didSet {
            if oldValue != zstdLevel {
                recordIdleDefaultOverrideIfNeeded()
                handleManualParameterChangeForSmartRecommendation()
            }
        }
    }
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
    public var openFinderAfterCompress: Bool = !RootFolderAccessManager.isIsolatedVerificationProcess {
        didSet {
            if oldValue != openFinderAfterCompress {
                recordIdleDefaultOverrideIfNeeded()
            }
        }
    }
    public var skipMacJunk: Bool = true {
        didSet {
            if oldValue != skipMacJunk {
                recordIdleDefaultOverrideIfNeeded()
            }
        }
    }
    
    // MARK: - 7. Sheets & Popovers Presentation
    public var isAlgorithmMatrixPresented: Bool = false
    public var isCompressionGuidePresented: Bool = false
    public var isPasswordVaultPresented: Bool = false
    
    // MARK: - 8. Execution State & Metrics
    public var isProcessing: Bool = false
    public package(set) var isCancellationRequested: Bool = false
    public var isProgressModalPresented: Bool = false
    public var currentProgress: ArchiveProgress = .zero
    public var activeCompressionTask: Task<Void, Never>? = nil
    public var activeSessionTaskId: UUID? = nil {
        didSet {
            if activeSessionTaskId != nil {
                operationDefaultsPhase = .awaitingNewOperation(
                    baseline: operationDefaultsPhase.baseline,
                    hasExplicitIdleOverride: false
                )
            }
        }
    }
    
    public var isSummarySheetPresented: Bool = false
    public var completedSummary: CompressionCompletedSummary? = nil
    public var isCreateFailureSheetPresented: Bool = false
    public var failedCreateTransactionReport: ArchiveCreateTransactionFailureReport? = nil
    public var failedCreateTransactionTaskId: UUID? = nil
    
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
    
    private enum OperationDefaultsPhase {
        case awaitingNewOperation(
            baseline: CompressionDefaultsSnapshot,
            hasExplicitIdleOverride: Bool
        )
        case activeOperation(baseline: CompressionDefaultsSnapshot)

        var baseline: CompressionDefaultsSnapshot {
            switch self {
            case .awaitingNewOperation(let baseline, _), .activeOperation(let baseline):
                return baseline
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var operationDefaultsPhase: OperationDefaultsPhase
    @ObservationIgnored private var isApplyingCompressionDefaults: Bool = false
    @ObservationIgnored private var isLoadingInputPaths: Bool = false

    public init(
        initialInputPaths: [String] = [],
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        let compressionDefaults = Self.loadCompressionDefaults(from: defaults)
        self.operationDefaultsPhase = .awaitingNewOperation(
            baseline: compressionDefaults,
            hasExplicitIdleOverride: false
        )
        applyCompressionDefaults(compressionDefaults)
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
        clearCreateFailureInspectionState()
        isLoadingInputPaths = true
        self.itemsList = validPaths.map { CompressFileItem(path: $0) }
        isLoadingInputPaths = false
        reloadCompressionDefaultsForNewOperationIfNeeded()
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
        reconcileRecoveryRecordEligibility()
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
        guard isCustomVolumeSelected,
              let bytes = Self.parseCustomVolumeBytes(
                  valueString: customVolumeValueString,
                  unit: customVolumeUnit
              ) else {
            splitVolumeOption = nil
            return
        }
        splitVolumeOption = bytes
    }

    public func calculateCustomVolume() {
        self.isCustomVolumeSelected = true
        updateCustomVolume()
    }
    
    public func applyPreset(id: UUID) {
        guard let preset = PresetManager.shared.presets.first(where: { $0.id == id }) else { return }
        recordIdleDefaultOverrideIfNeeded()
        let snapshot = preset.clone()
        self.selectedFormat = snapshot.format
        self.compressionLevel = snapshot.level
        syncSplitVolumeFromPreset(snapshot.splitVolumeSizeBytes)
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
        if let destinationDirectoryPath = options.destinationDirectoryPath {
            let trimmedDest = destinationDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDest.isEmpty {
                self.targetDirectory = URL(fileURLWithPath: trimmedDest).path
            }
        }
        if let customOutputPath = options.customOutputPath, !customOutputPath.isEmpty {
            applyCustomOutputPath(customOutputPath)
        }
        if let password = options.password {
            self.enableEncryption = !password.isEmpty
            self.password = password
        }
        reconcileSelectedFormatWithInputs()
        if let requestedLevel = options.compressionLevel {
            applyClampedCompressionLevel(requestedLevel)
        }
    }

    private func applyCustomOutputPath(_ customOutputPath: String) {
        let nsPath = customOutputPath as NSString
        let parent = nsPath.deletingLastPathComponent
        if !parent.isEmpty {
            self.targetDirectory = parent
        }
        let fileName = nsPath.lastPathComponent
        guard !fileName.isEmpty else { return }
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

    private func applyClampedCompressionLevel(_ requestedLevel: Int) {
        let clamped = max(
            selectedFormat.minCompressionLevel,
            min(selectedFormat.maxCompressionLevel, requestedLevel)
        )
        self.compressionLevel = ArchiveCompressionLevel(levelInt: clamped)
        if (selectedFormat == .zst || selectedFormat == .tarZst) && clamped >= 1 {
            self.zstdLevel = min(22, max(1, clamped))
        }
        reconcileRecoveryRecordEligibility()
    }

    private static func loadCompressionDefaults(
        from defaults: UserDefaults
    ) -> CompressionDefaultsSnapshot {
        CompressionDefaultsSnapshot.load(
            from: defaults,
            defaultOpenFinder: !RootFolderAccessManager.isIsolatedVerificationProcess
        )
    }

    private func applyCompressionDefaults(_ snapshot: CompressionDefaultsSnapshot) {
        isApplyingCompressionDefaults = true
        defer { isApplyingCompressionDefaults = false }
        selectedPresetID = nil
        lastAppliedRecommendation = nil
        hasUserOverriddenRecommendation = false
        selectedFormat = snapshot.defaultFormat
        compressionLevel = CompressionDefaultsSnapshot.clampedLevel(
            snapshot.defaultTier.archiveCompressionLevel,
            for: snapshot.defaultFormat
        )
        zstdLevel = ZstdFormatOptions().zstdLevel
        skipMacJunk = snapshot.skipMacJunk
        openFinderAfterCompress = snapshot.openFinderAfterCompress
    }

    private func reloadCompressionDefaultsForNewOperationIfNeeded() {
        let latestSnapshot = Self.loadCompressionDefaults(from: defaults)
        let shouldApply: Bool
        switch operationDefaultsPhase {
        case .awaitingNewOperation(let baseline, let hasExplicitIdleOverride):
            shouldApply = !hasExplicitIdleOverride || latestSnapshot != baseline
        case .activeOperation(let baseline):
            shouldApply = latestSnapshot != baseline
        }
        operationDefaultsPhase = .activeOperation(baseline: latestSnapshot)
        if shouldApply {
            applyCompressionDefaults(latestSnapshot)
        }
    }

    private func handleItemsListChangedForOperationDefaults(wasEmpty: Bool) {
        guard !isLoadingInputPaths else { return }
        if itemsList.isEmpty {
            if !wasEmpty {
                operationDefaultsPhase = .awaitingNewOperation(
                    baseline: operationDefaultsPhase.baseline,
                    hasExplicitIdleOverride: false
                )
            }
            return
        }
        if wasEmpty && !isProcessing {
            reloadCompressionDefaultsForNewOperationIfNeeded()
            reconcileSelectedFormatWithInputs()
        }
    }

    private func recordIdleDefaultOverrideIfNeeded() {
        guard !isApplyingCompressionDefaults && !isApplyingSmartRecommendation else { return }
        if case .awaitingNewOperation(let baseline, false) = operationDefaultsPhase {
            operationDefaultsPhase = .awaitingNewOperation(
                baseline: baseline,
                hasExplicitIdleOverride: true
            )
        }
    }
}
