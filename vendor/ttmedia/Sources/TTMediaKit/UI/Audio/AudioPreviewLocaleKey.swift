// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI

/// Localized vocabulary for audio preview states, waveform extraction placeholders,
/// format capability diagnostics, and safety budget notifications.
public enum AudioPreviewLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case extractingWaveform = "media.audio.extractingWaveform"
    case waveformUnavailable = "media.audio.waveformUnavailable"
    case digitalSilenceBadge = "media.audio.digitalSilenceBadge"
    case sampledEnvelopeBadge = "media.audio.sampledEnvelopeBadge"
    case completenessUnverifiedBadge = "media.audio.completenessUnverifiedBadge"
    case liveLevel = "media.audio.liveLevel"
    case liveLevelAccessibility = "media.audio.liveLevelAccessibility"
    case playbackFailureTitle = "media.audio.playbackFailureTitle"
    case copyDiagnostics = "media.audio.copyDiagnostics"
    case copied = "media.audio.copied"
    case openExternal = "media.audio.openExternal"
    case retry = "media.audio.retry"
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
    case liveLevelPercentFormat = "media.audio.liveLevelPercentFormat"
    case rewindSecondsFormat = "media.audio.rewindSecondsFormat"
    case forwardSecondsFormat = "media.audio.forwardSecondsFormat"
    case play = "media.audio.play"
    case pause = "media.audio.pause"
    case mute = "media.audio.mute"
    case unmute = "media.audio.unmute"
    case normalPlaybackSpeedFormat = "media.audio.normalPlaybackSpeedFormat"
    case changePlaybackSpeedHelp = "media.audio.changePlaybackSpeedHelp"
    case audioSpecsTitle = "media.audio.audioSpecsTitle"
    case specFormat = "media.audio.specFormat"
    case specSampleRate = "media.audio.specSampleRate"
    case specBitrate = "media.audio.specBitrate"
    case specChannels = "media.audio.specChannels"
    case specFileSize = "media.audio.specFileSize"
    case specDuration = "media.audio.specDuration"
    case specAudioEngine = "media.audio.specAudioEngine"
    case specWaveformBins = "media.audio.specWaveformBins"
    case losslessBadge = "media.audio.losslessBadge"
    case miniPlayerBadge = "media.audio.miniPlayerBadge"
    case detachMiniPlayerHelp = "media.audio.detachMiniPlayerHelp"
    case clickToPauseHelp = "media.audio.clickToPauseHelp"
    case clickToPlayHelp = "media.audio.clickToPlayHelp"
    case unknownTrack = "media.audio.unknownTrack"
    case unknownArtist = "media.audio.unknownArtist"
    case previousOrSeekBackHelp = "media.audio.previousOrSeekBackHelp"
    case nextOrSeekForwardHelp = "media.audio.nextOrSeekForwardHelp"
    case volumeMuteOrScrollHelp = "media.audio.volumeMuteOrScrollHelp"
    case restoreToMainWindowHelp = "media.audio.restoreToMainWindowHelp"
    case waveformOnlyPreviewBadge = "media.audio.waveformOnlyPreviewBadge"
    case waveformOnlyPreviewNotice = "media.audio.waveformOnlyPreviewNotice"
    case localWindowModeLabel = "media.audio.localWindowModeLabel"
    case wholeTrackOverviewModeLabel = "media.audio.wholeTrackOverviewModeLabel"
    case localWindowPendingBadge = "media.audio.localWindowPendingBadge"
    case scrollingWaveformAccessibilityLabel = "media.audio.scrollingWaveformAccessibilityLabel"
    case overviewScrubberAccessibilityLabel = "media.audio.overviewScrubberAccessibilityLabel"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .extractingWaveform: (
            "Extracting audio waveform…",
            "正在提取音频波形…",
            "正在擷取音訊波形…"
        ),
        .waveformUnavailable: (
            "Waveform preview unavailable",
            "波形预览不可用",
            "波形預覽不可用"
        ),
        .digitalSilenceBadge: (
            "Digital Silence",
            "数字静音",
            "數位靜音"
        ),
        .sampledEnvelopeBadge: (
            "Sampled Envelope",
            "抽样包络",
            "抽樣包絡"
        ),
        .completenessUnverifiedBadge: (
            "Sampled / Completeness Unverified",
            "抽样结果／完整性未确认",
            "抽樣結果／完整性未確認"
        ),
        .liveLevel: (
            "LEVEL",
            "实时电平",
            "即時電平"
        ),
        .liveLevelAccessibility: (
            "Real-time Output Level",
            "实时输出电平",
            "即時輸出電平"
        ),
        .playbackFailureTitle: (
            "Playback Failure",
            "播放失败",
            "播放失敗"
        ),
        .copyDiagnostics: (
            "Copy Diagnostics",
            "复制诊断信息",
            "拷貝診斷資訊"
        ),
        .copied: (
            "Copied",
            "已复制",
            "已拷貝"
        ),
        .openExternal: (
            "Open External",
            "外部打开",
            "外部打開"
        ),
        .retry: (
            "Retry",
            "重试",
            "重試"
        ),
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
        .liveLevelPercentFormat: (
            "%d percent",
            "百分之 %d",
            "百分之 %d"
        ),
        .rewindSecondsFormat: (
            "Rewind %d seconds",
            "快退 %d 秒",
            "快退 %d 秒"
        ),
        .forwardSecondsFormat: (
            "Forward %d seconds",
            "快进 %d 秒",
            "快轉 %d 秒"
        ),
        .play: (
            "Play",
            "播放",
            "播放"
        ),
        .pause: (
            "Pause",
            "暂停",
            "暫停"
        ),
        .mute: (
            "Mute",
            "静音",
            "靜音"
        ),
        .unmute: (
            "Unmute",
            "取消静音",
            "取消靜音"
        ),
        .normalPlaybackSpeedFormat: (
            "%@ (Normal)",
            "%@（正常）",
            "%@（正常）"
        ),
        .changePlaybackSpeedHelp: (
            "Change playback speed",
            "调整播放速度",
            "調整播放速度"
        ),
        .audioSpecsTitle: (
            "Audio Specs",
            "音频规格",
            "音訊規格"
        ),
        .specFormat: (
            "Format",
            "格式",
            "格式"
        ),
        .specSampleRate: (
            "Sample Rate",
            "采样率",
            "取樣率"
        ),
        .specBitrate: (
            "Bitrate",
            "比特率",
            "位元率"
        ),
        .specChannels: (
            "Channels",
            "声道",
            "聲道"
        ),
        .specFileSize: (
            "File Size",
            "文件大小",
            "檔案大小"
        ),
        .specDuration: (
            "Duration",
            "时长",
            "時長"
        ),
        .specAudioEngine: (
            "Audio Engine",
            "音频引擎",
            "音訊引擎"
        ),
        .specWaveformBins: (
            "Waveform Bins",
            "波形分桶",
            "波形分箱"
        ),
        .losslessBadge: (
            "LOSSLESS",
            "无损",
            "無損"
        ),
        .miniPlayerBadge: (
            "MINI",
            "迷你窗",
            "迷你窗"
        ),
        .detachMiniPlayerHelp: (
            "Detach Mini Player",
            "分离迷你播放器",
            "分離迷你播放器"
        ),
        .clickToPauseHelp: (
            "Click to pause playback",
            "点击暂停播放",
            "點按以暫停播放"
        ),
        .clickToPlayHelp: (
            "Click to start playback",
            "点击开始播放",
            "點按以開始播放"
        ),
        .unknownTrack: (
            "Unknown Track",
            "未知曲目",
            "未知曲目"
        ),
        .unknownArtist: (
            "Unknown Artist",
            "未知歌手",
            "未知演出者"
        ),
        .previousOrSeekBackHelp: (
            "Previous / Seek Back",
            "上一曲 / 快退",
            "上一首 / 快退"
        ),
        .nextOrSeekForwardHelp: (
            "Next / Seek Forward",
            "下一曲 / 快进",
            "下一首 / 快轉"
        ),
        .volumeMuteOrScrollHelp: (
            "Volume (Click to Mute / Scroll to adjust)",
            "音量（点击静音 / 滚动调节）",
            "音量（點按靜音 / 捲動調整）"
        ),
        .restoreToMainWindowHelp: (
            "Restore to Main Window",
            "恢复到主窗口",
            "還原至主視窗"
        ),
        .waveformOnlyPreviewBadge: (
            "Waveform Preview Only",
            "仅支持波形预览",
            "僅支援波形預覽"
        ),
        .waveformOnlyPreviewNotice: (
            "Waveform and timeline preview only — native playback unavailable",
            "当前格式仅支持波形与定位预览，原生播放不可用",
            "目前格式僅支援波形與定位預覽，原生播放不可用"
        ),
        .localWindowModeLabel: (
            "Window",
            "局部滚动",
            "局部捲動"
        ),
        .wholeTrackOverviewModeLabel: (
            "Overview",
            "整首概览",
            "整首概覽"
        ),
        .localWindowPendingBadge: (
            "Local Window Pending · Overview",
            "局部高分待就绪 · 整首概览",
            "局部高分待就緒 · 整首概覽"
        ),
        .scrollingWaveformAccessibilityLabel: (
            "Scrolling audio waveform timeline",
            "滚动音频波形时间轴",
            "捲動音訊波形時間軸"
        ),
        .overviewScrubberAccessibilityLabel: (
            "Whole-track waveform overview scrubber",
            "整首波形概览定位条",
            "整首波形概覽定位條"
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

