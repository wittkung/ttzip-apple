// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import Observation
import os
import TTI18nCore
import TTI18nUI

/// Playback and subtitle state belong to the media, never to a viewport layout.
@MainActor
@Observable
internal final class VideoPlaybackSession {
    let timelineThumbnails = VideoTimelineThumbnailSource()
    let sessionID = UUID()
    let url: URL
    let canonicalURL: URL
    let coordinatorID = UUID().uuidString
    let experienceStore: PlaybackExperienceStore
    private(set) var isStopped = false
    private(set) var stopReason: String?
    private(set) var hasStarted = false
    private(set) var lastKnownTime: CMTime = .zero
    private(set) var lastKnownWasPlaying = false
    private(set) var activeViewports: Set<UUID> = []
    private var viewportOrder: [UUID] = []
    private var viewportFullScreenFlags: [UUID: Bool] = [:]
    private(set) var activePresenterViewportID: UUID?

    var playbackError: String?
    var playbackFaultCategory: VideoPlaybackFaultCategory?
    var audioFaultNotice: String?
    var isAudioFaultIsolated = false
    var isLoading = true
    var isShowingLoadingIndicator = false
    var loadingIndicatorDelayNanoseconds: UInt64 = 350_000_000
    var naturalVideoSize: CGSize = .zero
    var rawVideoNaturalSize: CGSize? = nil
    var videoPixelAspectRatio: CGSize = CGSize(width: 1, height: 1)
    var videoRotationDegrees: Int = 0
    var userRotationDegrees: Int = 0 {
        didSet { savePlaybackExperience(force: true); publishPresentationGeometry() }
    }
    var checkpointState = VideoPlaybackCheckpointState()
    var effectiveRotationDegrees: Int {
        VideoContentGeometry.normalizedRotationDegrees(videoRotationDegrees + userRotationDegrees)
    }
    var catalogSubtitleTracks: [TTMediaSubtitleTrackInfo] = []
    @ObservationIgnored var lastKnownVideoContentRect: CGRect? = nil
    @ObservationIgnored var latestHostScreenObservation: VideoHostScreenObservation? = nil
    var formatPresentationState = VideoFormatPresentationState()
    var telemetry = VideoPlaybackTelemetryMetrics()
    var activeController: VideoPlaybackController?
    var isPlaying = false {
        didSet {
            if isPlaying { lastKnownWasPlaying = true }
            MediaPlaybackCoordinator.shared.updatePlaybackState(id: coordinatorID, isPlaying: isPlaying)
        }
    }
    var currentTime: CMTime = .zero {
        didSet {
            if !isTearingDown,
               !isSettingUpPlayback,
               currentTime.isValid,
               !currentTime.isIndefinite,
               CMTimeGetSeconds(currentTime) >= 0 {
                lastKnownTime = currentTime
            }
            refreshActiveSubtitleTexts()
            savePlaybackExperience()
        }
    }
    var duration: CMTime = .zero
    var volume: Float = 1
    var isMuted = false
    var previousVolume: Float = 1
    var playbackRate: Float = 1
    var subtitleTrack: ExternalSubtitleTrack? {
        didSet { refreshActiveSubtitleTexts() }
    }
    var bitmapSubtitleTrack: BitmapSubtitleTrack?
    var secondarySubtitleTrack: ExternalSubtitleTrack? {
        didSet { refreshActiveSubtitleTexts() }
    }
    var subtitleName: String?
    var secondarySubtitleName: String?
    var subtitleError: String?
    var isSubtitleLoading = false
    var pendingPrimarySubtitleSelection: PendingSubtitleSelection?
    var pendingSecondarySubtitleSelection: PendingSubtitleSelection?
    var subtitleLoadGeneration = UUID()
    var secondarySubtitleLoadGeneration = UUID()
    var subtitlePrewarmGeneration = UUID()
    var activePrewarmRequestID: UInt64?
    var activePrimaryRequestID: UInt64?
    var activeSecondaryRequestID: UInt64?
    var activeDefaultEmbeddedRequestID: UInt64?
    var embeddedSubtitles: [EmbeddedSubtitleTrack] = []
    var isMergingPreservedSubtitles = false
    var preservedExternalSubtitles: [URL] = []
    var companionSubtitles: [URL] = [] {
        didSet {
            mergePreservedExternalSubtitlesIfNeeded()
        }
    }
    var directorySubtitles: [URL] = []
    var subtitleCache: [String: ExternalSubtitleTrack] = [:]
    var bitmapSubtitleCache: [String: BitmapSubtitleTrack] = [:]
    var selectedSubtitleID: String? { didSet { savePlaybackExperience(force: true) } }
    var selectedSecondarySubtitleID: String = "off" { didSet { savePlaybackExperience(force: true) } }
    var subtitleStyle: SubtitleStyleConfiguration = SubtitleStyleConfiguration.loadFromDefaults() {
        didSet { refreshActiveSubtitleTexts(); savePlaybackExperience(force: true) }
    }
    var activeSubtitleText: String = ""
    var activeSecondarySubtitleText: String = ""
    var osdMessage: String?
    var osdDismissTask: Task<Void, Never>?
    var subtitleDiscoveryTask: Task<Void, Never>?
    var subtitlePrewarmTask: Task<Void, Never>?
    var subtitleLoadTask: Task<Void, Never>?
    var secondarySubtitleLoadTask: Task<Void, Never>?
    var externalSubtitleLoader: @Sendable (URL) async throws -> ExternalSubtitleTrack = { url in
        try await VideoPlaybackSession.loadExternalTrackOffMainActor(from: url)
    }
    var embeddedSubtitleLoader: (@Sendable (Int64) async throws -> Data)?
    var embeddedSubtitleRequestLoader: (@Sendable (Int64, UInt64) async throws -> Data)?
    var embeddedSubtitleRequestCanceller: (@Sendable (UInt64) -> Void)?
    var subtitleTransportOverride: (any MediaSubtitleTransport)?
    var workerClientProvider: @MainActor () -> MediaWorkerXPCClient = { MediaWorkerXPCClient.makeDefault() }
    private var loadTask: Task<Void, Never>?
    private var loadingIndicatorDelayTask: Task<Void, Never>?
    private var isSecurityScoped = false
    private var autoPlay = false
    private var isTearingDown = false
    private var isSettingUpPlayback = false
    var sessionGeneration: UInt64?
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "VideoPlaybackSession")

    var handle: VideoPlaybackSessionHandle {
        VideoPlaybackSessionHandle(sessionID: sessionID, canonicalURL: canonicalURL, sourceURL: url)
    }

    var userPlaybackIntent: Bool {
        activeController?.userPlaybackIntent ?? isPlaying
    }

    var seekGeneration: UInt64 {
        activeController?.seekGeneration ?? 0
    }

    var isUnexpectedlyEmptyController: Bool {
        !isLoading && activeController == nil && playbackError == nil && hasStarted && !isStopped
    }

    var orderedActiveViewports: [UUID] { viewportOrder }

    var activeSubtitleCodec: String? {
        VideoContentGeometry.resolveActiveSubtitleCodec(
            selectedSubtitleID: selectedSubtitleID,
            embeddedSubtitles: embeddedSubtitles,
            catalogSubtitleTracks: catalogSubtitleTracks
        )
    }

    func videoContentRect(in viewportSize: CGSize) -> CGRect? {
        guard viewportSize.width > 0, viewportSize.height > 0,
              let rawSize = rawVideoNaturalSize,
              rawSize.width > 0, rawSize.height > 0 else {
            return nil
        }
        let rect = VideoContentGeometry.contentRect(
            inside: viewportSize,
            rawVideoSize: rawSize,
            pixelAspectRatio: videoPixelAspectRatio,
            rotationDegrees: effectiveRotationDegrees
        )
        if rect.width > 0 && rect.height > 0 {
            lastKnownVideoContentRect = rect
            return rect
        }
        return nil
    }

    func subtitleVideoGeometry(for viewportSize: CGSize) -> SubtitleVideoContentGeometry {
        SubtitleVideoContentGeometry(
            viewportSize: viewportSize,
            videoNaturalSize: rawVideoNaturalSize,
            pixelAspectRatio: videoPixelAspectRatio,
            rotationDegrees: effectiveRotationDegrees,
            explicitVideoRect: videoContentRect(in: viewportSize),
            lastKnownVideoRect: lastKnownVideoContentRect
        )
    }

    func isViewportFullScreen(_ viewportID: UUID) -> Bool {
        viewportFullScreenFlags[viewportID] ?? false
    }

    init(url: URL, experienceStore: PlaybackExperienceStore? = nil) {
        self.experienceStore = experienceStore ?? .shared
        self.url = url
        self.canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        restoreExperienceSettings()
    }

    func seek(to time: CMTime) {
        let rawSeconds = CMTimeGetSeconds(time)
        let clampedSeconds = rawSeconds.isFinite ? max(0.0, rawSeconds) : 0.0
        let clampedTime = CMTime(
            seconds: clampedSeconds,
            preferredTimescale: time.timescale > 0 ? time.timescale : 600
        )
        telemetry.recordSeekRequested()
        lastKnownTime = clampedTime
        currentTime = clampedTime
        if let activeController {
            let intendedPlaying = activeController.userPlaybackIntent || activeController.isPlaying || isPlaying
            activeController.seek(to: clampedTime)
            isPlaying = activeController.isPlaying || (!isLoading && intendedPlaying)
        }
        refreshActiveSubtitleTexts()
    }

    func acquireViewport(
        _ viewportID: UUID,
        isFullScreen: Bool,
        promoteToPresenter: Bool = true,
        caller: String = "claim"
    ) {
        let wasAlreadyActive = activeViewports.contains(viewportID)
        activeViewports.insert(viewportID)
        if !wasAlreadyActive {
            viewportOrder.append(viewportID)
        }
        viewportFullScreenFlags[viewportID] = isFullScreen

        if shouldPromoteViewport(viewportID, isFullScreen: isFullScreen, wasAlreadyActive: wasAlreadyActive, requestedPromote: promoteToPresenter) {
            let previousPresenter = activePresenterViewportID
            activePresenterViewportID = viewportID
            logger.info(
                "[PlaybackLifecycle] PRESENTER_TRANSFER session=\(self.sessionID.uuidString, privacy: .public) from=\(previousPresenter?.uuidString ?? "none", privacy: .public) to=\(viewportID.uuidString, privacy: .public) isFullScreen=\(isFullScreen) activeViewports=\(self.activeViewports.count) caller=\(caller, privacy: .public)"
            )
        } else {
            logger.info(
                "[PlaybackLifecycle] PRESENTER_RETAINED session=\(self.sessionID.uuidString, privacy: .public) presenter=\(self.activePresenterViewportID?.uuidString ?? "none", privacy: .public) candidate=\(viewportID.uuidString, privacy: .public) isFullScreen=\(isFullScreen) wasAlreadyActive=\(wasAlreadyActive) caller=\(caller, privacy: .public)"
            )
        }
        updateFullScreenPresentationFlag()
    }

    private func shouldPromoteViewport(
        _ viewportID: UUID,
        isFullScreen: Bool,
        wasAlreadyActive: Bool,
        requestedPromote: Bool
    ) -> Bool {
        guard let currentPresenter = activePresenterViewportID else { return true }
        guard requestedPromote else { return false }
        let hasOtherActiveFullScreen = activeViewports.contains {
            $0 != viewportID && (viewportFullScreenFlags[$0] ?? false)
        }
        let currentPresenterIsFullScreen = viewportFullScreenFlags[currentPresenter] ?? false
        if !isFullScreen && (hasOtherActiveFullScreen || currentPresenterIsFullScreen) {
            return false
        }
        if wasAlreadyActive && currentPresenter != viewportID {
            return isFullScreen && !currentPresenterIsFullScreen
        }
        return true
    }

    @discardableResult
    func releaseViewport(_ viewportID: UUID, caller: String = "release") -> Bool {
        activeViewports.remove(viewportID)
        viewportOrder.removeAll { $0 == viewportID }
        viewportFullScreenFlags.removeValue(forKey: viewportID)
        if activePresenterViewportID == viewportID {
            let fallback = viewportOrder.last(where: { viewportFullScreenFlags[$0] == true }) ?? viewportOrder.last
            activePresenterViewportID = fallback
            logger.info(
                "[PlaybackLifecycle] PRESENTER_FALLBACK session=\(self.sessionID.uuidString, privacy: .public) departed=\(viewportID.uuidString, privacy: .public) fallback=\(fallback?.uuidString ?? "none", privacy: .public) remainingViewports=\(self.activeViewports.count) caller=\(caller, privacy: .public)"
            )
        }
        updateFullScreenPresentationFlag()
        return activeViewports.isEmpty
    }

    private func updateFullScreenPresentationFlag() {
        let anyFullScreen = viewportFullScreenFlags.values.contains(true)
        MediaPlaybackCoordinator.shared.setFullScreenPresentation(id: coordinatorID, isFullScreen: anyFullScreen)
    }



    func restorePreservedContext(from previous: VideoPlaybackSession) {
        let time = previous.lastKnownTime
        if time.isValid && !time.isIndefinite && CMTimeGetSeconds(time) >= 0 {
            self.lastKnownTime = time
            self.currentTime = time
        }
        self.volume = previous.volume
        self.isMuted = previous.isMuted
        self.previousVolume = previous.previousVolume
        self.playbackRate = previous.playbackRate
        self.externalSubtitleLoader = previous.externalSubtitleLoader
        self.embeddedSubtitleLoader = previous.embeddedSubtitleLoader
        self.embeddedSubtitleRequestLoader = previous.embeddedSubtitleRequestLoader
        self.embeddedSubtitleRequestCanceller = previous.embeddedSubtitleRequestCanceller
        self.subtitleTransportOverride = previous.subtitleTransportOverride
        self.subtitleCache = previous.subtitleCache
        self.bitmapSubtitleCache = previous.bitmapSubtitleCache
        self.embeddedSubtitles = previous.embeddedSubtitles
        self.directorySubtitles = previous.directorySubtitles
        self.preservedExternalSubtitles = previous.preservedExternalSubtitles
        registerPreservedExternalURL(from: previous.selectedSubtitleID)
        registerPreservedExternalURL(from: previous.selectedSecondarySubtitleID)
        self.companionSubtitles = previous.companionSubtitles
        self.selectedSubtitleID = previous.selectedSubtitleID
        self.selectedSecondarySubtitleID = previous.selectedSecondarySubtitleID
        self.subtitleName = previous.subtitleName
        self.secondarySubtitleName = previous.secondarySubtitleName
        self.subtitleTrack = previous.subtitleTrack ?? previous.selectedSubtitleID.flatMap { previous.subtitleCache[$0] }
        self.bitmapSubtitleTrack = previous.bitmapSubtitleTrack ?? previous.selectedSubtitleID.flatMap { previous.bitmapSubtitleCache[$0] }
        if previous.selectedSecondarySubtitleID != "off" {
            self.secondarySubtitleTrack = previous.secondarySubtitleTrack ?? previous.subtitleCache[previous.selectedSecondarySubtitleID]
        }
        self.subtitleStyle = previous.subtitleStyle
        self.naturalVideoSize = previous.naturalVideoSize
        self.rawVideoNaturalSize = previous.rawVideoNaturalSize
        self.videoPixelAspectRatio = previous.videoPixelAspectRatio
        self.videoRotationDegrees = previous.videoRotationDegrees
        self.catalogSubtitleTracks = previous.catalogSubtitleTracks
        self.lastKnownVideoContentRect = previous.lastKnownVideoContentRect
        self.formatPresentationState = previous.formatPresentationState
        if previous.playbackError == nil, previous.isAudioFaultIsolated {
            self.isAudioFaultIsolated = true
            self.audioFaultNotice = previous.audioFaultNotice
            self.playbackFaultCategory = previous.playbackFaultCategory
        }
        refreshActiveSubtitleTexts()
    }





    func start(autoPlay: Bool) {
        guard !hasStarted, loadTask == nil, !isStopped else {
            logger.info(
                "[PlaybackLifecycle] START_IGNORED session=\(self.sessionID.uuidString, privacy: .public) hasStarted=\(self.hasStarted) isStopped=\(self.isStopped) requestedAutoPlay=\(autoPlay) currentIsPlaying=\(self.isPlaying) currentTime=\(CMTimeGetSeconds(self.currentTime))"
            )
            return
        }
        self.hasStarted = true
        self.autoPlay = autoPlay
        logger.info(
            "[PlaybackLifecycle] START_BEGIN session=\(self.sessionID.uuidString, privacy: .public) url=\(self.url.lastPathComponent, privacy: .public) autoPlay=\(autoPlay) resumeTime=\(CMTimeGetSeconds(self.lastKnownTime))"
        )
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let generation = await PreviewSessionCoordinator.shared.beginSession(targetURL: url)
            guard !Task.isCancelled else { return }
            sessionGeneration = generation
            await setupPlayback(for: url, generation: generation)
        }
    }

    func stop(reason: String = "unspecified") {
        savePlaybackExperience(force: true)
        let controllerID = activeController?.identityDescription ?? "none"
        logger.info(
            "[PlaybackLifecycle] STOP session=\(self.sessionID.uuidString, privacy: .public) controller=\(controllerID, privacy: .public) reason=\(reason, privacy: .public) activeViewports=\(self.activeViewports.count) presenter=\(self.activePresenterViewportID?.uuidString ?? "none", privacy: .public)"
        )
        stopReason = reason
        isStopped = true
        timelineThumbnails.stop()
        cancelSilentLoadingIndicator()
        pendingPrimarySubtitleSelection = nil
        pendingSecondarySubtitleSelection = nil
        subtitleLoadGeneration = UUID()
        secondarySubtitleLoadGeneration = UUID()
        subtitlePrewarmGeneration = UUID()
        cancelAllSessionSubtitleRequests()
        MediaPlaybackCoordinator.shared.unregisterSession(id: coordinatorID)
        loadTask?.cancel()
        loadTask = nil
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        secondarySubtitleLoadTask?.cancel()
        secondarySubtitleLoadTask = nil
        subtitleDiscoveryTask?.cancel()
        subtitleDiscoveryTask = nil
        subtitlePrewarmTask?.cancel()
        subtitlePrewarmTask = nil
        osdDismissTask?.cancel()
        osdDismissTask = nil
        if let sessionGeneration {
            PreviewSessionCoordinator.shared.cancelSession(generation: sessionGeneration)
        }
        teardownPlayback()
    }

    private func scheduleSilentLoadingIndicator(for generation: UInt64) {
        loadingIndicatorDelayTask?.cancel()
        isShowingLoadingIndicator = false
        let delayNanos = loadingIndicatorDelayNanoseconds
        loadingIndicatorDelayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanos)
            guard !Task.isCancelled,
                  let self,
                  !self.isStopped,
                  self.sessionGeneration == generation,
                  self.isLoading,
                  self.playbackError == nil,
                  !self.telemetry.hasEnqueuedFirstVideoSample else {
                return
            }
            self.isShowingLoadingIndicator = true
        }
    }

    internal func cancelSilentLoadingIndicator() {
        loadingIndicatorDelayTask?.cancel()
        loadingIndicatorDelayTask = nil
        isShowingLoadingIndicator = false
    }

    private func registerPlaybackControls() {
        MediaPlaybackCoordinator.shared.registerSession(
            id: coordinatorID, isPlaying: isPlaying,
            togglePlayPause: { [weak self] in
                guard let self, let active = self.activeController else { return }
                active.togglePlayPause()
                self.isPlaying = active.userPlaybackIntent || active.isPlaying
            },
            seekBy: { [weak self] delta in
                guard let self else { return }
                let seconds = max(0, CMTimeGetSeconds(currentTime) + delta)
                self.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
            },
            stop: { [weak self] in self?.stop(reason: "MediaPlaybackCoordinator.stop") }
        )
        updateFullScreenPresentationFlag()
    }

    private func isGenerationValid(_ generation: UInt64) -> Bool {
        !Task.isCancelled && PreviewSessionCoordinator.shared.isSessionActive(generation: generation)
    }

    private func makePlaybackController(for targetURL: URL) -> VideoPlaybackController {
        let ext = targetURL.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) {
            let nc = AVAssetReaderPlaybackController(url: targetURL)
            nc.registersWithCoordinator = false
            return .native(nc)
        }
        let wc = AVSampleBufferWorkerPlaybackController(url: targetURL, client: workerClientProvider())
        return .worker(wc)
    }

    private func loadController(_ wrapper: VideoPlaybackController) async throws {
        switch wrapper {
        case .native(let nc):
            try await nc.load(autoPlay: autoPlay)
        case .worker(let wc):
            await wc.startPlayback(autoPlay: autoPlay)
            await wc.waitForInitialMediaReadinessOrFailure()
            if let fatalError = wc.fatalError {
                throw fatalError
            }
        }
    }

    func setVolume(_ vol: Float) {
        let clamped = max(0.0, min(1.0, vol))
        volume = clamped
        if clamped > 0 {
            previousVolume = clamped
        }
        isMuted = (clamped == 0.0)
        activeController?.setMuted(isMuted)
        activeController?.setVolume(clamped)
    }

    func toggleMute() {
        if isMuted {
            isMuted = false
            let restore = previousVolume > 0 ? previousVolume : 0.8
            volume = restore
            activeController?.setMuted(false)
            activeController?.setVolume(restore)
        } else {
            if volume > 0 {
                previousVolume = volume
            } else if previousVolume <= 0 {
                previousVolume = 0.8
            }
            isMuted = true
            volume = 0.0
            activeController?.setMuted(true)
            activeController?.setVolume(0.0)
        }
    }

    func setPlaybackRate(_ rate: Float) {
        let clamped = rate > 0 ? rate : 1.0
        playbackRate = clamped
        activeController?.setPlaybackRate(clamped)
    }

    func applyPlaybackSettings(to wrapper: VideoPlaybackController) {
        let clampedRate = playbackRate > 0 ? playbackRate : 1.0
        playbackRate = clampedRate
        let clampedVolume = max(0.0, min(1.0, volume))
        if isMuted {
            if clampedVolume > 0 {
                previousVolume = clampedVolume
            } else if previousVolume <= 0 {
                previousVolume = 0.8
            }
            volume = 0.0
            wrapper.setMuted(true)
            wrapper.setVolume(0.0)
        } else {
            volume = clampedVolume
            if clampedVolume > 0 {
                previousVolume = clampedVolume
            }
            wrapper.setMuted(false)
            wrapper.setVolume(clampedVolume)
        }
        wrapper.setPlaybackRate(clampedRate)
    }

    private func syncControllerMetadata(from wrapper: VideoPlaybackController) {
        self.naturalVideoSize = wrapper.naturalVideoSize
        self.rawVideoNaturalSize = wrapper.rawVideoNaturalSize
        self.videoPixelAspectRatio = wrapper.videoPixelAspectRatio
        self.videoRotationDegrees = wrapper.videoRotationDegrees
        publishPresentationGeometry()
        self.catalogSubtitleTracks = wrapper.catalogSubtitleTracks
        self.formatPresentationState = wrapper.formatPresentationState
    }

    private func finalizeLoadedController(_ wrapper: VideoPlaybackController, resumeTime requestedResumeTime: CMTime) {
        cancelSilentLoadingIndicator()
        telemetry.recordControllerLoaded()
        self.duration = wrapper.duration
        timelineThumbnails.start(url: url, duration: duration.seconds)
        let resumeTime = restoredExperienceTime(or: requestedResumeTime)
        syncControllerMetadata(from: wrapper)
        self.isPlaying = wrapper.isPlaying
        if case .worker(let wc) = wrapper, wc.isAudioIsolated, let fault = wc.audioFault {
            applyAudioFault(fault)
        }
        applyPlaybackSettings(to: wrapper)
        if case .worker(let wc) = wrapper, wc.seekGeneration > 0 {
            self.lastKnownTime = wc.coordinator.currentTime
            self.currentTime = wc.coordinator.currentTime
        } else if resumeTime.isValid && !resumeTime.isIndefinite && CMTimeGetSeconds(resumeTime) > 0 {
            self.lastKnownTime = resumeTime
            self.currentTime = resumeTime
            wrapper.seek(to: resumeTime)
        } else {
            self.lastKnownTime = .zero
            self.currentTime = .zero
        }
        refreshActiveSubtitleTexts()
        registerPlaybackControls()
        discoverSubtitles()
        let discoveryTask = subtitleDiscoveryTask
        Task { @MainActor [weak self] in
            await discoveryTask?.value
            guard let self, !self.isStopped else { return }
            self.restoreSelectedSubtitlesAfterDiscoveryIfNeeded()
        }
        logger.info(
            "[PlaybackLifecycle] LOAD_SUCCESS session=\(self.sessionID.uuidString, privacy: .public) controller=\(wrapper.identityDescription, privacy: .public) autoPlay=\(self.autoPlay) isPlaying=\(self.isPlaying) duration=\(CMTimeGetSeconds(self.duration)) presenter=\(self.activePresenterViewportID?.uuidString ?? "none", privacy: .public)"
        )
    }

    private func setupPlayback(for targetURL: URL, generation: UInt64) async {
        let resumeTime = lastKnownTime
        teardownPlayback()
        isLoading = true
        isSettingUpPlayback = true
        telemetry.recordLoadStart()
        scheduleSilentLoadingIndicator(for: generation)
        defer {
            isSettingUpPlayback = false
            if sessionGeneration == generation {
                isLoading = false
                cancelSilentLoadingIndicator()
            }
        }
        playbackError = nil
        playbackFaultCategory = nil
        audioFaultNotice = nil
        isAudioFaultIsolated = false
        guard isGenerationValid(generation) else { return }

        if SecurityScopedResourceManager.shared.startAccessing(url: targetURL) {
            isSecurityScoped = true
        }

        let wrapper = makePlaybackController(for: targetURL)
        applyPlaybackSettings(to: wrapper)
        propagateHostScreenObservation(to: wrapper)
        configureCallbacks(for: wrapper)

        guard isGenerationValid(generation) else {
            discardController(wrapper, reason: "cancelled_before_load")
            return
        }
        self.activeController = wrapper

        do {
            try await loadController(wrapper)
            guard isGenerationValid(generation) else {
                discardController(wrapper, reason: "cancelled_after_load")
                return
            }
            isSettingUpPlayback = false
            finalizeLoadedController(wrapper, resumeTime: resumeTime)
        } catch is CancellationError {
            discardController(wrapper, reason: "CancellationError")
        } catch {
            guard isGenerationValid(generation) else {
                discardController(wrapper, reason: "cancelled_on_error")
                return
            }
            applyFatalPlaybackError(error)
            logger.warning(
                "[PlaybackLifecycle] LOAD_FAILED session=\(self.sessionID.uuidString, privacy: .public) controller=\(wrapper.identityDescription, privacy: .public) url=\(targetURL.lastPathComponent, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            discardController(wrapper, reason: "load_error:\(error.localizedDescription)")
        }
    }

    private func isActiveControllerCallbackValid(for wrapper: VideoPlaybackController, requireNotStopped: Bool = true) -> Bool {
        if requireNotStopped && isStopped { return false }
        return activeController?.identity == wrapper.identity
    }

    private func configureCallbacks(for wrapper: VideoPlaybackController) {
        wrapper.setOnError { [weak self] error in
            guard let self, self.isActiveControllerCallbackValid(for: wrapper) else { return }
            self.applyFatalPlaybackError(error)
        }

        if case .worker(let wc) = wrapper {
            wc.onAudioFault = { [weak self] fault in
                guard let self, self.isActiveControllerCallbackValid(for: wrapper) else { return }
                self.applyAudioFault(fault)
            }
        }

        wrapper.setOnFirstVideoFrameEnqueued { [weak self] _ in
            guard let self, self.isActiveControllerCallbackValid(for: wrapper) else { return }
            self.cancelSilentLoadingIndicator()
            self.telemetry.recordFirstVideoSampleEnqueued()
            self.syncControllerMetadata(from: wrapper)
        }

        wrapper.setOnFormatPresentationStateChanged { [weak self] updatedState in
            guard let self, self.isActiveControllerCallbackValid(for: wrapper) else { return }
            self.formatPresentationState = updatedState
        }

        configureProgressCallbacks(for: wrapper)
    }

    private func configureProgressCallbacks(for wrapper: VideoPlaybackController) {
        wrapper.setOnSeekCompleted { [weak self] completedTime, _ in
            guard let self, self.isActiveControllerCallbackValid(for: wrapper) else { return }
            self.telemetry.recordSeekPipelineCompleted()
            self.currentTime = completedTime
            self.isPlaying = wrapper.isPlaying
            self.refreshActiveSubtitleTexts()
        }

        wrapper.setOnTimeUpdate { [weak self] time in
            guard let self, self.isActiveControllerCallbackValid(for: wrapper, requireNotStopped: false) else { return }
            self.currentTime = time
            self.isPlaying = wrapper.isPlaying
        }

        wrapper.setOnPlaybackEnded { [weak self] in
            guard let self, self.isActiveControllerCallbackValid(for: wrapper, requireNotStopped: false) else { return }
            self.isPlaying = false
        }
    }

    internal func applyAudioFault(_ fault: AVSampleBufferAudioFault) {
        guard playbackError == nil else { return }
        isAudioFaultIsolated = true
        playbackFaultCategory = fault.kind == .unsupportedAudioTrack
            ? .unsupportedAudioTrack
            : .audioInitializationFailed
        audioFaultNotice = Self.describeAudioFault(fault)
        let codecLabel = fault.codecName ?? "unknown"
        logger.warning(
            "[PlaybackLifecycle] AUDIO_FAULT_ISOLATED session=\(self.sessionID.uuidString, privacy: .public) category=\(self.playbackFaultCategory?.rawValue ?? "none", privacy: .public) codec=\(codecLabel, privacy: .public) detail=\(fault.diagnosticDetail, privacy: .public)"
        )
    }

    internal func applyFatalPlaybackError(_ error: Error) {
        cancelSilentLoadingIndicator()
        let category = Self.classifyFatalError(error)
        playbackFaultCategory = category
        let described = Self.describeFatalPlaybackError(error, category: category)
        playbackError = described
        formatPresentationState = formatPresentationState.applyingDiagnosticFailure(described)
        isPlaying = false
    }

    internal static func classifyFatalError(_ error: Error) -> VideoPlaybackFaultCategory {
        VideoPlaybackFaultFormatter.classifyFatalError(error)
    }

    internal static func describeAudioFault(_ fault: AVSampleBufferAudioFault) -> String {
        VideoPlaybackFaultFormatter.describeAudioFault(fault)
    }

    internal static func describeFatalPlaybackError(
        _ error: Error,
        category: VideoPlaybackFaultCategory
    ) -> String {
        VideoPlaybackFaultFormatter.describeFatalPlaybackError(error, category: category)
    }

    private func discardController(_ wrapper: VideoPlaybackController, reason: String) {
        logger.info(
            "[PlaybackLifecycle] DISCARD_CONTROLLER session=\(self.sessionID.uuidString, privacy: .public) controller=\(wrapper.identityDescription, privacy: .public) reason=\(reason, privacy: .public)"
        )
        if case .worker(let wc) = wrapper {
            wc.onAudioFault = nil
        }
        wrapper.clearCallbacks()
        wrapper.stop()
        if activeController?.identity == wrapper.identity {
            activeController = nil
        }
    }

    private func teardownPlayback() {
        isTearingDown = true
        defer { isTearingDown = false }
        if let active = activeController {
            if case .worker(let wc) = active {
                wc.onAudioFault = nil
            }
            active.clearCallbacks()
            active.stop()
            self.activeController = nil
        }
        self.isPlaying = false
        self.currentTime = .zero
        self.duration = .zero
        if isSecurityScoped {
            SecurityScopedResourceManager.shared.stopAccessing(url: url)
            isSecurityScoped = false
        }
    }
}
