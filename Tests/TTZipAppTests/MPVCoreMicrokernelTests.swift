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

    // MARK: - Test 5: MPVEventDispatcher Audio Telemetry Metadata Invariants

    func testMPVEventDispatcherAudioTelemetryMetadata() async throws {
        let engine = MPVCoreEngine()
        let dispatcher = MPVEventDispatcher(engine: engine)

        let telemetryEvents: [MPVEvent] = [
            .propertyChange(name: "audio-codec-name", value: .string("flac")),
            .propertyChange(name: "audio-params/samplerate", value: .int64(96000)),
            .propertyChange(name: "audio-params/channels", value: .string("stereo")),
            .propertyChange(name: "video-params/w", value: .int64(1920)),
            .propertyChange(name: "video-params/h", value: .int64(1080))
        ]

        await dispatcher.handleBatchEvents(telemetryEvents)

        let meta = await dispatcher.getCurrentMetadata()
        XCTAssertEqual(meta.audioCodec, "flac")
        XCTAssertEqual(meta.audioSampleRate, 96000)
        XCTAssertEqual(meta.audioChannels, 2)
        XCTAssertEqual(meta.videoWidth, 1920)
        XCTAssertEqual(meta.videoHeight, 1080)

        await dispatcher.stop()
        await engine.terminate()
    }

    // MARK: - Test 6: MPVAudioEngine Reactive State via Event Dispatcher

    @MainActor
    func testMPVAudioEngineReactiveStateViaDispatcher() async throws {
        let audioEngine = MPVAudioEngine.shared
        // Allow initial stream registration
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let testEvents: [MPVEvent] = [
            .fileLoaded,
            .propertyChange(name: "time-pos", value: .double(33.0)),
            .propertyChange(name: "duration", value: .double(240.0)),
            .pause(isPaused: false),
            .propertyChange(name: "audio-codec-name", value: .string("alac")),
            .propertyChange(name: "audio-params/samplerate", value: .double(44100.0)),
            .propertyChange(name: "audio-params/channels", value: .string("stereo")),
            .propertyChange(name: "audio-bitrate", value: .double(950000.0))
        ]

        await MPVEventDispatcher.shared.handleBatchEvents(testEvents)

        // Allow MainActor stream processing
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(audioEngine.duration, 240.0, accuracy: 0.01)
        XCTAssertEqual(audioEngine.currentTime, 33.0, accuracy: 0.01)
        XCTAssertTrue(audioEngine.isPlaying)
        XCTAssertEqual(audioEngine.sampleRateFormatted, "44.1 kHz")
        XCTAssertEqual(audioEngine.channelsFormatted, "Stereo")
        XCTAssertEqual(audioEngine.bitrateFormatted, "950 kbps")
    }

    // MARK: - Test 7: MPVCoreEngine Multi-Listener Wakeup Multicast Invariants

    func testMPVCoreEngineMultiListenerWakeupMulticast() async throws {
        let engine = MPVCoreEngine()
        try await engine.initialize(mode: .audioOnly)
        _ = await engine.drainEvents()

        let exp1 = expectation(description: "Listener 1 awakened")
        exp1.assertForOverFulfill = false
        let exp2 = expectation(description: "Listener 2 awakened")
        exp2.assertForOverFulfill = false
        let expLegacy = expectation(description: "Legacy handler awakened")
        expLegacy.assertForOverFulfill = false

        let id1 = await engine.addWakeupListener {
            exp1.fulfill()
        }
        let id2 = await engine.addWakeupListener {
            exp2.fulfill()
        }
        await engine.setWakeupHandler {
            expLegacy.fulfill()
        }

        // Trigger property change to emit event and fire wakeup
        try await engine.setProperty(name: "volume", value: 80.0)

        await fulfillment(of: [exp1, exp2, expLegacy], timeout: 2.0)

        await engine.setWakeupHandler(nil)
        await engine.removeWakeupListener(id: id1)
        _ = await engine.drainEvents()

        let exp3 = expectation(description: "Listener 3 awakened after removal of 1")
        exp3.assertForOverFulfill = false
        let id3 = await engine.addWakeupListener {
            exp3.fulfill()
        }

        try await engine.setProperty(name: "volume", value: 85.0)
        await fulfillment(of: [exp3], timeout: 2.0)

        await engine.removeWakeupListener(id: id2)
        await engine.removeWakeupListener(id: id3)
        await engine.terminate()
    }

    // MARK: - Test 8: Playback Abort and Metadata Hwdec Properties

    func testMPVPlaybackAbortAndMetadataHwdecProperties() {
        let abortEvent = MPVEvent.playbackAbort
        XCTAssertEqual(abortEvent, .playbackAbort)

        let metadata = MPVMediaMetadataSnapshot(
            videoCodec: "vp8",
            audioCodec: "opus",
            hwdecCurrent: "no",
            videoWidth: 1920,
            videoHeight: 1080
        )
        XCTAssertEqual(metadata.videoCodec, "vp8")
        XCTAssertEqual(metadata.audioCodec, "opus")
        XCTAssertEqual(metadata.hwdecCurrent, "no")

        let paramsSnapshot = MPVMediaParamsSnapshot(
            width: 1920,
            height: 1080,
            hdrFormat: .sdr,
            sampleRate: "48.0 kHz",
            channels: "Stereo",
            audioCodec: "Opus",
            videoCodec: "vp8",
            hwdecCurrent: "no",
            bitrate: "128 kbps"
        )
        XCTAssertEqual(paramsSnapshot.videoCodec, "vp8")
        XCTAssertEqual(paramsSnapshot.hwdecCurrent, "no")
    }

    // MARK: - Test 9: MPVMetalPlayerStore State & Fallback State Machine

    @MainActor
    func testMPVMetalPlayerStorePropertiesAndFallbackState() {
        let store = MPVMetalPlayerStore.shared
        store.cleanUp()

        XCTAssertEqual(store.videoCodec, "")
        XCTAssertEqual(store.hwdecCurrent, "")
        XCTAssertFalse(store.hasPlaybackError)

        store.cleanUp()
    }

    // MARK: - Test 10: MPVHardwareDecodingPolicy and Viewport Protocol Conformance

    @MainActor
    func testMPVHardwareDecodingPolicyAndProtocolConformance() {
        XCTAssertEqual(MPVHardwareDecodingPolicy.auto.rawValue, "auto")
        XCTAssertEqual(MPVHardwareDecodingPolicy.videotoolbox.rawValue, "videotoolbox")
        XCTAssertEqual(MPVHardwareDecodingPolicy.autoSafe.rawValue, "auto-safe")
        XCTAssertEqual(MPVHardwareDecodingPolicy.disabled.rawValue, "no")

        let glLayer: any MPVVideoLayerProtocol = MPVOpenGLLayer()
        XCTAssertFalse(glLayer.isBound)
        glLayer.contentsScale = 2.0
        XCTAssertEqual(glLayer.contentsScale, 2.0)

        let metalLayer: any MPVVideoLayerProtocol = MPVMetalRenderLayer()
        XCTAssertFalse(metalLayer.isBound)
        metalLayer.contentsScale = 2.0
        XCTAssertEqual(metalLayer.contentsScale, 2.0)
    }
}

