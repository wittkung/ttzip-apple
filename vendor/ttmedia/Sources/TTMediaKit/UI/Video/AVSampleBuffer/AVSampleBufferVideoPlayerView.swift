// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import os
import Observation
import UniformTypeIdentifiers
import TTKitDesign

/// SwiftUI video player view backed by the hardware-accelerated `AVSampleBuffer` presentation stack.
///
/// Features a floating frosted glass control bar with continuous precision timeline scrubber,
/// elapsed/remaining time toggle, volume popover slider, multi-speed selector, PiP,
/// fullscreen media focus bridge, and center gesture HUD indicators.
@MainActor
public struct AVSampleBufferVideoPlayerView: View {
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "AVSampleBufferVideoPlayerView")

    public let url: URL
    public let isFullScreen: Bool
    public let autoPlay: Bool
    public var onFallbackToMPV: (@MainActor () -> Void)?

    @State private var playback: VideoPlaybackSession
    @State private var viewportID = UUID()

    // MARK: - Playback & UI State
    private var subtitleTrack: ExternalSubtitleTrack? {
        get { playback.subtitleTrack }
        nonmutating set { playback.subtitleTrack = newValue }
    }
    private var subtitleName: String? {
        get { playback.subtitleName }
        nonmutating set { playback.subtitleName = newValue }
    }
    private var subtitleError: String? {
        get { playback.subtitleError }
        nonmutating set { playback.subtitleError = newValue }
    }
    private var subtitleLoadTask: Task<Void, Never>? {
        get { playback.subtitleLoadTask }
        nonmutating set { playback.subtitleLoadTask = newValue }
    }
    private var isLoading: Bool {
        get { playback.isLoading }
        nonmutating set { playback.isLoading = newValue }
    }
    private var playbackError: String? {
        get { playback.playbackError }
        nonmutating set { playback.playbackError = newValue }
    }
    @State private var retryGeneration = 0
    private var activeController: VideoPlaybackController? {
        get { playback.activeController }
        nonmutating set { playback.activeController = newValue }
    }
    @Environment(\.mediaControlsVisibility) private var sharedControls
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
    private var previousVolume: Float {
        get { playback.previousVolume }
        nonmutating set { playback.previousVolume = newValue }
    }
    private var playbackRate: Float {
        get { playback.playbackRate }
        nonmutating set { playback.playbackRate = newValue }
    }

    // Controls Visibility & Inactivity Timer
    private var controlsOpacity: Double { controls.isVisible ? 1 : 0 }

    // Center Splash HUD
    @State private var showCenterHUD: Bool = false
    @State private var centerHUDIcon: String = "play.fill"
    @State private var centerHUDScale: CGFloat = 0.8
    @State private var centerHUDOpacity: Double = 0.0
    @State private var hudDismissTask: Task<Void, Never>? = nil

    public init(
        url: URL,
        isFullScreen: Bool = false,
        autoPlay: Bool? = nil,
        onFallbackToMPV: (@MainActor () -> Void)? = nil
    ) {
        self.url = url
        _playback = State(initialValue: VideoPlaybackSession(url: url))
        self.isFullScreen = isFullScreen
        self.autoPlay = autoPlay ?? isFullScreen
        self.onFallbackToMPV = onFallbackToMPV
    }

    public var body: some View {
        let _ = controls.isVisible
        GeometryReader { geo in
            viewportZStack(in: geo.size)
        }
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
        .alert(MediaLocalization.text(.subtitleFailed), isPresented: Binding(
            get: { subtitleError != nil }, set: { if !$0 { subtitleError = nil } }
        )) { Button(MediaLocalization.text(.ok)) { subtitleError = nil } } message: { Text(subtitleError ?? "") }
        .onDisappear {
            hudDismissTask?.cancel()
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
        }
    }

    @ViewBuilder
    private func playerCanvasRepresentable(
        for controller: VideoPlaybackController,
        videoContentRect: CGRect?
    ) -> some View {
        AVSampleBufferHostRepresentable(
            controller: controller,
            sessionID: playback.sessionID,
            viewportID: viewportID,
            isPresenting: playback.activePresenterViewportID == viewportID,
            isControlBarVisible: controls.isVisible,
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
            formatDetailsSummary: playback.formatPresentationState.detailedFormatSummary
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

            if playback.isShowingLoadingIndicator {
                ProgressView(MediaLocalization.text(.loadingMedia))
                    .padding().ttOverlayGlassPlate(cornerRadius: 16)
            }

            playbackErrorBannerOverlay

            subtitleOverlay(resolvedVideoRect: resolvedVideoRect, viewportSize: viewportSize)

            bitmapSubtitleOverlay(resolvedVideoRect: resolvedVideoRect, viewportSize: viewportSize)

            topRightStatusOverlay

            if showCenterHUD {
                centerSplashHUD
            }

            controlsOverlayView(in: viewportSize)
        }
        .contentShape(Rectangle())
        .contextMenu {
            playerContextMenuContent
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

    @ViewBuilder
    private func subtitleOverlay(resolvedVideoRect: CGRect?, viewportSize: CGSize) -> some View {
        SubtitleOverlayView(
            primaryText: playback.activeSubtitleText,
            secondaryText: playback.activeSecondarySubtitleText,
            style: playback.subtitleStyle,
            controlsVisible: controls.isVisible,
            viewportWidth: viewportSize.width,
            viewportHeight: viewportSize.height,
            videoContentRect: resolvedVideoRect,
            videoNaturalSize: playback.rawVideoNaturalSize,
            videoPixelAspectRatio: playback.videoPixelAspectRatio,
            videoRotationDegrees: playback.effectiveRotationDegrees,
            lastKnownVideoRect: playback.lastKnownVideoContentRect
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
    private var playbackErrorBannerOverlay: some View {
        if let playbackError {
            VStack(spacing: 12) {
                Label(MediaLocalization.text(.playbackFailed), systemImage: "exclamationmark.triangle")
                Text(playbackError).font(.caption).textSelection(.enabled)
                Button(MediaLocalization.text(.retry)) { retryGeneration += 1 }
            }
            .padding()
            .ttOverlayGlassPlate(cornerRadius: 16)
            .padding()
        } else if playback.isUnexpectedlyEmptyController {
            VStack(spacing: 12) {
                Label(MediaLocalization.text(.playbackFailed), systemImage: "exclamationmark.triangle")
                Button(MediaLocalization.text(.retry)) { retryGeneration += 1 }
            }
            .padding()
            .ttOverlayGlassPlate(cornerRadius: 16)
            .padding()
        }
    }

    @ViewBuilder
    private func controlsOverlayView(in viewportSize: CGSize) -> some View {
        let badgeText = playback.formatPresentationState.alwaysAvailableBadgeText
        AVSampleBufferControlsOverlay(
            availableWidth: viewportSize.width,
            videoURL: url,
            userRotationDegrees: playback.userRotationDegrees,
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying,
            isFullScreen: isFullScreen,
            volume: volume,
            isMuted: isMuted,
            playbackRate: playbackRate,
            pipSupported: pipSupported,
            pipActive: pipActive,
            onTogglePlayPause: { togglePlayPauseFromControlBar() },
            onSeekBy: { delta in seekBy(delta) },
            onSeekTo: { time in seekTo(time) },
            onVolumeChange: { vol in setVolume(vol) },
            onMuteToggle: { toggleMute() },
            onRateChange: { rate in setPlaybackRate(rate) },
            onPipToggle: { togglePip() },
            onFullScreenToggle: { toggleFullScreen() },
            onUserInteraction: { resetAutoHideTimer() },
            onLoadSubtitles: { selectSubtitles() },
            onRemoveSubtitles: { playback.selectSubtitle("off") },
            subtitleName: subtitleName,
            subtitleOptions: playback.subtitleOptions,
            selectedSubtitleID: playback.selectedSubtitleID,
            onSelectSubtitle: { playback.selectSubtitle($0) },
            selectedSecondarySubtitleID: playback.selectedSecondarySubtitleID,
            onSelectSecondarySubtitle: { playback.selectSecondarySubtitle($0) },
            subtitleStyle: playback.subtitleStyle,
            onUpdateSubtitleStyle: { playback.updateSubtitleStyle($0) },
            subtitleVideoGeometry: playback.subtitleVideoGeometry(for: viewportSize),
            activeSubtitleCodec: playback.activeSubtitleCodec,
            formatBadgeText: badgeText,
            formatPresentationState: playback.formatPresentationState,
            onScrubbingStateChange: { scrubbing in controls.setScrubbing(scrubbing) },
            onPopoverVisibilityChange: { visible in
                MediaPlaybackCoordinator.shared.setShortcutSuspended(id: playback.coordinatorID, suspended: visible)
                if visible {
                    controls.acquireInteractionLock(id: "controlBarPopover")
                } else {
                    controls.releaseInteractionLock(id: "controlBarPopover")
                }
            }
        )
        .environment(controls)
        .environment(playback.timelineThumbnails)
        .environment(\.ttButtonHelpEnabled, controls.isVisible)
        .opacity(controlsOpacity)
        .animation(.spring(response: 0.16, dampingFraction: 1.0), value: controlsOpacity)
        .allowsHitTesting(controlsOpacity > 0.05)
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

    // MARK: - Status & Center Splash HUD Views

    @ViewBuilder
    private var topRightStatusOverlay: some View {
        let activeAudioNotice = playbackError == nil ? playback.audioFaultNotice : nil
        if activeAudioNotice != nil || playback.osdMessage != nil {
            VStack(alignment: .trailing, spacing: 8) {
                if let activeAudioNotice {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.yellow)
                        Text(activeAudioNotice)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial.opacity(0.82), in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.yellow.opacity(0.35), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }

                if let osdMessage = playback.osdMessage {
                    Text(osdMessage)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial.opacity(0.75), in: Capsule())
                        .overlay(
                            Capsule().strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, isFullScreen ? 56 : 16)
            .padding(.trailing, 18)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var centerSplashHUD: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 68, height: 68)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.40), radius: 12, y: 4)
            Image(systemName: centerHUDIcon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
        .scaleEffect(centerHUDScale)
        .opacity(centerHUDOpacity)
        .allowsHitTesting(false)
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

    private var volumeIconName: String {
        if isMuted || volume == 0.0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
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

    @ViewBuilder
    private var playerContextMenuContent: some View {
        Button(isPlaying ? MediaLocalization.text(.pause) : MediaLocalization.text(.play)) {
            togglePlayPauseWithoutHUD()
        }
        Divider()
        Menu(VideoInteractionLocalization.text(.rotationMenu)) {
            Button(VideoInteractionLocalization.text(.rotateClockwise)) {
                playback.rotateClockwise()
            }
            Button(VideoInteractionLocalization.text(.rotateCounterClockwise)) {
                playback.rotateCounterClockwise()
            }
            Button(VideoInteractionLocalization.text(.rotate180)) {
                playback.rotate180()
            }
            Divider()
            Button(VideoInteractionLocalization.text(.resetOrientation)) {
                playback.resetRotation()
            }
            .disabled(playback.userRotationDegrees == 0)
        }
        Divider()
        Button(MediaLocalization.text(isFullScreen ? .exitFullscreen : .fullscreen)) {
            toggleFullScreen()
        }
        Divider()
        Text(playback.formatPresentationState.detailedFormatSummary)
    }

    private func seekBy(_ delta: Double) {
        let currentSec = CMTimeGetSeconds(currentTime)
        let totalSec = CMTimeGetSeconds(duration)
        let targetSec = max(0.0, min(totalSec > 0 ? totalSec : 36000.0, currentSec + delta))
        let targetTime = CMTime(seconds: targetSec, preferredTimescale: duration.timescale > 0 ? duration.timescale : 600)
        playback.seek(to: targetTime)
        triggerSplashHUD(icon: delta > 0 ? "goforward.10" : "gobackward.10")
    }

    private func adjustVolume(by delta: Float) {
        setVolume(volume + delta)
    }

    private func setVolume(_ vol: Float) {
        playback.setVolume(vol)
        triggerSplashHUD(icon: volumeIconName)
    }

    private func toggleMute() {
        playback.toggleMute()
        triggerSplashHUD(icon: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }

    private func setPlaybackRate(_ rate: Float) {
        playback.setPlaybackRate(rate)
        triggerSplashHUD(icon: "gauge.with.needle.fill")
    }

    private func triggerSplashHUD(icon: String) {
        hudDismissTask?.cancel()
        centerHUDIcon = icon
        centerHUDScale = 0.75
        centerHUDOpacity = 0.0
        showCenterHUD = true

        withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
            centerHUDScale = 1.05
            centerHUDOpacity = 1.0
        }

        hudDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.24)) {
                centerHUDOpacity = 0.0
                centerHUDScale = 1.20
            }
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            showCenterHUD = false
        }
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
        controls.acquireInteractionLock(id: "subtitleOpenPanel")
        let panel = NSOpenPanel()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.allowedContentTypes = ExternalSubtitleTrack.orderedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            Task { @MainActor in
                defer { controls.releaseInteractionLock(id: "subtitleOpenPanel") }
                guard response == .OK, let selected = panel.url else { return }
                playback.loadExternalSubtitle(selected)
            }
        }
    }

    private func toggleFullScreen() {
        TTMediaDetector.beginFullscreenEphemeralHandoff(for: url)
        let userInfo: [AnyHashable: Any] = ["url": url, "name": url.lastPathComponent]
        NotificationCenter.default.post(
            name: .ttMediaToggleMediaFocusNotification,
            object: url,
            userInfo: userInfo
        )
    }

    private func formatTimestamp(_ time: CMTime) -> String {
        guard time.isValid && !time.isIndefinite else { return "00:00" }
        let totalSeconds = Int(max(0, CMTimeGetSeconds(time)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Internal Representable Host

@MainActor
private struct AVSampleBufferHostRepresentable: NSViewRepresentable {
    let controller: VideoPlaybackController
    let sessionID: UUID
    let viewportID: UUID
    let isPresenting: Bool
    let isControlBarVisible: Bool
    let controlsVisibility: MediaControlsVisibility
    let videoContentRect: CGRect?
    let userRotationDegrees: Int
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let onDropFiles: ([URL]) -> Void
    let onMouseMovedAtPoint: (CGPoint) -> Void
    let onMouseHoverChanged: (Bool) -> Void
    let onWindowFocusLost: () -> Void
    let onRotateClockwise: () -> Void
    let onRotateCounterClockwise: () -> Void
    let onRotate180: () -> Void
    let onResetRotation: () -> Void
    let onHostScreenObservationChanged: (VideoHostScreenObservation?, UUID?) -> Void
    let formatDetailsSummary: String?

    func makeNSView(context: Context) -> AVSampleBufferPlayerNSView {
        let view = AVSampleBufferPlayerNSView(
            frame: .zero,
            renderer: AVSampleBufferRenderer(displayLayer: controller.displayLayer),
            synchronizer: controller.synchronizer,
            audioRenderer: controller.audioRenderer,
            attachesDisplayLayerImmediately: isPresenting
        )
        view.isControlBarVisible = isControlBarVisible
        view.controlsVisibility = controlsVisibility
        view.videoContentRect = videoContentRect
        view.userRotationDegrees = userRotationDegrees
        view.formatDetailsSummary = formatDetailsSummary
        view.onHostScreenObservationChanged = onHostScreenObservationChanged
        view.updatePresentationOwnership(
            sessionID: sessionID,
            viewportID: viewportID,
            isPresenting: isPresenting,
            reason: "makeNSView"
        )
        view.onTogglePlayPause = { [controller] in
            controller.togglePlayPause()
        }
        view.onSeek = { [controller] targetTime in
            controller.seek(to: targetTime)
        }
        view.onCanvasSingleClick = onSingleClick
        view.onCanvasDoubleClick = onDoubleClick
        view.onVolumeChange = onVolumeChange
        view.onMuteToggle = onMuteToggle
        view.onDropFiles = onDropFiles
        view.onMouseMovedAtPoint = onMouseMovedAtPoint
        view.onHoverChanged = onMouseHoverChanged
        view.onWindowFocusLost = onWindowFocusLost
        view.onRotateClockwise = onRotateClockwise
        view.onRotateCounterClockwise = onRotateCounterClockwise
        view.onRotate180 = onRotate180
        view.onResetRotation = onResetRotation
        return view
    }

    func updateNSView(_ nsView: AVSampleBufferPlayerNSView, context: Context) {
        nsView.controlsVisibility = controlsVisibility
        if nsView.isControlBarVisible != isControlBarVisible {
            nsView.isControlBarVisible = isControlBarVisible
            if isControlBarVisible {
                nsView.cancelPendingCanvasSingleClick()
            }
        }
        nsView.videoContentRect = videoContentRect
        nsView.userRotationDegrees = userRotationDegrees
        nsView.formatDetailsSummary = formatDetailsSummary
        nsView.onHostScreenObservationChanged = onHostScreenObservationChanged
        nsView.updatePresentationOwnership(
            sessionID: sessionID,
            viewportID: viewportID,
            isPresenting: isPresenting,
            reason: "updateNSView"
        )
        nsView.onDropFiles = onDropFiles
        nsView.onMouseMovedAtPoint = onMouseMovedAtPoint
        nsView.onHoverChanged = onMouseHoverChanged
        nsView.onWindowFocusLost = onWindowFocusLost
        nsView.onRotateClockwise = onRotateClockwise
        nsView.onRotateCounterClockwise = onRotateCounterClockwise
        nsView.onRotate180 = onRotate180
        nsView.onResetRotation = onResetRotation
    }
}
