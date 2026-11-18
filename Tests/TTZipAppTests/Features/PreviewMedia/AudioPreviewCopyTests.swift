// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import enum TTI18nCore.AppLanguage
import class TTI18nUI.LocalizationState
import XCTest
@testable import TTZipPreviewKit

final class AudioPreviewCopyTests: XCTestCase {
    @MainActor
    func testTTZipAudioPreviewWaveformAndDiagnosticCardLocalizationAcrossThreeLanguages() {
        let localization = LocalizationState.shared
        let savedLanguage = localization.currentLanguage
        defer { localization.setLanguage(savedLanguage) }

        let languages: [AppLanguage] = [.en, .zhHans, .zhHant]
        for language in languages {
            localization.setLanguage(language)
            for key in TTZipAudioPreviewLocaleKey.allCases {
                let resolved = TTZipAudioPreviewLocalization.text(key)
                XCTAssertFalse(resolved.isEmpty, "Translation for \(key.rawValue) in \(language.bcp47) must not be empty")
                XCTAssertNotEqual(resolved, key.rawValue, "Translation for \(key.rawValue) in \(language.bcp47) must not fall back to rawKey")
            }
        }

        localization.setLanguage(.zhHans)
        XCTAssertTrue(TTZipAudioPreviewLocalization.text(.extractingWaveform).contains("正在提取"))
        XCTAssertTrue(TTZipAudioPreviewLocalization.text(.waveformUnavailable).contains("不可用"))
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.digitalSilenceBadge), "数字静音")
        XCTAssertTrue(TTZipAudioPreviewLocalization.text(.sampledEnvelopeBadge).contains("抽样包络"))
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.completenessUnverifiedBadge), "抽样结果／完整性未确认")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.waveformOnlyPreviewBadge), "仅支持波形预览")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.playbackFailureTitle), "播放失败")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.copyDiagnostics), "复制诊断信息")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.copied), "已复制")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.openExternal), "外部打开")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.retry), "重试")

        localization.setLanguage(.zhHant)
        XCTAssertTrue(TTZipAudioPreviewLocalization.text(.sampledEnvelopeBadge).contains("抽樣包絡"))
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.completenessUnverifiedBadge), "抽樣結果／完整性未確認")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.digitalSilenceBadge), "數位靜音")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.waveformOnlyPreviewBadge), "僅支援波形預覽")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.playbackFailureTitle), "播放失敗")

        localization.setLanguage(.en)
        XCTAssertTrue(TTZipAudioPreviewLocalization.text(.extractingWaveform).contains("Extracting"))
        XCTAssertTrue(TTZipAudioPreviewLocalization.text(.sampledEnvelopeBadge).contains("Sampled Envelope"))
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.completenessUnverifiedBadge), "Sampled / Completeness Unverified")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.digitalSilenceBadge), "Digital Silence")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.waveformOnlyPreviewBadge), "Waveform Preview Only")
        XCTAssertEqual(TTZipAudioPreviewLocalization.text(.playbackFailureTitle), "Playback Failure")
    }

    @MainActor
    func testAudioPlayerControlsSpecsAndMiniPlayerLocalizationAcrossThreeLanguages() {
        let localization = LocalizationState.shared
        let savedLanguage = localization.currentLanguage
        defer { localization.setLanguage(savedLanguage) }

        let languages: [AppLanguage] = [.en, .zhHans, .zhHant]
        let labels: [(TTZipAudioPreviewLocaleKey, [String])] = [
            (.play, ["Play", "播放", "播放"]),
            (.pause, ["Pause", "暂停", "暫停"]),
            (.mute, ["Mute", "静音", "靜音"]),
            (.unmute, ["Unmute", "取消静音", "取消靜音"]),
            (.changePlaybackSpeedHelp, ["Change playback speed", "调整播放速度", "調整播放速度"]),
            (.audioSpecsTitle, ["Audio Specs", "音频规格", "音訊規格"]),
            (.specFormat, ["Format", "格式", "格式"]),
            (.specSampleRate, ["Sample Rate", "采样率", "取樣率"]),
            (.specBitrate, ["Bitrate", "比特率", "位元率"]),
            (.specChannels, ["Channels", "声道", "聲道"]),
            (.specFileSize, ["File Size", "文件大小", "檔案大小"]),
            (.specDuration, ["Duration", "时长", "時長"]),
            (.specAudioEngine, ["Audio Engine", "音频引擎", "音訊引擎"]),
            (.specWaveformBins, ["Waveform Bins", "波形分桶", "波形分箱"]),
            (.losslessBadge, ["LOSSLESS", "无损", "無損"]),
            (.miniPlayerBadge, ["MINI", "迷你窗", "迷你窗"]),
            (.detachMiniPlayerHelp, ["Detach Mini Player", "分离迷你播放器", "分離迷你播放器"]),
            (.clickToPauseHelp, ["Click to pause playback", "点击暂停播放", "點按以暫停播放"]),
            (.clickToPlayHelp, ["Click to start playback", "点击开始播放", "點按以開始播放"]),
            (.unknownTrack, ["Unknown Track", "未知曲目", "未知曲目"]),
            (.unknownArtist, ["Unknown Artist", "未知歌手", "未知演出者"]),
            (.previousOrSeekBackHelp, ["Previous / Seek Back", "上一曲 / 快退", "上一首 / 快退"]),
            (.nextOrSeekForwardHelp, ["Next / Seek Forward", "下一曲 / 快进", "下一首 / 快轉"]),
            (.volumeMuteOrScrollHelp, ["Volume (Click to Mute / Scroll to adjust)", "音量（点击静音 / 滚动调节）", "音量（點按靜音 / 捲動調整）"]),
            (.restoreToMainWindowHelp, ["Restore to Main Window", "恢复到主窗口", "還原至主視窗"]),
        ]
        let formattedLabels: [(TTZipAudioPreviewLocaleKey, CVarArg, [String])] = [
            (.rewindSecondsFormat, 15, ["Rewind 15 seconds", "快退 15 秒", "快退 15 秒"]),
            (.forwardSecondsFormat, 15, ["Forward 15 seconds", "快进 15 秒", "快轉 15 秒"]),
            (.normalPlaybackSpeedFormat, "1.0×", ["1.0× (Normal)", "1.0×（正常）", "1.0×（正常）"]),
            (.liveLevelPercentFormat, 75, ["75 percent", "百分之 75", "百分之 75"]),
        ]

        for (index, language) in languages.enumerated() {
            localization.setLanguage(language)
            for (key, expected) in labels {
                XCTAssertEqual(TTZipAudioPreviewLocalization.text(key), expected[index], "\(key.rawValue) in \(language.bcp47)")
            }
            for (key, argument, expected) in formattedLabels {
                XCTAssertEqual(
                    TTZipAudioPreviewLocalization.format(key, argument), expected[index], "\(key.rawValue) in \(language.bcp47)"
                )
            }
        }
    }
}
