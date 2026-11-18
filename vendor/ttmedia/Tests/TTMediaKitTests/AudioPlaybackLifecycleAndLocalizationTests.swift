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
        engine.stopIfCurrent(
            url: sharedURL,
            generation: genA,
            sessionID: "view-session-A"
        )
        XCTAssertEqual(engine.currentURL, sharedURL, "Outgoing View A must not tear down View B on same-URL handoff")
        XCTAssertEqual(engine.activeOwnerSessionID, "view-session-B")
        XCTAssertEqual(engine.activeLoadGeneration, genB)
        XCTAssertNotNil(engine.audioPlayer)

        // The current session ID cannot authorize a stale generation.
        engine.stopIfCurrent(url: sharedURL, generation: genA, sessionID: "view-session-B")
        XCTAssertEqual(engine.currentURL, sharedURL, "Stale generation must not stop active session")

        // Active View B runs onDisappear -> tears down cleanly
        engine.stopIfCurrent(
            url: sharedURL,
            generation: genB,
            sessionID: "view-session-B"
        )
        XCTAssertNil(engine.currentURL)
        XCTAssertNil(engine.activeOwnerSessionID)
        XCTAssertNil(engine.audioPlayer)
    }

    // MARK: - 8. TTI18n Localization Switching & Unsupported Format Feedback

    func testTTI18nLanguageSwitchingAndUnsupportedFormatClassification() async throws {
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

        let engine = MPVAudioEngine()

        // Test Simplified Chinese
        AudioPreviewLocalization.setLanguage(bcp47: "zh-Hans")
        XCTAssertEqual(MPVAudioFailureReason.emptyAudioData.localizedMessage, "音频数据为空（0 字节）。")
        XCTAssertEqual(MPVAudioFailureReason.outputEngineStartFailed.localizedMessage, "音频输出引擎无法启动播放。")
        XCTAssertEqual(MPVAudioFailureReason.playbackDecodeError.localizedMessage, "播放过程中发生音频解码错误。")

        let wmaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttmedia-i18n-\(UUID().uuidString).wma")
        try Data([0x30, 0x26, 0xB2, 0x75]).write(to: wmaURL)
        defer { try? FileManager.default.removeItem(at: wmaURL) }

        engine.load(url: wmaURL)
        let zhError = try XCTUnwrap(engine.errorMessage)
        XCTAssertTrue(zhError.contains("暂不支持"), "Expected Chinese unsupported error, got: \(zhError)")

        // Switch dynamically to Traditional Chinese
        AudioPreviewLocalization.setLanguage(bcp47: "zh-Hant")
        XCTAssertEqual(MPVAudioFailureReason.emptyAudioData.localizedMessage, "音訊資料為空（0 位元組）。")
        XCTAssertEqual(MPVAudioFailureReason.outputEngineStartFailed.localizedMessage, "音訊輸出引擎無法啟動播放。")
        XCTAssertEqual(MPVAudioFailureReason.playbackDecodeError.localizedMessage, "播放過程中發生音訊解碼錯誤。")
        let hantError = try XCTUnwrap(engine.errorMessage)
        XCTAssertTrue(hantError.contains("暫不支援"), "Expected Traditional Chinese unsupported error, got: \(hantError)")

        // Switch dynamically to English and verify computed errorMessage updates immediately
        AudioPreviewLocalization.setLanguage(bcp47: "en")
        XCTAssertEqual(MPVAudioFailureReason.emptyAudioData.localizedMessage, "Audio data is empty (0 bytes).")
        XCTAssertEqual(MPVAudioFailureReason.outputEngineStartFailed.localizedMessage, "Audio output engine failed to start playback.")
        XCTAssertEqual(MPVAudioFailureReason.playbackDecodeError.localizedMessage, "Audio decode error occurred during playback.")
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
}
