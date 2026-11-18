// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI

/// Localized vocabulary for audio format capability diagnostics, loading failures,
/// and safety budget notifications in `MPVAudioEngine`.
public enum AudioPreviewLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case emptyAudioData = "media.audio.emptyAudioData"
    case directDataBudgetExceededFormat = "media.audio.directDataBudgetExceededFormat"
    case fallbackBudgetExceededFormat = "media.audio.fallbackBudgetExceededFormat"
    case fileNotFoundFormat = "media.audio.fileNotFoundFormat"
    case emptyAudioFileFormat = "media.audio.emptyAudioFileFormat"
    case noPlayableChannelsOrDuration = "media.audio.noPlayableChannelsOrDuration"
    case outputEngineStartFailed = "media.audio.outputEngineStartFailed"
    case playbackDecodeError = "media.audio.playbackDecodeError"
    case midiRequiresSynthesizerFormat = "media.audio.midiRequiresSynthesizerFormat"
    case unsupportedCodecFormat = "media.audio.unsupportedCodecFormat"
    case unsupportedStreamFormat = "media.audio.unsupportedStreamFormat"
    case corruptStreamFormat = "media.audio.corruptStreamFormat"
    case loadFailedFormat = "media.audio.loadFailedFormat"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .emptyAudioData: (
            "Audio data is empty (0 bytes).",
            "音频数据为空（0 字节）。",
            "音訊資料為空（0 位元組）。"
        ),
        .directDataBudgetExceededFormat: (
            "In-memory audio payload (%@) exceeds the %@ safety budget.",
            "内存音频负载（%@）超出 %@ 安全预算限制。",
            "記憶體音訊負載（%@）超出 %@ 安全預算限制。"
        ),
        .fallbackBudgetExceededFormat: (
            "%@ (File size %@ exceeds the %@ in-memory fallback budget.)",
            "%@（文件大小 %@ 超出 %@ 内存回退预算。）",
            "%@（檔案大小 %@ 超出 %@ 記憶體回退預算。）"
        ),
        .fileNotFoundFormat: (
            "Audio file not found: %@",
            "未找到音频文件：%@",
            "找不到音訊檔案：%@"
        ),
        .emptyAudioFileFormat: (
            "Audio file is empty (0 bytes): %@",
            "音频文件为空（0 字节）：%@",
            "音訊檔案為空（0 位元組）：%@"
        ),
        .noPlayableChannelsOrDuration: (
            "Audio stream contains no playable channels or duration.",
            "音频流不包含可播放的声道或有效时长。",
            "音訊串流不包含可播放的聲道或有效時長。"
        ),
        .outputEngineStartFailed: (
            "Audio output engine failed to start playback.",
            "音频输出引擎无法启动播放。",
            "音訊輸出引擎無法啟動播放。"
        ),
        .playbackDecodeError: (
            "Audio decode error occurred during playback.",
            "播放过程中发生音频解码错误。",
            "播放過程中發生音訊解碼錯誤。"
        ),
        .midiRequiresSynthesizerFormat: (
            "MIDI (%@) is a symbolic musical event sequence requiring a SoundFont synthesizer and cannot be decoded as a PCM audio stream.",
            "MIDI（%@）属于符号乐谱事件序列，需要 SoundFont 合成器，无法作为 PCM 音频流直接解码。",
            "MIDI（%@）屬於符號樂譜事件序列，需要 SoundFont 合成器，無法作為 PCM 音訊串流直接解碼。"
        ),
        .unsupportedCodecFormat: (
            "%@ (%@) is not supported by native macOS CoreAudio. Open in an external player to listen.",
            "原生 macOS CoreAudio 暂不支持 %@（%@）编码格式，请使用外部播放器打开。",
            "原生 macOS CoreAudio 暫不支援 %@（%@）編碼格式，請使用外部播放器打開。"
        ),
        .unsupportedStreamFormat: (
            "Unsupported audio format or codec (%@): native macOS CoreAudio cannot decode this stream.",
            "不支持的音频格式或编码（%@）：原生 macOS CoreAudio 无法解码该音频流。",
            "不支援的音訊格式或編碼（%@）：原生 macOS CoreAudio 無法解碼該音訊串流。"
        ),
        .corruptStreamFormat: (
            "Corrupt or truncated audio stream (%@): packet data could not be decoded.",
            "音频流已损坏或被截断（%@）：无法解码数据包。",
            "音訊串流已損毀或被截斷（%@）：無法解碼封包。"
        ),
        .loadFailedFormat: (
            "Failed to load audio (%@): %@",
            "无法加载音频（%@）：%@",
            "無法載入音訊（%@）：%@"
        ),
    ]
}

/// Resolves audio preview vocabulary through the shared observable `TTI18n` localization state.
@MainActor
public enum AudioPreviewLocalization {
    public static func text(_ key: AudioPreviewLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    public static func format(_ key: AudioPreviewLocaleKey, _ args: CVarArg...) -> String {
        let template = LocalizationState.shared.t(key)
        return String(format: template, arguments: args)
    }

    public static var currentLanguageBCP47: String {
        LocalizationState.shared.currentLanguage.bcp47
    }

    public static func setLanguage(bcp47: String) {
        let lang = AppLanguage.from(identifier: bcp47) ?? .en
        LocalizationState.shared.setLanguage(lang)
    }

    nonisolated public static func resolveNonisolated(_ key: AudioPreviewLocaleKey, _ args: CVarArg...) -> String {
        let lang = LocalizationManager.shared.currentLanguage
        let template = key.fallbackTranslation(for: lang)
        guard !args.isEmpty else { return template }
        return String(format: template, arguments: args)
    }
}

/// Typed localization-aware failure reason for audio loading and playback errors.
public indirect enum MPVAudioFailureReason: Sendable, Equatable {
    case emptyAudioData
    case directDataBudgetExceeded(sizeText: String, budgetText: String)
    case fileNotFound(fileName: String)
    case emptyAudioFile(fileName: String)
    case requiresSynthesizer(extensionLabel: String)
    case unsupportedCodec(formatName: String, extensionLabel: String)
    case fallbackBudgetExceeded(baseReason: MPVAudioFailureReason, sizeText: String, budgetText: String)
    case unsupportedStreamFormat(label: String)
    case corruptStream(label: String)
    case noPlayableChannelsOrDuration
    case outputEngineStartFailed
    case playbackDecodeError
    case loadFailed(label: String, underlyingDescription: String)

    @MainActor
    public var localizedMessage: String {
        switch self {
        case .emptyAudioData:
            return AudioPreviewLocalization.text(.emptyAudioData)
        case .directDataBudgetExceeded(let sizeText, let budgetText):
            return AudioPreviewLocalization.format(.directDataBudgetExceededFormat, sizeText, budgetText)
        case .fileNotFound(let fileName):
            return AudioPreviewLocalization.format(.fileNotFoundFormat, fileName)
        case .emptyAudioFile(let fileName):
            return AudioPreviewLocalization.format(.emptyAudioFileFormat, fileName)
        case .requiresSynthesizer(let extensionLabel):
            return AudioPreviewLocalization.format(.midiRequiresSynthesizerFormat, extensionLabel)
        case .unsupportedCodec(let formatName, let extensionLabel):
            return AudioPreviewLocalization.format(.unsupportedCodecFormat, formatName, extensionLabel)
        case .fallbackBudgetExceeded(let baseReason, let sizeText, let budgetText):
            return AudioPreviewLocalization.format(
                .fallbackBudgetExceededFormat,
                baseReason.localizedMessage,
                sizeText,
                budgetText
            )
        case .unsupportedStreamFormat(let label):
            return AudioPreviewLocalization.format(.unsupportedStreamFormat, label)
        case .corruptStream(let label):
            return AudioPreviewLocalization.format(.corruptStreamFormat, label)
        case .noPlayableChannelsOrDuration:
            return AudioPreviewLocalization.text(.noPlayableChannelsOrDuration)
        case .outputEngineStartFailed:
            return AudioPreviewLocalization.text(.outputEngineStartFailed)
        case .playbackDecodeError:
            return AudioPreviewLocalization.text(.playbackDecodeError)
        case .loadFailed(let label, let underlyingDescription):
            return AudioPreviewLocalization.format(.loadFailedFormat, label, underlyingDescription)
        }
    }
}

public struct MPVAudioMetadata: Sendable {
    public var title: String?
    public var artist: String?

    public init(title: String? = nil, artist: String? = nil) {
        self.title = title
        self.artist = artist
    }
}

/// Container, codec, and 4-stage verification record for formats tested with real corpus fixtures.
public struct MPVAudioVerifiedFormatSpec: Sendable, Equatable {
    public let extensionName: String
    public let containerFormat: String
    public let codecName: String
    public let sampleLoaded: Bool
    public let waveformExtracted: Bool
    public let playbackVerified: Bool
    public let naturalCompletionVerified: Bool
    public let testSystem: String

    public init(
        extensionName: String,
        containerFormat: String,
        codecName: String,
        sampleLoaded: Bool = true,
        waveformExtracted: Bool = true,
        playbackVerified: Bool = true,
        naturalCompletionVerified: Bool? = nil,
        testSystem: String = "macOS-arm64"
    ) {
        self.extensionName = extensionName
        self.containerFormat = containerFormat
        self.codecName = codecName
        self.sampleLoaded = sampleLoaded
        self.waveformExtracted = waveformExtracted
        self.playbackVerified = playbackVerified
        self.naturalCompletionVerified = naturalCompletionVerified ?? playbackVerified
        self.testSystem = testSystem
    }
}

/// Capability classification for audio formats routed to `MPVAudioEngine`.
public enum MPVAudioFormatSupport: Sendable, Equatable {
    /// Probed on macOS arm64 with corpus fixtures (`sampleLoaded`, `waveformExtracted`, `playbackVerified`, and `naturalCompletionVerified`).
    case verifiedNativeCoreAudio(spec: MPVAudioVerifiedFormatSpec)
    /// Registered in macOS CoreAudio `kAudioFileGlobalInfo_AllExtensions`, but not yet backed by a dedicated audio fixture.
    case candidateNativeCoreAudio(extensionName: String)
    /// Symbolic musical sequence requiring an instrument SoundFont/DLS synthesizer.
    case requiresSynthesizer(formatName: String, reason: String)
    /// Third-party archival or proprietary audio codec not supported by native CoreAudio.
    case unsupportedCodec(formatName: String, reason: String)
    /// Unclassified extension evaluated dynamically by CoreAudio header probing.
    case unknown(extensionName: String)

    public var isPlayableNatively: Bool {
        switch self {
        case .verifiedNativeCoreAudio(let spec):
            return spec.playbackVerified
        case .candidateNativeCoreAudio:
            return true
        case .requiresSynthesizer, .unsupportedCodec, .unknown:
            return false
        }
    }

    public var isCorpusVerified: Bool {
        if case .verifiedNativeCoreAudio(let spec) = self {
            return spec.sampleLoaded && spec.waveformExtracted && spec.playbackVerified
        }
        return false
    }
}

/// Measured main-thread latency breakdown across the 4 synchronous `AVAudioPlayer` stages.
public struct MPVAudioLoadTimingMetrics: Sendable, Equatable {
    public let urlInitDurationMs: Double
    public let dataFallbackDurationMs: Double
    public let prepareDurationMs: Double
    public var firstPlayDurationMs: Double
    public let totalLoadDurationMs: Double
    public let usedDataFallback: Bool
    public let didPrepareSynchronously: Bool
    public let fileSizeBytes: Int64

    public var exceededMainThreadFrameBudget: Bool {
        urlInitDurationMs > MPVAudioEngine.maxMainThreadStageBudgetMs ||
        dataFallbackDurationMs > MPVAudioEngine.maxMainThreadStageBudgetMs ||
        prepareDurationMs > MPVAudioEngine.maxMainThreadStageBudgetMs ||
        firstPlayDurationMs > MPVAudioEngine.maxMainThreadStageBudgetMs
    }
}

