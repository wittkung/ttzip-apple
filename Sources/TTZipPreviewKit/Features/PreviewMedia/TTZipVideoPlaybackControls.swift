// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

@preconcurrency import CoreMedia
import SwiftUI
import TTKitDesign
import TTMediaKit

private struct VideoTimelineTrackAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

@MainActor
struct TTZipVideoPlaybackControls: View {
    let context: VideoPlaybackControlsContext

    private struct TimelinePointer {
        let time: CMTime
        let x: CGFloat
    }

    @State private var hover: TimelinePointer?
    @State private var scrub: TimelinePointer?
    @State private var showRemainingTime = false
    @State private var showVolumePopover = false
    @State private var showSubtitlePopover = false
    @State private var showFormatDetailsPopover = false
    @State private var showGIFExportPopover = false
    @State private var showLosslessTrimPopover = false
    @State private var showContainerRemuxPopover = false
    @State private var showAudioExtractPopover = false

    private var transport: VideoPlaybackControlsContext.Transport { context.transport }
    private var isCompact: Bool { context.viewportSize.width < 380 }
    private var isScrubbing: Bool { scrub != nil }
    private var displayedTime: CMTime { scrub?.time ?? transport.currentTime }
    private var isAnyPopoverPresented: Bool {
        showVolumePopover || showSubtitlePopover || showFormatDetailsPopover ||
            showGIFExportPopover || showLosslessTrimPopover || showContainerRemuxPopover ||
            showAudioExtractPopover
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if isCompact {
                compactBar
            } else {
                wideBar
            }
        }
        .overlayPreferenceValue(VideoTimelineTrackAnchor.self) { anchor in
            GeometryReader { geometry in
                if let anchor, let pointer = scrub ?? hover, !isAnyPopoverPresented {
                    VideoTimelineThumbnailView(
                        time: pointer.time,
                        image: context.thumbnail(at: pointer.time),
                        rotationDegrees: context.rotationDegrees,
                        track: geometry[anchor],
                        pointerX: pointer.x,
                        viewport: geometry.size
                    )
                }
            }
            .allowsHitTesting(false)
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            context.send(.interaction(.scrubbing(scrubbing)))
        }
        .onChange(of: isAnyPopoverPresented) { _, presented in
            context.send(.interaction(.popoverPresented(presented)))
        }
        .onAppear { hover = nil }
        .onDisappear {
            context.send(.interaction(.scrubbing(false)))
            scrub = nil
            if isAnyPopoverPresented {
                context.send(.interaction(.popoverPresented(false)))
            }
        }
    }

    private var compactBar: some View {
        HStack(spacing: 8) {
            playPauseButton
            timeline.frame(minWidth: 40, maxWidth: .infinity)
            Text("\(formatVideoTimelineTimestamp(displayedTime)) / \(formatVideoTimelineTimestamp(transport.duration))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            formatBadge
            exportControls
            subtitleControls
            fullscreenButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: UniversalTokens.Dimensions.hairlineWidth)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var wideBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                seekButton(seconds: -10, icon: "gobackward.10", help: MediaLocalization.text(.seekBack))
                playPauseButton
                seekButton(seconds: 10, icon: "goforward.10", help: MediaLocalization.text(.seekForward))
            }

            Text(formatVideoTimelineTimestamp(displayedTime))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
            timeline.frame(minWidth: 80, maxWidth: .infinity)
            durationButton
            wideUtilities
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: UniversalTokens.Dimensions.hairlineWidth)
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private var playPauseButton: some View {
        let title = MediaLocalization.text(transport.isPlaying ? .pause : .play)
        return Button {
            context.send(.togglePlayPause)
            recordActivity()
        } label: {
            Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: isCompact ? 13 : 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: isCompact ? 28 : nil, height: isCompact ? 28 : nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("TTZipVideoPlayPause")
        .ttButtonHelp(title)
    }

    private func seekButton(seconds: Double, icon: String, help: String) -> some View {
        Button {
            context.send(.seekBy(seconds))
            recordActivity()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .ttButtonHelp(help)
    }

    private var durationButton: some View {
        Button {
            showRemainingTime.toggle()
            recordActivity()
        } label: {
            Text(formattedDuration)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .ttButtonHelp(MediaLocalization.text(.remainingTime))
    }

    private var formattedDuration: String {
        guard showRemainingTime else { return formatVideoTimelineTimestamp(transport.duration) }
        let remaining = max(0, CMTimeGetSeconds(transport.duration) - CMTimeGetSeconds(displayedTime))
        return "-\(formatVideoTimelineTimestamp(CMTime(seconds: remaining, preferredTimescale: durationTimescale)))"
    }

    private var wideUtilities: some View {
        HStack(spacing: 10) {
            volumeButton
            playbackRateMenu
            if transport.pipSupported {
                Button {
                    context.send(.togglePictureInPicture)
                    recordActivity()
                } label: {
                    Image(systemName: transport.pipActive ? "pip.exit" : "pip.enter")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .ttButtonHelp(MediaLocalization.text(.pip))
            }
            subtitleControls
            exportControls
            formatBadge
            fullscreenButton
        }
    }

    private var volumeButton: some View {
        Button {
            context.send(.toggleMute)
            recordActivity()
        } label: {
            Image(systemName: volumeIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showVolumePopover, arrowEdge: .top) {
            VStack(spacing: 8) {
                HStack {
                    Text(MediaLocalization.text(.volume))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(transport.volume * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Slider(
                    value: Binding(
                        get: { Double(transport.volume) },
                        set: { context.send(.setVolume(Float($0))) }
                    ),
                    in: 0...1
                )
                .frame(width: 120)
            }
            .padding(10)
        }
        .simultaneousGesture(TapGesture().onEnded { recordActivity() })
        .ttButtonHelp(MediaLocalization.text(.volumeMute))
    }

    private var volumeIcon: String {
        if transport.isMuted || transport.volume == 0 { return "speaker.slash.fill" }
        if transport.volume < 0.33 { return "speaker.wave.1.fill" }
        if transport.volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                Button(String(format: "%.2fx", rate)) {
                    context.send(.setPlaybackRate(Float(rate)))
                    recordActivity()
                }
            }
        } label: {
            Text(String(format: "%.2fx", transport.playbackRate))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .ttButtonHelp(MediaLocalization.text(.playbackSpeed))
    }

    private var subtitleControls: some View {
        TTZipVideoSubtitleControls(
            context: context,
            isCompact: isCompact,
            isStylePresented: $showSubtitlePopover
        )
    }

    @ViewBuilder
    private var formatBadge: some View {
        let text = context.format.alwaysAvailableBadgeText
        if !text.isEmpty {
            TTZipVideoFormatBadgeButton(
                badgeText: text,
                isCompact: isCompact,
                state: context.format,
                isPopoverPresented: $showFormatDetailsPopover,
                onUserInteraction: recordActivity
            )
        }
    }

    @ViewBuilder
    private var exportControls: some View {
        TTZipVideoGIFExportButton(
            videoURL: context.videoURL,
            currentTime: transport.currentTime,
            duration: transport.duration,
            isCompact: isCompact,
            isPopoverPresented: $showGIFExportPopover,
            onUserInteraction: recordActivity
        )
        TTZipVideoLosslessTrimButton(
            videoURL: context.videoURL,
            currentTime: transport.currentTime,
            duration: transport.duration,
            isCompact: isCompact,
            isPopoverPresented: $showLosslessTrimPopover,
            onUserInteraction: recordActivity
        )
        TTZipMediaContainerRemuxButton(
            videoURL: context.videoURL,
            isCompact: isCompact,
            isPopoverPresented: $showContainerRemuxPopover,
            onUserInteraction: recordActivity
        )
        TTZipMediaAudioExtractButton(
            videoURL: context.videoURL,
            isCompact: isCompact,
            isPopoverPresented: $showAudioExtractPopover,
            onUserInteraction: recordActivity
        )
    }

    private var fullscreenButton: some View {
        let isExiting = !isCompact && transport.isFullScreen
        return Button {
            context.send(.toggleFullScreen)
            recordActivity()
        } label: {
            Image(systemName: isExiting ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: isCompact ? 11 : 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: isCompact ? 20 : nil, height: isCompact ? 20 : nil)
        }
        .buttonStyle(.plain)
        .ttButtonHelp(MediaLocalization.text(isExiting ? .exitFullscreen : .fullscreen))
    }

    private var timeline: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            timelineTrack(width: width)
                .frame(height: 28)
                .anchorPreference(key: VideoTimelineTrackAnchor.self, value: .bounds) { $0 }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hover = timelinePointer(x: location.x, width: width, timescale: 600)
                        recordActivity()
                    case .ended:
                        hover = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrub = timelinePointer(x: value.location.x, width: width, timescale: durationTimescale)
                            recordActivity()
                        }
                        .onEnded { value in
                            let pointer = timelinePointer(x: value.location.x, width: width, timescale: durationTimescale)
                            context.send(.seekTo(pointer.time))
                            scrub = nil
                            recordActivity()
                        }
                )
        }
        .frame(height: 28)
    }

    private func timelineTrack(width: CGFloat) -> some View {
        let progress = max(0, min(1, CMTimeGetSeconds(displayedTime) / timelineDuration))
        let isExpanded = isScrubbing || hover != nil
        let trackHeight: CGFloat = isExpanded ? 6 : 4
        let thumbSize: CGFloat = isExpanded ? 13 : 8
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(height: trackHeight)
            Capsule()
                .fill(LinearGradient(
                    colors: [TTKitTheme.bambooGreen, .white.opacity(0.90)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(width: width * CGFloat(progress), height: trackHeight)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.40), radius: 3, y: 1)
                .frame(width: thumbSize, height: thumbSize)
                .offset(x: max(0, min(width - thumbSize, width * CGFloat(progress) - thumbSize / 2)))
        }
    }

    private var timelineDuration: Double { max(0.001, CMTimeGetSeconds(transport.duration)) }

    private var durationTimescale: CMTimeScale {
        transport.duration.timescale > 0 ? transport.duration.timescale : 600
    }

    private func timelinePointer(x: CGFloat, width: CGFloat, timescale: CMTimeScale) -> TimelinePointer {
        let fraction = max(0, min(1, x / max(1, width)))
        return TimelinePointer(time: CMTime(seconds: fraction * timelineDuration, preferredTimescale: timescale), x: x)
    }

    private func recordActivity() {
        context.send(.interaction(.activity))
    }
}

extension View {
    func ttzipVideoUtilityCapsule(isCompact: Bool) -> some View {
        foregroundStyle(.white.opacity(isCompact ? 0.85 : 0.92))
            .padding(.horizontal, isCompact ? 4 : 6)
            .padding(.vertical, isCompact ? 2 : 3)
            .background(Color.white.opacity(0.14), in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    Color.white.opacity(isCompact ? 0.14 : 0.20),
                    lineWidth: UniversalTokens.Dimensions.hairlineWidth
                )
            }
    }
}

struct TTZipVideoExportNotice: View {
    enum Kind {
        case warning
        case error
    }

    let message: String
    let kind: Kind

    var body: some View {
        let tint: Color = kind == .warning ? .orange : .red
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundStyle(tint)
                .font(.system(size: 11))
            if kind == .warning {
                messageText.foregroundStyle(.secondary)
            } else {
                messageText.foregroundStyle(.primary).textSelection(.enabled)
            }
        }
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var messageText: some View {
        Text(message)
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct TTZipVideoExportProgress: View {
    let value: Double
    let cancelIdentifier: String
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .accessibilityIdentifier(cancelIdentifier)
            }
        }
    }
}
