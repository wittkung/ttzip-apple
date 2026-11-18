// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI

/// Target scenario profile matching Rust `Scenario` codes in `recommendCodec(data:scenario:)`.
public enum SmartCompressionScenario: Int32, CaseIterable, Sendable, Equatable, Identifiable {
    case instantTransfer = 0
    case balancedDaily = 1
    case coldStorage = 2

    public var id: Int32 { rawValue }

    @MainActor
    public var localizedTitle: String {
        let l10n = AppLocalizationState.shared
        switch self {
        case .instantTransfer:
            return l10n.uiString(
                zh: "极速传输",
                en: "Instant Transfer",
                zhHant: "極速傳輸",
                ja: "高速転送",
                ko: "고속 전송",
                de: "Soforttransfer",
                fr: "Transfert rapide",
                es: "Transferencia rápida"
            )
        case .balancedDaily:
            return l10n.uiString(
                zh: "日常均衡",
                en: "Balanced Daily",
                zhHant: "日常均衡",
                ja: "標準バランス",
                ko: "일상 균형",
                de: "Ausgewogen",
                fr: "Équilibré",
                es: "Equilibrado"
            )
        case .coldStorage:
            return l10n.uiString(
                zh: "冷备高压缩",
                en: "Cold Storage",
                zhHant: "冷備高壓縮",
                ja: "高圧縮保管",
                ko: "콜드 스토리지",
                de: "Kaltarchiv",
                fr: "Archivage froid",
                es: "Archivo frío"
            )
        }
    }

    public var iconName: String {
        switch self {
        case .instantTransfer: return "bolt.horizontal.fill"
        case .balancedDaily: return "scale.3d"
        case .coldStorage: return "archivebox.circle.fill"
        }
    }
}

/// Structured codec recommendation resolved from bounded payload sampling and format constraints.
public struct SmartCodecRecommendation: Sendable, Equatable {
    public let scenario: SmartCompressionScenario
    public let rawRecommendedCodec: String
    public let measuredEntropy: Double
    public let sampleBytesCount: Int
    public let recommendedFormat: ArchiveCompressionFormat
    public let recommendedLevel: ArchiveCompressionLevel
    public let recommendedAlgorithm: String
    public let recommendedZstdLevel: Int
    public let summaryText: String

    public init(
        scenario: SmartCompressionScenario,
        rawRecommendedCodec: String,
        measuredEntropy: Double,
        sampleBytesCount: Int,
        recommendedFormat: ArchiveCompressionFormat,
        recommendedLevel: ArchiveCompressionLevel,
        recommendedAlgorithm: String,
        recommendedZstdLevel: Int,
        summaryText: String
    ) {
        self.scenario = scenario
        self.rawRecommendedCodec = rawRecommendedCodec
        self.measuredEntropy = measuredEntropy
        self.sampleBytesCount = sampleBytesCount
        self.recommendedFormat = recommendedFormat
        self.recommendedLevel = recommendedLevel
        self.recommendedAlgorithm = recommendedAlgorithm
        self.recommendedZstdLevel = recommendedZstdLevel
        self.summaryText = summaryText
    }
}

/// Lifecycle state machine for smart codec recommendation probing.
public enum SmartRecommendationState: Sendable, Equatable {
    case idle
    case sampling(generation: UInt64)
    case ready(SmartCodecRecommendation)
    case failed(String)
}

/// Errors encountered during bounded file sampling for smart codec recommendation.
public enum SmartRecommendationSampleError: LocalizedError, Sendable, Equatable {
    case noInputItems
    case unreadableInput(String)
    case emptySample

    public var errorDescription: String? {
        switch self {
        case .noInputItems:
            return "No input files available for sampling."
        case .unreadableInput(let path):
            return "Unable to read sample bytes from \(path)."
        case .emptySample:
            return "No readable file bytes available to sample."
        }
    }
}

extension CompressFormSession {
    public static let maxRecommendationSampleBytes: Int = 256 * 1024
    public static let maxSampledFilesCount: Int = 16

    @discardableResult
    public func requestSmartRecommendation() -> Task<Void, Never>? {
        recommendationGeneration &+= 1
        activeRecommendationTask?.cancel()
        let generation = recommendationGeneration
        let inputPaths = itemsList.map(\.path)
        let scenario = smartScenario

        guard !inputPaths.isEmpty else {
            activeRecommendationTask = nil
            smartRecommendationState = .failed(Self.localizedNoInputErrorMessage())
            return nil
        }

        smartRecommendationState = .sampling(generation: generation)
        let customSampler = sampleDataProviderOverride
        let maxBytes = Self.maxRecommendationSampleBytes
        let maxFiles = Self.maxSampledFilesCount

        let task = Task { @MainActor [weak self] in
            let probeResult = await Self.runDetachedEntropyProbe(
                inputPaths: inputPaths,
                scenario: scenario,
                maxBytes: maxBytes,
                maxFiles: maxFiles,
                customSampler: customSampler
            )
            guard let self else { return }
            guard self.recommendationGeneration == generation, !Task.isCancelled else {
                return
            }
            self.activeRecommendationTask = nil
            switch probeResult {
            case .success(let payload):
                let recommendation = Self.buildRecommendation(
                    scenario: scenario,
                    rawRecommendedCodec: payload.rawCodec,
                    measuredEntropy: payload.entropy,
                    sampleBytesCount: payload.sampleBytesCount,
                    selectedFormat: self.selectedFormat,
                    isSingleRegularFileInput: self.isSingleRegularFileInput
                )
                self.smartRecommendationState = .ready(recommendation)
            case .failure(let error):
                if error is CancellationError { return }
                self.smartRecommendationState = .failed(Self.localizedSampleFailureMessage(for: error))
            }
        }
        activeRecommendationTask = task
        return task
    }

    @discardableResult
    public func evaluateSmartRecommendation() async -> SmartRecommendationState {
        let task = requestSmartRecommendation()
        await task?.value
        return smartRecommendationState
    }

    public func cancelSmartRecommendation() {
        recommendationGeneration &+= 1
        activeRecommendationTask?.cancel()
        activeRecommendationTask = nil
        if case .sampling = smartRecommendationState {
            smartRecommendationState = .idle
        }
    }

    public func applySmartRecommendation(allowFormatChange: Bool = false) {
        guard case .ready(let recommendation) = smartRecommendationState else { return }
        applyRecommendation(recommendation, allowFormatChange: allowFormatChange)
    }

    public func applyRecommendation(
        _ recommendation: SmartCodecRecommendation,
        allowFormatChange: Bool = false
    ) {
        isApplyingSmartRecommendation = true
        defer { isApplyingSmartRecommendation = false }

        let targetFormat: ArchiveCompressionFormat
        if allowFormatChange {
            targetFormat = Self.preferredFormat(
                forRawCodec: recommendation.rawRecommendedCodec,
                fallback: selectedFormat,
                isSingleRegularFileInput: isSingleRegularFileInput
            )
        } else {
            targetFormat = Self.sanitizeTargetFormat(
                selectedFormat,
                isSingleRegularFileInput: isSingleRegularFileInput
            )
        }

        if selectedFormat != targetFormat {
            selectedFormat = targetFormat
        }
        let resolved = Self.buildRecommendation(
            scenario: recommendation.scenario,
            rawRecommendedCodec: recommendation.rawRecommendedCodec,
            measuredEntropy: recommendation.measuredEntropy,
            sampleBytesCount: recommendation.sampleBytesCount,
            selectedFormat: selectedFormat,
            isSingleRegularFileInput: isSingleRegularFileInput
        )
        compressionLevel = resolved.recommendedLevel
        compressionAlgorithm = resolved.recommendedAlgorithm
        zstdLevel = resolved.recommendedZstdLevel
        lastAppliedRecommendation = resolved
        hasUserOverriddenRecommendation = false
        smartRecommendationState = .ready(resolved)
        reconcileSelectedFormatWithInputs()
    }

    package func resolvedAdvancedOptionsForCurrentState() -> ArchiveAdvancedOptions {
        makeAdvancedOptions()
    }

    package func handleInputsChangedForSmartRecommendation() {
        recommendationGeneration &+= 1
        activeRecommendationTask?.cancel()
        activeRecommendationTask = nil
        smartRecommendationState = .idle
        lastAppliedRecommendation = nil
        hasUserOverriddenRecommendation = false
    }

    package func handleSelectedFormatChangedForSmartRecommendation() {
        recommendationGeneration &+= 1
        activeRecommendationTask?.cancel()
        activeRecommendationTask = nil
        guard !isApplyingSmartRecommendation else { return }
        if lastAppliedRecommendation != nil {
            hasUserOverriddenRecommendation = true
        }
        if case .sampling = smartRecommendationState {
            smartRecommendationState = .idle
        } else if case .ready(let existing) = smartRecommendationState {
            smartRecommendationState = .ready(
                Self.buildRecommendation(
                    scenario: existing.scenario,
                    rawRecommendedCodec: existing.rawRecommendedCodec,
                    measuredEntropy: existing.measuredEntropy,
                    sampleBytesCount: existing.sampleBytesCount,
                    selectedFormat: selectedFormat,
                    isSingleRegularFileInput: isSingleRegularFileInput
                )
            )
        }
    }

    package func handleManualParameterChangeForSmartRecommendation() {
        if !isApplyingSmartRecommendation && lastAppliedRecommendation != nil {
            hasUserOverriddenRecommendation = true
        }
    }
}

// MARK: - Detached Sampling & Parameter Resolution

extension CompressFormSession {
    private struct ProbePayload: Sendable {
        let sampleBytesCount: Int
        let entropy: Double
        let rawCodec: String
    }

    private final class DetachedProbeTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Result<ProbePayload, Error>, Never>?
        private var cancelled = false

        func install(_ task: Task<Result<ProbePayload, Error>, Never>) {
            let shouldCancel = lock.withLock { () -> Bool in
                self.task = task
                return cancelled
            }
            if shouldCancel {
                task.cancel()
            }
        }

        func cancel() {
            let current = lock.withLock { () -> Task<Result<ProbePayload, Error>, Never>? in
                cancelled = true
                return task
            }
            current?.cancel()
        }
    }

    private static func runDetachedEntropyProbe(
        inputPaths: [String],
        scenario: SmartCompressionScenario,
        maxBytes: Int,
        maxFiles: Int,
        customSampler: (@Sendable ([String], Int) async throws -> Data)?
    ) async -> Result<ProbePayload, Error> {
        let box = DetachedProbeTaskBox()
        return await withTaskCancellationHandler {
            let detachedTask = Task.detached(priority: .userInitiated) { () -> Result<ProbePayload, Error> in
                do {
                    try Task.checkCancellation()
                    let sampledData: Data
                    if let customSampler {
                        sampledData = try await customSampler(inputPaths, maxBytes)
                    } else {
                        sampledData = try Self.sampleBoundedPayload(
                            from: inputPaths,
                            maxTotalBytes: maxBytes,
                            maxFiles: maxFiles
                        )
                    }
                    try Task.checkCancellation()
                    guard !sampledData.isEmpty else {
                        throw SmartRecommendationSampleError.emptySample
                    }
                    let entropy = estimateShannonEntropy(data: sampledData)
                    let rawCodec = recommendCodec(data: sampledData, scenario: scenario.rawValue)
                    return .success(
                        ProbePayload(
                            sampleBytesCount: sampledData.count,
                            entropy: entropy,
                            rawCodec: rawCodec
                        )
                    )
                } catch {
                    return .failure(error)
                }
            }
            box.install(detachedTask)
            return await detachedTask.value
        } onCancel: {
            box.cancel()
        }
    }

    nonisolated package static func sampleBoundedPayload(
        from inputPaths: [String],
        maxTotalBytes: Int,
        maxFiles: Int
    ) throws -> Data {
        guard !inputPaths.isEmpty else {
            throw SmartRecommendationSampleError.noInputItems
        }
        let collected = try collectCandidateFileURLs(from: inputPaths, maxFiles: maxFiles)
        var firstErrorPath = collected.firstErrorPath
        guard !collected.urls.isEmpty else {
            if let errPath = firstErrorPath {
                throw SmartRecommendationSampleError.unreadableInput(errPath)
            }
            throw SmartRecommendationSampleError.emptySample
        }

        var buffer = Data()
        buffer.reserveCapacity(min(maxTotalBytes, 64 * 1024))
        for fileURL in collected.urls {
            try Task.checkCancellation()
            let remaining = maxTotalBytes - buffer.count
            if remaining <= 0 { break }
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }
                if let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty {
                    buffer.append(chunk)
                }
            } catch {
                firstErrorPath = firstErrorPath ?? fileURL.path
            }
        }
        guard !buffer.isEmpty else {
            if let errPath = firstErrorPath {
                throw SmartRecommendationSampleError.unreadableInput(errPath)
            }
            throw SmartRecommendationSampleError.emptySample
        }
        return buffer
    }

    nonisolated private static func collectCandidateFileURLs(
        from inputPaths: [String],
        maxFiles: Int
    ) throws -> (urls: [URL], firstErrorPath: String?) {
        var urls: [URL] = []
        var firstErrorPath: String?
        let fm = FileManager.default

        for rawPath in inputPaths {
            try Task.checkCancellation()
            if urls.count >= maxFiles { break }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rawPath, isDirectory: &isDir) else {
                firstErrorPath = firstErrorPath ?? rawPath
                continue
            }
            if isDir.boolValue {
                let remainingFiles = maxFiles - urls.count
                let nested = try enumerateRegularFiles(
                    in: URL(fileURLWithPath: rawPath),
                    limit: remainingFiles
                )
                urls.append(contentsOf: nested)
            } else {
                urls.append(URL(fileURLWithPath: rawPath))
            }
        }
        return (urls, firstErrorPath)
    }

    nonisolated private static func enumerateRegularFiles(
        in directoryURL: URL,
        limit: Int
    ) throws -> [URL] {
        guard limit > 0,
              let enumerator = FileManager.default.enumerator(
                  at: directoryURL,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }
        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            if results.count >= limit { break }
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                results.append(fileURL)
            }
        }
        return results
    }

    package static func buildRecommendation(
        scenario: SmartCompressionScenario,
        rawRecommendedCodec: String,
        measuredEntropy: Double,
        sampleBytesCount: Int,
        selectedFormat: ArchiveCompressionFormat,
        isSingleRegularFileInput: Bool
    ) -> SmartCodecRecommendation {
        let effectiveFormat = sanitizeTargetFormat(
            selectedFormat,
            isSingleRegularFileInput: isSingleRegularFileInput
        )
        let mapped = resolveFormatParameters(
            rawCodec: rawRecommendedCodec,
            scenario: scenario,
            for: effectiveFormat
        )
        let summary = makeRecommendationSummary(
            scenario: scenario,
            rawCodec: rawRecommendedCodec,
            entropy: measuredEntropy,
            format: effectiveFormat,
            level: mapped.level
        )
        return SmartCodecRecommendation(
            scenario: scenario,
            rawRecommendedCodec: rawRecommendedCodec,
            measuredEntropy: measuredEntropy,
            sampleBytesCount: sampleBytesCount,
            recommendedFormat: effectiveFormat,
            recommendedLevel: mapped.level,
            recommendedAlgorithm: mapped.algorithm,
            recommendedZstdLevel: mapped.zstdLevel,
            summaryText: summary
        )
    }

    package static func sanitizeTargetFormat(
        _ format: ArchiveCompressionFormat,
        isSingleRegularFileInput: Bool
    ) -> ArchiveCompressionFormat {
        if format.isReadOnly {
            return .sevenZip
        }
        if format.isSingleStreamFormat && !isSingleRegularFileInput {
            return format.correspondingTarCompositeFormat ?? .tarZst
        }
        return format
    }

    package static func preferredFormat(
        forRawCodec rawCodec: String,
        fallback: ArchiveCompressionFormat,
        isSingleRegularFileInput: Bool
    ) -> ArchiveCompressionFormat {
        let sanitizedFallback = sanitizeTargetFormat(
            fallback,
            isSingleRegularFileInput: isSingleRegularFileInput
        )
        switch rawCodec {
        case "7Z-LZMA2":
            return .sevenZip
        case "ZIP-Deflate":
            return .zip
        case "Zstandard":
            return (isSingleRegularFileInput && sanitizedFallback == .zst) ? .zst : .tarZst
        case "LZ4":
            return (isSingleRegularFileInput && sanitizedFallback == .lz4) ? .lz4 : .tarLz4
        default:
            return sanitizedFallback
        }
    }

    package static func resolveFormatParameters(
        rawCodec: String,
        scenario: SmartCompressionScenario,
        for format: ArchiveCompressionFormat
    ) -> (level: ArchiveCompressionLevel, algorithm: String, zstdLevel: Int) {
        if format.supportedLevels == [.store] || rawCodec == "Store" {
            return (level: .store, algorithm: "Copy", zstdLevel: 1)
        }
        switch format {
        case .sevenZip:
            return resolveSevenZipParameters(rawCodec: rawCodec, scenario: scenario)
        case .zip:
            let level: ArchiveCompressionLevel = (scenario == .instantTransfer)
                ? .level1
                : ((scenario == .coldStorage) ? .level9 : .level6)
            return (level: level, algorithm: "LZMA2", zstdLevel: 3)
        case .zst, .tarZst:
            return resolveZstdParameters(rawCodec: rawCodec, scenario: scenario)
        default:
            return resolveGenericMultiLevelParameters(
                scenario: scenario,
                supportedLevels: format.supportedLevels
            )
        }
    }

    private static func resolveSevenZipParameters(
        rawCodec: String,
        scenario: SmartCompressionScenario
    ) -> (level: ArchiveCompressionLevel, algorithm: String, zstdLevel: Int) {
        let level: ArchiveCompressionLevel
        if rawCodec == "7Z-LZMA2" {
            level = (scenario == .coldStorage) ? .level9 : .level6
        } else if rawCodec == "Zstandard" || rawCodec == "LZ4" {
            level = (scenario == .instantTransfer) ? .level1 : .level6
        } else {
            level = (scenario == .instantTransfer)
                ? .level1
                : ((scenario == .coldStorage) ? .level9 : .level6)
        }
        return (level: level, algorithm: "LZMA2", zstdLevel: 3)
    }

    private static func resolveZstdParameters(
        rawCodec: String,
        scenario: SmartCompressionScenario
    ) -> (level: ArchiveCompressionLevel, algorithm: String, zstdLevel: Int) {
        if rawCodec == "Store" {
            return (level: .store, algorithm: "Copy", zstdLevel: 1)
        }
        switch scenario {
        case .instantTransfer:
            return (level: .level1, algorithm: "LZMA2", zstdLevel: 1)
        case .balancedDaily:
            return (level: .level3, algorithm: "LZMA2", zstdLevel: 3)
        case .coldStorage:
            return (level: .level9, algorithm: "LZMA2", zstdLevel: 19)
        }
    }

    private static func resolveGenericMultiLevelParameters(
        scenario: SmartCompressionScenario,
        supportedLevels: [ArchiveCompressionLevel]
    ) -> (level: ArchiveCompressionLevel, algorithm: String, zstdLevel: Int) {
        let desired: ArchiveCompressionLevel = (scenario == .instantTransfer)
            ? .level1
            : ((scenario == .coldStorage) ? .level9 : .level6)
        let resolvedLevel = supportedLevels.contains(desired)
            ? desired
            : (supportedLevels.last ?? .store)
        let algo = (resolvedLevel == .store) ? "Copy" : "LZMA2"
        return (level: resolvedLevel, algorithm: algo, zstdLevel: 3)
    }

    private static func makeRecommendationSummary(
        scenario: SmartCompressionScenario,
        rawCodec: String,
        entropy: Double,
        format: ArchiveCompressionFormat,
        level: ArchiveCompressionLevel
    ) -> String {
        let entropyStr = String(format: "%.2f", entropy)
        let l10n = AppLocalizationState.shared
        if format.supportedLevels == [.store] {
            return l10n.uiString(
                zh: "当前格式 \(format.displayName) 为纯容器，已保持 Store (L0) 直通打包（样本熵 H=\(entropyStr)）",
                en: "\(format.displayName) is a store-only container; keeping Store (L0) (sample H=\(entropyStr))",
                zhHant: "目前格式 \(format.displayName) 為純容器，已保持 Store (L0) 直通打包（樣本熵 H=\(entropyStr)）"
            )
        }
        if rawCodec == "Store" {
            return l10n.uiString(
                zh: "检测到高熵低可压缩样本（H=\(entropyStr)），推荐 Store (L0) 免压缩直通",
                en: "High-entropy sample detected (H=\(entropyStr)); Store (L0) recommended to skip redundant compression",
                zhHant: "偵測到高熵低可壓縮樣本（H=\(entropyStr)），推薦 Store (L0) 免壓縮直通"
            )
        }
        return l10n.uiString(
            zh: "\(scenario.localizedTitle)场景下样本熵 H=\(entropyStr)（引擎推荐 \(rawCodec)），建议 \(format.displayName) 使用 L\(level.rawValue)",
            en: "\(scenario.localizedTitle) sample H=\(entropyStr) (engine: \(rawCodec)); recommended \(format.displayName) L\(level.rawValue)",
            zhHant: "\(scenario.localizedTitle)場景下樣本熵 H=\(entropyStr)（引擎推薦 \(rawCodec)），建議 \(format.displayName) 使用 L\(level.rawValue)"
        )
    }

    private static func localizedNoInputErrorMessage() -> String {
        AppLocalizationState.shared.uiString(
            zh: "请先添加待压缩文件后再运行智能推荐",
            en: "Add input files before requesting a smart recommendation",
            zhHant: "請先加入待壓縮檔案後再執行智慧推薦"
        )
    }

    private static func localizedSampleFailureMessage(for error: Error) -> String {
        let l10n = AppLocalizationState.shared
        if let sampleErr = error as? SmartRecommendationSampleError {
            switch sampleErr {
            case .noInputItems:
                return localizedNoInputErrorMessage()
            case .emptySample:
                return l10n.uiString(
                    zh: "无法从所选输入中读取有效样本字节（文件为空或无普通文件）",
                    en: "No readable sample bytes found in selected inputs (empty or no regular files)",
                    zhHant: "無法從所選輸入中讀取有效樣本位元組（檔案為空或無一般檔案）"
                )
            case .unreadableInput(let path):
                let name = (path as NSString).lastPathComponent
                return l10n.uiString(
                    zh: "无法读取样本文件：\(name)",
                    en: "Unable to read sample file: \(name)",
                    zhHant: "無法讀取樣本檔案：\(name)"
                )
            }
        }
        return error.localizedDescription
    }

    // MARK: - Recovery Record (RS-FEC) Eligibility & State

    public static let supportedRecoveryRedundancyPercents: [Int] = [0, 3, 5, 10, 20]

    public var canEnableRecoveryRecord: Bool {
        selectedFormat.supportsRecoveryRecord && splitVolumeOption == nil && !isCustomVolumeSelected
    }

    public func reconcileRecoveryRecordEligibility() {
        if !canEnableRecoveryRecord && recoveryRecordRedundancyPercent != 0 {
            recoveryRecordRedundancyPercent = 0
        }
    }
}
