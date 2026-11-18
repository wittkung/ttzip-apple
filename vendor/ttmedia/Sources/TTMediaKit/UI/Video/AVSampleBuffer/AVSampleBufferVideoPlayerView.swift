// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import os
import Observation

/// SwiftUI video player view backed by the hardware-accelerated `AVSampleBuffer` presentation stack.
///
@MainActor
public struct AVSampleBufferVideoPlayerView: View {
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "AVSampleBufferVideoPlayerView")
    private let renderStatus: (@MainActor (VideoPlaybackStatus) -> AnyView)?
    private let renderNotices: (@MainActor (VideoPlaybackNotices) -> AnyView)?
    private let playbackMenus: VideoPlaybackMenus?
    private let renderFeedback: (@MainActor (VideoPlaybackFeedback?) -> AnyView)?
    private let subtitlePresentation: VideoSubtitlePresentation?
    private let onFullscreenRequest: (@MainActor (URL) -> Void)?

    public let url: URL
    public let isFullScreen: Bool
    public let autoPlay: Bool

    @State private var playback: VideoPlaybackSession
    @State private var viewportID = UUID()
    @State private var subtitlePicker: (id: UUID, visibility: MediaControlsVisibility)?

    // MARK: - Playback & UI State
    @State private var retryGeneration = 0
    private var activeController: VideoPlaybackController? {
        get { playback.activeController }
        nonmutating set { playback.activeController = newValue }
    }
    @Environment(\.mediaControlsVisibility) private var sharedControls
    @Environment(\.videoPlaybackControls) private var videoPlaybackControls
    @State private var localControls = MediaControlsVisibility()
    private var controls: MediaControlsVisibility { sharedControls ?? localControls }
    private var isHovered: Bool { controls.isHovered }
    private var isPlaying: Bool {
        get { playback.isPlaying }
        nonmutating set { playback.isPlaying = newValue }
    }
    private var currentTime: CMTime {
        get { playback.currentTime }
        nonmutating set { playback.currentTime = newValue }
    }
    private var duration: CMTime {
        get { playback.duration }
        nonmutating set { playback.duration = newValue }
    }

    // Audio & Speed State
    private var volume: Float {
        get { playback.volume }
        nonmutating set { playback.volume = newValue }
    }
    private var isMuted: Bool {
        get { playback.isMuted }
        nonmutating set { playback.isMuted = newValue }
    }
    private var playbackRate: Float {
        get { playback.playbackRate }
        nonmutating set { playback.playbackRate = newValue }
    }

    // Controls Visibility & Inactivity Timer
    private var controlsOpacity: Double { controls.isVisible ? 1 : 0 }

    @State private var feedback: VideoPlaybackFeedback?

    public init(
        url: URL,
        isFullScreen: Bool = false,
        autoPlay: Bool? = nil,
        renderStatus: (@MainActor (VideoPlaybackStatus) -> AnyView)? = nil,
        renderNotices: (@MainActor (VideoPlaybackNotices) -> AnyView)? = nil,
        playbackMenus: VideoPlaybackMenus? = nil,
        renderFeedback: (@MainActor (VideoPlaybackFeedback?) -> AnyView)? = nil,
        subtitlePresentation: VideoSubtitlePresentation? = nil,
        onFullscreenRequest: (@MainActor (URL) -> Void)? = nil
    ) {
        self.url = url
        _playback = State(initialValue: VideoPlaybackSession(url: url))
        self.isFullScreen = isFullScreen
        self.autoPlay = autoPlay ?? isFullScreen
        self.renderStatus = renderStatus
        self.renderNotices = renderNotices
        self.playbackMenus = playbackMenus
        self.renderFeedback = renderFeedback
        self.subtitlePresentation = subtitlePresentation
        self.onFullscreenRequest = onFullscreenRequest
    }

    public var body: some View {
        let _ = controls.isVisible
        let session = playback
        let viewport = AnyView(GeometryReader { geo in viewportZStack(in: geo.size) })
        let presentedViewport = subtitlePresentation?.attachFailureAlert(viewport, session.subtitleError) {
            session.subtitleError = nil
        } ?? viewport
        presentedViewport
        .background(MediaKeyboardWindowAnchor(
            sessionID: playback.coordinatorID,
            isPresenter: playback.activePresenterViewportID == viewportID
        ))
        .onAppear {
            claimAndBindViewport(caller: "onAppear", restart: false, promoteToPresenter: true)
        }
        .task(id: "\(url.absoluteString)#\(retryGeneration)") {
            let isRestart = retryGeneration > 0
            claimAndBindViewport(caller: "task", restart: isRestart, promoteToPresenter: isFullScreen || isRestart)
            playback.start(autoPlay: autoPlay)
        }
        .onChange(of: VideoPlaybackSessions.shared.current?.sessionID) { _, _ in
            rebindToCurrentSessionIfNeeded()
        }
        .onChange(of: isPlaying) { _, playing in controls.isPlaying = playing }
        .onChange(of: controls.isHovered) { _, hovered in
            MediaPlaybackCoordinator.shared.setHovered(id: playback.coordinatorID, isHovered: hovered)
        }
        .onDisappear {
            endSubtitlePicker()
            feedback = nil
            if sharedControls == nil {
                localControls.tearDown()
            } else {
                controls.forceRestoreCursor()
            }
            MediaPlaybackCoordinator.shared.setHovered(id: playback.coordinatorID, isHovered: false)
            VideoPlaybackSessions.shared.release(
                sessionID: playback.sessionID,
                viewportID: viewportID,
                caller: isFullScreen ? "onDisappear(fullScreen)" : "onDisappear(inspector)"
            )
            if playback.activePresenterViewportID == nil {
                GIFExportManager.shared.handlePreviewClosed(for: url)
                VideoLosslessTrimManager.shared.handlePreviewClosed(for: url)
                MediaContainerRemuxManager.shared.handlePreviewClosed(for: url)
                MediaAudioExtractManager.shared.resetForPreviewClose(for: url)
            }
        }
    }

    @ViewBuilder
    private func playerCanvasRepresentable(
        for controller: VideoPlaybackController,
        videoContentRect: CGRect?
    ) -> some View {
        let hasControlBar = videoPlaybackControls != nil
        AVSampleBufferHostRepresentable(
            controller: controller,
            sessionID: playback.sessionID,
            viewportID: viewportID,
            isPresenting: playback.activePresenterViewportID == viewportID,
            hasControlBar: hasControlBar,
            isControlBarVisible: hasControlBar && controls.isVisible,
            controlsVisibility: controls,
            videoContentRect: videoContentRect,
            userRotationDegrees: playback.effectiveRotationDegrees,
            onSingleClick: { handleCanvasClick() },
            onDoubleClick: { toggleFullScreen() },
            onVolumeChange: { delta in adjustVolume(by: delta) },
            onMuteToggle: { toggleMute() },
            onDropFiles: { urls in handleDroppedFiles(urls) },
            onMouseMovedAtPoint: { point in controls.recordMouseMove(at: point) },
            onMouseHoverChanged: { hovering in handleHoverChange(hovering) },
            onWindowFocusLost: { controls.forceRestoreCursor() },
            onRotateClockwise: { playback.rotateClockwise() },
            onRotateCounterClockwise: { playback.rotateCounterClockwise() },
            onRotate180: { playback.rotate180() },
            onResetRotation: { playback.resetRotation() },
            onHostScreenObservationChanged: { snapshot, receiptSessionID in
                playback.updateHostScreenObservation(snapshot, forSessionID: receiptSessionID)
            },
            formatDetailsSummary: playback.formatPresentationState.detailedFormatSummary,
            makeCanvasMenu: playbackMenus?.makeCanvasMenu
        )
        .id(controller.identity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func viewportZStack(in viewportSize: CGSize) -> some View {
        let resolvedVideoRect = playback.videoContentRect(in: viewportSize)
        ZStack {
            Color.black

            if let activeController {
                playerCanvasRepresentable(for: activeController, videoContentRect: resolvedVideoRect)
            }

            playbackStatusOverlay

            if let renderTextOverlay = subtitlePresentation?.renderTextOverlay {
                renderTextOverlay(textSubtitleOverlay(resolvedVideoRect: resolvedVideoRect, viewportSize: viewportSize))
            }

            bitmapSubtitleOverlay(resolvedVideoRect: resolvedVideoRect, viewportSize: viewportSize)

            topRightStatusOverlay

            if let renderFeedback {
                renderFeedback(feedback)
            }

            controlsOverlayView(in: viewportSize)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let playbackMenus {
                playbackMenus.renderContextMenu(contextMenuContext)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                controls.recordMouseMove(at: location)
            case .ended:
                if sharedControls == nil { handleHoverChange(false) }
            }
        }
        .onKeyPress(.space) {
            guard MediaPlaybackCoordinator.shared.shouldInterceptMediaKeys() else { return .ignored }
            togglePlayPauseWithoutHUD()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard MediaPlaybackCoordinator.shared.shouldInterceptMediaKeys() else { return .ignored }
            seekBy(-10.0)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard MediaPlaybackCoordinator.shared.shouldInterceptMediaKeys() else { return .ignored }
            seekBy(10.0)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard MediaPlaybackCoordinator.shared.shouldInterceptMediaKeys() else { return .ignored }
            adjustVolume(by: 0.10)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard MediaPlaybackCoordinator.shared.shouldInterceptMediaKeys() else { return .ignored }
            adjustVolume(by: -0.10)
            return .handled
        }
    }

    private func textSubtitleOverlay(
        resolvedVideoRect: CGRect?,
        viewportSize: CGSize
    ) -> VideoSubtitlePresentation.TextOverlay {
        VideoSubtitlePresentation.TextOverlay(
            primaryText: playback.activeSubtitleText,
            secondaryText: playback.activeSecondarySubtitleText,
            style: playback.subtitleStyle,
            geometry: SubtitleVideoContentGeometry(
                viewportSize: viewportSize,
                videoNaturalSize: playback.rawVideoNaturalSize,
                pixelAspectRatio: playback.videoPixelAspectRatio,
                rotationDegrees: playback.effectiveRotationDegrees,
                explicitVideoRect: resolvedVideoRect,
                lastKnownVideoRect: playback.lastKnownVideoContentRect
            )
        )
    }

    @ViewBuilder
    private func bitmapSubtitleOverlay(resolvedVideoRect: CGRect?, viewportSize: CGSize) -> some View {
        BitmapSubtitleOverlayView(
            trackID: playback.selectedSubtitleID,
            activeCue: playback.bitmapSubtitleTrack?.activeCue(
                at: CMTimeGetSeconds(playback.currentTime) - playback.subtitleStyle.delay
            ),
            videoRect: resolvedVideoRect,
            viewportSize: viewportSize,
            rotationDegrees: playback.effectiveRotationDegrees
        )
    }

    @ViewBuilder
    private var playbackStatusOverlay: some View {
        if let renderStatus {
            renderStatus(playbackStatus)
        }
    }

    private var playbackStatus: VideoPlaybackStatus {
        let detail = playback.playbackError
        if detail != nil || playback.isUnexpectedlyEmptyController {
            let sessionID = playback.sessionID
            let generation = retryGeneration
            return .failed(detail: detail) {
                guard playback.sessionID == sessionID,
                      playback.activeViewports.contains(viewportID),
                      retryGeneration == generation,
                      playback.playbackError != nil || playback.isUnexpectedlyEmptyController else { return }
                retryGeneration += 1
            }
        }
        return playback.isShowingLoadingIndicator ? .loading : .hidden
    }

    private func controlsOverlayView(in viewportSize: CGSize) -> some View {
        Group {
            if let videoPlaybackControls {
                videoPlaybackControls(playbackControlsContext(in: viewportSize))
            }
        }
        .environment(controls)
        .environment(\.ttButtonHelpEnabled, controls.isVisible)
        .opacity(controlsOpacity)
        .animation(.spring(response: 0.16, dampingFraction: 1.0), value: controlsOpacity)
        .allowsHitTesting(controlsOpacity > 0.05)
    }

    private func playbackControlsContext(in viewportSize: CGSize) -> VideoPlaybackControlsContext {
        let sessionID = playback.sessionID
        return VideoPlaybackControlsContext(
            videoURL: url,
            viewportSize: viewportSize,
            rotationDegrees: playback.userRotationDegrees,
            transport: .init(
                currentTime: currentTime,
                duration: duration,
                isPlaying: isPlaying,
                isFullScreen: isFullScreen,
                volume: volume,
                isMuted: isMuted,
                playbackRate: playbackRate,
                pipSupported: pipSupported,
                pipActive: pipActive
            ),
            subtitles: .init(
                name: playback.subtitleName,
                options: playback.subtitleOptions,
                selectedID: playback.selectedSubtitleID,
                selectedSecondaryID: playback.selectedSecondarySubtitleID,
                style: playback.subtitleStyle,
                geometry: playback.subtitleVideoGeometry(for: viewportSize),
                activeCodec: playback.activeSubtitleCodec
            ),
            format: playback.formatPresentationState,
            cachedThumbnail: { time in
                guard playback.sessionID == sessionID else { return nil }
                let thumbnails = playback.timelineThumbnails
                guard VideoTimelineThumbnailSource.matchesSourceURL(thumbnails.sourceURL, videoURL: url) else {
                    return nil
                }
                return thumbnails.frame(at: CMTimeGetSeconds(time))?.image
            },
            dispatch: handlePlaybackControlsAction
        )
    }

    private func handlePlaybackControlsAction(_ action: VideoPlaybackControlsContext.Action) {
        switch action {
        case .togglePlayPause:
            togglePlayPauseFromControlBar()
        case .seekBy(let delta):
            seekBy(delta)
        case .seekTo(let time):
            seekTo(time)
        case .setVolume(let value):
            setVolume(value)
        case .toggleMute:
            toggleMute()
        case .setPlaybackRate(let rate):
            setPlaybackRate(rate)
        case .togglePictureInPicture:
            togglePip()
        case .toggleFullScreen:
            toggleFullScreen()
        case .interaction(let interaction):
            handleControlsInteraction(interaction)
        case .subtitle(let subtitleAction):
            handleControlsSubtitleAction(subtitleAction)
        }
    }

    private func handleControlsInteraction(_ interaction: VideoPlaybackControlsContext.Interaction) {
        switch interaction {
        case .activity:
            resetAutoHideTimer()
        case .scrubbing(let active):
            controls.setScrubbing(active)
        case .popoverPresented(let visible):
            MediaPlaybackCoordinator.shared.setShortcutSuspended(id: playback.coordinatorID, suspended: visible)
            if visible {
                controls.acquireInteractionLock(id: "controlBarPopover")
            } else {
                controls.releaseInteractionLock(id: "controlBarPopover")
            }
        }
    }

    private func handleControlsSubtitleAction(_ action: VideoPlaybackControlsContext.SubtitleAction) {
        switch action {
        case .load:
            selectSubtitles()
        case .remove:
            playback.selectSubtitle("off")
        case .select(let id):
            playback.selectSubtitle(id)
        case .selectSecondary(let id):
            playback.selectSecondarySubtitle(id)
        case .updateStyle(let style):
            playback.updateSubtitleStyle(style)
        }
    }

    private func claimAndBindViewport(caller: String, restart: Bool, promoteToPresenter: Bool) {
        let session = VideoPlaybackSessions.shared.claim(
            url: url,
            viewportID: viewportID,
            isFullScreen: isFullScreen,
            promoteToPresenter: promoteToPresenter,
            restart: restart,
            caller: "\(caller)(\(isFullScreen ? "fullScreen" : "inspector"))"
        )
        VideoPlaybackSessions.shared.bindViewport(
            viewportID: viewportID,
            sessionID: session.sessionID
        ) { newSession in
            playback = newSession
            controls.isPlaying = newSession.isPlaying
        }
        playback = session
        controls.isPlaying = session.isPlaying
    }

    private func rebindToCurrentSessionIfNeeded() {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let current = VideoPlaybackSessions.shared.current,
              !current.isStopped,
              current.canonicalURL == canonical,
              current.sessionID != playback.sessionID else {
            return
        }
        claimAndBindViewport(caller: "rebind", restart: false, promoteToPresenter: isFullScreen)
    }

    @ViewBuilder
    private var topRightStatusOverlay: some View {
        if let renderNotices {
            renderNotices(VideoPlaybackNotices(
                audioWarning: playback.playbackError == nil ? playback.audioFaultNotice : nil,
                osdMessage: playback.osdMessage
            ))
        }
    }

    private var pipSupported: Bool {
        if case .worker(let wc) = activeController {
            return wc.pipController.isPictureInPictureSupported
        }
        return false
    }

    private var pipActive: Bool {
        if case .worker(let wc) = activeController {
            return wc.pipController.isPictureInPictureActive
        }
        return false
    }

    private func togglePip() {
        if case .worker(let wc) = activeController, wc.pipController.canTogglePictureInPicture {
            wc.pipController.togglePictureInPicture()
        }
    }

    private func seekTo(_ time: CMTime) {
        playback.seek(to: time)
    }

    // MARK: - Player Actions & Gesture Handlers

    private func handleCanvasClick() {
        togglePlayPauseWithoutHUD()
    }

    private func handleHoverChange(_ hovering: Bool) {
        controls.setHovered(hovering)
    }

    private func togglePlayPauseFromControlBar() {
        togglePlayPauseWithoutHUD()
    }

    private func togglePlayPauseWithoutHUD() {
        guard let activeController else { return }
        activeController.togglePlayPause()
        isPlaying = activeController.userPlaybackIntent || activeController.isPlaying
        controls.isPlaying = isPlaying
    }

    private var contextMenuContext: VideoPlaybackMenus.Context {
        VideoPlaybackMenus.Context(
            playback: .init(
                isPlaying: isPlaying,
                canResetRotation: playback.userRotationDegrees != 0,
                formatSummary: playback.formatPresentationState.detailedFormatSummary,
                dispatch: handleContextMenuAction
            ),
            videoURL: url,
            isFullScreen: isFullScreen,
            readPlaybackRange: { (CMTimeGetSeconds(currentTime), CMTimeGetSeconds(duration)) }
        )
    }

    private func handleContextMenuAction(_ action: VideoPlaybackMenus.Action) {
        switch action {
        case .togglePlayPause: togglePlayPauseWithoutHUD()
        case .rotateClockwise: playback.rotateClockwise()
        case .rotateCounterClockwise: playback.rotateCounterClockwise()
        case .rotate180: playback.rotate180()
        case .resetRotation: playback.resetRotation()
        case .toggleFullScreen: toggleFullScreen()
        }
    }

    private func seekBy(_ delta: Double) {
        let currentSec = CMTimeGetSeconds(currentTime)
        let totalSec = CMTimeGetSeconds(duration)
        let targetSec = max(0.0, min(totalSec > 0 ? totalSec : 36000.0, currentSec + delta))
        let targetTime = CMTime(seconds: targetSec, preferredTimescale: duration.timescale > 0 ? duration.timescale : 600)
        playback.seek(to: targetTime)
        presentFeedback(delta > 0 ? .seekForward : .seekBackward)
    }

    private func adjustVolume(by delta: Float) {
        setVolume(volume + delta)
    }

    private func setVolume(_ vol: Float) {
        playback.setVolume(vol)
        presentFeedback(.volume(level: volume, isMuted: isMuted))
    }

    private func toggleMute() {
        playback.toggleMute()
        presentFeedback(.muteChanged(isMuted: isMuted))
    }

    private func setPlaybackRate(_ rate: Float) {
        playback.setPlaybackRate(rate)
        presentFeedback(.rateChanged)
    }

    private func presentFeedback(_ change: VideoPlaybackFeedback.Change) {
        guard renderFeedback != nil else { return }
        feedback = VideoPlaybackFeedback(change: change)
    }

    private func resetAutoHideTimer() {
        controls.isPlaying = isPlaying
        controls.recordControlBarInteraction()
    }

    // MARK: - Playback Setup & Teardown

    private func handleDroppedFiles(_ urls: [URL]) {
        guard let subtitleURL = urls.first(where: {
            ExternalSubtitleTrack.supportedExtensions.contains($0.pathExtension.lowercased())
        }) else { return }
        playback.loadExternalSubtitle(subtitleURL)
    }

    private func selectSubtitles() {
        guard let subtitlePresentation, subtitlePicker == nil else { return }
        let session = playback
        let id = UUID()
        let visibility = controls
        subtitlePicker = (id, visibility)
        visibility.acquireInteractionLock(id: id)
        subtitlePresentation.pickFile(
            url.deletingLastPathComponent(),
            ExternalSubtitleTrack.orderedExtensions
        ) { selected in
            guard subtitlePicker?.id == id else { return }
            defer { endSubtitlePicker() }
            guard let selected,
                  VideoPlaybackSessions.shared.current === session,
                  session.activeViewports.contains(viewportID) else { return }
            session.loadExternalSubtitle(selected)
        }
    }

    private func endSubtitlePicker() {
        guard let picker = subtitlePicker else { return }
        subtitlePicker = nil
        picker.visibility.releaseInteractionLock(id: picker.id)
    }

    private func toggleFullScreen() {
        guard let onFullscreenRequest else { return }
        TTMediaDetector.beginFullscreenEphemeralHandoff(for: url)
        onFullscreenRequest(url)
    }
}
