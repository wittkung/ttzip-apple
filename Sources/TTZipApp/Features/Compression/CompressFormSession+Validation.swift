// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI

/// Strongly-typed compression options payload.
public struct CompressIntentOptions: Sendable, Codable, Equatable, Hashable {
    public let presetID: UUID?
    public let targetFormat: ArchiveCompressionFormat?
    public let separateArchives: Bool
    public let deleteSourceAfterCompression: Bool
    public let customOutputPath: String?
    public let password: String?
    public let compressionLevel: Int?
    public let destinationDirectoryPath: String?

    public init(
        presetID: UUID? = nil,
        targetFormat: ArchiveCompressionFormat? = nil,
        separateArchives: Bool = false,
        deleteSourceAfterCompression: Bool = false,
        customOutputPath: String? = nil,
        password: String? = nil,
        compressionLevel: Int? = nil,
        destinationDirectoryPath: String? = nil
    ) {
        self.presetID = presetID
        self.targetFormat = targetFormat
        self.separateArchives = separateArchives
        self.deleteSourceAfterCompression = deleteSourceAfterCompression
        self.customOutputPath = customOutputPath
        self.password = password
        self.compressionLevel = compressionLevel
        self.destinationDirectoryPath = destinationDirectoryPath
    }
}

extension CompressFormSession {
    /// Standard preset split-volume sizes rendered as primary selector pills.
    public static let standardSplitVolumeSizes: Set<Int64> = [
        700 * 1024 * 1024,
        4000 * 1024 * 1024,
        4700 * 1024 * 1024
    ]

    /// Parses a custom split-volume size string and unit (`"MB"` or `"GB"`) into bytes
    /// with positive-number validation and overflow-safe arithmetic.
    public static func parseCustomVolumeBytes(valueString: String, unit: String) -> Int64? {
        let trimmed = valueString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let multiplier: Int64 = (unit == "GB") ? (1024 * 1024 * 1024) : (1024 * 1024)
        if let intVal = Int64(trimmed) {
            guard intVal > 0 else { return nil }
            let (product, overflow) = intVal.multipliedReportingOverflow(by: multiplier)
            guard !overflow, product > 0 else { return nil }
            return product
        }
        guard let decimalVal = Double(trimmed), decimalVal.isFinite, decimalVal > 0 else {
            return nil
        }
        let kibMultiplier: Int64 = (unit == "GB") ? (1024 * 1024) : 1024
        let scaledKiB = (decimalVal * 1024.0).rounded()
        guard scaledKiB >= 1.0, scaledKiB < Double(Int64.max) else { return nil }
        let kibInt = Int64(scaledKiB)
        let (product, overflow) = kibInt.multipliedReportingOverflow(by: kibMultiplier)
        guard !overflow, product > 0 else { return nil }
        return product
    }

    /// Whether the current custom split-volume input parses to a valid positive byte count without overflow.
    public var isCustomVolumeValid: Bool {
        Self.parseCustomVolumeBytes(valueString: customVolumeValueString, unit: customVolumeUnit) != nil
    }

    /// Synchronizes `splitVolumeOption`, `isCustomVolumeSelected`, and custom input fields from a preset's split size.
    package func syncSplitVolumeFromPreset(_ sizeBytes: Int64?) {
        guard let size = sizeBytes, size > 0 else {
            isCustomVolumeSelected = false
            splitVolumeOption = nil
            return
        }
        if Self.standardSplitVolumeSizes.contains(size) {
            isCustomVolumeSelected = false
            splitVolumeOption = size
            return
        }
        let gb: Int64 = 1024 * 1024 * 1024
        let mb: Int64 = 1024 * 1024
        isCustomVolumeSelected = false
        if size % gb == 0 {
            customVolumeUnit = "GB"
            customVolumeValueString = String(size / gb)
        } else if size % mb == 0 {
            customVolumeUnit = "MB"
            customVolumeValueString = String(size / mb)
        } else {
            customVolumeUnit = "MB"
            customVolumeValueString = String(format: "%g", Double(size) / Double(mb))
        }
        isCustomVolumeSelected = true
        splitVolumeOption = size
    }

    /// Password trimmed of leading/trailing whitespace and newlines.
    public var trimmedPassword: String {
        password.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the encryption configuration has a non-whitespace password when encryption is enabled.
    public var hasValidEncryptionPassword: Bool {
        !enableEncryption || !trimmedPassword.isEmpty
    }

    /// Whether the session is ready to start compression across inputs, output name, encryption, and custom split volume.
    public var canStartCompression: Bool {
        if isProcessing || itemsList.isEmpty || outputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if !hasValidEncryptionPassword {
            return false
        }
        if isCustomVolumeSelected && selectedFormat.supportsSplitVolume && !isCustomVolumeValid {
            return false
        }
        return true
    }

    /// Resolves an archive filename for a given stem and format, avoiding duplicate format extensions.
    public static func resolveOutputFileName(
        stem: String,
        format: ArchiveCompressionFormat
    ) -> String {
        let ext = format.fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let suffix = ".\(ext)"
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? stem : trimmed
        if base.count > suffix.count && base.lowercased().hasSuffix(suffix.lowercased()) {
            let prefix = String(base.dropLast(suffix.count))
            return "\(prefix).\(ext)"
        }
        return "\(base).\(ext)"
    }

    /// Canonical output archive filename for the current `outputName` and `selectedFormat`.
    public var resolvedOutputFileName: String {
        let candidate = Self.resolveOutputFileName(stem: outputName, format: selectedFormat)
        let standardizedInputs = Self.standardizedInputPaths(for: itemsList)
        let standardizedTargetDir = URL(fileURLWithPath: targetDirectory).standardizedFileURL
        return deduplicateAgainstInputCollisions(
            candidateFileName: candidate,
            standardizedInputs: standardizedInputs,
            standardizedTargetDir: standardizedTargetDir
        )
    }

    private static func standardizedInputPaths(for items: [CompressFileItem]) -> Set<String> {
        Set(items.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
    }

    private func deduplicateAgainstInputCollisions(
        candidateFileName: String,
        standardizedInputs: Set<String>,
        standardizedTargetDir: URL
    ) -> String {
        let ext = selectedFormat.fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !ext.isEmpty, !standardizedInputs.isEmpty else { return candidateFileName }
        var resolved = candidateFileName
        while true {
            let candidatePath = standardizedTargetDir
                .appendingPathComponent(resolved)
                .standardizedFileURL
                .path
            guard standardizedInputs.contains(candidatePath) else {
                return resolved
            }
            resolved = "\(resolved).\(ext)"
        }
    }

    /// Planned archive creation unit (either a single combined archive or one archive per input item).
    public struct CompressionExecutionJob: Sendable, Equatable {
        public let inputPaths: [String]
        public let outputFileName: String
        public let outputPath: String
        public let estimatedBytes: Int64
    }

    /// Resolves the execution job list, honoring `createSeparateArchives` when multiple inputs are present.
    public func resolvedExecutionJobs() -> [CompressionExecutionJob] {
        guard !itemsList.isEmpty else { return [] }
        if createSeparateArchives && itemsList.count > 1 {
            let standardizedInputs = Self.standardizedInputPaths(for: itemsList)
            let standardizedTargetDir = URL(fileURLWithPath: targetDirectory).standardizedFileURL
            var usedNames: Set<String> = []
            return itemsList.map { item in
                let rawName = (item.path as NSString).lastPathComponent
                let stem: String
                if item.isDirectory || selectedFormat.isSingleStreamFormat {
                    stem = rawName
                } else {
                    let deletedExt = (rawName as NSString).deletingPathExtension
                    stem = deletedExt.isEmpty ? rawName : deletedExt
                }
                var candidateName = deduplicateAgainstInputCollisions(
                    candidateFileName: Self.resolveOutputFileName(stem: stem, format: selectedFormat),
                    standardizedInputs: standardizedInputs,
                    standardizedTargetDir: standardizedTargetDir
                )
                var suffixIndex = 2
                while usedNames.contains(candidateName.lowercased()) {
                    candidateName = deduplicateAgainstInputCollisions(
                        candidateFileName: Self.resolveOutputFileName(
                            stem: "\(stem) (\(suffixIndex))",
                            format: selectedFormat
                        ),
                        standardizedInputs: standardizedInputs,
                        standardizedTargetDir: standardizedTargetDir
                    )
                    suffixIndex += 1
                }
                usedNames.insert(candidateName.lowercased())
                let outPath = (targetDirectory as NSString).appendingPathComponent(candidateName)
                return CompressionExecutionJob(
                    inputPaths: [item.path],
                    outputFileName: candidateName,
                    outputPath: outPath,
                    estimatedBytes: max(0, item.size)
                )
            }
        }
        let fileName = resolvedOutputFileName
        let fullPath = (targetDirectory as NSString).appendingPathComponent(fileName)
        let totalBytes = itemsList.reduce(Int64(0)) { $0 + max(0, $1.size) }
        return [
            CompressionExecutionJob(
                inputPaths: itemsList.map(\.path),
                outputFileName: fileName,
                outputPath: fullPath,
                estimatedBytes: totalBytes
            )
        ]
    }

    /// Executes one or more planned archive creation jobs sequentially and aggregates their results.
    nonisolated package static func executeCompressionJobs(
        jobs: [CompressionExecutionJob],
        format: ArchiveCompressionFormat,
        level: ArchiveCompressionLevel,
        password: String?,
        splitSize: Int64?,
        filterOptions: ArchiveFilterOptions,
        advancedOptions: ArchiveAdvancedOptions,
        token: CancellationToken?,
        executor: QuickCompressExecutor,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws -> ArchiveOperationResult {
        if jobs.count <= 1, let singleJob = jobs.first {
            return try await executor(
                singleJob.inputPaths,
                singleJob.outputPath,
                format,
                level,
                password,
                splitSize,
                filterOptions,
                advancedOptions,
                onProgress,
                token
            )
        }
        return try await executeMultiItemJobs(
            jobs: jobs,
            format: format,
            level: level,
            password: password,
            splitSize: splitSize,
            filterOptions: filterOptions,
            advancedOptions: advancedOptions,
            token: token,
            executor: executor,
            onProgress: onProgress
        )
    }

    nonisolated private static func executeMultiItemJobs(
        jobs: [CompressionExecutionJob],
        format: ArchiveCompressionFormat,
        level: ArchiveCompressionLevel,
        password: String?,
        splitSize: Int64?,
        filterOptions: ArchiveFilterOptions,
        advancedOptions: ArchiveAdvancedOptions,
        token: CancellationToken?,
        executor: QuickCompressExecutor,
        onProgress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws -> ArchiveOperationResult {
        let batchTotalBytes = jobs.reduce(Int64(0)) { $0 + max(0, $1.estimatedBytes) }
        var completedBytesPrefix: Int64 = 0
        var totalOriginal: Int64 = 0
        var totalCompressed: Int64 = 0
        var totalDuration: Double = 0.0
        var aggregatedFailed: [FailedItem] = []
        var firstOutputPath: String = ""

        for job in jobs {
            if token?.isCancelled() == true || Task.isCancelled {
                throw ArchiveError.cancelled
            }
            let prefixSnapshot = completedBytesPrefix
            let result = try await executor(
                job.inputPaths,
                job.outputPath,
                format,
                level,
                password,
                splitSize,
                filterOptions,
                advancedOptions,
                { prog in
                    let combinedProg = ArchiveProgress(
                        state: prog.state,
                        bytesProcessed: prefixSnapshot + max(0, prog.bytesProcessed),
                        totalBytes: max(batchTotalBytes, prefixSnapshot + max(0, prog.totalBytes)),
                        currentFileName: prog.currentFileName.isEmpty ? job.outputFileName : prog.currentFileName,
                        throughputMBs: prog.throughputMBs
                    )
                    onProgress(combinedProg)
                },
                token
            )
            if firstOutputPath.isEmpty && !result.outputPath.isEmpty {
                firstOutputPath = result.outputPath
            }
            completedBytesPrefix += max(job.estimatedBytes, result.originalBytes)
            totalOriginal += result.originalBytes
            totalCompressed += result.compressedBytes
            totalDuration += result.durationSeconds
            if let outcome = result.outcome, outcome.status == .completedWithFailures {
                aggregatedFailed.append(contentsOf: outcome.failed)
            }
        }
        if firstOutputPath.isEmpty {
            firstOutputPath = jobs.first?.outputPath ?? ""
        }
        let mergedOutcome: ExtractionOutcome? = aggregatedFailed.isEmpty ? nil : ExtractionOutcome(
            status: .completedWithFailures,
            extracted: UInt64(jobs.count),
            replaced: 0,
            keptBoth: 0,
            skipped: 0,
            failed: aggregatedFailed
        )
        let throughput = totalDuration > 0
            ? (Double(totalOriginal) / (1024.0 * 1024.0)) / totalDuration
            : 0.0
        return ArchiveOperationResult(
            outputPath: firstOutputPath,
            originalBytes: totalOriginal,
            compressedBytes: totalCompressed,
            durationSeconds: totalDuration,
            throughputMBs: throughput,
            outcome: mergedOutcome
        )
    }
}
