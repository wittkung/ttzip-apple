// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import CoreMedia
import os
import TTMediaDemux
@preconcurrency import AVFoundation
@testable import TTMediaKit

final class MediaPresentationStateTests: XCTestCase {
    @MainActor
    func testDepartingViewportCannotCancelNewOwner() async {
        let coordinator = PreviewSessionCoordinator()
        let url = URL(fileURLWithPath: "/tmp/example.mp4")
        let old = await coordinator.beginSession(targetURL: url)
        let new = await coordinator.beginSession(targetURL: url)
        coordinator.cancelSession(generation: old)
        XCTAssertTrue(coordinator.isSessionActive(generation: new))
        coordinator.cancelSession(generation: new)
        XCTAssertFalse(coordinator.isSessionActive(generation: new))
    }

    @MainActor
    func testChromeHidesOnExitWhilePlayingAndPaused() {
        let chrome = MediaControlsVisibility()
        for playing in [true, false] {
            chrome.isPlaying = playing
            chrome.setHovered(true)
            XCTAssertTrue(chrome.isVisible)
            chrome.setHovered(false)
            XCTAssertFalse(chrome.isVisible)
        }
    }

    @MainActor
    func testInactivityAndFilePickerShareOneVisibilityState() {
        let chrome = MediaControlsVisibility()
        chrome.isPlaying = true
        chrome.setHovered(true)
        chrome.hideForInactivity()
        XCTAssertFalse(chrome.isVisible)
        chrome.beginInteraction()
        chrome.setHovered(false)
        chrome.hideForInactivity()
        XCTAssertTrue(chrome.isVisible)
        chrome.endInteraction()
        XCTAssertFalse(chrome.isVisible)
    }

    @MainActor
    func testViewportLeaseKeepsControllerStateAndSubtitles() async {
        let sessions = VideoPlaybackSessions()
        let url = URL(fileURLWithPath: "/tmp/lease.mkv")
        let first = UUID()
        let second = UUID()
        let original = sessions.claim(url: url, owner: first)
        original.currentTime = CMTime(seconds: 96, preferredTimescale: 600)
        original.isPlaying = false
        original.selectedSubtitleID = "off"
        original.subtitleTrack = ExternalSubtitleTrack(cues: [.init(start: 0, end: 100, text: "Test")])
        let expanded = sessions.claim(url: url, owner: second)
        sessions.release(owner: first)
        try? await Task.sleep(for: .milliseconds(400))
        let restored = sessions.claim(url: url, owner: first)
        XCTAssertTrue(original === expanded && expanded === restored)
        XCTAssertEqual(CMTimeGetSeconds(restored.currentTime), 96)
        XCTAssertFalse(restored.isPlaying)
        XCTAssertEqual(restored.subtitleTrack?.text(at: 96), "Test")
        XCTAssertEqual(restored.selectedSubtitleID, "off")
        sessions.release(owner: first)
    }

    @MainActor
    func testLiveNativeControllerAndClockSurviveViewportLeaseTransfer() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await AVSampleBufferPresentationTests.createSyntheticH264MP4(at: url, frameCount: 30)
        let sessions = VideoPlaybackSessions()
        let inspector = UUID()
        let fullWindow = UUID()
        let session = sessions.claim(url: url, owner: inspector)
        session.start(autoPlay: false)
        let deadline = ContinuousClock.now + .seconds(3)
        while session.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(session.isLoading)
        guard case .native(let controller) = session.activeController else {
            XCTFail("Native controller did not load: \(session.playbackError ?? "unknown")")
            return
        }
        defer { session.stop(); sessions.release(owner: inspector) }
        controller.seek(to: CMTime(seconds: 0.4, preferredTimescale: 600))
        let identity = ObjectIdentifier(controller)
        let expanded = sessions.claim(url: url, owner: fullWindow)
        sessions.release(owner: inspector)
        let restored = sessions.claim(url: url, owner: inspector)
        sessions.release(owner: fullWindow)
        guard case .native(let retained) = restored.activeController else { return XCTFail("Controller lost") }
        XCTAssertTrue(session === expanded && expanded === restored)
        XCTAssertEqual(ObjectIdentifier(retained), identity)
        XCTAssertEqual(CMTimeGetSeconds(retained.currentTime), 0.4, accuracy: 0.02)
        XCTAssertFalse(retained.isPlaying)
        let first = AVSampleBufferPlayerNSView(renderer: AVSampleBufferRenderer(displayLayer: retained.displayLayer))
        let second = AVSampleBufferPlayerNSView(renderer: AVSampleBufferRenderer(displayLayer: retained.displayLayer))
        second.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        second.layout()
        first.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        first.layout()
        XCTAssertTrue(retained.displayLayer.superlayer === second.layer)
        XCTAssertEqual(retained.displayLayer.frame.size, CGSize(width: 640, height: 360))
        MediaPlaybackCoordinator.shared.stopActivePlayback()
        XCTAssertTrue(session.isStopped)
        XCTAssertFalse(sessions.claim(url: url, owner: inspector) === session)
    }

    func testCompanionDiscoveryRequiresMatchingNameBoundaryAndListsDirectorySubtitles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["movie.zh.srt", "movie.srt", "movie2.srt", "movie.vtt", "Timeline 1.srt", "Timeline 1_Subtitle 1.ttml"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        let video = folder.appendingPathComponent("movie.mkv")
        let matches = VideoPlaybackSession.companions(for: video)
        XCTAssertEqual(matches.map(\.lastPathComponent), ["movie.srt", "movie.vtt", "movie.zh.srt"])
        let others = VideoPlaybackSession.directorySubtitles(for: video, excluding: matches)
        XCTAssertEqual(others.map(\.lastPathComponent), ["movie2.srt", "Timeline 1.srt", "Timeline 1_Subtitle 1.ttml"])
    }

    func testRustSubtitleBridgeAndSeekClock() throws {
        let bytes = Data("WEBVTT\n\n00:01.000 --> 00:03.000\n你好\nWorld\n\n00:02.000 --> 00:04.000\nOverlap".utf8)
        let track = try ExternalSubtitleTrack.parse(bytes)
        XCTAssertEqual(track.text(at: 0), "")
        XCTAssertEqual(track.text(at: 2), "你好\nWorld\nOverlap")
        XCTAssertEqual(track.text(at: 4), "")
        XCTAssertEqual(track.text(at: 1), "你好\nWorld")
        XCTAssertEqual(track.text(at: 1.5, delay: 0.5), "你好\nWorld")
        XCTAssertEqual(track.text(at: 1.2, delay: 0.5), "")
        XCTAssertThrowsError(try ExternalSubtitleTrack.parse(Data("broken".utf8)))
        XCTAssertThrowsError(try ExternalSubtitleTrack.parse(Data(repeating: 0x41, count: 4 * 1024 * 1024 + 1)))
    }

    func testZeroDurationCueRepairTTMLAndLegacyGB18030Encoding() throws {
        let zeroDurationSRT = Data("""
        336
        00:14:49,212 --> 00:14:50,511
        哪怕你完全不知道

        337
        00:14:52,456 --> 00:14:52,456
        π

        338
        00:14:53,456 --> 00:14:54,077
        的十进制展开
        """.utf8)
        let srtTrack = try ExternalSubtitleTrack.parse(zeroDurationSRT)
        XCTAssertEqual(srtTrack.cues.count, 3)
        XCTAssertEqual(srtTrack.text(at: 892.5), "π")

        let ttml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
        <p begin="01:00:01.000" end="01:00:03.000">达芬奇时间轴<br/>第二行</p>
        </div></body></tt>
        """.utf8)
        let ttmlTrack = try ExternalSubtitleTrack.parse(ttml)
        XCTAssertEqual(ttmlTrack.text(at: 1.5), "")
        XCTAssertEqual(ttmlTrack.text(at: 3601.5), "达芬奇时间轴\n第二行")
        XCTAssertEqual(ttmlTrack.text(at: 1.5, delay: -3600.0), "达芬奇时间轴\n第二行")

        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let gbData = try XCTUnwrap("1\n00:00:01,000 --> 00:00:03,000\n简体中文字幕\n".data(using: gb18030))
        let gbTrack = try ExternalSubtitleTrack.parse(gbData)
        XCTAssertEqual(gbTrack.text(at: 2.0), "简体中文字幕")
    }

    @MainActor
    func testSubtitleOverlayBottomPaddingIsInvariantWhenControlsVisibilityChanges() {
        let style = SubtitleStyleConfiguration(verticalPosition: 85.0)
        for width in [CGFloat(320), CGFloat(960)] {
            let visibleOverlay = SubtitleOverlayView(
                primaryText: "测试字幕",
                secondaryText: "",
                style: style,
                controlsVisible: true,
                viewportWidth: width,
                viewportHeight: 540
            )
            let hiddenOverlay = SubtitleOverlayView(
                primaryText: "测试字幕",
                secondaryText: "",
                style: style,
                controlsVisible: false,
                viewportWidth: width,
                viewportHeight: 540
            )
            XCTAssertEqual(visibleOverlay.bottomPadding, hiddenOverlay.bottomPadding, accuracy: 0.001)
        }
    }

    func testLongSpanningEarlyCueJumpIndexSkipsEndedIntermediateCues() {
        var cues: [ExternalSubtitleTrack.Cue] = [
            .init(start: 0.0, end: 7200.0, text: "Watermark")
        ]
        for idx in 1...2000 {
            let start = Double(idx * 2)
            cues.append(.init(start: start, end: start + 1.0, text: "Line \(idx)"))
        }
        let track = ExternalSubtitleTrack(cues: cues)
        XCTAssertEqual(track.text(at: 6500.0), "Watermark")
        XCTAssertEqual(track.text(at: 2000.5), "Watermark\nLine 1000")
    }

    @MainActor
    func testBackgroundPrewarmRespectsTrackCountBudgetAndCancellation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var urls: [URL] = []
        for idx in 1...5 {
            let fileURL = folder.appendingPathComponent("movie.lang\(idx).srt")
            try Data("1\n00:00:01,000 --> 00:00:02,000\nSub \(idx)\n".utf8).write(to: fileURL)
            urls.append(fileURL)
        }
        let session = VideoPlaybackSession(url: folder.appendingPathComponent("movie.mkv"))
        session.scheduleBackgroundSubtitlePrewarm(candidates: urls, others: [], budgetSeconds: 4.0, maxTracks: 2)
        await session.subtitlePrewarmTask?.value
        XCTAssertEqual(session.subtitleCache.count, 2)
        session.stop()

        // Verify mid-flight prewarm cancellation on: (1) player stop, (2) file change / rediscovery, (3) track switch.
        for trigger in ["stop", "changeFile", "switchTrack"] {
            try await assertMidFlightPrewarmCancellation(urls: urls, folder: folder, trigger: trigger)
        }
    }

    @MainActor
    private func assertMidFlightPrewarmCancellation(urls: [URL], folder: URL, trigger: String) async throws {
        let probe = SubtitleLoadProbe(pauseIndex: 2)
        let session = VideoPlaybackSession(url: folder.appendingPathComponent("movie.mkv"))
        session.companionSubtitles = urls
        session.externalSubtitleLoader = { url in
            await probe.load(url: url)
        }
        session.scheduleBackgroundSubtitlePrewarm(candidates: urls, others: [], budgetSeconds: 4.0, maxTracks: 5)
        let prewarmTask = try XCTUnwrap(session.subtitlePrewarmTask)
        await probe.waitUntilPausedOnSecondTrack()

        if trigger == "stop" {
            session.stop()
        } else if trigger == "changeFile" {
            session.cancelSubtitlePrewarm()
            session.scheduleBackgroundSubtitlePrewarm(candidates: [], others: [], budgetSeconds: 4.0, maxTracks: 5)
        } else {
            let cachedURL = urls[4]
            session.subtitleCache[cachedURL.absoluteString] = ExternalSubtitleTrack(cues: [.init(start: 0, end: 5, text: "Cached 5")])
            session.selectSubtitle(cachedURL.absoluteString, showFeedback: false)
        }

        await probe.releasePausedTrack()
        await prewarmTask.value

        let stats = await probe.snapshot()
        // 1. Background work actually stopped: structured cancellation reached track #2 and tracks #3..#5 never started.
        XCTAssertTrue(stats.observedTaskCancelledOnPausedTrack, "Trigger \(trigger) did not propagate structured Task cancellation")
        XCTAssertEqual(stats.startedURLs.count, 2, "Trigger \(trigger) failed to stop remaining prewarm queue")
        // 2. Stale result not written back: even though track #2 returned a track object after release, cache rejected it.
        XCTAssertNotNil(session.subtitleCache[urls[0].absoluteString])
        XCTAssertNil(session.subtitleCache[urls[1].absoluteString], "Trigger \(trigger) allowed stale prewarm writeback")
        XCTAssertNil(session.subtitleCache[urls[2].absoluteString])
        session.stop()
    }

    @MainActor
    func testCacheHitSelectionCancelsInFlightUncachedLoadAndPreventsOverwrite() async throws {
        let urlA = URL(fileURLWithPath: "/tmp/uncached-a.srt")
        let urlB = URL(fileURLWithPath: "/tmp/cached-b.srt")
        let probe = SubtitleLoadProbe(pauseIndex: 1)
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/race.mkv"))
        session.currentTime = CMTime(seconds: 2.0, preferredTimescale: 600)
        session.companionSubtitles = [urlA, urlB]
        session.subtitleCache[urlB.absoluteString] = ExternalSubtitleTrack(cues: [.init(start: 1, end: 5, text: "Cached B")])
        session.externalSubtitleLoader = { url in await probe.load(url: url) }

        // 1. Primary track: start uncached A via loadExternalSubtitle, then select cached B via loadExternalSubtitle.
        session.loadExternalSubtitle(urlA, showFeedback: false)
        let inFlightPrimaryA = try XCTUnwrap(session.subtitleLoadTask)
        await probe.waitUntilPausedOnSecondTrack()
        session.loadExternalSubtitle(urlB, showFeedback: false)
        XCTAssertEqual(session.selectedSubtitleID, urlB.absoluteString)
        XCTAssertEqual(session.activeSubtitleText, "Cached B")
        await probe.releasePausedTrack()
        await inFlightPrimaryA.value
        let primaryStats = await probe.snapshot()
        XCTAssertTrue(primaryStats.observedTaskCancelledOnPausedTrack)
        XCTAssertEqual(session.selectedSubtitleID, urlB.absoluteString)
        XCTAssertEqual(session.activeSubtitleText, "Cached B")
        XCTAssertNil(session.subtitleCache[urlA.absoluteString])

        // 2. Secondary track: start uncached A via selectSecondarySubtitle, then select cached B via selectSecondarySubtitle.
        let secondaryProbe = SubtitleLoadProbe(pauseIndex: 1)
        session.externalSubtitleLoader = { url in await secondaryProbe.load(url: url) }
        session.selectSecondarySubtitle(urlA.absoluteString)
        let inFlightSecondaryA = try XCTUnwrap(session.secondarySubtitleLoadTask)
        await secondaryProbe.waitUntilPausedOnSecondTrack()
        session.selectSecondarySubtitle(urlB.absoluteString)
        XCTAssertEqual(session.selectedSecondarySubtitleID, urlB.absoluteString)
        XCTAssertEqual(session.activeSecondarySubtitleText, "Cached B")
        await secondaryProbe.releasePausedTrack()
        await inFlightSecondaryA.value
        let secondaryStats = await secondaryProbe.snapshot()
        XCTAssertTrue(secondaryStats.observedTaskCancelledOnPausedTrack)
        XCTAssertEqual(session.selectedSecondarySubtitleID, urlB.absoluteString)
        XCTAssertEqual(session.activeSecondarySubtitleText, "Cached B")
        session.stop()
    }

    @MainActor
    func testCachedSubtitleSwitchIsSynchronousWithoutLoadingSpinnerAndSupportsDualSubtitles() {
        defer { UserDefaults.standard.removeObject(forKey: SubtitleStyleConfiguration.defaultsKey) }
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/cached-sub.mkv"))
        session.subtitleStyle = SubtitleStyleConfiguration()
        session.embeddedSubtitles = [
            EmbeddedSubtitleTrack(id: 3, title: "简体中文", language: "zh", codec: "S_TEXT/UTF8", supported: true),
            EmbeddedSubtitleTrack(id: 4, title: "English", language: "en", codec: "S_TEXT/ASS", supported: true),
        ]
        session.subtitleCache["embedded:3"] = ExternalSubtitleTrack(cues: [.init(start: 1, end: 5, text: "你好")])
        session.subtitleCache["embedded:4"] = ExternalSubtitleTrack(cues: [.init(start: 1, end: 5, text: "Hello")])
        session.currentTime = CMTime(seconds: 2.0, preferredTimescale: 600)

        session.selectSubtitle("embedded:3")
        XCTAssertFalse(session.isSubtitleLoading)
        XCTAssertEqual(session.selectedSubtitleID, "embedded:3")
        XCTAssertEqual(session.activeSubtitleText, "你好")
        XCTAssertNotNil(session.osdMessage)

        session.selectSecondarySubtitle("embedded:4")
        XCTAssertEqual(session.selectedSecondarySubtitleID, "embedded:4")
        XCTAssertEqual(session.activeSecondarySubtitleText, "Hello")

        var style = session.subtitleStyle
        style.delay = 1.5
        style.scale = 1.5
        session.updateSubtitleStyle(style)
        XCTAssertEqual(session.activeSubtitleText, "")
        session.currentTime = CMTime(seconds: 3.0, preferredTimescale: 600)
        XCTAssertEqual(session.activeSubtitleText, "你好")
        XCTAssertEqual(session.activeSecondarySubtitleText, "Hello")
    }

    func testSubtitleStyleConfigurationClampingAndPersistence() throws {
        let suiteName = "com.metastudyline.ttmedia.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let custom = SubtitleStyleConfiguration(
            fontSize: 60,
            scale: 3.0,
            isBold: true,
            isItalic: true,
            textColor: .yellow,
            borderWidth: 8.0,
            backgroundOpacity: 0.99,
            verticalPosition: 5.0,
            delay: -15.0
        )
        XCTAssertEqual(custom.fontSize, 48.0)
        XCTAssertEqual(custom.scale, 2.0)
        XCTAssertEqual(custom.borderWidth, 4.0)
        XCTAssertEqual(custom.backgroundOpacity, 0.85)
        XCTAssertEqual(custom.verticalPosition, 10.0)
        XCTAssertEqual(custom.delay, -10.0)

        custom.saveToDefaults(defaults)
        let loaded = SubtitleStyleConfiguration.loadFromDefaults(defaults)
        XCTAssertEqual(loaded, custom)
    }

    @MainActor
    func testMidScanIncompletePrewarmRefusesPartialCacheAndSubsequentSelectionLoadsLateCues() async throws {
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/mid-scan-budget.mkv"))
        session.embeddedSubtitles = [
            EmbeddedSubtitleTrack(id: 3, title: "中文", language: "zh", codec: "S_TEXT/UTF8", supported: true),
            EmbeddedSubtitleTrack(id: 4, title: "English", language: "en", codec: "S_TEXT/UTF8", supported: true),
        ]
        let recorder = PrewarmRequestRecorder()
        session.externalSubtitleLoader = { _ in
            try? await Task.sleep(for: .milliseconds(120))
            return ExternalSubtitleTrack(cues: [.init(start: 0, end: 2, text: "Ext")])
        }
        session.embeddedSubtitleLoader = { track in
            await recorder.record(track)
            if VideoPlaybackSession.isPrewarmContainerRequest(track) {
                return Data("""
                {
                  "tracks": [
                    {"id": 3, "title": "中文", "language": "zh", "codec": "S_TEXT/UTF8", "supported": true},
                    {"id": 4, "title": "English", "language": "en", "codec": "S_TEXT/UTF8", "supported": true}
                  ],
                  "complete": false,
                  "trackCues": {
                    "3": [{"start": 1.0, "end": 2.0, "text": "前段字幕"}],
                    "4": [{"start": 1.0, "end": 2.0, "text": "Early cue"}]
                  }
                }
                """.utf8)
            }
            if track == 3 {
                return Data("""
                {
                  "cues": [
                    {"start": 1.0, "end": 2.0, "text": "前段字幕"},
                    {"start": 600.0, "end": 602.0, "text": "后段字幕"}
                  ]
                }
                """.utf8)
            }
            return Data("{\"cues\":[]}".utf8)
        }

        // 1. Prewarm with 1 external track + maxTracks = 2 leaves only 1 slot for embedded prewarm.
        // Must NOT bypass via track == 3; must encode targetTrackID == 3, maxTracks == 1, and remaining budget < 1500ms.
        let extURL = URL(fileURLWithPath: "/tmp/mid-scan-budget.srt")
        session.scheduleBackgroundSubtitlePrewarm(candidates: [extURL], others: [], budgetSeconds: 1.5, maxTracks: 2)
        await session.subtitlePrewarmTask?.value
        let recorded = await recorder.snapshot()
        XCTAssertEqual(recorded.count, 1)
        let decoded = try XCTUnwrap(VideoPlaybackSession.decodePrewarmContainerRequest(recorded[0]))
        XCTAssertEqual(decoded.targetTrackID, 3)
        XCTAssertEqual(decoded.maxTracks, 1)
        XCTAssertLessThan(decoded.budgetMs, 1450, "Embedded prewarm must receive remaining budget, not fresh 4000ms")
        XCTAssertNil(session.subtitleCache["embedded:3"], "Incomplete mid-scan prewarm must not enter subtitleCache")

        // 2. Explicit selection of track 3 sends track == 3 (unbounded user load) and loads both early and late cues.
        session.selectSubtitle("embedded:3", showFeedback: false)
        let loadTask = try XCTUnwrap(session.subtitleLoadTask)
        await loadTask.value
        let allRecorded = await recorder.snapshot()
        XCTAssertEqual(allRecorded.last, 3)
        session.currentTime = CMTime(seconds: 1.5, preferredTimescale: 600)
        XCTAssertEqual(session.activeSubtitleText, "前段字幕")
        session.currentTime = CMTime(seconds: 600.5, preferredTimescale: 600)
        XCTAssertEqual(session.activeSubtitleText, "后段字幕")
        session.stop()
    }

    @MainActor
    func testPrewarmEncodingBoundaryRejectsInt64MinOverflowAndUnrepresentableTrackIDs() async {
        // 1. Int64.min and negative non-prewarm sentinels must never overflow or decode as valid prewarm requests.
        XCTAssertNil(VideoPlaybackSession.decodePrewarmContainerRequest(Int64.min))
        XCTAssertNil(VideoPlaybackSession.decodePrewarmContainerRequest(-1))
        XCTAssertFalse(VideoPlaybackSession.isPrewarmContainerRequest(Int64.min))

        // 2. Track IDs <= 0 or exceeding UInt32.max must be rejected rather than truncated into another track.
        let overflowTrackID: Int64 = (1 << 32) + 3
        XCTAssertNil(VideoPlaybackSession.encodePrewarmContainerRequest(targetTrackID: 0 as UInt64, maxTracks: 1, budgetMs: 1200))
        XCTAssertNil(VideoPlaybackSession.encodePrewarmContainerRequest(targetTrackID: -5 as Int64, maxTracks: 1, budgetMs: 1200))
        XCTAssertNil(VideoPlaybackSession.encodePrewarmContainerRequest(targetTrackID: overflowTrackID, maxTracks: 1, budgetMs: 1200))
        XCTAssertNil(VideoPlaybackSession.encodePrewarmContainerRequest(targetTrackID: UInt64(overflowTrackID), maxTracks: 1, budgetMs: 1200))

        // 3. Valid boundary UInt32.max round-trips losslessly.
        let maxValid = UInt64(UInt32.max)
        let encodedMax = VideoPlaybackSession.encodePrewarmContainerRequest(targetTrackID: maxValid, maxTracks: 1, budgetMs: 1200)
        let decodedMax = encodedMax.flatMap { VideoPlaybackSession.decodePrewarmContainerRequest($0) }
        XCTAssertEqual(decodedMax?.targetTrackID, maxValid)
        XCTAssertEqual(decodedMax?.maxTracks, 1)
        XCTAssertEqual(decodedMax?.budgetMs, 1200)

        // 4. Session prewarm must refuse unrepresentable track IDs without invoking the container reader for track 3.
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/overflow-track.mkv"))
        session.embeddedSubtitles = [
            EmbeddedSubtitleTrack(id: overflowTrackID, title: "Overflow", language: "zh", codec: "S_TEXT/UTF8", supported: true)
        ]
        let recorder = PrewarmRequestRecorder()
        session.embeddedSubtitleLoader = { track in
            await recorder.record(track)
            return Data("{\"complete\":true,\"trackCues\":{\"3\":[{\"start\":1.0,\"end\":2.0,\"text\":\"Wrong Track 3\"}]}}".utf8)
        }
        session.scheduleBackgroundSubtitlePrewarm(candidates: [], others: [], budgetSeconds: 1.5, maxTracks: 1)
        await session.subtitlePrewarmTask?.value
        let recorded = await recorder.snapshot()
        XCTAssertTrue(recorded.isEmpty, "Unrepresentable track ID must never be truncated or sent to container reader")
        XCTAssertNil(session.subtitleCache["embedded:3"])
        XCTAssertNil(session.subtitleCache["embedded:\(overflowTrackID)"])
        session.stop()
    }
}

private actor PrewarmRequestRecorder {
    private var tracks: [Int64] = []
    func record(_ track: Int64) { tracks.append(track) }
    func snapshot() -> [Int64] { tracks }
}

private actor SubtitleLoadProbe {
    struct Snapshot: Sendable {
        let startedURLs: [URL]
        let observedTaskCancelledOnPausedTrack: Bool
    }

    private let pauseIndex: Int
    private var startedURLs: [URL] = []
    private var observedCancelled = false
    private var reachedPause = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(pauseIndex: Int) {
        self.pauseIndex = pauseIndex
    }

    func load(url: URL) async -> ExternalSubtitleTrack {
        startedURLs.append(url)
        if startedURLs.count == pauseIndex {
            reachedPause = true
            for waiter in pauseWaiters { waiter.resume() }
            pauseWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            observedCancelled = Task.isCancelled
        }
        return ExternalSubtitleTrack(cues: [.init(start: 1, end: 5, text: "Loaded \(url.lastPathComponent)")])
    }

    func waitUntilPausedOnSecondTrack() async {
        if reachedPause { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func releasePausedTrack() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(startedURLs: startedURLs, observedTaskCancelledOnPausedTrack: observedCancelled)
    }
}


