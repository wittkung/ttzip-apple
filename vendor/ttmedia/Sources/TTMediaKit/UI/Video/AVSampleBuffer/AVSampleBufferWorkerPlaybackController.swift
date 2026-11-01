// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreMedia
import CoreVideo
@preconcurrency import AVFoundation

/// Fatal playback errors that require stopping the video session.
public enum AVSampleBufferFatalPlaybackError: LocalizedError, Sendable, Equatable {
    case containerCorrupted(String)
    case workerCrashed(String)

    public var errorDescription: String? {
        switch self {
        case .containerCorrupted(let detail):
            return detail
        case .workerCrashed(let detail):
            return detail
        }
    }
}

@MainActor
public final class AVSampleBufferWorkerPlaybackController: ObservableObject {
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var errorMessage: String? = nil
    @Published public private(set) var audioFault: AVSampleBufferAudioFault? = nil
    @Published public private(set) var isAudioIsolated: Bool = false
    public private(set) var fatalError: Error? = nil

    public private(set) var selectedVideoStreamIndex: UInt32? = nil
    public private(set) var selectedAudioStreamIndex: UInt32? = nil
    public private(set) var enqueuedAudioPacketCount: Int = 0
    public private(set) var enqueuedVideoPacketCount: Int = 0
    public private(set) var ignoredMismatchedStreamPackets: Int = 0
    public private(set) var ignoredStaleSeekResponseCount: Int = 0
    public private(set) var naturalVideoSize: CGSize = .zero
    public private(set) var rawVideoNaturalSize: CGSize? = nil
    public private(set) var videoPixelAspectRatio: CGSize = CGSize(width: 1, height: 1)
    public private(set) var videoRotationDegrees: Int = 0
    public private(set) var catalogSubtitleTracks: [TTMediaSubtitleTrackInfo] = []
    public internal(set) var formatPresentationState = VideoFormatPresentationState()
    internal var latestHostScreenObservation: VideoHostScreenObservation? = nil
    internal var sampleObservationTimeline = VideoSamplePresentationTimelineTracker()
    public var onFormatPresentationStateChanged: (@MainActor (VideoFormatPresentationState) -> Void)?

    public var onError: (@MainActor (Error) -> Void)?
    public var onAudioFault: (@MainActor (AVSampleBufferAudioFault) -> Void)?

    internal var backpressurePollIntervalNanos: UInt64 = 10_000_000
    internal var stallPollThreshold: Int = 8
    internal var prerollBackpressureDrainThreshold: Int = 2
    internal var videoQueueReadinessOverride: (@MainActor () -> Bool)?

    internal private(set) var playbackGeneration: UInt64 = 0
    private var inputExhausted = false
    private var isTornDown = false
    public private(set) var hasEnqueuedInitialMediaSample = false
    private var initialReadinessContinuations: [CheckedContinuation<Void, Never>] = []
    private var lastSampleEnd: CMTime = .zero

    public let coordinator: AVSampleBufferPlayerCoordinator
    public let audioPipeline: AVSampleBufferAudioPipeline
    public let reconstructor: SampleBufferReconstructor
    public let client: MediaWorkerXPCClient
    public let pipController: AVSampleBufferPiPController

    private let url: URL
    private var activeSessionId: String?
    private var packetPumpTask: Task<Void, Never>?
    private var activeSeekTask: Task<Void, Never>?

    private var videoTrack: TTMediaVideoTrackInfo?
    private var audioTrack: TTMediaAudioTrackInfo?
    private var videoFormatDesc: CMFormatDescription?
    private var audioFormatDesc: CMAudioFormatDescription?

    public var onTimeUpdate: (@MainActor (CMTime) -> Void)? {
        get { coordinator.onTimeUpdate }
        set { coordinator.onTimeUpdate = newValue }
    }
    public var onPlaybackEnded: (@MainActor () -> Void)? {
        get { coordinator.onPlaybackEnded }
        set { coordinator.onPlaybackEnded = newValue }
    }
    public var onFirstVideoFrameEnqueued: (@MainActor (CMTime) -> Void)? {
        get { coordinator.onFirstVideoFrameEnqueued }
        set { coordinator.onFirstVideoFrameEnqueued = newValue }
    }
    public var onSeekCompleted: (@MainActor (CMTime, UInt64) -> Void)? {
        get { coordinator.onSeekCompleted }
        set { coordinator.onSeekCompleted = newValue }
    }
    public var isPlaying: Bool { coordinator.isPlaying }
    public var userPlaybackIntent: Bool { coordinator.userPlaybackIntent }
    public var seekGeneration: UInt64 { coordinator.seekGeneration }
    public var duration: CMTime { coordinator.duration }
    public var hasUsableAudioTrack: Bool { audioTrack != nil && !isAudioIsolated }

    private var hasReachedPresentationEnd: Bool {
        let end = (lastSampleEnd.isNumeric && lastSampleEnd > .zero) ? lastSampleEnd : coordinator.duration
        guard end.isNumeric, end > .zero, coordinator.currentTime.isNumeric else { return false }
        return CMTimeCompare(coordinator.currentTime, end) >= 0
    }

    public func togglePlayPause() {
        if coordinator.isPlaying || coordinator.userPlaybackIntent {
            coordinator.pause()
        } else if inputExhausted, hasReachedPresentationEnd {
            coordinator.setUserPlaybackIntent(true)
            Task { [weak self] in
                guard let self else { return }
                await self.seek(to: 0)
                if self.errorMessage == nil, self.coordinator.userPlaybackIntent {
                    self.coordinator.play()
                }
            }
        } else {
            coordinator.play()
        }
    }

    public init(url: URL, client: MediaWorkerXPCClient? = nil) {
        self.url = url
        let coordinator = AVSampleBufferPlayerCoordinator()
        self.coordinator = coordinator
        self.audioPipeline = AVSampleBufferAudioPipeline(audioRenderer: coordinator.audioRenderer)
        self.audioPipeline.attach(to: coordinator.synchronizer)
        self.reconstructor = SampleBufferReconstructor()
        let resolvedClient = client ?? MediaWorkerXPCClient.makeDefault()
        self.client = resolvedClient
        self.pipController = AVSampleBufferPiPController(coordinator: coordinator)
        coordinator.onVideoSampleEnqueued = { [weak self] enqueuedSample in
            guard let self, !self.isTornDown else { return }
            self.recordVideoSampleEnqueuedForObservation(enqueuedSample, forGeneration: self.playbackGeneration)
        }
        coordinator.onInternalPresentationTimeChanged = { [weak self] _ in
            guard let self, !self.isTornDown,
                  (!self.sampleObservationTimeline.pendingFutureSamples.isEmpty
                   || (self.sampleObservationTimeline.activePresentedSample != nil
                       && self.formatPresentationState.outputObservationStatus == .detecting)) else { return }
            self.refreshLiveOutputObservation(sampleBuffer: nil)
        }
        resolvedClient.onCrash = { [weak self] error in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handleWorkerCrash(error)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handleWorkerCrash(error)
                }
            }
        }
    }

    deinit {
        // MainActor isolated types perform async teardown via teardown() before release.
    }

    public static func isWorkerCrashError(_ error: Error) -> Bool {
        if let fatal = error as? AVSampleBufferFatalPlaybackError {
            if case .workerCrashed = fatal { return true }
            return false
        }
        guard let workerErr = error as? MediaWorkerError else { return false }
        switch workerErr {
        case .workerCrashed, .connectionInterrupted, .connectionInvalidated, .serviceUnavailable, .timedOut:
            return true
        default:
            return false
        }
    }

    private func resumeInitialReadinessWaiters() {
        guard !initialReadinessContinuations.isEmpty else { return }
        let waiters = initialReadinessContinuations
        initialReadinessContinuations.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func completeInitialMediaReadiness() {
        hasEnqueuedInitialMediaSample = true
        isLoading = false
        coordinator.markReadyAndApplyPlaybackIntent()
        resumeInitialReadinessWaiters()
    }

    internal func waitForInitialMediaReadinessOrFailure() async {
        if hasEnqueuedInitialMediaSample || !isLoading || fatalError != nil || isTornDown || coordinator.isReady { return }
        await withCheckedContinuation { initialReadinessContinuations.append($0) }
    }

    private func reportError(_ error: Error, message: String? = nil) {
        if Self.isWorkerCrashError(error) {
            activeSessionId = nil
        }
        let alreadyHadError = (errorMessage != nil)
        isLoading = false
        coordinator.markTerminalFailure()
        fatalError = error
        let resolvedMessage = message ?? error.localizedDescription
        errorMessage = resolvedMessage
        formatPresentationState = formatPresentationState.applyingDiagnosticFailure(resolvedMessage)
        onFormatPresentationStateChanged?(formatPresentationState)
        resumeInitialReadinessWaiters()
        if !alreadyHadError {
            onError?(error)
        }
    }

    private func isolateAudioFault(_ fault: AVSampleBufferAudioFault) {
        guard !isAudioIsolated else { return }
        isAudioIsolated = true
        audioFault = fault
        audioTrack = nil
        selectedAudioStreamIndex = nil
        audioFormatDesc = nil
        audioPipeline.isolate(from: coordinator.synchronizer, fault: fault)
        if !isTornDown && !Task.isCancelled && activeSessionId != nil
            && coordinator.isPlaying && !coordinator.isSeeking {
            let effectiveRate = coordinator.playbackRate > 0 ? coordinator.playbackRate : 1.0
            coordinator.synchronizer.setRate(effectiveRate, time: coordinator.currentTime)
        }
        onAudioFault?(fault)
    }

    private func handleWorkerCrash(_ error: MediaWorkerError) {
        guard !isTornDown else { return }
        activeSessionId = nil
        packetPumpTask?.cancel()
        packetPumpTask = nil
        reportError(error)
    }

    public func startPlayback(autoPlay: Bool = true) async {
        resumeInitialReadinessWaiters()
        isTornDown = false
        hasEnqueuedInitialMediaSample = false
        activeSeekTask?.cancel()
        activeSeekTask = nil
        playbackGeneration &+= 1
        let generation = playbackGeneration
        inputExhausted = false
        isLoading = true
        errorMessage = nil
        fatalError = nil
        audioFault = nil
        isAudioIsolated = false
        enqueuedAudioPacketCount = 0
        enqueuedVideoPacketCount = 0
        ignoredMismatchedStreamPackets = 0
        ignoredStaleSeekResponseCount = 0
        videoTrack = nil
        audioTrack = nil
        selectedVideoStreamIndex = nil
        selectedAudioStreamIndex = nil
        videoFormatDesc = nil
        audioFormatDesc = nil
        naturalVideoSize = .zero
        rawVideoNaturalSize = nil
        videoPixelAspectRatio = CGSize(width: 1, height: 1)
        videoRotationDegrees = 0
        catalogSubtitleTracks = []
        resetSampleObservationForNewGeneration()
        formatPresentationState = VideoFormatPresentationState()
        coordinator.setUserPlaybackIntent(autoPlay)
        audioPipeline.resetIsolationState()

        do {
            let metadata = try await client.open(url: url)
            guard !Task.isCancelled, generation == playbackGeneration else {
                try? await client.close(sessionId: metadata.sessionId)
                return
            }
            self.activeSessionId = metadata.sessionId
            self.catalogSubtitleTracks = metadata.catalogSubtitleTracks

            try validateAndConfigureVideoTrack(from: metadata)

            let dur = metadata.durationSeconds > 0
                ? CMTime(seconds: metadata.durationSeconds, preferredTimescale: 600)
                : .indefinite
            coordinator.prepare(duration: dur, readyImmediately: false)

            configureAudioTrack(from: metadata)

            packetPumpTask?.cancel()
            packetPumpTask = Task { [weak self] in
                await self?.pumpPackets(generation: generation)
            }
        } catch {
            guard generation == playbackGeneration, !Task.isCancelled else { return }
            isLoading = false
            reportError(error)
        }
    }

    private func validateAndConfigureVideoTrack(from metadata: TTMediaStreamInfo) throws {
        if metadata.metadataCapability == "legacy_c_abi_missing_track_identity" {
            throw AVSampleBufferFatalPlaybackError.containerCorrupted(
                "Compatibility limitation: native demuxer lacks structured V1 track identity metadata (ttmedia_demux_query_tracks_json)"
            )
        }
        guard !metadata.format.isEmpty, metadata.format != "corrupted" else {
            throw AVSampleBufferFatalPlaybackError.containerCorrupted(
                "Invalid or corrupted media container format"
            )
        }
        guard let candidate = metadata.videoTracks.first(where: \.isSelectedForPackets) ?? metadata.videoTracks.first else {
            self.videoTrack = nil
            self.selectedVideoStreamIndex = nil
            self.naturalVideoSize = .zero
            self.rawVideoNaturalSize = nil
            self.videoPixelAspectRatio = CGSize(width: 1, height: 1)
            self.videoRotationDegrees = 0
            return
        }
        guard candidate.trackIndex >= 0 else {
            throw AVSampleBufferFatalPlaybackError.containerCorrupted(
                "Compatibility limitation: video track is missing valid container trackIndex"
            )
        }
        guard let vCodec = candidate.codec, candidate.demuxSelectable else {
            throw AVSampleBufferFatalPlaybackError.containerCorrupted(
                "Unsupported video codec: \(candidate.codecName)"
            )
        }
        guard candidate.width > 0, candidate.height > 0 else {
            throw AVSampleBufferFatalPlaybackError.containerCorrupted(
                "Invalid or missing video dimensions (\(candidate.width)x\(candidate.height)) for \(vCodec.rawValue)"
            )
        }
        let resolvedIndex = metadata.selectedVideoTrackNumber ?? candidate.trackIndex
        guard resolvedIndex >= 0 else {
            throw AVSampleBufferFatalPlaybackError.containerCorrupted(
                "Invalid selected video track number \(resolvedIndex)"
            )
        }
        self.videoTrack = candidate
        self.selectedVideoStreamIndex = UInt32(resolvedIndex)
        let rawW = candidate.pixelWidth > 0 ? candidate.pixelWidth : candidate.width
        let rawH = candidate.pixelHeight > 0 ? candidate.pixelHeight : candidate.height
        let rawSize = CGSize(width: CGFloat(rawW), height: CGFloat(rawH))
        let par = VideoContentGeometry.pixelAspectRatio(
            pixelWidth: rawW, pixelHeight: rawH,
            displayWidth: candidate.displayWidth, displayHeight: candidate.displayHeight
        )
        self.rawVideoNaturalSize = rawSize
        self.videoPixelAspectRatio = par
        self.videoRotationDegrees = 0
        self.naturalVideoSize = VideoContentGeometry.orientedDisplaySize(
            rawVideoSize: rawSize, pixelAspectRatio: par, rotationDegrees: 0
        )
        self.formatPresentationState = Self.makeFormatPresentationState(from: candidate)
        VideoRendererOutputEvaluator.configureDisplayLayerEDR(
            displayLayer: coordinator.displayLayer,
            sourceDynamicRange: formatPresentationState.sourceDynamicRange,
            hostScreen: latestHostScreenObservation
        )
    }

    private func configureAudioTrack(from metadata: TTMediaStreamInfo) {
        let allAudio = !metadata.audioTracks.isEmpty ? metadata.audioTracks : metadata.catalogAudioTracks
        guard !allAudio.isEmpty else {
            self.audioTrack = nil
            self.selectedAudioStreamIndex = nil
            audioPipeline.detach(from: coordinator.synchronizer)
            return
        }
        if let selNum = metadata.selectedAudioTrackNumber,
           let matched = allAudio.first(where: { $0.trackIndex == selNum }) {
            activateOrIsolateAudioCandidate(matched)
            return
        }
        if metadata.selectedAudioTrackNumber == nil,
           let primNum = metadata.primaryAudioTrackNumber,
           let primary = allAudio.first(where: { $0.trackIndex == primNum }) {
            activateOrIsolateAudioCandidate(primary)
            return
        }
        if let selectedCandidate = allAudio.first(where: \.isSelectedForPackets) {
            activateOrIsolateAudioCandidate(selectedCandidate)
            return
        }

        activateOrIsolateAudioCandidate(allAudio[0])
    }

    private func activateOrIsolateAudioCandidate(_ track: TTMediaAudioTrackInfo) {
        if let fault = AVSampleBufferAudioPipeline.validateCandidateTrack(track) {
            isolateAudioFault(fault)
            return
        }
        self.audioTrack = track
        self.selectedAudioStreamIndex = UInt32(track.trackIndex)
        audioPipeline.attach(to: coordinator.synchronizer)
    }

    private func evaluateInitialEOFError() -> AVSampleBufferFatalPlaybackError? {
        guard !hasEnqueuedInitialMediaSample else { return nil }
        if videoTrack != nil {
            return .containerCorrupted("Media stream ended at EOF with 0 decoded video frames")
        }
        return .containerCorrupted("Media stream ended at EOF with 0 decoded audio or video packets")
    }

    private func pumpPackets(generation: UInt64) async {
        guard let sessionId = activeSessionId else { return }
        while !Task.isCancelled, generation == playbackGeneration {
            do {
                guard let packet = try await client.readNextPacket(sessionId: sessionId) else {
                    guard generation == playbackGeneration, !Task.isCancelled else { return }
                    if let eofError = evaluateInitialEOFError() {
                        reportError(eofError, message: eofError.localizedDescription)
                        break
                    }
                    inputExhausted = true
                    coordinator.finishInput(at: lastSampleEnd)
                    break
                }

                if packet.mediaType == .audio {
                    try await processAudioPacket(packet, generation: generation)
                } else if packet.mediaType == .video {
                    try await processVideoPacket(packet, generation: generation)
                }
            } catch is CancellationError {
                break
            } catch {
                if !Task.isCancelled, generation == playbackGeneration {
                    reportError(error, message: error.localizedDescription)
                }
                break
            }
        }
    }

    private func processAudioPacket(_ packet: MediaPacketDTO, generation: UInt64) async throws {
        guard !isAudioIsolated, audioTrack != nil else { return }
        if let expectedStreamIndex = selectedAudioStreamIndex, packet.streamIndex != expectedStreamIndex {
            ignoredMismatchedStreamPackets += 1
            return
        }
        if coordinator.shouldDiscardPrerollAudio(pts: packet.presentationTimeStamp, duration: packet.duration) {
            return
        }
        let ready = try await waitForAudioBackpressure(generation: generation)
        try Task.checkCancellation()
        guard generation == playbackGeneration, ready, !isAudioIsolated else { return }

        let codecLabel = audioTrack?.codecName
        do {
            try enqueueAudioPacket(packet)
        } catch {
            let fault = AVSampleBufferAudioPipeline.classifyFault(
                from: error, codecName: codecLabel,
                sampleRateHz: audioTrack?.sampleRate, channelCount: audioTrack?.channels
            )
            isolateAudioFault(fault)
            return
        }

        enqueuedAudioPacketCount += 1
        if videoTrack == nil, !hasEnqueuedInitialMediaSample {
            completeInitialMediaReadiness()
        }
        if let rendererFault = audioPipeline.detectRendererFailure(
            codec: audioTrack?.codec, codecName: codecLabel,
            sampleRateHz: audioTrack?.sampleRate, channelCount: audioTrack?.channels
        ) {
            isolateAudioFault(rendererFault)
            return
        }

        let sampleEnd = CMTimeAdd(packet.presentationTimeStamp, packet.duration)
        if sampleEnd.isNumeric, sampleEnd > lastSampleEnd {
            lastSampleEnd = sampleEnd
        }
    }

    private func processVideoPacket(_ packet: MediaPacketDTO, generation: UInt64) async throws {
        if let expectedStreamIndex = selectedVideoStreamIndex, packet.streamIndex != expectedStreamIndex {
            ignoredMismatchedStreamPackets += 1
            return
        }
        try await waitForVideoBackpressure(generation: generation)
        try Task.checkCancellation()
        guard generation == playbackGeneration else { return }

        let sampleEnd = CMTimeAdd(packet.presentationTimeStamp, packet.duration)
        if sampleEnd.isNumeric, sampleEnd > lastSampleEnd {
            lastSampleEnd = sampleEnd
        }
        try enqueueVideoPacket(packet)
        enqueuedVideoPacketCount += 1
        if coordinator.displayLayer.status == .failed {
            throw AVSampleBufferFatalPlaybackError.containerCorrupted(
                coordinator.displayLayer.error?.localizedDescription ?? "Video display layer failed"
            )
        }
        if !hasEnqueuedInitialMediaSample, coordinator.hasAnchoredInitialFrame {
            completeInitialMediaReadiness()
        }
        if isAudioIsolated && coordinator.isPlaying && !coordinator.isSeeking && coordinator.synchronizer.rate == 0 {
            let effectiveRate = coordinator.playbackRate > 0 ? coordinator.playbackRate : 1.0
            coordinator.synchronizer.setRate(effectiveRate, time: coordinator.currentTime)
        }
    }

    private func enqueueVideoPacket(_ packet: MediaPacketDTO) throws {
        guard let track = videoTrack, let codec = track.codec, track.width > 0, track.height > 0 else {
            throw AVSampleBufferFatalPlaybackError.containerCorrupted("Missing or invalid video track configuration")
        }
        if videoFormatDesc == nil {
            let params = VideoFormatParameters(
                codec: codec, width: Int32(track.width), height: Int32(track.height),
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                colorPrimaries: track.colorMetadata.colorPrimaries,
                transferFunction: track.colorMetadata.transferCharacteristics,
                yCbCrMatrix: track.colorMetadata.matrixCoefficients,
                extradata: track.extradata ?? Data()
            )
            let createdDesc = try reconstructor.formatDescription(for: packet.streamIndex, parameters: params)
            videoFormatDesc = createdDesc
            if videoPixelAspectRatio == CGSize(width: 1, height: 1) {
                let formatPAR = VideoContentGeometry.extractPixelAspectRatio(from: createdDesc)
                if formatPAR != CGSize(width: 1, height: 1), let rawSize = rawVideoNaturalSize {
                    videoPixelAspectRatio = formatPAR
                    naturalVideoSize = VideoContentGeometry.orientedDisplaySize(
                        rawVideoSize: rawSize, pixelAspectRatio: formatPAR, rotationDegrees: videoRotationDegrees
                    )
                }
            }
        }
        if let desc = videoFormatDesc {
            let sample = try reconstructor.reconstruct(packet: packet, formatDescription: desc)
            coordinator.enqueueVideoBuffer(sample)
        }
    }

    private func enqueueAudioPacket(_ packet: MediaPacketDTO) throws {
        guard let track = audioTrack, !isAudioIsolated else { return }
        guard let codec = track.codec, codec != .vorbis else {
            let label = track.codecName.isEmpty ? (track.codec?.rawValue ?? "unknown") : track.codecName
            throw AVSampleBufferAudioPipelineError.unsupportedCodec(label)
        }
        guard track.sampleRate > 0, track.channels > 0 else {
            throw AVSampleBufferAudioPipelineError.formatDescriptionFailed(-50)
        }
        let extradata = track.extradata ?? Data()
        if enqueuedAudioPacketCount == 0,
           let unsupportedSig = AVSampleBufferAudioPipeline.detectUnsupportedBitstreamSignature(
               payload: packet.payloadData, codec: codec, extradata: extradata, channelCount: UInt32(track.channels)
           ) {
            throw AVSampleBufferAudioPipelineError.unsupportedCodec(unsupportedSig)
        }
        if audioFormatDesc == nil {
            let params = AudioFormatParameters(
                codec: codec, sampleRate: track.sampleRate, channelCount: UInt32(track.channels),
                bitsPerChannel: UInt32(track.bitDepth ?? 16), channelLayoutTag: 0, extradata: extradata
            )
            audioFormatDesc = try audioPipeline.createAudioFormatDescription(from: params)
        }
        if let desc = audioFormatDesc {
            try audioPipeline.reconstructAndEnqueue(packet: packet, formatDescription: desc)
        }
    }

    private var isVideoQueueReadyForMoreMediaData: Bool {
        if let override = videoQueueReadinessOverride {
            return override()
        }
        return coordinator.displayLayer.isReadyForMoreMediaData
    }

    private func waitForVideoBackpressure(generation: UInt64) async throws {
        var prerollBackpressurePolls = 0
        while !isVideoQueueReadyForMoreMediaData {
            if coordinator.displayLayer.status == .failed {
                throw AVSampleBufferFatalPlaybackError.containerCorrupted(
                    coordinator.displayLayer.error?.localizedDescription ?? "Video display layer failed"
                )
            }
            if coordinator.isPrerolling {
                prerollBackpressurePolls += 1
                if prerollBackpressurePolls >= max(1, prerollBackpressureDrainThreshold) {
                    prerollBackpressurePolls = 0
                    coordinator.drainPrerollVideoQueueForBackpressure()
                    if isVideoQueueReadyForMoreMediaData {
                        break
                    }
                }
            }
            try await Task.sleep(nanoseconds: backpressurePollIntervalNanos)
            if Task.isCancelled || generation != playbackGeneration { return }
        }
    }

    private func waitForAudioBackpressure(generation: UInt64) async throws -> Bool {
        guard !isAudioIsolated, audioTrack != nil else { return false }
        var consecutiveFrozenClockPolls = 0
        var lastObservedClockSeconds = CMTimeGetSeconds(coordinator.synchronizer.currentTime())

        while !audioPipeline.isReadyForMoreMediaData {
            if shouldAbortAudioBackpressureWait(generation: generation) {
                return false
            }
            if let rendererFault = audioPipeline.detectRendererFailure(
                codec: audioTrack?.codec, codecName: audioTrack?.codecName,
                sampleRateHz: audioTrack?.sampleRate, channelCount: audioTrack?.channels
            ) {
                isolateAudioFault(rendererFault)
                return false
            }
            if evaluateAudioBackpressureStallEvidence(
                lastObservedClockSeconds: &lastObservedClockSeconds,
                consecutiveFrozenClockPolls: &consecutiveFrozenClockPolls
            ) {
                isolateAudioFault(
                    AVSampleBufferAudioFault(
                        kind: .audioInitializationFailed,
                        stage: .pipelineStall,
                        codecName: audioTrack?.codecName,
                        statusCode: 1_718_449_215,
                        diagnosticDetail: "Persistent audio renderer stall under active play intent with queued media and frozen synchronizer clock",
                        sampleRateHz: audioTrack?.sampleRate,
                        channelCount: audioTrack?.channels
                    )
                )
                return false
            }
            try await Task.sleep(nanoseconds: backpressurePollIntervalNanos)
        }
        return !isAudioIsolated
    }

    private func shouldAbortAudioBackpressureWait(generation: UInt64) -> Bool {
        Task.isCancelled || generation != playbackGeneration || isAudioIsolated || activeSessionId == nil
    }

    private func isEligibleForAudioStallCheck() -> Bool {
        guard coordinator.isPlaying, !coordinator.isSeeking else { return false }
        guard enqueuedAudioPacketCount > 0, enqueuedVideoPacketCount > 0 else { return false }
        return audioPipeline.isAttachedToSynchronizer && coordinator.displayLayer.status != .failed
    }

    private func evaluateAudioBackpressureStallEvidence(
        lastObservedClockSeconds: inout Double,
        consecutiveFrozenClockPolls: inout Int
    ) -> Bool {
        guard isEligibleForAudioStallCheck() else {
            consecutiveFrozenClockPolls = 0
            lastObservedClockSeconds = CMTimeGetSeconds(coordinator.synchronizer.currentTime())
            return false
        }
        let nowSeconds = CMTimeGetSeconds(coordinator.synchronizer.currentTime())
        let clockAdvanced = nowSeconds.isFinite
            && lastObservedClockSeconds.isFinite
            && (nowSeconds - lastObservedClockSeconds) > 1e-5
        if clockAdvanced {
            consecutiveFrozenClockPolls = 0
            lastObservedClockSeconds = nowSeconds
            return false
        }
        consecutiveFrozenClockPolls += 1
        return consecutiveFrozenClockPolls >= stallPollThreshold
    }

    @discardableResult
    public func requestSeek(to seconds: Double) -> Task<Void, Never>? {
        guard let prepared = prepareSeekOperation(to: seconds) else { return nil }
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executePreparedSeek(prepared)
        }
        activeSeekTask = task
        return task
    }

    public func seek(to seconds: Double) async {
        guard let prepared = prepareSeekOperation(to: seconds) else { return }
        await executePreparedSeek(prepared)
    }

    private struct PreparedSeekContext {
        let sessionId: String
        let clampedSeconds: Double
        let targetTime: CMTime
        let generation: UInt64
        let seekGen: UInt64
        let oldPump: Task<Void, Never>?
    }

    private func prepareSeekOperation(to seconds: Double) -> PreparedSeekContext? {
        guard let sessionId = activeSessionId else { return nil }
        let clampedSeconds = max(0.0, seconds.isFinite ? seconds : 0.0)
        let targetTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        let seekGen = coordinator.beginSeekIntent(to: targetTime)
        audioPipeline.flush()
        activeSeekTask?.cancel()
        activeSeekTask = nil
        playbackGeneration &+= 1
        let generation = playbackGeneration
        resetSampleObservationForNewGeneration()
        refreshLiveOutputObservation(sampleBuffer: nil)
        let oldPump = packetPumpTask
        packetPumpTask = nil
        oldPump?.cancel()
        return PreparedSeekContext(
            sessionId: sessionId, clampedSeconds: clampedSeconds, targetTime: targetTime,
            generation: generation, seekGen: seekGen, oldPump: oldPump
        )
    }

    private func executePreparedSeek(_ ctx: PreparedSeekContext) async {
        await ctx.oldPump?.value
        guard ctx.generation == playbackGeneration, ctx.seekGen == coordinator.seekGeneration, !Task.isCancelled else {
            return
        }
        do {
            _ = try await client.seek(to: ctx.clampedSeconds, sessionId: ctx.sessionId, accurate: false)
            guard ctx.generation == playbackGeneration, ctx.seekGen == coordinator.seekGeneration, !Task.isCancelled else {
                ignoredStaleSeekResponseCount += 1
                return
            }
            errorMessage = nil
            fatalError = nil
            inputExhausted = false
            isLoading = !hasEnqueuedInitialMediaSample
            lastSampleEnd = .zero
            coordinator.seek(to: ctx.targetTime, preroll: true, preserveCurrentIntent: true)
            packetPumpTask?.cancel()
            let generation = ctx.generation
            packetPumpTask = Task { [weak self] in await self?.pumpPackets(generation: generation) }
        } catch is CancellationError {
            return
        } catch {
            guard ctx.generation == playbackGeneration, ctx.seekGen == coordinator.seekGeneration, !Task.isCancelled else {
                ignoredStaleSeekResponseCount += 1
                return
            }
            reportError(error)
        }
    }

    public func teardown() {
        isTornDown = true
        isLoading = false
        resumeInitialReadinessWaiters()
        activeSeekTask?.cancel()
        activeSeekTask = nil
        playbackGeneration &+= 1
        packetPumpTask?.cancel()
        packetPumpTask = nil
        client.cancelAllSubtitleRequestsForActiveSession()
        if let sessionId = activeSessionId {
            activeSessionId = nil
            Task { [client] in
                try? await client.close(sessionId: sessionId)
            }
        }
        coordinator.displayLayer.flush()
        audioPipeline.flush()
        audioPipeline.detach(from: coordinator.synchronizer)
        coordinator.teardown()
    }

    public func stop() async {
        isTornDown = true
        isLoading = false
        resumeInitialReadinessWaiters()
        activeSeekTask?.cancel()
        activeSeekTask = nil
        playbackGeneration &+= 1
        let oldPump = packetPumpTask
        packetPumpTask = nil
        oldPump?.cancel()
        await oldPump?.value

        coordinator.displayLayer.flush()
        audioPipeline.flush()
        audioPipeline.detach(from: coordinator.synchronizer)
        coordinator.teardown()
        client.cancelAllSubtitleRequestsForActiveSession()
        if let sessionId = activeSessionId {
            activeSessionId = nil
            try? await client.close(sessionId: sessionId)
        }
    }
}
