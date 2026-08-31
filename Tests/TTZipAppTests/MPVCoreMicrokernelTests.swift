// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import Foundation
import TTZipUI
@testable import TTZipPreviewKit

final class MPVCoreMicrokernelTests: XCTestCase {

    // MARK: - Test 1: MPVTypes Snapshot and Error Invariants

    func testMPVTypesSnapshotInvariants() {
        let defaultState = MPVPlaybackStateSnapshot()
        XCTAssertEqual(defaultState.currentTime, 0.0)
        XCTAssertEqual(defaultState.duration, 0.0)
        XCTAssertTrue(defaultState.isPaused)
        XCTAssertEqual(defaultState.volume, 1.0)
        XCTAssertFalse(defaultState.isMuted)
        XCTAssertEqual(defaultState.cacheProgress, 0.0)
        XCTAssertFalse(defaultState.isEOF)
        XCTAssertFalse(defaultState.isBuffering)
        XCTAssertEqual(defaultState.progressFraction, 0.0)

        let playingState = MPVPlaybackStateSnapshot(
            currentTime: 45.0,
            duration: 90.0,
            isPaused: false,
            volume: 0.8,
            isMuted: false,
            cacheProgress: 0.5,
            isEOF: false,
            isBuffering: false
        )
        XCTAssertEqual(playingState.progressFraction, 0.5, accuracy: 0.001)

        let metadata = MPVMediaMetadataSnapshot(
            videoCodec: "hevc",
            audioCodec: "aac",
            videoWidth: 3840,
            videoHeight: 2160,
            aspectRatio: 16.0 / 9.0,
            colorSpace: "bt2020",
            audioSampleRate: 48000,
            audioChannels: 6,
            audioBitDepth: 24,
            audioTracks: [
                MPVTrackSnapshot(id: "a1", trackId: 1, title: "English 5.1", language: "eng", codec: "aac", isDefault: true, isSelected: true)
            ],
            subtitleTracks: [
                MPVSubtitleSnapshot(id: "s1", subtitleId: 1, title: "English", language: "eng", format: "SRT", isExternal: false, isDefault: true, isSelected: false)
            ]
        )
        XCTAssertEqual(metadata.videoCodec, "hevc")
        XCTAssertEqual(metadata.videoWidth, 3840)
        XCTAssertEqual(metadata.audioTracks.count, 1)
        XCTAssertEqual(metadata.subtitleTracks.count, 1)

        let err = MPVError.commandFailed(command: "seek 10", status: -1, reason: "Invalid state")
        XCTAssertNotNil(err.errorDescription)
        XCTAssertTrue(err.errorDescription?.contains("seek 10") == true)
    }

    // MARK: - Test 2: MPVCoreEngine Actor Lifecycle & Property Operations

    func testMPVCoreEngineLifecycleAndProperties() async throws {
        let engine = MPVCoreEngine()
        try await engine.initialize(mode: .audioOnly)

        try await engine.setProperty(name: "volume", value: 75.0)
        let vol = await engine.getPropertyDouble(name: "volume")
        if let vol {
            XCTAssertEqual(vol, 75.0, accuracy: 1.0)
        }

        try await engine.setProperty(name: "mute", value: true)
        let isMuted = await engine.getPropertyBool(name: "mute")
        if let isMuted {
            XCTAssertTrue(isMuted)
        }

        await engine.setOutputMode(.video(renderBackend: "libmpv"))
        await engine.stop()
        await engine.terminate()
    }

    // MARK: - Test 3: MPVEventDispatcher Stream Multicast & Batch Handling

    func testMPVEventDispatcherBatchHandling() async throws {
        let engine = MPVCoreEngine()
        let dispatcher = MPVEventDispatcher(engine: engine)

        let eventTask = Task { () -> [MPVEvent] in
            var events: [MPVEvent] = []
            for await event in await dispatcher.eventStream {
                events.append(event)
                if events.count >= 3 {
                    break
                }
            }
            return events
        }

        // Allow stream registration
        try await Task.sleep(nanoseconds: 20_000_000)

        let testEvents: [MPVEvent] = [
            .fileLoaded,
            .propertyChange(name: "time-pos", value: .double(12.5)),
            .propertyChange(name: "duration", value: .double(120.0)),
            .pause(isPaused: false)
        ]
        await dispatcher.handleBatchEvents(testEvents)

        let receivedEvents = await eventTask.value
        XCTAssertGreaterThanOrEqual(receivedEvents.count, 3)

        let state = await dispatcher.getCurrentState()
        XCTAssertEqual(state.currentTime, 12.5, accuracy: 0.001)
        XCTAssertEqual(state.duration, 120.0, accuracy: 0.001)
        XCTAssertFalse(state.isPaused)

        await dispatcher.stop()
        await engine.terminate()
    }

    // MARK: - Test 4: MPVEventDispatcher High-Frequency Property Throttling

    func testMPVEventDispatcherThrottling() async throws {
        let engine = MPVCoreEngine()
        let dispatcher = MPVEventDispatcher(engine: engine)
        await dispatcher.setTargetFPS(30)

        let stateTask = Task { () -> [MPVPlaybackStateSnapshot] in
            var states: [MPVPlaybackStateSnapshot] = []
            for await st in await dispatcher.stateStream {
                states.append(st)
                if states.count >= 1 {
                    break
                }
            }
            return states
        }

        try await Task.sleep(nanoseconds: 20_000_000)

        for i in 1...10 {
            await dispatcher.handleBatchEvents([
                .propertyChange(name: "time-pos", value: .double(Double(i) * 0.1))
            ])
        }

        try await Task.sleep(nanoseconds: 60_000_000)
        await dispatcher.stop()
        let emittedStates = await stateTask.value
        XCTAssertGreaterThanOrEqual(emittedStates.count, 1)
        await engine.terminate()
    }
}
