// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTI18nCore
import TTI18nUI

enum TTZipAudioPreviewLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
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

    func fallbackTranslation(for language: AppLanguage) -> String {
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

@MainActor
enum TTZipAudioPreviewLocalization {
    static func text(_ key: TTZipAudioPreviewLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    static func format(_ key: TTZipAudioPreviewLocaleKey, _ args: CVarArg...) -> String {
        let template = LocalizationState.shared.t(key)
        return String(format: template, arguments: args)
    }
}
