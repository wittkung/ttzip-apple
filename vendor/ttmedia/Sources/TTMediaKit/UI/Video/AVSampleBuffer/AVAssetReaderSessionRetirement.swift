// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import os

/// Internal observation seam and per-session retirement state for `AVAssetReaderPlaybackController`.
///
/// Enforces:
/// 1. Exactly-once retirement initiation per `SessionState` (`beginRetirementIfNeeded()`);
/// 2. Two-boolean derived cross-queue quiescence barrier (`didRetireVideoQueue && didRetireAudioQueue`)
///    without redundant counters, ensuring `reader.cancelReading()` is never invoked while either
///    `videoOutput.copyNextSampleBuffer()` or `audioOutput.copyNextSampleBuffer()` is in flight;
/// 3. Single-slot pending start coalescing (`PendingStartRequest`) so rapid seeks or re-loads while
///    an old session is retiring never accumulate multiple `AVAssetReader` instances or retirement closures.
extension AVAssetReaderPlaybackController {
    internal struct NativeReaderLifecycleProbe: Sendable {
        internal enum MediaKind: String, Sendable {
            case video
            case audio
        }

        internal var didCreateSession: (@Sendable (_ sessionID: UUID) -> Void)?
        internal var willCopyNextSampleBuffer: (@Sendable (_ sessionID: UUID, _ kind: MediaKind) -> Void)?
        internal var didCopyNextSampleBuffer: (@Sendable (_ sessionID: UUID, _ kind: MediaKind, _ hasBuffer: Bool) -> Void)?
        internal var transformCopiedVideoSampleBuffer: (@Sendable (_ sessionID: UUID, _ buffer: CMSampleBuffer) -> CMSampleBuffer?)?
        internal var didEnqueueSampleBuffer: (@Sendable (_ sessionID: UUID, _ kind: MediaKind, _ pts: CMTime) -> Void)?
        internal var didRequestCancel: (@Sendable (_ sessionID: UUID) -> Void)?
        internal var didQuiesceQueue: (@Sendable (_ sessionID: UUID, _ kind: MediaKind) -> Void)?
        internal var didFlushRenderer: (@Sendable (_ sessionID: UUID, _ kind: MediaKind) -> Void)?
        internal var willCancelReading: (@Sendable (_ sessionID: UUID) -> Void)?
        internal var didCancelReading: (@Sendable (_ sessionID: UUID) -> Void)?
        internal var didArmFeederQueue: (@Sendable (_ sessionID: UUID, _ kind: MediaKind) -> Void)?
        internal var didCompleteRetirement: (@Sendable (_ sessionID: UUID) -> Void)?

        internal init(
            didCreateSession: (@Sendable (_ sessionID: UUID) -> Void)? = nil,
            willCopyNextSampleBuffer: (@Sendable (_ sessionID: UUID, _ kind: MediaKind) -> Void)? = nil,
            didCopyNextSampleBuffer: (@Sendable (_ sessionID: UUID, _ kind: MediaKind, _ hasBuffer: Bool) -> Void)? = nil,
            transformCopiedVideoSampleBuffer: (@Sendable (_ sessionID: UUID, _ buffer: CMSampleBuffer) -> CMSampleBuffer?)? = nil,
            didEnqueueSampleBuffer: (@Sendable (_ sessionID: UUID, _ kind: MediaKind, _ pts: CMTime) -> Void)? = nil,
            didRequestCancel: (@Sendable (_ sessionID: UUID) -> Void)? = nil,
            didQuiesceQueue: (@Sendable (_ sessionID: UUID, _ kind: MediaKind) -> Void)? = nil,
            didFlushRenderer: (@Sendable (_ sessionID: UUID, _ kind: MediaKind) -> Void)? = nil,
            willCancelReading: (@Sendable (_ sessionID: UUID) -> Void)? = nil,
            didCancelReading: (@Sendable (_ sessionID: UUID) -> Void)? = nil,
            didArmFeederQueue: (@Sendable (_ sessionID: UUID, _ kind: MediaKind) -> Void)? = nil,
            didCompleteRetirement: (@Sendable (_ sessionID: UUID) -> Void)? = nil
        ) {
            self.didCreateSession = didCreateSession
            self.willCopyNextSampleBuffer = willCopyNextSampleBuffer
            self.didCopyNextSampleBuffer = didCopyNextSampleBuffer
            self.transformCopiedVideoSampleBuffer = transformCopiedVideoSampleBuffer
            self.didEnqueueSampleBuffer = didEnqueueSampleBuffer
            self.didRequestCancel = didRequestCancel
            self.didQuiesceQueue = didQuiesceQueue
            self.didFlushRenderer = didFlushRenderer
            self.willCancelReading = willCancelReading
            self.didCancelReading = didCancelReading
            self.didArmFeederQueue = didArmFeederQueue
            self.didCompleteRetirement = didCompleteRetirement
        }
    }

    internal struct NativeEnqueuedVideoSampleSnapshot: @unchecked Sendable {
        internal let sampleBuffer: CMSampleBuffer
        internal let sessionID: UUID
        internal let generation: UInt64
        internal let pts: CMTime
        internal let isDoNotDisplay: Bool
        internal let displayImmediately: Bool
        internal let colorimetry: VideoSampleColorimetrySnapshot
    }

    internal struct PendingStartRequest: Sendable, Equatable {
        internal enum Trigger: Sendable, Equatable {
            case initialLoad
            case seek
            case restart
        }

        internal let startTime: CMTime
        internal let seekGeneration: UInt64
        internal let transitionGeneration: UInt64
        internal let trigger: Trigger
    }

    internal final class SessionState: @unchecked Sendable {
        struct Status {
            var isCancelled: Bool = false
            var hasBegunRetirement: Bool = false
            var didRetireVideoQueue: Bool = false
            var didRetireAudioQueue: Bool = false
            var isVideoFinished: Bool = false
            var isAudioFinished: Bool = false
            var hasDispatchedFinished: Bool = false
            var hasEnqueuedFirstVideoSample: Bool = false
        }

        let id: UUID = UUID()
        let transitionGeneration: UInt64
        let reader: AVAssetReader
        let videoOutput: AVAssetReaderTrackOutput?
        let audioOutput: AVAssetReaderTrackOutput?
        let videoRenderer: AVSampleBufferVideoRenderer
        let audioRenderer: AVSampleBufferAudioRenderer
        let probe: NativeReaderLifecycleProbe?
        private let statusLock: OSAllocatedUnfairLock<Status>
        var onFinished: (@MainActor () -> Void)?
        var onFirstVideoSample: (@MainActor (CMTime) -> Void)?
        var onVideoSampleEnqueued: (@MainActor (NativeEnqueuedVideoSampleSnapshot) -> Void)?

        init(
            transitionGeneration: UInt64 = 0,
            reader: AVAssetReader,
            videoOutput: AVAssetReaderTrackOutput?,
            audioOutput: AVAssetReaderTrackOutput?,
            videoRenderer: AVSampleBufferVideoRenderer,
            audioRenderer: AVSampleBufferAudioRenderer,
            probe: NativeReaderLifecycleProbe?
        ) {
            self.transitionGeneration = transitionGeneration
            self.reader = reader
            self.videoOutput = videoOutput
            self.audioOutput = audioOutput
            self.videoRenderer = videoRenderer
            self.audioRenderer = audioRenderer
            self.probe = probe
            var initialStatus = Status()
            // Single-queue video-only sessions derive audio quiescence as already satisfied.
            if audioOutput == nil {
                initialStatus.didRetireAudioQueue = true
            }
            self.statusLock = OSAllocatedUnfairLock(initialState: initialStatus)
        }

        var isCancelled: Bool {
            get { statusLock.withLock { $0.isCancelled } }
            set { statusLock.withLock { $0.isCancelled = newValue } }
        }

        var isVideoFinished: Bool {
            statusLock.withLock { $0.isVideoFinished }
        }

        var isAudioFinished: Bool {
            statusLock.withLock { $0.isAudioFinished }
        }

        var hasDispatchedFinished: Bool {
            statusLock.withLock { $0.hasDispatchedFinished }
        }

        /// Initiates retirement at most once per session, setting `isCancelled = true` atomically.
        func beginRetirementIfNeeded() -> Bool {
            statusLock.withLock { status in
                status.isCancelled = true
                guard !status.hasBegunRetirement else { return false }
                status.hasBegunRetirement = true
                return true
            }
        }

        /// Records that `kind`'s serial feeder queue has exited its drain loop and flushed its renderer.
        /// Returns `true` for the single queue that completes the two-queue quiescence barrier.
        func markQueueRetired(_ kind: NativeReaderLifecycleProbe.MediaKind) -> Bool {
            statusLock.withLock { status in
                let wasBothRetired = status.didRetireVideoQueue && status.didRetireAudioQueue
                switch kind {
                case .video:
                    status.didRetireVideoQueue = true
                case .audio:
                    status.didRetireAudioQueue = true
                }
                let isNowBothRetired = status.didRetireVideoQueue && status.didRetireAudioQueue
                return !wasBothRetired && isNowBothRetired
            }
        }

        func notifyFirstVideoSampleIfNeeded(_ pts: CMTime) {
            let isFirst = statusLock.withLock { status -> Bool in
                guard !status.hasEnqueuedFirstVideoSample && !status.isCancelled else { return false }
                status.hasEnqueuedFirstVideoSample = true
                return true
            }
            if isFirst {
                Task { @MainActor [weak self] in
                    self?.onFirstVideoSample?(pts)
                }
            }
        }

        func notifyVideoSampleEnqueued(_ snapshot: NativeEnqueuedVideoSampleSnapshot) {
            let isActive = statusLock.withLock { !$0.isCancelled }
            guard isActive else { return }
            Task { @MainActor [weak self] in
                self?.onVideoSampleEnqueued?(snapshot)
            }
        }

        func markVideoFinished() {
            let shouldDispatch = statusLock.withLock { status -> Bool in
                status.isVideoFinished = true
                let audioDone = (audioOutput == nil) || status.isAudioFinished
                if audioDone && !status.hasDispatchedFinished && !status.isCancelled {
                    status.hasDispatchedFinished = true
                    return true
                }
                return false
            }
            if shouldDispatch {
                Task { @MainActor [weak self] in
                    self?.onFinished?()
                }
            }
        }

        func markAudioFinished() {
            let shouldDispatch = statusLock.withLock { status -> Bool in
                status.isAudioFinished = true
                if status.isVideoFinished && !status.hasDispatchedFinished && !status.isCancelled {
                    status.hasDispatchedFinished = true
                    return true
                }
                return false
            }
            if shouldDispatch {
                Task { @MainActor [weak self] in
                    self?.onFinished?()
                }
            }
        }
    }
}
