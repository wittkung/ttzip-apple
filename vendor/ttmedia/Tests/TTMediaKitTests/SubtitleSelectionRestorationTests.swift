// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import CoreMedia
import TTMediaDemux
@testable import TTMediaKit

final class SubtitleSelectionRestorationTests: XCTestCase {
    func testBitmapSubtitleTransportKeepsTimedClearAndImageCues() async throws {
        let response = Data(#"{"bitmapCuesV1":[{"start":4,"end":5,"canvasWidth":4,"canvasHeight":2,"compositions":[]},{"start":1,"end":3,"canvasWidth":4,"canvasHeight":2,"compositions":[{"x":1,"y":0,"width":2,"height":1,"pngBase64":"iVBORw0KGgo="}]}]}"#.utf8)
        let track = try await VideoPlaybackSession.decodeBitmapTrackOffMainActor(response)
        XCTAssertEqual(track.cues.count, 2)
        XCTAssertNil(track.activeCue(at: 0.5))
        XCTAssertEqual(track.activeCue(at: 1.5)?.cue.compositions.first?.pngBase64.count, 8)
        XCTAssertNil(track.activeCue(at: 3.5))
        XCTAssertTrue(try XCTUnwrap(track.activeCue(at: 4.5)).cue.compositions.isEmpty)
    }

    @MainActor
    func testSelectingEmbeddedPGSUsesBitmapLaneAndRejectsSecondarySelection() async throws {
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/pgs-selection-\(UUID()).mkv"))
        defer { session.stop() }
        session.embeddedSubtitles = [
            EmbeddedSubtitleTrack(id: 3, title: "PGS", language: "eng", codec: "S_HDMV/PGS", supported: true)
        ]
        session.embeddedSubtitleRequestLoader = { _, _ in
            Data(#"{"bitmapCuesV1":[{"start":1,"end":3,"canvasWidth":4,"canvasHeight":2,"compositions":[]}]}"#.utf8)
        }
        session.selectSubtitle("embedded:3", showFeedback: false)
        await waitForCompletion(session.subtitleLoadTask)
        XCTAssertEqual(session.selectedSubtitleID, "embedded:3")
        XCTAssertNotNil(session.bitmapSubtitleTrack)
        XCTAssertNil(session.subtitleTrack)
        session.selectSecondarySubtitle("embedded:3")
        XCTAssertEqual(session.selectedSecondarySubtitleID, "off")
    }

    @MainActor
    func testDefaultEmbeddedPGSLoadsThroughBitmapDecoder() async throws {
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/pgs-default-\(UUID()).mkv"))
        defer { session.stop() }
        session.embeddedSubtitleRequestLoader = { track, _ in
            if track == -1 {
                return Data(#"{"tracks":[{"id":3,"title":"PGS","language":"eng","codec":"S_HDMV/PGS","supported":true,"isDefault":true,"isForced":false}]}"#.utf8)
            }
            return Data(#"{"bitmapCuesV1":[{"start":1,"end":3,"canvasWidth":4,"canvasHeight":2,"compositions":[]}]}"#.utf8)
        }
        session.discoverSubtitles()
        await waitForCompletion(session.subtitleDiscoveryTask)
        XCTAssertEqual(session.selectedSubtitleID, "embedded:3")
        XCTAssertNotNil(session.bitmapSubtitleTrack)
        XCTAssertNil(session.subtitleTrack)
    }

    @MainActor
    func testDiscoveryRestorationReusesExternalSelectionsStartedBeforeOrDuringDiscovery() async throws {
        for selectionFirst in [true, false] {
            try await assertExternalSelectionsSurviveDiscovery(selectionFirst: selectionFirst)
        }
    }

    @MainActor
    private func assertExternalSelectionsSurviveDiscovery(selectionFirst: Bool) async throws {
        let video = FileManager.default.temporaryDirectory
            .appendingPathComponent("subtitle-restoration-\(UUID())", isDirectory: true)
            .appendingPathComponent("video.mkv")
        let session = VideoPlaybackSession(url: video)
        let primary = URL(fileURLWithPath: "/tmp/manual-primary-\(UUID()).srt")
        let secondary = URL(fileURLWithPath: "/tmp/manual-secondary-\(UUID()).srt")
        let catalogGate = SubtitleRestorationBarrier()
        let selectionGate = SubtitleRestorationBarrier()
        let calls = SubtitleRestorationCalls()
        let catalogStarted = expectation(description: "Catalog entered")
        let primaryStarted = expectation(description: "Primary entered")
        let secondaryStarted = expectation(description: "Secondary entered")
        session.currentTime = CMTime(seconds: 4.2, preferredTimescale: 600)
        session.companionSubtitles = [primary, secondary]
        session.embeddedSubtitleRequestLoader = { _, _ in
            catalogStarted.fulfill()
            await catalogGate.wait()
            return Data(#"{"tracks":[]}"#.utf8)
        }
        session.externalSubtitleLoader = { url in
            _ = await calls.record(url.absoluteString)
            if url == primary { primaryStarted.fulfill() } else { secondaryStarted.fulfill() }
            await selectionGate.wait()
            return ExternalSubtitleTrack(cues: [.init(start: 1, end: 9, text: url.lastPathComponent)])
        }
        defer {
            session.stop()
            Task { await catalogGate.release(); await selectionGate.release() }
        }
        if !selectionFirst {
            session.discoverSubtitles()
            await fulfillment(of: [catalogStarted], timeout: 2)
        }
        session.loadExternalSubtitle(primary, showFeedback: false)
        session.selectSecondarySubtitle(secondary.absoluteString)
        let primaryTask = try XCTUnwrap(session.subtitleLoadTask)
        let secondaryTask = try XCTUnwrap(session.secondarySubtitleLoadTask)
        await fulfillment(of: [primaryStarted, secondaryStarted], timeout: 2)
        if selectionFirst {
            session.discoverSubtitles()
            await fulfillment(of: [catalogStarted], timeout: 2)
        }
        let primaryGeneration = session.subtitleLoadGeneration
        let secondaryGeneration = session.secondarySubtitleLoadGeneration
        await catalogGate.release()
        await waitForCompletion(session.subtitleDiscoveryTask)
        session.restoreSelectedSubtitlesAfterDiscoveryIfNeeded()
        let counts = await calls.snapshot()
        XCTAssertEqual(counts[primary.absoluteString], 1)
        XCTAssertEqual(counts[secondary.absoluteString], 1)
        XCTAssertFalse(primaryTask.isCancelled)
        XCTAssertFalse(secondaryTask.isCancelled)
        XCTAssertEqual(session.subtitleLoadGeneration, primaryGeneration)
        XCTAssertEqual(session.secondarySubtitleLoadGeneration, secondaryGeneration)
        await selectionGate.release()
        await waitForCompletion(primaryTask)
        await waitForCompletion(secondaryTask)
        XCTAssertEqual(session.activeSubtitleText, primary.lastPathComponent)
        XCTAssertEqual(session.activeSecondarySubtitleText, secondary.lastPathComponent)
        XCTAssertNil(session.pendingPrimarySubtitleSelection)
        XCTAssertNil(session.pendingSecondarySubtitleSelection)
        XCTAssertNil(session.subtitleLoadTask)
        XCTAssertNil(session.secondarySubtitleLoadTask)
    }

    @MainActor
    func testRestorationReusesPendingEmbeddedSelectionsAndReleasesTheirOwnership() async throws {
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/embedded-restoration-\(UUID()).mkv"))
        let gate = SubtitleRestorationBarrier()
        let calls = SubtitleRestorationCalls()
        let started = expectation(description: "Both embedded lanes entered")
        started.expectedFulfillmentCount = 2
        session.currentTime = CMTime(seconds: 4.2, preferredTimescale: 600)
        session.embeddedSubtitles = [3, 4].map {
            EmbeddedSubtitleTrack(id: Int64($0), title: "Track \($0)", language: "en", codec: "S_TEXT/UTF8", supported: true)
        }
        session.embeddedSubtitleRequestLoader = { track, _ in
            _ = await calls.record(String(track))
            started.fulfill()
            await gate.wait()
            return Data("{\"cues\":[{\"start\":1,\"end\":9,\"text\":\"Track \(track)\"}]}".utf8)
        }
        defer { session.stop(); Task { await gate.release() } }
        session.selectSubtitle("embedded:3", showFeedback: false)
        session.selectSecondarySubtitle("embedded:4")
        let primaryTask = try XCTUnwrap(session.subtitleLoadTask)
        let secondaryTask = try XCTUnwrap(session.secondarySubtitleLoadTask)
        await fulfillment(of: [started], timeout: 2)
        session.restoreSelectedSubtitlesAfterDiscoveryIfNeeded()
        let counts = await calls.snapshot()
        XCTAssertEqual(counts, ["3": 1, "4": 1])
        XCTAssertFalse(primaryTask.isCancelled)
        XCTAssertFalse(secondaryTask.isCancelled)
        await gate.release()
        await waitForCompletion(primaryTask)
        await waitForCompletion(secondaryTask)
        XCTAssertEqual(session.activeSubtitleText, "Track 3")
        XCTAssertEqual(session.activeSecondarySubtitleText, "Track 4")
        XCTAssertNil(session.pendingPrimarySubtitleSelection)
        XCTAssertNil(session.pendingSecondarySubtitleSelection)
    }

    @MainActor
    func testFailedExternalSelectionClearsPendingOwnershipAndCanRetry() async throws {
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/retry-restoration-\(UUID()).mkv"))
        let primary = URL(fileURLWithPath: "/tmp/primary-\(UUID()).srt")
        let secondary = URL(fileURLWithPath: "/tmp/secondary-\(UUID()).srt")
        let calls = SubtitleRestorationCalls()
        session.currentTime = CMTime(seconds: 4.2, preferredTimescale: 600)
        session.companionSubtitles = [primary, secondary]
        session.externalSubtitleLoader = { url in
            if await calls.record(url.absoluteString) == 1 { throw CocoaError(.fileReadUnknown) }
            return ExternalSubtitleTrack(cues: [.init(start: 1, end: 9, text: "Retried")])
        }
        defer { session.stop() }
        session.loadExternalSubtitle(primary, showFeedback: false)
        session.selectSecondarySubtitle(secondary.absoluteString)
        await waitForCompletion(session.subtitleLoadTask)
        await waitForCompletion(session.secondarySubtitleLoadTask)
        XCTAssertNil(session.pendingPrimarySubtitleSelection)
        XCTAssertNil(session.pendingSecondarySubtitleSelection)
        XCTAssertNil(session.subtitleLoadTask)
        XCTAssertNil(session.secondarySubtitleLoadTask)
        session.loadExternalSubtitle(primary, showFeedback: false)
        session.selectSecondarySubtitle(secondary.absoluteString)
        await waitForCompletion(session.subtitleLoadTask)
        await waitForCompletion(session.secondarySubtitleLoadTask)
        XCTAssertEqual(session.activeSubtitleText, "Retried")
        XCTAssertEqual(session.activeSecondarySubtitleText, "Retried")
    }

    @MainActor
    func testCancelledOlderSelectionCannotClearTheNewerPendingLane() async throws {
        for secondary in [false, true] { try await assertCancelledSelectionOwnership(secondary: secondary) }
    }

    @MainActor
    private func waitForCompletion(_ task: Task<Void, Never>?) async {
        guard let task else { return }
        let completed = expectation(description: "Subtitle task completed")
        Task {
            await task.value
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 2)
    }

    @MainActor
    private func assertCancelledSelectionOwnership(secondary: Bool) async throws {
        let session = VideoPlaybackSession(url: URL(fileURLWithPath: "/tmp/cancel-restoration-\(UUID()).mkv"))
        let oldURL = URL(fileURLWithPath: "/tmp/old-\(UUID()).srt")
        let newURL = URL(fileURLWithPath: "/tmp/new-\(UUID()).srt")
        let oldGate = SubtitleRestorationBarrier()
        let newGate = SubtitleRestorationBarrier()
        let oldStarted = expectation(description: "Old selection entered")
        let newStarted = expectation(description: "New selection entered")
        session.companionSubtitles = [oldURL, newURL]
        session.externalSubtitleLoader = { url in
            if url == oldURL { oldStarted.fulfill(); await oldGate.wait() }
            else { newStarted.fulfill(); await newGate.wait() }
            return ExternalSubtitleTrack(cues: [.init(start: 1, end: 9, text: url.lastPathComponent)])
        }
        defer { session.stop(); Task { await oldGate.release(); await newGate.release() } }
        if secondary { session.selectSecondarySubtitle(oldURL.absoluteString) }
        else { session.loadExternalSubtitle(oldURL, showFeedback: false) }
        let oldTask = try XCTUnwrap(secondary ? session.secondarySubtitleLoadTask : session.subtitleLoadTask)
        await fulfillment(of: [oldStarted], timeout: 2)
        if secondary { session.selectSecondarySubtitle(newURL.absoluteString) }
        else { session.loadExternalSubtitle(newURL, showFeedback: false) }
        let newTask = try XCTUnwrap(secondary ? session.secondarySubtitleLoadTask : session.subtitleLoadTask)
        await fulfillment(of: [newStarted], timeout: 2)
        await oldGate.release()
        await waitForCompletion(oldTask)
        let pending = secondary ? session.pendingSecondarySubtitleSelection : session.pendingPrimarySubtitleSelection
        XCTAssertEqual(pending?.id, newURL.absoluteString)
        XCTAssertFalse(newTask.isCancelled)
        newTask.cancel()
        await newGate.release()
        await waitForCompletion(newTask)
        XCTAssertNil(secondary ? session.pendingSecondarySubtitleSelection : session.pendingPrimarySubtitleSelection)
        XCTAssertNil(secondary ? session.secondarySubtitleLoadTask : session.subtitleLoadTask)
    }
}

private actor SubtitleRestorationBarrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor SubtitleRestorationCalls {
    private var counts: [String: Int] = [:]

    func record(_ id: String) -> Int {
        counts[id, default: 0] += 1
        return counts[id, default: 0]
    }

    func snapshot() -> [String: Int] { counts }
}
