// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import Observation
import AppKit
import TTZipCore

public struct CompressionCompletedSummary: Sendable {
    public let archivePath: String
    public let originalBytes: Int64
    public let compressedBytes: Int64
    public let elapsedSeconds: Double
    public let throughputMBs: Double
    public let format: ArchiveCompressionFormat
    public let isEncrypted: Bool
    
    public init(
        archivePath: String,
        originalBytes: Int64,
        compressedBytes: Int64,
        elapsedSeconds: Double,
        throughputMBs: Double,
        format: ArchiveCompressionFormat,
        isEncrypted: Bool
    ) {
        self.archivePath = archivePath
        self.originalBytes = originalBytes
        self.compressedBytes = compressedBytes
        self.elapsedSeconds = elapsedSeconds
        self.throughputMBs = throughputMBs
        self.format = format
        self.isEncrypted = isEncrypted
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
    public var cpuThreadsOption: String = "All Cores"
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
    public var isProgressModalPresented: Bool = false
    public var currentProgress: ArchiveProgress = .zero
    public var activeCompressionTask: Task<Void, Never>? = nil
    
    public var isSummarySheetPresented: Bool = false
    public var completedSummary: CompressionCompletedSummary? = nil
    
    public let cachedTotalCores = AppleSiliconTuner.shared.topology.totalCores
    
    public init(initialInputPaths: [String] = []) {
        if !initialInputPaths.isEmpty {
            self.itemsList = initialInputPaths.map { CompressFileItem(path: $0) }
            if let first = initialInputPaths.first {
                let parent = (first as NSString).deletingLastPathComponent
                if !parent.isEmpty { self.targetDirectory = parent }
                let name = (first as NSString).lastPathComponent
                self.outputName = (name as NSString).deletingPathExtension
            }
        }
    }
    
    // MARK: - Actions
    
    public func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !itemsList.contains(where: { $0.path == url.path }) {
                itemsList.append(CompressFileItem(path: url.path))
            }
        }
    }
    
    public func pickFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !itemsList.contains(where: { $0.path == url.path }) {
                itemsList.append(CompressFileItem(path: url.path))
            }
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
    }
    
    public func calculateCustomVolume() {
        guard let val = Int64(customVolumeValueString) else {
            splitVolumeOption = nil
            return
        }
        let multiplier: Int64 = (customVolumeUnit == "GB") ? 1024 * 1024 * 1024 : 1024 * 1024
        splitVolumeOption = val * multiplier
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
    }
    
    public func startCompression() {
        guard !isProcessing && !itemsList.isEmpty && !outputName.isEmpty else { return }
        let ext = selectedFormat.fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let inputPaths = itemsList.map { $0.path }
        guard !inputPaths.isEmpty else { return }
        let fullOutputPath = (targetDirectory as NSString).appendingPathComponent("\(outputName).\(ext)")
        
        isProcessing = true
        isProgressModalPresented = true
        
        let throttler = ThrottledProgressPublisher(maxFrequencyHz: 60.0)
        activeCompressionTask = Task {
            defer { Task { @MainActor in self.isProcessing = false } }
            do {
                let algo = (compressionLevel == .store) ? "Copy" : ((compressionAlgorithm == "Copy") ? "LZMA2" : compressionAlgorithm)
                let dictMB = (compressionLevel == .store) ? 0 : effectiveDictionarySizeMB
                let advOpts = ArchiveAdvancedOptions.builder()
                    .withAlgorithm(algo)
                    .withDictionarySizeMB(dictMB)
                    .withCpuThreads(cachedTotalCores)
                    .withSolidArchive(compressionLevel == .store ? false : enableSolidArchive)
                    .withEncryptFileNames(encryptFileNames)
                    .withZipEncryption(zipEncryptionMethod)
                    .withZipEncodingUTF8(zipEncodingUTF8)
                    .withZstdLevel(zstdLevel)
                    .withZstdEnableLDM(zstdEnableLDM)
                    .withPreservePosixAttributes(preservePosixAttributes)
                    .build()
                
                let cmdResult = try await TTZipEngineFacade.shared.compressWithCommand(
                    inputs: inputPaths,
                    outputPath: fullOutputPath,
                    format: selectedFormat,
                    level: compressionLevel,
                    password: enableEncryption ? password : nil,
                    splitSize: splitVolumeOption,
                    filterOptions: ArchiveFilterOptions(skipMacJunk: skipMacJunk),
                    advancedOptions: advOpts,
                    progress: { prog in
                        let isTerminal: Bool
                        switch prog.state {
                        case .completed, .failed, .cancelled:
                            isTerminal = true
                        default:
                            isTerminal = false
                        }
                        if isTerminal || throttler.shouldEmit() {
                            Task { @MainActor in self.currentProgress = prog }
                        }
                    },
                    engineFacade: TTZipEngineFacade.shared
                )
                
                if openFinderAfterCompress {
                    NSWorkspace.shared.selectFile(fullOutputPath, inFileViewerRootedAtPath: targetDirectory)
                }
                
                let compressedSize = (cmdResult.metadata["compressedSize"] as NSString?)?.longLongValue ?? 0
                let originalSize = (cmdResult.metadata["originalSize"] as NSString?)?.longLongValue ?? 0
                let elapsed = cmdResult.executionDuration
                let throughput = elapsed > 0 ? (Double(originalSize) / 1024.0 / 1024.0) / elapsed : 0.0
                
                Task { @MainActor in
                    self.completedSummary = CompressionCompletedSummary(
                        archivePath: fullOutputPath,
                        originalBytes: originalSize,
                        compressedBytes: compressedSize,
                        elapsedSeconds: elapsed,
                        throughputMBs: throughput,
                        format: self.selectedFormat,
                        isEncrypted: self.enableEncryption
                    )
                    self.isProgressModalPresented = false
                    self.isSummarySheetPresented = true
                }
            } catch {
                Task { @MainActor in self.isProgressModalPresented = false }
            }
        }
    }
}
