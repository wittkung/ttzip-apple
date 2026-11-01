// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

/// Master playback coordinator governing `AVSampleBufferDisplayLayer` and `AVSampleBufferAudioRenderer`
/// under a single `AVSampleBufferRenderSynchronizer` clock source (`CMTimebase` SSOT).
///
/// Implements hardware decode presentation, frame-accurate synchronization within ATSC IS-191 tolerances,
/// and preroll seek suppression using `kCMSampleAttachmentKey_DoNotDisplay = true` to decode reference frames
/// without visual tearing or stutter.
@MainActor
public final class AVSampleBufferPlayerCoordinator: ObservableObject {
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "AVSampleBufferPlayerCoordinator")

    // MARK: - Presentation Pipeline Components

    public let displayLayer: AVSampleBufferDisplayLayer
    public let audioRenderer: AVSampleBufferAudioRenderer
    public let synchronizer: AVSampleBufferRenderSynchronizer

    // MARK: - Playback State Properties

    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentTime: CMTime = .zero
    @Published public private(set) var duration: CMTime = .zero
    @Published public var playbackRate: Float = 1.0 {
        didSet {
            handlePlaybackRateChange(playbackRate)
        }
    }
    @Published public var volume: Float = 1.0 {
        didSet {
            audioRenderer.volume = max(0.0, min(1.0, volume))
        }
    }
    @Published public var isMuted: Bool = false {
        didSet {
            audioRenderer.isMuted = isMuted
        }
    }
    @Published public private(set) var isSeeking: Bool = false
    @Published public private(set) var isPrerolling: Bool = false
    public private(set) var userPlaybackIntent: Bool = false
    public private(set) var seekGeneration: UInt64 = 0
    public private(set) var preTargetSuppressedFrameCount: Int = 0
    public private(set) var firstVisibleFramePTSAfterSeek: CMTime?
    public private(set) var prerollBackpressureDrainCount: Int = 0

    // MARK: - Preroll & Seek Internal State

    private var inputEndTime: CMTime?
    private var targetSeekTime: CMTime?
    private var wasPlayingBeforeSeek: Bool = false
    internal private(set) var hasAnchoredInitialFrame: Bool = false

    // MARK: - Time Observation

    private var periodicTimeObserverToken: Any?
    private var isPipelineTornDown: Bool = false

    // MARK: - Callbacks

    public var onTimeUpdate: (@MainActor (CMTime) -> Void)?
    public var onPlaybackEnded: (@MainActor () -> Void)?
    public var onError: (@MainActor (Error) -> Void)?
    public var onVideoSampleEnqueued: (@MainActor (CMSampleBuffer) -> Void)?
    public var onFirstVideoFrameEnqueued: (@MainActor (CMTime) -> Void)?
    public var onSeekCompleted: (@MainActor (CMTime, UInt64) -> Void)?
    public var onPrerollQueueDrained: (@MainActor () -> Void)?
    internal var onInternalPresentationTimeChanged: (@MainActor (CMTime) -> Void)?

    // MARK: - Initialization & Teardown

    @MainActor
    public init(
        displayLayer: AVSampleBufferDisplayLayer,
        audioRenderer: AVSampleBufferAudioRenderer,
        synchronizer: AVSampleBufferRenderSynchronizer
    ) {
        self.displayLayer = displayLayer
        self.audioRenderer = audioRenderer
        self.synchronizer = synchronizer

        self.displayLayer.videoGravity = .resizeAspect
        attachRenderers()
        installPeriodicTimeObserver()
    }

    @MainActor
    public convenience init() {
        self.init(
            displayLayer: AVSampleBufferDisplayLayer(),
            audioRenderer: AVSampleBufferAudioRenderer(),
            synchronizer: AVSampleBufferRenderSynchronizer()
        )
    }

    isolated deinit {
        teardownPipeline()
    }

    // MARK: - Renderer Attachment

    private func attachRenderers() {
        isPipelineTornDown = false
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
    }

    private func teardownPipeline() {
        guard !isPipelineTornDown else { return }
        isPipelineTornDown = true
        removePeriodicTimeObserver()
        synchronizer.setRate(0.0, time: currentTime)
        displayLayer.stopRequestingMediaData()
        displayLayer.flush()
        audioRenderer.stopRequestingMediaData()
        audioRenderer.flush()
        synchronizer.removeRenderer(displayLayer.sampleBufferRenderer, at: .invalid)
        synchronizer.removeRenderer(audioRenderer, at: .invalid)
    }

    // MARK: - Public Playback Controls

    /// Starts or resumes playback at the current playback rate.
    public func play() {
        userPlaybackIntent = true
        wasPlayingBeforeSeek = true
        guard isReady else { return }
        if duration > .zero && currentTime >= duration {
            seek(to: .zero, preroll: false)
        }
        isPlaying = true
        if !isPrerolling {
            let effectiveRate = playbackRate > 0 ? playbackRate : 1.0
            synchronizer.setRate(effectiveRate, time: currentTime)
        }
    }

    /// Pauses playback and halts the master timebase.
    public func pause() {
        userPlaybackIntent = false
        wasPlayingBeforeSeek = false
        synchronizer.setRate(0.0, time: currentTime)
        isPlaying = false
    }

    /// Toggles between playing and paused states.
    public func togglePlayPause() {
        if isPlaying || userPlaybackIntent {
            pause()
        } else {
            play()
        }
    }

    /// Explicitly updates the user's playback intent (e.g., on initial load with `autoPlay`).
    public func setUserPlaybackIntent(_ intendedPlaying: Bool) {
        userPlaybackIntent = intendedPlaying
        wasPlayingBeforeSeek = intendedPlaying
    }

    /// Prepares the coordinator for playback with a known duration.
    public func prepare(duration: CMTime, readyImmediately: Bool = true) {
        self.duration = duration
        inputEndTime = nil
        hasAnchoredInitialFrame = false
        self.isReady = readyImmediately
        if !readyImmediately {
            self.isPlaying = false
        }
        if !isPlaying {
            synchronizer.setRate(0.0, time: .zero)
        }
    }

    /// Marks the coordinator ready once the first media sample is enqueued and honors userPlaybackIntent.
    public func markReadyAndApplyPlaybackIntent() {
        guard !isReady else { return }
        isReady = true
        if isSeeking || isPrerolling {
            completeSeek(at: targetSeekTime ?? currentTime)
        } else if userPlaybackIntent {
            play()
        }
    }

    /// Marks terminal playback failure so the coordinator cannot remain ready or playing.
    public func markTerminalFailure() {
        pause()
        isReady = false
        isSeeking = false
        isPrerolling = false
        targetSeekTime = nil
    }

    /// Resets playback state and flushes hardware renderers.
    public func reset() {
        pause()
        displayLayer.flush()
        audioRenderer.flush()
        currentTime = .zero
        duration = .zero
        isReady = false
        isSeeking = false
        isPrerolling = false
        hasAnchoredInitialFrame = false
        targetSeekTime = nil
    }

    /// Dismisses the coordinator and fully cleans up renderers and observers.
    public func teardown() {
        teardownPipeline()
        isReady = false
        isPlaying = false
        userPlaybackIntent = false
        wasPlayingBeforeSeek = false
        isSeeking = false
        isPrerolling = false
        hasAnchoredInitialFrame = false
        targetSeekTime = nil
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
    }

    // MARK: - Seeking & Preroll Suppression (R4)

    /// Records the start of a seek immediately before async transport operations so consecutive seeks
    /// and in-flight play/pause toggles preserve accurate playback intent.
    @discardableResult
    public func beginSeekIntent(to targetTime: CMTime) -> UInt64 {
        seekGeneration &+= 1
        inputEndTime = nil
        preTargetSuppressedFrameCount = 0
        firstVisibleFramePTSAfterSeek = nil
        prerollBackpressureDrainCount = 0
        let intendedPlaying = (isSeeking || isPrerolling) ? wasPlayingBeforeSeek : (isPlaying || userPlaybackIntent)
        self.wasPlayingBeforeSeek = intendedPlaying
        self.userPlaybackIntent = intendedPlaying

        let clampedTarget = clampTimeToDuration(targetTime)
        synchronizer.setRate(0.0, time: clampedTarget)
        isPlaying = isReady ? intendedPlaying : false

        displayLayer.flush()
        audioRenderer.flush()

        self.currentTime = clampedTarget
        self.isSeeking = true
        self.targetSeekTime = clampedTarget
        self.isPrerolling = true
        onTimeUpdate?(clampedTarget)
        return seekGeneration
    }

    /// Seeks to the specified target presentation timestamp.
    ///
    /// When `preroll` is enabled, frames arriving prior to `targetTime` (PTS < targetTime)
    /// are tagged with `kCMSampleAttachmentKey_DoNotDisplay = true` so VideoToolbox primes
    /// decoding reference buffers without displaying stale or transitional frames.
    public func seek(to targetTime: CMTime, preroll: Bool = true, preserveCurrentIntent: Bool = false) {
        if !preserveCurrentIntent {
            seekGeneration &+= 1
            preTargetSuppressedFrameCount = 0
            firstVisibleFramePTSAfterSeek = nil
            prerollBackpressureDrainCount = 0
        }
        inputEndTime = nil
        let intendedPlaying: Bool
        if preserveCurrentIntent {
            intendedPlaying = userPlaybackIntent
        } else {
            intendedPlaying = (isSeeking || isPrerolling) ? wasPlayingBeforeSeek : (isPlaying || userPlaybackIntent)
        }
        self.wasPlayingBeforeSeek = intendedPlaying
        self.userPlaybackIntent = intendedPlaying

        let clampedTarget = clampTimeToDuration(targetTime)
        // Halt master clock immediately during seek while preserving logical play/pause intent
        synchronizer.setRate(0.0, time: clampedTarget)
        isPlaying = isReady ? intendedPlaying : false

        // Flush hardware renderers to prevent stale frame artifacts
        displayLayer.flush()
        audioRenderer.flush()

        self.currentTime = clampedTarget
        self.isSeeking = true
        self.targetSeekTime = clampedTarget
        self.isPrerolling = preroll

        if !preroll {
            completeSeek(at: clampedTarget)
        }
        onTimeUpdate?(clampedTarget)
    }

    /// Input EOF fixes an end boundary without prematurely stopping queued presentation.
    public func finishInput(at lastSampleEnd: CMTime) {
        let end = duration.isNumeric && duration > .zero ? duration : lastSampleEnd
        if isSeeking || isPrerolling {
            let rawTarget = targetSeekTime ?? currentTime
            let safeResume: CMTime
            if end.isNumeric && end > .zero && CMTimeCompare(rawTarget, end) >= 0 {
                let backoffSeconds = max(0.0, CMTimeGetSeconds(end) - 0.05)
                safeResume = CMTime(seconds: backoffSeconds, preferredTimescale: end.timescale > 0 ? end.timescale : 600)
            } else {
                safeResume = rawTarget
            }
            completeSeek(at: safeResume)
        }
        inputEndTime = end
        updateCurrentTime(synchronizer.currentTime())
    }

    /// Drains saturated pre-target (`kCMSampleAttachmentKey_DoNotDisplay = true`) frames from the display layer
    /// when a long GOP exceeds the video queue capacity before `targetSeekTime` is reached.
    /// Strictly preserves `isPrerolling == true`, `isSeeking == true`, `targetSeekTime`, and `currentTime`
    /// so pre-target frames are never displayed and playback never jumps back to an earlier timestamp.
    public func drainPrerollVideoQueueForBackpressure() {
        guard isPrerolling, targetSeekTime != nil else { return }
        prerollBackpressureDrainCount += 1
        displayLayer.flush()
        onPrerollQueueDrained?()
    }

    /// Returns true if an incoming audio packet precedes the active preroll target time and should be dropped
    /// before waiting on or enqueuing to `AVSampleBufferAudioRenderer`.
    public func shouldDiscardPrerollAudio(pts: CMTime, duration: CMTime = .zero) -> Bool {
        guard isPrerolling, let targetTime = targetSeekTime, pts.isValid else { return false }
        let endPTS = (duration.isNumeric && duration > .zero) ? CMTimeAdd(pts, duration) : pts
        return CMTimeCompare(endPTS, targetTime) <= 0 && CMTimeCompare(pts, targetTime) < 0
    }

    /// Relative seek convenience jumping by delta seconds.
    public func seek(by seconds: Double, preroll: Bool = true) {
        let currentSec = CMTimeGetSeconds(currentTime)
        let targetSec = max(0.0, currentSec + seconds)
        let timescale = duration.timescale > 0 ? duration.timescale : 600
        let targetTime = CMTime(seconds: targetSec, preferredTimescale: timescale)
        seek(to: targetTime, preroll: preroll)
    }

    /// Evaluates and tags incoming video sample buffer during seeking.
    ///
    /// Frames with PTS < targetSeekTime are marked with `kCMSampleAttachmentKey_DoNotDisplay = true`.
    /// When the target frame arrives, suppression is lifted and playback resumes.
    public func processSampleBufferForPreroll(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
        guard isPrerolling, let targetTime = targetSeekTime else {
            return sampleBuffer
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dur = CMSampleBufferGetDuration(sampleBuffer)
        let frameEnd = (pts.isValid && dur.isNumeric && dur > .zero) ? CMTimeAdd(pts, dur) : pts
        if pts.isValid && CMTimeCompare(pts, targetTime) < 0 && CMTimeCompare(frameEnd, targetTime) <= 0 {
            preTargetSuppressedFrameCount += 1
            Self.setDoNotDisplayAttachment(on: sampleBuffer, doNotDisplay: true)
        } else {
            Self.setDoNotDisplayAttachment(on: sampleBuffer, doNotDisplay: false)
            isReady = true
            if firstVisibleFramePTSAfterSeek == nil {
                firstVisibleFramePTSAfterSeek = pts
            }
            let resumeTime = (pts.isValid && CMTimeCompare(pts, targetTime) > 0) ? pts : targetTime
            completeSeek(at: resumeTime)
        }
        return sampleBuffer
    }

    /// Enqueues a video sample buffer to the display layer with automatic preroll suppression.
    public func enqueueVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        let processed = processSampleBufferForPreroll(sampleBuffer)
        let isDoNotDisplay = Self.isDoNotDisplayAttachmentSet(on: processed)
        let isFirstDisplayableFrame = !hasAnchoredInitialFrame && !isDoNotDisplay
        let pts = CMSampleBufferGetPresentationTimeStamp(processed)
        if isFirstDisplayableFrame {
            hasAnchoredInitialFrame = true
            markReadyAndApplyPlaybackIntent()
            if !isPlaying, !isSeeking, pts.isNumeric, CMTimeGetSeconds(currentTime) <= 0.001 {
                synchronizer.setRate(0.0, time: pts)
                currentTime = pts
            }
        }
        displayLayer.enqueue(processed)
        onVideoSampleEnqueued?(processed)
        if isFirstDisplayableFrame {
            onFirstVideoFrameEnqueued?(pts)
        }
    }

    /// Returns true if `kCMSampleAttachmentKey_DoNotDisplay` is set on the sample buffer.
    nonisolated public static func isDoNotDisplayAttachmentSet(on sampleBuffer: CMSampleBuffer) -> Bool {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let keyPtr = Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque()
            if let valPtr = CFDictionaryGetValue(dict, keyPtr) {
                let cfBool = unsafeBitCast(valPtr, to: CFBoolean.self)
                if CFBooleanGetValue(cfBool) { return true }
            }
        }
        if let attached = CMGetAttachment(sampleBuffer, key: kCMSampleAttachmentKey_DoNotDisplay, attachmentModeOut: nil) {
            if CFGetTypeID(attached) == CFBooleanGetTypeID() {
                return CFBooleanGetValue(unsafeBitCast(attached, to: CFBoolean.self))
            }
        }
        return false
    }

    /// Returns true if `kCMSampleAttachmentKey_DisplayImmediately` is set on the sample buffer.
    nonisolated public static func isDisplayImmediatelyAttachmentSet(on sampleBuffer: CMSampleBuffer) -> Bool {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let keyPtr = Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque()
            if let valPtr = CFDictionaryGetValue(dict, keyPtr) {
                let cfBool = unsafeBitCast(valPtr, to: CFBoolean.self)
                if CFBooleanGetValue(cfBool) { return true }
            }
        }
        if let attached = CMGetAttachment(sampleBuffer, key: kCMSampleAttachmentKey_DisplayImmediately, attachmentModeOut: nil) {
            if CFGetTypeID(attached) == CFBooleanGetTypeID() {
                return CFBooleanGetValue(unsafeBitCast(attached, to: CFBoolean.self))
            }
        }
        return false
    }

    /// Enqueues an audio sample buffer to the audio renderer, discarding pre-seek preroll frames.
    public func enqueueAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let dur = CMSampleBufferGetDuration(sampleBuffer)
        if shouldDiscardPrerollAudio(pts: pts, duration: dur) {
            return
        }
        audioRenderer.enqueue(sampleBuffer)
    }

    /// Marks or clears the `kCMSampleAttachmentKey_DoNotDisplay` CoreMedia attachment.
    nonisolated public static func setDoNotDisplayAttachment(on sampleBuffer: CMSampleBuffer, doNotDisplay: Bool) {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let count = CFArrayGetCount(attachments)
            for index in 0..<count {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, index), to: CFMutableDictionary.self)
                if doNotDisplay {
                    CFDictionarySetValue(
                        dict,
                        Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(),
                        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                    )
                } else {
                    CFDictionaryRemoveValue(
                        dict,
                        Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque()
                    )
                }
            }
        }

        if doNotDisplay {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_DoNotDisplay,
                value: kCFBooleanTrue,
                attachmentMode: kCMAttachmentMode_ShouldPropagate
            )
        } else {
            CMRemoveAttachment(sampleBuffer, key: kCMSampleAttachmentKey_DoNotDisplay)
        }
    }

    // MARK: - Private Helpers

    private func completeSeek(at presentationTime: CMTime) {
        let completedGeneration = seekGeneration
        let shouldResume = wasPlayingBeforeSeek || userPlaybackIntent
        isPrerolling = false
        isSeeking = false
        targetSeekTime = nil
        currentTime = presentationTime

        if isReady && shouldResume {
            let rateToResume = playbackRate > 0 ? playbackRate : 1.0
            synchronizer.setRate(rateToResume, time: presentationTime)
            isPlaying = true
        } else {
            synchronizer.setRate(0.0, time: presentationTime)
            isPlaying = false
        }
        onInternalPresentationTimeChanged?(presentationTime)
        onSeekCompleted?(presentationTime, completedGeneration)
    }

    private func clampTimeToDuration(_ time: CMTime) -> CMTime {
        let targetSec = max(0.0, CMTimeGetSeconds(time))
        let maxSec = duration > .zero ? CMTimeGetSeconds(duration) : targetSec
        let clampedSec = min(targetSec, maxSec)
        let timescale = time.timescale > 0 ? time.timescale : (duration.timescale > 0 ? duration.timescale : 600)
        return CMTime(seconds: clampedSec, preferredTimescale: timescale)
    }

    private func handlePlaybackRateChange(_ rate: Float) {
        if isPlaying && !isPrerolling {
            synchronizer.setRate(rate, time: synchronizer.currentTime())
        }
    }

    // MARK: - Periodic Time Observation & Heartbeat

    private func installPeriodicTimeObserver() {
        removePeriodicTimeObserver()
        let interval = CMTime(value: 1, timescale: 30)
        periodicTimeObserverToken = synchronizer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.updateCurrentTime(time)
            }
        }
    }

    private func removePeriodicTimeObserver() {
        if let token = periodicTimeObserverToken {
            synchronizer.removeTimeObserver(token)
            periodicTimeObserverToken = nil
        }
    }

    private func updateCurrentTime(_ time: CMTime) {
        guard !isSeeking, time.isValid else { return }
        self.currentTime = time
        self.onInternalPresentationTimeChanged?(time)
        self.onTimeUpdate?(time)
        let end = inputEndTime ?? duration
        if isPlaying, end.isNumeric, end > .zero, CMTimeCompare(time, end) >= 0 {
            handlePlaybackEnded()
        }
    }

    private func handlePlaybackEnded() {
        pause()
        onPlaybackEnded?()
    }
}
