// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
@preconcurrency import CoreMedia
import TTKitDesign
import TTI18nUI

/// Suspended floating frosted glass controls overlay supporting both compact and wide presentation modes.
@MainActor
public struct AVSampleBufferControlsOverlay: View {
    @Environment(MediaControlsVisibility.self) private var visibility: MediaControlsVisibility?
    @Environment(VideoTimelineThumbnailSource.self) private var thumbnails: VideoTimelineThumbnailSource?
    public let videoURL: URL?
    public let userRotationDegrees: Int
    public let availableWidth: CGFloat
    public let currentTime: CMTime
    public let duration: CMTime
    public let isPlaying: Bool
    public let isFullScreen: Bool
    public let volume: Float
    public let isMuted: Bool
    public let playbackRate: Float
    public let pipSupported: Bool
    public let pipActive: Bool

    public let onTogglePlayPause: () -> Void
    public let onSeekBy: (Double) -> Void
    public let onSeekTo: (CMTime) -> Void
    public let onVolumeChange: (Float) -> Void
    public let onMuteToggle: () -> Void
    public let onRateChange: (Float) -> Void
    public let onPipToggle: () -> Void
    public let onFullScreenToggle: () -> Void
    public let onUserInteraction: () -> Void

    public let onLoadSubtitles: () -> Void
    public let onRemoveSubtitles: () -> Void
    public let subtitleName: String?
    public let subtitleOptions: [SubtitleMenuOption]
    public let selectedSubtitleID: String?
    public let onSelectSubtitle: (String) -> Void
    public let selectedSecondarySubtitleID: String
    public let onSelectSecondarySubtitle: (String) -> Void
    public let subtitleStyle: SubtitleStyleConfiguration
    public let onUpdateSubtitleStyle: (SubtitleStyleConfiguration) -> Void
    public let subtitleVideoGeometry: SubtitleVideoContentGeometry?
    public let activeSubtitleCodec: String?
    public let formatBadgeText: String?
    public let formatPresentationState: VideoFormatPresentationState?
    public let onScrubbingStateChange: (Bool) -> Void
    public let onPopoverVisibilityChange: (Bool) -> Void

    @State private var isScrubbing: Bool = false
    @State private var scrubTime: CMTime = .zero
    @State private var isHoveringScrubber: Bool = false
    @State private var hoverTime: CMTime = .zero
    @State private var hoverLocationX: CGFloat = 0.0
    @State private var showRemainingTime: Bool = false
    @State private var showVolumePopover: Bool = false
    @State private var showSubtitlePopover: Bool = false
    @State private var showFormatDetailsPopover: Bool = false

    public init(
        availableWidth: CGFloat,
        videoURL: URL? = nil,
        userRotationDegrees: Int = 0,
        currentTime: CMTime,
        duration: CMTime,
        isPlaying: Bool,
        isFullScreen: Bool,
        volume: Float,
        isMuted: Bool,
        playbackRate: Float,
        pipSupported: Bool,
        pipActive: Bool,
        onTogglePlayPause: @escaping () -> Void,
        onSeekBy: @escaping (Double) -> Void,
        onSeekTo: @escaping (CMTime) -> Void,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void,
        onRateChange: @escaping (Float) -> Void,
        onPipToggle: @escaping () -> Void,
        onFullScreenToggle: @escaping () -> Void,
        onUserInteraction: @escaping () -> Void,
        onLoadSubtitles: @escaping () -> Void = {},
        onRemoveSubtitles: @escaping () -> Void = {},
        subtitleName: String? = nil,
        subtitleOptions: [SubtitleMenuOption] = [],
        selectedSubtitleID: String? = nil,
        onSelectSubtitle: @escaping (String) -> Void = { _ in },
        selectedSecondarySubtitleID: String = "off",
        onSelectSecondarySubtitle: @escaping (String) -> Void = { _ in },
        subtitleStyle: SubtitleStyleConfiguration = SubtitleStyleConfiguration(),
        onUpdateSubtitleStyle: @escaping (SubtitleStyleConfiguration) -> Void = { _ in },
        subtitleVideoGeometry: SubtitleVideoContentGeometry? = nil,
        activeSubtitleCodec: String? = nil,
        formatBadgeText: String? = nil,
        formatPresentationState: VideoFormatPresentationState? = nil,
        onScrubbingStateChange: @escaping (Bool) -> Void = { _ in },
        onPopoverVisibilityChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.videoURL = videoURL
        self.userRotationDegrees = userRotationDegrees
        self.availableWidth = availableWidth
        self.currentTime = currentTime
        self.duration = duration
        self.isPlaying = isPlaying
        self.isFullScreen = isFullScreen
        self.volume = volume
        self.isMuted = isMuted
        self.playbackRate = playbackRate
        self.pipSupported = pipSupported
        self.pipActive = pipActive
        self.onTogglePlayPause = onTogglePlayPause
        self.onSeekBy = onSeekBy
        self.onSeekTo = onSeekTo
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self.onRateChange = onRateChange
        self.onPipToggle = onPipToggle
        self.onFullScreenToggle = onFullScreenToggle
        self.onUserInteraction = onUserInteraction
        self.onLoadSubtitles = onLoadSubtitles
        self.onRemoveSubtitles = onRemoveSubtitles
        self.subtitleName = subtitleName
        self.subtitleOptions = subtitleOptions
        self.selectedSubtitleID = selectedSubtitleID
        self.onSelectSubtitle = onSelectSubtitle
        self.selectedSecondarySubtitleID = selectedSecondarySubtitleID
        self.onSelectSecondarySubtitle = onSelectSecondarySubtitle
        self.subtitleStyle = subtitleStyle
        self.onUpdateSubtitleStyle = onUpdateSubtitleStyle
        self.subtitleVideoGeometry = subtitleVideoGeometry
        self.activeSubtitleCodec = activeSubtitleCodec
        self.formatBadgeText = formatBadgeText
        self.formatPresentationState = formatPresentationState
        self.onScrubbingStateChange = onScrubbingStateChange
        self.onPopoverVisibilityChange = onPopoverVisibilityChange
    }

    private var isCompact: Bool {
        availableWidth < 380
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if isCompact {
                compactControlsBar
            } else {
                wideControlsBar
            }
        }
        .overlayPreferenceValue(VideoTimelineTrackAnchor.self) { anchor in
            GeometryReader { geometry in
                if let anchor, (isHoveringScrubber || isScrubbing),
                   !showVolumePopover, !showSubtitlePopover, !showFormatDetailsPopover {
                    let seconds = CMTimeGetSeconds(isScrubbing ? scrubTime : hoverTime)
                    let image = thumbnails?.sourceURL == videoURL ? thumbnails?.frame(at: seconds)?.image : nil
                    let size = CGSize(width: 156, height: image == nil ? 28 : 128)
                    VideoTimelineThumbnailView(image: image,
                                               timestamp: formatTimestamp(isScrubbing ? scrubTime : hoverTime),
                                               rotationDegrees: userRotationDegrees)
                        .position(VideoTimelinePreviewLayout.center(
                            track: geometry[anchor], pointerX: hoverLocationX,
                            preview: size, viewport: geometry.size
                        ))
                }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: isScrubbing) { _, scrubbing in onScrubbingStateChange(scrubbing) }
        .onAppear { isHoveringScrubber = false }
        .onDisappear {
            onScrubbingStateChange(false)
        }
        .onChange(of: showVolumePopover || showSubtitlePopover || showFormatDetailsPopover) { _, isAnyPopoverShown in
            onPopoverVisibilityChange(isAnyPopoverShown)
        }
    }

    private var subtitleMenu: some View {
        HStack(spacing: 2) {
            SubtitleTrackMenu(
                languageCode: LocalizationState.shared.currentLanguage.bcp47,
                options: subtitleOptions,
                selectedID: selectedSubtitleID,
                selectedSecondaryID: selectedSecondarySubtitleID,
                hasExternalSubtitle: subtitleName != nil,
                controlsVisibility: visibility,
                onSelect: onSelectSubtitle,
                onSelectSecondary: onSelectSecondarySubtitle,
                onRemove: onRemoveSubtitles,
                onLoad: onLoadSubtitles,
                onShowStyle: { showSubtitlePopover = true },
                onUserInteraction: onUserInteraction
            )
            .frame(width: 24, height: 28)
            .ttButtonHelp(MediaLocalization.text(.subtitleHelp))

            if !isCompact {
                Button {
                    showSubtitlePopover.toggle()
                    onUserInteraction()
                } label: {
                    Image(systemName: "textformat.size")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.plain)
                .ttButtonHelp(MediaLocalization.text(.subtitleStyle))
            }
        }
        .popover(isPresented: $showSubtitlePopover, arrowEdge: .top) {
            SubtitleQuickSettingsPopover(
                subtitleOptions: subtitleOptions,
                selectedSubtitleID: selectedSubtitleID,
                selectedSecondarySubtitleID: selectedSecondarySubtitleID,
                style: subtitleStyle,
                videoGeometry: subtitleVideoGeometry,
                activeSubtitleCodec: activeSubtitleCodec,
                onSelectSubtitle: onSelectSubtitle,
                onSelectSecondarySubtitle: onSelectSecondarySubtitle,
                onLoadSubtitles: onLoadSubtitles,
                onUpdateStyle: onUpdateSubtitleStyle,
                onUserInteraction: onUserInteraction
            )
        }
    }

    // MARK: - Compact Mode Controls (< 380 pt)

    @ViewBuilder
    private func formatBadgeControl(isCompact: Bool) -> some View {
        let resolvedState = formatPresentationState ?? VideoFormatPresentationState(badgeText: formatBadgeText)
        let resolvedBadge = formatBadgeText ?? resolvedState.alwaysAvailableBadgeText
        if !resolvedBadge.isEmpty {
            VideoFormatBadgeButton(
                badgeText: resolvedBadge,
                isCompact: isCompact,
                state: resolvedState,
                isPopoverPresented: $showFormatDetailsPopover,
                onUserInteraction: onUserInteraction
            )
        }
    }

    @ViewBuilder
    private var compactControlsBar: some View {
        HStack(spacing: 8) {
            Button(action: {
                onTogglePlayPause()
                onUserInteraction()
            }) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(MediaLocalization.text(isPlaying ? .pause : .play))
            .ttButtonHelp(MediaLocalization.text(isPlaying ? .pause : .play))

            timelineScrubberView
                .frame(minWidth: 40, maxWidth: .infinity)

            Text(formattedCompactTime)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))

            formatBadgeControl(isCompact: true)

            subtitleMenu

            Button(action: {
                onFullScreenToggle()
                onUserInteraction()
            }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .ttButtonHelp(MediaLocalization.text(.fullscreen))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Wide Mode Controls (>= 380 pt)

    @ViewBuilder
    private var wideControlsBar: some View {
        HStack(spacing: 12) {
            // Left transport cluster
            HStack(spacing: 10) {
                Button(action: {
                    onSeekBy(-10.0)
                    onUserInteraction()
                }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .ttButtonHelp(MediaLocalization.text(.seekBack))

                Button(action: {
                    onTogglePlayPause()
                    onUserInteraction()
                }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .ttButtonHelp(MediaLocalization.text(isPlaying ? .pause : .play))

                Button(action: {
                    onSeekBy(10.0)
                    onUserInteraction()
                }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .ttButtonHelp(MediaLocalization.text(.seekForward))
            }

            // Current timestamp
            Text(formattedCurrentTime)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))

            // Draggable Precision Timeline Scrubber with Hover Time Bubble
            timelineScrubberView
                .frame(minWidth: 80, maxWidth: .infinity)

            // Duration or Remaining Time
            Button(action: {
                showRemainingTime.toggle()
                onUserInteraction()
            }) {
                Text(formattedDurationTime)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .ttButtonHelp(MediaLocalization.text(.remainingTime))

            // Right utility cluster
            HStack(spacing: 10) {
                // Volume Control Button with Popover
                Button(action: {
                    onMuteToggle()
                    onUserInteraction()
                }) {
                    Image(systemName: volumeIconName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showVolumePopover, arrowEdge: .top) {
                    volumePopoverContent
                }
                .simultaneousGesture(TapGesture().onEnded { onUserInteraction() })
                .ttButtonHelp(MediaLocalization.text(.volumeMute))

                // Playback Rate Menu
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button("\(String(format: "%.2fx", rate))") {
                            onRateChange(Float(rate))
                            onUserInteraction()
                        }
                    }
                } label: {
                    Text(String(format: "%.2fx", playbackRate))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .ttButtonHelp(MediaLocalization.text(.playbackSpeed))

                // Picture-in-Picture Button
                if pipSupported {
                    Button(action: {
                        onPipToggle()
                        onUserInteraction()
                    }) {
                        Image(systemName: pipActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .ttButtonHelp(MediaLocalization.text(.pip))
                }

                subtitleMenu

                formatBadgeControl(isCompact: false)

                // Fullscreen / Media Focus Button
                Button(action: {
                    onFullScreenToggle()
                    onUserInteraction()
                }) {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .ttButtonHelp(MediaLocalization.text(isFullScreen ? .exitFullscreen : .fullscreen))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Timeline Scrubber View with Hover Time Bubble

    @ViewBuilder
    private var timelineScrubberView: some View {
        GeometryReader { geo in
            let totalSec = max(0.001, CMTimeGetSeconds(duration))
            let currentSec = isScrubbing ? CMTimeGetSeconds(scrubTime) : CMTimeGetSeconds(currentTime)
            let progress = max(0.0, min(1.0, currentSec / totalSec))
            let trackWidth = max(0.0, geo.size.width)
            let isExpanded = isScrubbing || isHoveringScrubber

            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: isExpanded ? 6 : 4)

                // Played Progress Track
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [TTKitTheme.bambooGreen, Color.white.opacity(0.90)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0.0, trackWidth * CGFloat(progress)), height: isExpanded ? 6 : 4)

                // Scrubber Thumb Handle
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.40), radius: 3, y: 1)
                    .frame(width: isExpanded ? 13 : 8, height: isExpanded ? 13 : 8)
                    .offset(x: max(0.0, min(trackWidth - (isExpanded ? 13 : 8), trackWidth * CGFloat(progress) - (isExpanded ? 6.5 : 4))))


            }
            .frame(height: 28)
            .anchorPreference(key: VideoTimelineTrackAnchor.self, value: .bounds) { $0 }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isHoveringScrubber = true
                    hoverLocationX = location.x
                    let fraction = max(0.0, min(1.0, location.x / max(1.0, trackWidth)))
                    hoverTime = CMTime(seconds: fraction * totalSec, preferredTimescale: 600)
                    onUserInteraction()
                case .ended:
                    isHoveringScrubber = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        hoverLocationX = value.location.x
                        let fraction = max(0.0, min(1.0, value.location.x / max(1.0, trackWidth)))
                        let targetSec = fraction * totalSec
                        scrubTime = CMTime(seconds: targetSec, preferredTimescale: duration.timescale > 0 ? duration.timescale : 600)
                        onUserInteraction()
                    }
                    .onEnded { value in
                        let fraction = max(0.0, min(1.0, value.location.x / max(1.0, trackWidth)))
                        let targetSec = fraction * totalSec
                        let finalTime = CMTime(seconds: targetSec, preferredTimescale: duration.timescale > 0 ? duration.timescale : 600)
                        onSeekTo(finalTime)
                        isScrubbing = false
                        onUserInteraction()
                    }
            )
        }
        .frame(height: 28)
    }

    // MARK: - Volume Popover Content

    @ViewBuilder
    private var volumePopoverContent: some View {
        VStack(spacing: 8) {
            HStack {
                Text(MediaLocalization.text(.volume))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(volume * 100))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Slider(
                value: Binding(
                    get: { Double(volume) },
                    set: { newVol in onVolumeChange(Float(newVol)) }
                ),
                in: 0.0...1.0
            )
            .frame(width: 120)
        }
        .padding(10)
    }

    // MARK: - Helpers

    private var formattedCurrentTime: String {
        let time = isScrubbing ? scrubTime : currentTime
        return formatTimestamp(time)
    }

    private var formattedDurationTime: String {
        if showRemainingTime {
            let total = CMTimeGetSeconds(duration)
            let curr = isScrubbing ? CMTimeGetSeconds(scrubTime) : CMTimeGetSeconds(currentTime)
            let rem = max(0.0, total - curr)
            return "-\(formatTimestamp(CMTime(seconds: rem, preferredTimescale: duration.timescale > 0 ? duration.timescale : 600)))"
        } else {
            return formatTimestamp(duration)
        }
    }

    private var formattedCompactTime: String {
        let curr = formatTimestamp(isScrubbing ? scrubTime : currentTime)
        let total = formatTimestamp(duration)
        return "\(curr) / \(total)"
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
