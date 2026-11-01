// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import QuartzCore
import os

/// Hardware-accelerated compressed passthrough media controller based on `AVAssetReader`.
///
/// Feeds compressed `CMSampleBuffer` instances directly from container tracks (`outputSettings = nil`)
/// into host `AVSampleBufferDisplayLayer` (leveraging Apple Silicon hardware decode exhaustion immunity)
/// and `AVSampleBufferAudioRenderer`, unified under a single `AVSampleBufferRenderSynchronizer` master clock.
@MainActor
public final class AVAssetReaderPlaybackController: Sendable {
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "AVAssetReaderPlaybackController")

    // MARK: - Presentation Components

    public let url: URL
    public let displayLayer: AVSampleBufferDisplayLayer
    public let audioRenderer: AVSampleBufferAudioRenderer
    public let synchronizer: AVSampleBufferRenderSynchronizer

    // MARK: - State

    public private(set) var duration: CMTime = .zero
    public private(set) var naturalSize: CGSize = .zero
    public private(set) var rawVideoNaturalSize: CGSize? = nil
    public private(set) var videoPixelAspectRatio: CGSize = CGSize(width: 1, height: 1)
    public private(set) var videoRotationDegrees: Int = 0
    public private(set) var isLoaded: Bool = false
    public private(set) var hasAudio: Bool = false
    public private(set) var isEndOfStream: Bool = false
    public private(set) var userPlaybackIntent: Bool = false
    public private(set) var seekGeneration: UInt64 = 0
    internal private(set) var transitionGeneration: UInt64 = 0
    public internal(set) var formatPresentationState = VideoFormatPresentationState()
    internal var latestHostScreenObservation: VideoHostScreenObservation? = nil
    internal var sampleObservationTimeline = VideoSamplePresentationTimelineTracker()
    internal var latestVideoFormatDescription: CMFormatDescription? = nil
    public var onFormatPresentationStateChanged: (@MainActor (VideoFormatPresentationState) -> Void)?
    private var hasReportedInitialFrame: Bool = false

    public var playbackRate: Float = 1.0 {
        didSet {
            if synchronizer.rate > 0.0, isReading, pendingStartRequest == nil {
                synchronizer.setRate(playbackRate, time: synchronizer.currentTime())
            }
        }
    }

    public var volume: Float = 1.0 {
        didSet {
            audioRenderer.volume = max(0.0, min(1.0, volume))
        }
    }

    public var isPlaying: Bool {
        if pendingStartRequest != nil {
            return userPlaybackIntent
        }
        return synchronizer.rate > 0.0
    }

    public var isReading: Bool {
        guard let activeSession, !activeSession.isCancelled else { return false }
        return retiringSessionID != activeSession.id
    }

    public var isSessionActive: Bool {
        isReading
    }

    internal var activeSessionID: UUID? {
        activeSession?.id
    }

    internal var activeSessionReaderForTesting: AVAssetReader? {
        activeSession?.reader
    }

    internal private(set) var retiringSessionID: UUID?
    internal private(set) var pendingStartRequest: PendingStartRequest?
    internal private(set) var createdSessionCount: Int = 0

    public var currentTime: CMTime {
        synchronizer.currentTime()
    }

    // MARK: - Callbacks

    public var onTimeUpdate: (@MainActor (CMTime) -> Void)?
    public var onPlaybackEnded: (@MainActor () -> Void)?
    public var onError: (@MainActor (Error) -> Void)?
    public var onFirstVideoFrameEnqueued: (@MainActor (CMTime) -> Void)?
    public var onSeekCompleted: (@MainActor (CMTime, UInt64) -> Void)?

    // MARK: - Internal Observation Seam

    internal var lifecycleProbe: NativeReaderLifecycleProbe?

    // MARK: - Internal Pipeline Infrastructure

    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?

    private let videoFeedQueue = DispatchQueue(label: "com.metastudyline.ttmedia.assetreader.video", qos: .userInteractive)
    private let audioFeedQueue = DispatchQueue(label: "com.metastudyline.ttmedia.assetreader.audio", qos: .userInteractive)

    private var activeSession: SessionState?
    public var registersWithCoordinator: Bool = true
    private var isRegisteredWithCoordinator: Bool = false
    private var timeObserverToken: Any?

    // MARK: - Initialization & Teardown

    public init(
        url: URL,
        displayLayer: AVSampleBufferDisplayLayer,
        audioRenderer: AVSampleBufferAudioRenderer,
        synchronizer: AVSampleBufferRenderSynchronizer
    ) {
        self.url = url
        self.displayLayer = displayLayer
        self.audioRenderer = audioRenderer
        self.synchronizer = synchronizer

        displayLayer.videoGravity = .resizeAspect
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
        installTimeObserver()
    }

    public convenience init(url: URL) {
        self.init(
            url: url,
            displayLayer: AVSampleBufferDisplayLayer(),
            audioRenderer: AVSampleBufferAudioRenderer(),
            synchronizer: AVSampleBufferRenderSynchronizer()
        )
    }

    isolated deinit {
        if let timeObserverToken {
            synchronizer.removeTimeObserver(timeObserverToken)
        }
        teardownCoordinatorSession()
        pendingStartRequest = nil
        retireCurrentSessionAsync()
    }

    private func installTimeObserver() {
        timeObserverToken = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.isLoaded, self.synchronizer.rate > 0.0,
                      self.isReading, self.pendingStartRequest == nil else { return }
                let observedSeekGen = self.seekGeneration
                let observedTransitionGen = self.transitionGeneration
                if !self.sampleObservationTimeline.pendingFutureSamples.isEmpty
                    || (self.sampleObservationTimeline.activePresentedSample != nil
                        && self.formatPresentationState.outputObservationStatus == .detecting) {
                    self.refreshLiveOutputObservation()
                }
                self.onTimeUpdate?(time)
                guard self.seekGeneration == observedSeekGen,
                      self.transitionGeneration == observedTransitionGen,
                      self.synchronizer.rate > 0.0,
                      self.isReading, self.pendingStartRequest == nil else { return }
                if self.duration.isNumeric, self.duration > .zero,
                   time >= self.duration, !self.isEndOfStream {
                    self.isEndOfStream = true
                    self.pause()
                    self.onPlaybackEnded?()
                }
            }
        }
    }

    // MARK: - Public Lifecycle

    /// Loads container tracks and pre-rolls the pipeline to presentation start timestamp.
    public func load(autoPlay: Bool = false) async throws {
        transitionGeneration &+= 1
        let loadTransitionGen = transitionGeneration
        let loadSeekGen = seekGeneration
        pendingStartRequest = nil
        retireCurrentSessionAsync()

        hasReportedInitialFrame = false
        resetSampleObservationForNewGeneration()
        userPlaybackIntent = autoPlay
        let asset = AVURLAsset(url: url)

        let (isPlayable, tracks) = try await asset.load(.isPlayable, .tracks)
        guard isPlayable else {
            throw NSError(
                domain: "com.metastudyline.ttmedia.assetreader",
                code: -1000,
                userInfo: [NSLocalizedDescriptionKey: "Asset is not playable: \(url.lastPathComponent)"]
            )
        }

        let videoTracks = tracks.filter { $0.mediaType == .video }
        guard let primaryVideoTrack = videoTracks.first else {
            throw NSError(
                domain: "com.metastudyline.ttmedia.assetreader",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "No video track discovered in container \(url.lastPathComponent)"]
            )
        }
        guard try await primaryVideoTrack.load(.isDecodable) else {
            throw NSError(
                domain: "com.metastudyline.ttmedia.assetreader",
                code: -1004,
                userInfo: [NSLocalizedDescriptionKey: "Primary video track is not decodable: \(url.lastPathComponent)"]
            )
        }
        let loadedDuration = try await asset.load(.duration)

        guard self.transitionGeneration == loadTransitionGen else { return }
        self.asset = asset
        self.videoTrack = primaryVideoTrack

        let audioTracks = tracks.filter { $0.mediaType == .audio }
        self.audioTrack = audioTracks.first
        self.hasAudio = audioTrack != nil
        self.duration = loadedDuration

        await applyVideoTrackGeometry(from: primaryVideoTrack)
        guard self.transitionGeneration == loadTransitionGen else { return }
        self.isLoaded = true
        self.isEndOfStream = false

        if registersWithCoordinator {
            registerCoordinatorSession()
        }

        let initialRequest = PendingStartRequest(
            startTime: .zero,
            seekGeneration: loadSeekGen,
            transitionGeneration: loadTransitionGen,
            trigger: .initialLoad
        )
        if activeSession != nil {
            submitOrStartPipelineRequest(initialRequest)
            synchronizer.setRate(0.0, time: .zero)
            updateCoordinatorPlaybackState(isPlaying: userPlaybackIntent)
        } else {
            try startPipelineForRequest(initialRequest)
        }
    }

    private func applyVideoTrackGeometry(from primaryVideoTrack: AVAssetTrack) async {
        let rawTrackSize = (try? await primaryVideoTrack.load(.naturalSize)) ?? .zero
        let preferredTransform = (try? await primaryVideoTrack.load(.preferredTransform)) ?? .identity
        let nominalFrameRate = (try? await primaryVideoTrack.load(.nominalFrameRate)) ?? 0
        let formatDescriptions = (try? await primaryVideoTrack.load(.formatDescriptions)) ?? []
        let firstFormatDesc = formatDescriptions.first
        self.latestVideoFormatDescription = firstFormatDesc
        let extractedPAR = VideoContentGeometry.extractPixelAspectRatio(from: firstFormatDesc)
        let extractedRotation = VideoContentGeometry.rotationDegrees(from: preferredTransform)
        let resolvedRawSize = Self.resolveCodedVideoSize(from: firstFormatDesc, fallback: rawTrackSize)

        if resolvedRawSize.width > 0, resolvedRawSize.height > 0 {
            self.rawVideoNaturalSize = resolvedRawSize
            self.videoPixelAspectRatio = extractedPAR
            self.videoRotationDegrees = extractedRotation
            self.naturalSize = VideoContentGeometry.orientedDisplaySize(
                rawVideoSize: resolvedRawSize,
                pixelAspectRatio: extractedPAR,
                rotationDegrees: extractedRotation
            )
        } else {
            self.rawVideoNaturalSize = nil
            self.videoPixelAspectRatio = CGSize(width: 1, height: 1)
            self.videoRotationDegrees = 0
            self.naturalSize = .zero
        }
        applyResolvedTrackFormatState(
            formatDesc: firstFormatDesc,
            codedSize: resolvedRawSize,
            nominalFrameRate: nominalFrameRate
        )
    }

    private static func resolveCodedVideoSize(from formatDesc: CMFormatDescription?, fallback: CGSize) -> CGSize {
        guard let formatDesc else { return fallback }
        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
        return (dims.width > 0 && dims.height > 0)
            ? CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
            : fallback
    }

    private func applyResolvedTrackFormatState(
        formatDesc: CMFormatDescription?,
        codedSize: CGSize,
        nominalFrameRate: Float
    ) {
        self.formatPresentationState = Self.extractFormatPresentationState(
            from: formatDesc,
            width: Int(codedSize.width),
            height: Int(codedSize.height),
            displayWidth: self.naturalSize.width > 0 ? Int(self.naturalSize.width.rounded()) : nil,
            displayHeight: self.naturalSize.height > 0 ? Int(self.naturalSize.height.rounded()) : nil,
            frameRateFps: nominalFrameRate > 0 ? Double(nominalFrameRate) : nil
        )
        VideoRendererOutputEvaluator.configureDisplayLayerEDR(
            displayLayer: displayLayer,
            sourceDynamicRange: formatPresentationState.sourceDynamicRange,
            hostScreen: latestHostScreenObservation
        )
    }

    internal static func extractFormatPresentationState(
        from formatDesc: CMFormatDescription?,
        width: Int = 0,
        height: Int = 0,
        displayWidth: Int? = nil,
        displayHeight: Int? = nil,
        frameRateFps: Double? = nil
    ) -> VideoFormatPresentationState {
        CMFormatDescriptionMetadataExtractor.extractPresentationState(
            from: formatDesc,
            width: width,
            height: height,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            frameRateFps: frameRateFps
        )
    }

    public func applyDisplayObservation(_ observation: VideoDisplayOutputObservation?) {
        if let gen = observation?.playbackGeneration, gen != transitionGeneration {
            return
        }
        formatPresentationState = formatPresentationState.applyingDisplayObservation(observation)
        onFormatPresentationStateChanged?(formatPresentationState)
    }

    /// Starts playback at current playback rate.
    public func play() {
        userPlaybackIntent = true
        guard isLoaded else { return }
        if isEndOfStream {
            seek(to: .zero)
            return
        }
        guard isReading else {
            updateCoordinatorPlaybackState(isPlaying: true)
            guard pendingStartRequest == nil else { return }
            transitionGeneration &+= 1
            resetSampleObservationForNewGeneration()
            refreshLiveOutputObservation()
            let anchor = synchronizer.currentTime()
            let restartTarget = clampPresentationTime(
                (anchor.isNumeric && anchor >= .zero) ? anchor : .zero
            )
            synchronizer.setRate(0.0, time: restartTarget)
            let request = PendingStartRequest(
                startTime: restartTarget,
                seekGeneration: seekGeneration,
                transitionGeneration: transitionGeneration,
                trigger: .restart
            )
            submitOrStartPipelineRequest(request)
            return
        }
        let anchor = synchronizer.currentTime()
        let start = (anchor.isNumeric && anchor >= .zero) ? anchor : .zero
        let effectiveRate = playbackRate > 0 ? playbackRate : 1.0
        synchronizer.setRate(effectiveRate, time: start)
        if !sampleObservationTimeline.pendingFutureSamples.isEmpty
            || (sampleObservationTimeline.activePresentedSample != nil
                && formatPresentationState.outputObservationStatus == .detecting) {
            refreshLiveOutputObservation()
        }
        updateCoordinatorPlaybackState(isPlaying: true)
    }

    /// Pauses playback.
    public func pause() {
        userPlaybackIntent = false
        let anchor = synchronizer.currentTime()
        let clamped = (anchor.isNumeric && anchor >= .zero) ? anchor : .zero
        synchronizer.setRate(0.0, time: clamped)
        updateCoordinatorPlaybackState(isPlaying: false)
    }

    /// Toggles play and pause state.
    public func togglePlayPause() {
        if isPlaying || userPlaybackIntent {
            pause()
        } else {
            play()
        }
    }

    /// Seeks to specified presentation timestamp, coalescing intermediate requests until the active session retires.
    public func seek(to targetTime: CMTime) {
        guard isLoaded else { return }
        seekGeneration &+= 1
        transitionGeneration &+= 1
        resetSampleObservationForNewGeneration()
        refreshLiveOutputObservation()
        let requestedSeekGen = seekGeneration
        let requestedTransitionGen = transitionGeneration
        let intendedPlaying = userPlaybackIntent || isPlaying
        userPlaybackIntent = intendedPlaying

        let clampedTime = clampPresentationTime(targetTime)
        isEndOfStream = false
        synchronizer.setRate(0.0, time: clampedTime)
        updateCoordinatorPlaybackState(isPlaying: userPlaybackIntent)
        onTimeUpdate?(clampedTime)

        let request = PendingStartRequest(
            startTime: clampedTime,
            seekGeneration: requestedSeekGen,
            transitionGeneration: requestedTransitionGen,
            trigger: .seek
        )
        submitOrStartPipelineRequest(request)
    }

    private func clampPresentationTime(_ targetTime: CMTime) -> CMTime {
        let durSeconds = (duration.isNumeric && duration > .zero) ? CMTimeGetSeconds(duration) : 0.0
        let rawTarget = max(0.0, CMTimeGetSeconds(targetTime).isFinite ? CMTimeGetSeconds(targetTime) : 0.0)
        let maxSeekable = durSeconds > 0.05 ? (durSeconds - 0.05) : durSeconds
        let clampedSeconds = durSeconds > 0 ? min(rawTarget, maxSeekable) : rawTarget
        let timescale = duration.timescale > 0 ? duration.timescale : 600
        return CMTime(seconds: clampedSeconds, preferredTimescale: timescale)
    }

    private func submitOrStartPipelineRequest(_ request: PendingStartRequest) {
        guard request.transitionGeneration == transitionGeneration, isLoaded else { return }
        if activeSession != nil {
            pendingStartRequest = request
            retireCurrentSessionAsync()
        } else {
            pendingStartRequest = nil
            do {
                try startPipelineForRequest(request)
            } catch {
                logger.error("Failed to initialize AVAssetReader at target time: \(error.localizedDescription)")
                formatPresentationState = formatPresentationState.applyingDiagnosticFailure(error.localizedDescription)
                onFormatPresentationStateChanged?(formatPresentationState)
                onError?(error)
            }
        }
    }

    /// Convenience relative seek in seconds.
    public func seek(by deltaSeconds: Double) {
        let currentSec = CMTimeGetSeconds(currentTime)
        let targetSec = max(0.0, currentSec + deltaSeconds)
        seek(to: CMTime(seconds: targetSec, preferredTimescale: duration.timescale))
    }

    /// Halts playback, clears any coalesced pending start intent, and retires the active reader asynchronously.
    public func stop() {
        transitionGeneration &+= 1
        resetSampleObservationForNewGeneration()
        pendingStartRequest = nil
        pause()
        retireCurrentSessionAsync()
        updateCoordinatorPlaybackState(isPlaying: false)
    }

    // MARK: - Pipeline Admission, Handoff & Two-Queue Quiescence Retirement

    private func startPipelineForRequest(_ request: PendingStartRequest) throws {
        try setupReaderPipeline(from: request.startTime)
        let effectiveRate = playbackRate > 0 ? playbackRate : 1.0
        let rateToSet: Float = userPlaybackIntent ? effectiveRate : 0.0
        synchronizer.setRate(rateToSet, time: request.startTime)
        updateCoordinatorPlaybackState(isPlaying: userPlaybackIntent)
        if request.trigger == .seek {
            onSeekCompleted?(request.startTime, request.seekGeneration)
        }
    }

    private func setupReaderPipeline(from startTime: CMTime) throws {
        guard let asset, let videoTrack else { return }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: startTime, duration: .positiveInfinity)

        // Compressed passthrough invariant: outputSettings = nil
        let vOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        vOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(vOutput) else {
            throw NSError(
                domain: "com.metastudyline.ttmedia.assetreader",
                code: -1002,
                userInfo: [NSLocalizedDescriptionKey: "Failed to attach compressed video track output to AVAssetReader"]
            )
        }
        reader.add(vOutput)

        var aOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioOut.alwaysCopiesSampleData = false
            if reader.canAdd(audioOut) {
                reader.add(audioOut)
                aOutput = audioOut
            }
        }

        guard reader.startReading() else {
            let err = reader.error ?? NSError(domain: "com.metastudyline.ttmedia.assetreader", code: -1003, userInfo: nil)
            throw err
        }

        let session = SessionState(
            transitionGeneration: transitionGeneration,
            reader: reader,
            videoOutput: vOutput,
            audioOutput: aOutput,
            videoRenderer: displayLayer.sampleBufferRenderer,
            audioRenderer: audioRenderer,
            probe: lifecycleProbe
        )
        createdSessionCount += 1
        session.probe?.didCreateSession?(session.id)
        session.onVideoSampleEnqueued = { [weak self, weak session] snapshot in
            self?.handleSessionVideoSampleEnqueued(snapshot, from: session)
        }
        session.onFinished = { [weak self, weak session] in
            self?.handleSessionReaderFinished(from: session)
        }
        self.activeSession = session
        self.retiringSessionID = nil

        armFeederLoops(session: session)
    }

    private func handleSessionVideoSampleEnqueued(_ snapshot: NativeEnqueuedVideoSampleSnapshot, from session: SessionState?) {
        guard let session, let active = activeSession,
              active.id == session.id, !session.isCancelled,
              snapshot.generation == transitionGeneration else { return }
        let isFirstDisplayable = !snapshot.isDoNotDisplay && !hasReportedInitialFrame
        if isFirstDisplayable, !isPlaying, !userPlaybackIntent, snapshot.pts.isNumeric {
            synchronizer.setRate(0.0, time: snapshot.pts)
        }
        recordVideoSampleEnqueuedForObservation(
            snapshot.sampleBuffer,
            preextractedSnapshot: snapshot.colorimetry,
            isDoNotDisplayOverride: snapshot.isDoNotDisplay,
            forSessionID: snapshot.sessionID,
            forGeneration: snapshot.generation
        )
        if isFirstDisplayable {
            hasReportedInitialFrame = true
            onFirstVideoFrameEnqueued?(snapshot.pts)
        }
    }

    private func handleSessionReaderFinished(from session: SessionState?) {
        guard let session, let active = activeSession, active.id == session.id, !session.isCancelled else { return }
        if session.reader.status == .failed, let error = session.reader.error {
            pause()
            formatPresentationState = formatPresentationState.applyingDiagnosticFailure(error.localizedDescription)
            onFormatPresentationStateChanged?(formatPresentationState)
            onError?(error)
        }
        // Reader EOF only means all samples were queued, not presented.
    }

    private func retireCurrentSessionAsync() {
        guard let session = activeSession else { return }
        guard session.beginRetirementIfNeeded() else { return }
        retiringSessionID = session.id
        session.probe?.didRequestCancel?(session.id)
        session.videoRenderer.stopRequestingMediaData()
        session.audioRenderer.stopRequestingMediaData()

        videoFeedQueue.async { [weak self] in
            Self.retireFeederQueue(session: session, kind: .video, controller: self)
        }

        if session.audioOutput != nil {
            audioFeedQueue.async { [weak self] in
                Self.retireFeederQueue(session: session, kind: .audio, controller: self)
            }
        }
    }

    nonisolated private static func retireFeederQueue(
        session: SessionState,
        kind: NativeReaderLifecycleProbe.MediaKind,
        controller: AVAssetReaderPlaybackController?
    ) {
        switch kind {
        case .video:
            session.videoRenderer.stopRequestingMediaData()
            session.videoRenderer.flush()
        case .audio:
            session.audioRenderer.stopRequestingMediaData()
            session.audioRenderer.flush()
        }
        session.probe?.didFlushRenderer?(session.id, kind)
        session.probe?.didQuiesceQueue?(session.id, kind)

        guard session.markQueueRetired(kind) else { return }
        session.probe?.willCancelReading?(session.id)
        session.reader.cancelReading()
        session.probe?.didCancelReading?(session.id)

        let retiredSessionID = session.id
        let probe = session.probe
        Task { @MainActor [weak controller] in
            guard let controller else {
                probe?.didCompleteRetirement?(retiredSessionID)
                return
            }
            controller.completeSessionRetirement(sessionID: retiredSessionID, probe: probe)
        }
    }

    internal func completeSessionRetirement(sessionID: UUID, probe: NativeReaderLifecycleProbe?) {
        guard activeSession?.id == sessionID else {
            probe?.didCompleteRetirement?(sessionID)
            return
        }
        activeSession = nil
        if retiringSessionID == sessionID {
            retiringSessionID = nil
        }

        guard let nextRequest = pendingStartRequest else {
            probe?.didCompleteRetirement?(sessionID)
            return
        }
        pendingStartRequest = nil
        guard nextRequest.transitionGeneration == transitionGeneration, isLoaded else {
            probe?.didCompleteRetirement?(sessionID)
            return
        }

        do {
            try startPipelineForRequest(nextRequest)
        } catch {
            logger.error("Failed to start coalesced AVAssetReader session: \(error.localizedDescription)")
            formatPresentationState = formatPresentationState.applyingDiagnosticFailure(error.localizedDescription)
            onFormatPresentationStateChanged?(formatPresentationState)
            onError?(error)
        }
        probe?.didCompleteRetirement?(sessionID)
    }

    private func armFeederLoops(session: SessionState) {
        let vRenderer = session.videoRenderer
        session.probe?.didArmFeederQueue?(session.id, .video)
        vRenderer.requestMediaDataWhenReady(on: videoFeedQueue) { [weak session] in
            guard let session, !session.isCancelled else { return }
            Self.drainVideoQueue(session: session)
        }

        if session.audioOutput != nil {
            let aRenderer = session.audioRenderer
            session.probe?.didArmFeederQueue?(session.id, .audio)
            aRenderer.requestMediaDataWhenReady(on: audioFeedQueue) { [weak session] in
                guard let session, !session.isCancelled else { return }
                Self.drainAudioQueue(session: session)
            }
        }
    }

    nonisolated private static func drainVideoQueue(session: SessionState) {
        guard let output = session.videoOutput else { return }
        let renderer = session.videoRenderer

        while renderer.isReadyForMoreMediaData {
            guard !session.isCancelled else { break }

            session.probe?.willCopyNextSampleBuffer?(session.id, .video)
            let rawBuffer = output.copyNextSampleBuffer()
            let buffer = rawBuffer.flatMap { raw in
                session.probe?.transformCopiedVideoSampleBuffer?(session.id, raw) ?? raw
            }
            session.probe?.didCopyNextSampleBuffer?(session.id, .video, buffer != nil)
            guard !session.isCancelled else { break }
            if let buffer {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                let isDoNotDisplay = AVSampleBufferPlayerCoordinator.isDoNotDisplayAttachmentSet(on: buffer)
                guard pts.isNumeric || isDoNotDisplay else {
                    continue
                }
                let displayImmediately = AVSampleBufferPlayerCoordinator.isDisplayImmediatelyAttachmentSet(on: buffer)
                let color = VideoRendererOutputEvaluator.extractSampleColorimetry(from: buffer)
                let colorSnapshot = VideoSampleColorimetrySnapshot(
                    pts: pts,
                    displayImmediately: displayImmediately,
                    primaries: color.primaries,
                    transfer: color.transfer,
                    matrix: color.matrix,
                    dynamicRange: color.dynamicRange
                )
                renderer.enqueue(buffer)
                session.probe?.didEnqueueSampleBuffer?(session.id, .video, pts)
                if !isDoNotDisplay {
                    session.notifyFirstVideoSampleIfNeeded(pts)
                }
                let snapshot = NativeEnqueuedVideoSampleSnapshot(
                    sampleBuffer: buffer,
                    sessionID: session.id,
                    generation: session.transitionGeneration,
                    pts: pts,
                    isDoNotDisplay: isDoNotDisplay,
                    displayImmediately: displayImmediately,
                    colorimetry: colorSnapshot
                )
                session.notifyVideoSampleEnqueued(snapshot)
            } else {
                renderer.stopRequestingMediaData()
                session.markVideoFinished()
                break
            }
        }
    }

    nonisolated private static func drainAudioQueue(session: SessionState) {
        guard let output = session.audioOutput else { return }
        let renderer = session.audioRenderer

        while renderer.isReadyForMoreMediaData {
            guard !session.isCancelled else { break }

            session.probe?.willCopyNextSampleBuffer?(session.id, .audio)
            let buffer = output.copyNextSampleBuffer()
            session.probe?.didCopyNextSampleBuffer?(session.id, .audio, buffer != nil)
            guard !session.isCancelled else { break }
            if let buffer {
                let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
                renderer.enqueue(buffer)
                session.probe?.didEnqueueSampleBuffer?(session.id, .audio, pts)
            } else {
                renderer.stopRequestingMediaData()
                session.markAudioFinished()
                break
            }
        }
    }

    // MARK: - Coordinator Registration

    public func registerCoordinatorSession() {
        guard !isRegisteredWithCoordinator else { return }
        MediaPlaybackCoordinator.shared.registerSession(
            id: url.path,
            isPlaying: isPlaying,
            togglePlayPause: { [weak self] in
                self?.togglePlayPause()
            },
            seekBy: { [weak self] delta in
                self?.seek(by: delta)
            },
            stop: { [weak self] in
                self?.stop()
            }
        )
        isRegisteredWithCoordinator = true
    }

    public func teardownCoordinatorSession() {
        if isRegisteredWithCoordinator {
            MediaPlaybackCoordinator.shared.unregisterSession(id: url.path)
            isRegisteredWithCoordinator = false
        }
    }

    private func updateCoordinatorPlaybackState(isPlaying: Bool) {
        MediaPlaybackCoordinator.shared.updatePlaybackState(id: url.path, isPlaying: isPlaying)
    }
}
