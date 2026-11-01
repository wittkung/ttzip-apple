// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
@testable import TTMediaKit

extension AudioAuthenticityAndLoadingTests {

    // MARK: - 7. Playback Lifecycle (Play, Pause, Seek, Finish, Close) & Verified Corpus Audit

    func testSupportedFormatsPlaybackLifecycleAndSeparateVerificationRecords() async throws {
        let engine = MPVAudioEngine()

        // Verify strict separation between 18 fixture-probed extensions (15 playable, 3 Ogg/Opus failing) and 7 unverified candidate extensions
        XCTAssertEqual(MPVAudioEngine.verifiedCorpusFormatSpecs.count, 18)
        XCTAssertEqual(MPVAudioEngine.verifiedPlayableCoreAudioExtensions.count, 15)
        XCTAssertEqual(MPVAudioEngine.unverifiedCandidateCoreAudioExtensions.count, 7)
        for unverifiedExt in MPVAudioEngine.unverifiedCandidateCoreAudioExtensions {
            let support = MPVAudioEngine.formatSupport(forExtension: unverifiedExt)
            XCTAssertTrue(support.isPlayableNatively)
            XCTAssertFalse(support.isCorpusVerified, "Unverified candidate .\(unverifiedExt) must not claim corpus verification")
        }
        for (ext, spec) in MPVAudioEngine.verifiedCorpusFormatSpecs {
            let support = MPVAudioEngine.formatSupport(forExtension: ext)
            XCTAssertEqual(support, .verifiedNativeCoreAudio(spec: spec))
            XCTAssertEqual(support.isPlayableNatively, spec.playbackVerified, "isPlayableNatively must honor playbackVerified for .\(ext)")
            XCTAssertEqual(support.isCorpusVerified, spec.playbackVerified, "isCorpusVerified must honor playbackVerified for .\(ext)")
        }
        for failingExt in ["ogg", "oga", "opus"] {
            XCTAssertFalse(MPVAudioEngine.formatSupport(forExtension: failingExt).isPlayableNatively)
            XCTAssertFalse(MPVAudioEngine.nativeCoreAudioExtensions.contains(failingExt))
        }

        let root = try XCTUnwrap(previewFixtureRootIfAvailable(), "Required preview corpus is missing")

        let unrelatedURL = FileManager.default.temporaryDirectory.appendingPathComponent("unrelated-other.wav")
        for (ext, spec) in MPVAudioEngine.verifiedCorpusFormatSpecs.sorted(by: { $0.key < $1.key }) {
            let fixtureURL = root.appendingPathComponent("audio/tone.\(ext)")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fixtureURL.path),
                "Missing real corpus fixture for .\(ext) at \(fixtureURL.path)"
            )

            let gen = engine.load(url: fixtureURL, ownerSessionID: "corpus-\(ext)")

            // Stage 1: Sample loaded
            XCTAssertEqual(!engine.hasPlaybackError, spec.sampleLoaded, "Load state mismatch for .\(ext): \(engine.errorMessage ?? "")")
            XCTAssertGreaterThan(engine.duration, 0.4, "Duration must be valid for .\(ext)")

            // Stage 2: Waveform extracted
            await engine.waitForWaveform()
            XCTAssertEqual(engine.waveformSamples.count, 1600, "Waveform count mismatch for .\(ext)")
            XCTAssertGreaterThan(engine.waveformSamples.max() ?? 0, 0.1, "Waveform peak too low for .\(ext)")

            // Stage 3: Play start, seek, pause, resume near tail, and real natural delegate completion
            engine.play()
            if !spec.playbackVerified {
                XCTAssertTrue(engine.hasPlaybackError, "Expected .\(ext) to fail AVAudioPlayer.play() on macOS")
                XCTAssertEqual(engine.failureReason, .outputEngineStartFailed)
                XCTAssertFalse(engine.didVerifyPlaybackStart)
                XCTAssertFalse(engine.didFinishPlayingNaturally)
                engine.stopIfCurrent(url: fixtureURL, generation: gen, sessionID: "corpus-\(ext)")
                continue
            }
            XCTAssertTrue(engine.didVerifyPlaybackStart, "Playback start must be verified for .\(ext)")
            XCTAssertFalse(engine.didFinishPlayingNaturally, "Natural completion must be false immediately after start for .\(ext)")

            engine.seek(to: 0.20)
            XCTAssertEqual(engine.currentTime, 0.20, accuracy: 0.20, "Seek failed for .\(ext)")
            engine.pause()
            XCTAssertFalse(engine.isPlaying)
            XCTAssertEqual(engine.currentLevel, 0.0)

            // Resume near end and wait for authentic AVAudioPlayerDelegate natural completion
            engine.seek(to: max(0.0, engine.duration - 0.06))
            engine.play()
            let finishedNaturally = await engine.waitForNaturalCompletion(timeoutSeconds: 1.5)
            XCTAssertTrue(finishedNaturally, "Expected authentic natural playback completion callback for .\(ext)")
            XCTAssertTrue(engine.didFinishPlayingNaturally)
            XCTAssertFalse(engine.isPlaying)
            XCTAssertEqual(engine.currentTime, engine.duration, accuracy: 0.02)
            XCTAssertEqual(engine.currentLevel, 0.0)

            engine.stopIfCurrent(url: unrelatedURL, generation: gen, sessionID: "corpus-\(ext)")
            XCTAssertEqual(engine.currentURL, fixtureURL, "stopIfCurrent with non-matching URL must not tear down session")
            engine.stopIfCurrent(url: fixtureURL, generation: gen, sessionID: "corpus-\(ext)")
            XCTAssertNil(engine.currentURL, "stopIfCurrent with matching URL + generation + sessionID must clear session")
        }
    }

    func testSameURLViewHandoffPreservesNewSessionOwnership() async throws {
        let engine = MPVAudioEngine()
        let wavData = makeTestWAVData(sampleRate: 16_000, frameCount: 8_000) { idx, _ in
            Int16(clamping: Int(sin(2.0 * Double.pi * 440.0 * Double(idx) / 16_000.0) * 20_000.0))
        }
        let sharedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-same-url-handoff-\(UUID().uuidString).wav")
        try wavData.write(to: sharedURL)
        defer { try? FileManager.default.removeItem(at: sharedURL) }

        // View A mounts and loads sharedURL
        let genA = engine.load(url: sharedURL, ownerSessionID: "view-session-A")
        engine.play()
        XCTAssertEqual(engine.currentURL, sharedURL)
        XCTAssertEqual(engine.activeOwnerSessionID, "view-session-A")
        XCTAssertEqual(engine.activeLoadGeneration, genA)

        // View B mounts for the SAME URL before View A's onDisappear runs
        let genB = engine.load(url: sharedURL, ownerSessionID: "view-session-B")
        engine.play()
        XCTAssertGreaterThan(genB, genA)
        XCTAssertEqual(engine.currentURL, sharedURL)
        XCTAssertEqual(engine.activeOwnerSessionID, "view-session-B")

        // Outgoing View A runs onDisappear (same URL, stale sessionID & generation) -> MUST NOT stop View B
        UnifiedAudioPlayerView.stopAudioEngineIfOwned(
            engine: engine,
            ownerURL: sharedURL,
            ownerSessionID: "view-session-A",
            ownerGeneration: genA
        )
        XCTAssertEqual(engine.currentURL, sharedURL, "Outgoing View A must not tear down View B on same-URL handoff")
        XCTAssertEqual(engine.activeOwnerSessionID, "view-session-B")
        XCTAssertEqual(engine.activeLoadGeneration, genB)
        XCTAssertNotNil(engine.audioPlayer)

        // Even an unowned legacy stop call (ownerSessionID: nil) or stale generation must not stop View B
        engine.stopIfCurrent(url: sharedURL, generation: genA, sessionID: "view-session-B")
        XCTAssertEqual(engine.currentURL, sharedURL, "Stale generation must not stop active session")

        // Active View B runs onDisappear -> tears down cleanly
        UnifiedAudioPlayerView.stopAudioEngineIfOwned(
            engine: engine,
            ownerURL: sharedURL,
            ownerSessionID: "view-session-B",
            ownerGeneration: genB
        )
        XCTAssertNil(engine.currentURL)
        XCTAssertNil(engine.activeOwnerSessionID)
        XCTAssertNil(engine.audioPlayer)
    }

    // MARK: - 8. TTI18n Localization Switching & Unsupported Format Feedback

    func testTTI18nLanguageSwitchingAndUnsupportedFormatClassification() async throws {
        let savedBCP47 = AudioPreviewLocalization.currentLanguageBCP47
        defer { AudioPreviewLocalization.setLanguage(bcp47: savedBCP47) }

        let engine = MPVAudioEngine()

        // Test Simplified Chinese
        AudioPreviewLocalization.setLanguage(bcp47: "zh-Hans")
        XCTAssertTrue(AudioPreviewLocalization.text(.extractingWaveform).contains("正在提取"))
        XCTAssertTrue(AudioPreviewLocalization.text(.waveformUnavailable).contains("不可用"))
        XCTAssertTrue(AudioPreviewLocalization.text(.sampledEnvelopeBadge).contains("抽样包络"))
        XCTAssertEqual(AudioPreviewLocalization.text(.completenessUnverifiedBadge), "抽样结果／完整性未确认")

        let wmaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-i18n-\(UUID().uuidString).wma")
        try Data([0x30, 0x26, 0xB2, 0x75]).write(to: wmaURL)
        defer { try? FileManager.default.removeItem(at: wmaURL) }

        engine.load(url: wmaURL)
        let zhError = try XCTUnwrap(engine.errorMessage)
        XCTAssertTrue(zhError.contains("暂不支持"), "Expected Chinese unsupported error, got: \(zhError)")

        // Switch dynamically to Traditional Chinese
        AudioPreviewLocalization.setLanguage(bcp47: "zh-Hant")
        XCTAssertTrue(AudioPreviewLocalization.text(.sampledEnvelopeBadge).contains("抽樣包絡"))
        XCTAssertEqual(AudioPreviewLocalization.text(.completenessUnverifiedBadge), "抽樣結果／完整性未確認")
        let hantError = try XCTUnwrap(engine.errorMessage)
        XCTAssertTrue(hantError.contains("暫不支援"), "Expected Traditional Chinese unsupported error, got: \(hantError)")

        // Switch dynamically to English and verify computed errorMessage updates immediately
        AudioPreviewLocalization.setLanguage(bcp47: "en")
        XCTAssertTrue(AudioPreviewLocalization.text(.extractingWaveform).contains("Extracting"))
        XCTAssertTrue(AudioPreviewLocalization.text(.sampledEnvelopeBadge).contains("Sampled Envelope"))
        XCTAssertEqual(AudioPreviewLocalization.text(.completenessUnverifiedBadge), "Sampled / Completeness Unverified")
        let enError = try XCTUnwrap(engine.errorMessage)
        XCTAssertTrue(
            enError.contains("is not supported by native macOS CoreAudio"),
            "Expected English unsupported error after language switch, got: \(enError)"
        )

        // Verify all 7 unsupported/synthesizer extensions fail fast with clear localized copy
        for ext in ["wma", "wv", "tta", "voc", "ra", "mid", "midi"] {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ttmedia-unsup-\(UUID().uuidString).\(ext)")
            try Data([0x4D, 0x54, 0x68, 0x64]).write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            engine.load(url: tempURL)
            XCTAssertTrue(engine.hasPlaybackError)
            XCTAssertFalse(engine.isBuffering)
            XCTAssertFalse(engine.isExtractingWaveform)
            XCTAssertTrue(engine.waveformSamples.isEmpty)
            XCTAssertNotNil(engine.errorMessage)
        }
    }

    func testAudioPlayerControlsSpecsAndMiniPlayerLocalizationAcrossThreeLanguages() {
        let savedBCP47 = AudioPreviewLocalization.currentLanguageBCP47
        defer { AudioPreviewLocalization.setLanguage(bcp47: savedBCP47) }

        for bcp47 in ["en", "zh-Hans", "zh-Hant"] {
            AudioPreviewLocalization.setLanguage(bcp47: bcp47)
            for key in AudioPreviewLocaleKey.allCases {
                let resolved = AudioPreviewLocalization.text(key)
                XCTAssertFalse(resolved.isEmpty, "Translation for \(key.rawValue) in \(bcp47) must not be empty")
                XCTAssertNotEqual(resolved, key.rawKey, "Translation for \(key.rawValue) in \(bcp47) must not fall back to rawKey")
            }
        }

        // 1. Simplified Chinese (zh-Hans)
        AudioPreviewLocalization.setLanguage(bcp47: "zh-Hans")
        XCTAssertEqual(AudioPreviewLocalization.format(.rewindSecondsFormat, 15), "快退 15 秒")
        XCTAssertEqual(AudioPreviewLocalization.format(.forwardSecondsFormat, 15), "快进 15 秒")
        XCTAssertEqual(AudioPreviewLocalization.text(.play), "播放")
        XCTAssertEqual(AudioPreviewLocalization.text(.pause), "暂停")
        XCTAssertEqual(AudioPreviewLocalization.text(.mute), "静音")
        XCTAssertEqual(AudioPreviewLocalization.text(.unmute), "取消静音")
        XCTAssertEqual(AudioPreviewLocalization.format(.normalPlaybackSpeedFormat, "1.0×"), "1.0×（正常）")
        XCTAssertEqual(AudioPreviewLocalization.text(.changePlaybackSpeedHelp), "调整播放速度")
        XCTAssertEqual(AudioPreviewLocalization.text(.audioSpecsTitle), "音频规格")
        XCTAssertEqual(AudioPreviewLocalization.text(.specFormat), "格式")
        XCTAssertEqual(AudioPreviewLocalization.text(.specSampleRate), "采样率")
        XCTAssertEqual(AudioPreviewLocalization.text(.specBitrate), "比特率")
        XCTAssertEqual(AudioPreviewLocalization.text(.specChannels), "声道")
        XCTAssertEqual(AudioPreviewLocalization.text(.specFileSize), "文件大小")
        XCTAssertEqual(AudioPreviewLocalization.text(.specDuration), "时长")
        XCTAssertEqual(AudioPreviewLocalization.text(.specAudioEngine), "音频引擎")
        XCTAssertEqual(AudioPreviewLocalization.text(.specWaveformBins), "波形分桶")
        XCTAssertEqual(AudioPreviewLocalization.text(.losslessBadge), "无损")
        XCTAssertEqual(AudioPreviewLocalization.text(.miniPlayerBadge), "迷你窗")
        XCTAssertEqual(AudioPreviewLocalization.text(.detachMiniPlayerHelp), "分离迷你播放器")
        XCTAssertEqual(AudioPreviewLocalization.text(.clickToPauseHelp), "点击暂停播放")
        XCTAssertEqual(AudioPreviewLocalization.text(.clickToPlayHelp), "点击开始播放")
        XCTAssertEqual(AudioPreviewLocalization.text(.unknownTrack), "未知曲目")
        XCTAssertEqual(AudioPreviewLocalization.text(.unknownArtist), "未知歌手")
        XCTAssertEqual(AudioPreviewLocalization.text(.previousOrSeekBackHelp), "上一曲 / 快退")
        XCTAssertEqual(AudioPreviewLocalization.text(.nextOrSeekForwardHelp), "下一曲 / 快进")
        XCTAssertEqual(AudioPreviewLocalization.text(.volumeMuteOrScrollHelp), "音量（点击静音 / 滚动调节）")
        XCTAssertEqual(AudioPreviewLocalization.text(.restoreToMainWindowHelp), "恢复到主窗口")
        XCTAssertEqual(AudioPreviewLocalization.format(.liveLevelPercentFormat, 75), "百分之 75")

        // 2. Traditional Chinese (zh-Hant)
        AudioPreviewLocalization.setLanguage(bcp47: "zh-Hant")
        XCTAssertEqual(AudioPreviewLocalization.format(.rewindSecondsFormat, 15), "快退 15 秒")
        XCTAssertEqual(AudioPreviewLocalization.format(.forwardSecondsFormat, 15), "快轉 15 秒")
        XCTAssertEqual(AudioPreviewLocalization.text(.play), "播放")
        XCTAssertEqual(AudioPreviewLocalization.text(.pause), "暫停")
        XCTAssertEqual(AudioPreviewLocalization.text(.mute), "靜音")
        XCTAssertEqual(AudioPreviewLocalization.text(.unmute), "取消靜音")
        XCTAssertEqual(AudioPreviewLocalization.format(.normalPlaybackSpeedFormat, "1.0×"), "1.0×（正常）")
        XCTAssertEqual(AudioPreviewLocalization.text(.changePlaybackSpeedHelp), "調整播放速度")
        XCTAssertEqual(AudioPreviewLocalization.text(.audioSpecsTitle), "音訊規格")
        XCTAssertEqual(AudioPreviewLocalization.text(.specFormat), "格式")
        XCTAssertEqual(AudioPreviewLocalization.text(.specSampleRate), "取樣率")
        XCTAssertEqual(AudioPreviewLocalization.text(.specBitrate), "位元率")
        XCTAssertEqual(AudioPreviewLocalization.text(.specChannels), "聲道")
        XCTAssertEqual(AudioPreviewLocalization.text(.specFileSize), "檔案大小")
        XCTAssertEqual(AudioPreviewLocalization.text(.specDuration), "時長")
        XCTAssertEqual(AudioPreviewLocalization.text(.specAudioEngine), "音訊引擎")
        XCTAssertEqual(AudioPreviewLocalization.text(.specWaveformBins), "波形分箱")
        XCTAssertEqual(AudioPreviewLocalization.text(.losslessBadge), "無損")
        XCTAssertEqual(AudioPreviewLocalization.text(.miniPlayerBadge), "迷你窗")
        XCTAssertEqual(AudioPreviewLocalization.text(.detachMiniPlayerHelp), "分離迷你播放器")
        XCTAssertEqual(AudioPreviewLocalization.text(.clickToPauseHelp), "點按以暫停播放")
        XCTAssertEqual(AudioPreviewLocalization.text(.clickToPlayHelp), "點按以開始播放")
        XCTAssertEqual(AudioPreviewLocalization.text(.unknownTrack), "未知曲目")
        XCTAssertEqual(AudioPreviewLocalization.text(.unknownArtist), "未知演出者")
        XCTAssertEqual(AudioPreviewLocalization.text(.previousOrSeekBackHelp), "上一首 / 快退")
        XCTAssertEqual(AudioPreviewLocalization.text(.nextOrSeekForwardHelp), "下一首 / 快轉")
        XCTAssertEqual(AudioPreviewLocalization.text(.volumeMuteOrScrollHelp), "音量（點按靜音 / 捲動調整）")
        XCTAssertEqual(AudioPreviewLocalization.text(.restoreToMainWindowHelp), "還原至主視窗")
        XCTAssertEqual(AudioPreviewLocalization.format(.liveLevelPercentFormat, 75), "百分之 75")

        // 3. English (en)
        AudioPreviewLocalization.setLanguage(bcp47: "en")
        XCTAssertEqual(AudioPreviewLocalization.format(.rewindSecondsFormat, 15), "Rewind 15 seconds")
        XCTAssertEqual(AudioPreviewLocalization.format(.forwardSecondsFormat, 15), "Forward 15 seconds")
        XCTAssertEqual(AudioPreviewLocalization.text(.play), "Play")
        XCTAssertEqual(AudioPreviewLocalization.text(.pause), "Pause")
        XCTAssertEqual(AudioPreviewLocalization.text(.mute), "Mute")
        XCTAssertEqual(AudioPreviewLocalization.text(.unmute), "Unmute")
        XCTAssertEqual(AudioPreviewLocalization.format(.normalPlaybackSpeedFormat, "1.0×"), "1.0× (Normal)")
        XCTAssertEqual(AudioPreviewLocalization.text(.changePlaybackSpeedHelp), "Change playback speed")
        XCTAssertEqual(AudioPreviewLocalization.text(.audioSpecsTitle), "Audio Specs")
        XCTAssertEqual(AudioPreviewLocalization.text(.specFormat), "Format")
        XCTAssertEqual(AudioPreviewLocalization.text(.specSampleRate), "Sample Rate")
        XCTAssertEqual(AudioPreviewLocalization.text(.specBitrate), "Bitrate")
        XCTAssertEqual(AudioPreviewLocalization.text(.specChannels), "Channels")
        XCTAssertEqual(AudioPreviewLocalization.text(.specFileSize), "File Size")
        XCTAssertEqual(AudioPreviewLocalization.text(.specDuration), "Duration")
        XCTAssertEqual(AudioPreviewLocalization.text(.specAudioEngine), "Audio Engine")
        XCTAssertEqual(AudioPreviewLocalization.text(.specWaveformBins), "Waveform Bins")
        XCTAssertEqual(AudioPreviewLocalization.text(.losslessBadge), "LOSSLESS")
        XCTAssertEqual(AudioPreviewLocalization.text(.miniPlayerBadge), "MINI")
        XCTAssertEqual(AudioPreviewLocalization.text(.detachMiniPlayerHelp), "Detach Mini Player")
        XCTAssertEqual(AudioPreviewLocalization.text(.clickToPauseHelp), "Click to pause playback")
        XCTAssertEqual(AudioPreviewLocalization.text(.clickToPlayHelp), "Click to start playback")
        XCTAssertEqual(AudioPreviewLocalization.text(.unknownTrack), "Unknown Track")
        XCTAssertEqual(AudioPreviewLocalization.text(.unknownArtist), "Unknown Artist")
        XCTAssertEqual(AudioPreviewLocalization.text(.previousOrSeekBackHelp), "Previous / Seek Back")
        XCTAssertEqual(AudioPreviewLocalization.text(.nextOrSeekForwardHelp), "Next / Seek Forward")
        XCTAssertEqual(AudioPreviewLocalization.text(.volumeMuteOrScrollHelp), "Volume (Click to Mute / Scroll to adjust)")
        XCTAssertEqual(AudioPreviewLocalization.text(.restoreToMainWindowHelp), "Restore to Main Window")
        XCTAssertEqual(AudioPreviewLocalization.format(.liveLevelPercentFormat, 75), "75 percent")
    }
}
