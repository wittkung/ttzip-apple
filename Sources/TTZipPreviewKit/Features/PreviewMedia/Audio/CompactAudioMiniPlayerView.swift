// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit
import TTZipUI

struct CompactAudioMiniPlayerView: View {
    @Bindable var store: MPVAudioEngine
    let title: String
    let artist: String?
    let artwork: NSImage?
    let onRestore: () -> Void

    @State private var isScrubberHovered = false

    var body: some View {
        ZStack {
            WindowDragBackingView()

            HStack(spacing: TTZipTheme.Spacing.sm) {
                VinylArtworkThumbnailView(artwork: artwork, isPlaying: store.isPlaying)
                    .frame(width: 48, height: 48)

                trackDetails
                transportControls
            }
            .padding(.horizontal, TTZipTheme.Spacing.sm)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 300, idealWidth: 360, minHeight: 72, maxHeight: 72)
        .background {
            VisualEffectBlurRepresentable(material: .hudWindow, blendingMode: .behindWindow)
            Color.black.opacity(0.40)
        }
        .clipShape(RoundedRectangle(cornerRadius: TTZipTheme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TTZipTheme.Radius.lg, style: .continuous)
                .strokeBorder(TTZipTheme.specularHairline, lineWidth: TTZipTheme.Layout.hairlineBorderWidth)
        }
    }

    private var trackDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 1) {
                MarqueeTextView(
                    text: title.isEmpty ? TTZipAudioPreviewLocalization.text(.unknownTrack) : title,
                    font: .callout.weight(.semibold),
                    color: Color.white.opacity(0.92)
                )
                .frame(height: 16)

                MarqueeTextView(
                    text: artist.flatMap { $0.isEmpty ? nil : $0 } ?? TTZipAudioPreviewLocalization.text(.unknownArtist),
                    font: .caption,
                    color: Color.white.opacity(0.55)
                )
                .frame(height: 14)
            }

            InteractiveMicroScrubber(
                currentTime: store.currentTime,
                duration: store.duration,
                cacheProgress: store.demuxerCacheProgress,
                isHovered: $isScrubberHovered,
                onSeek: { store.seek(to: $0) }
            )
            .frame(height: isScrubberHovered ? 8 : 4)
            .animation(TTZipTheme.Motion.micro, value: isScrubberHovered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transportControls: some View {
        HStack(spacing: 2) {
            MiniTransportButton(
                systemImage: "backward.fill",
                helpText: TTZipAudioPreviewLocalization.text(.previousOrSeekBackHelp),
                action: seekBack
            )

            Button { store.togglePlayPause() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .offset(x: store.isPlaying ? 0 : 1)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(TTZipAudioPreviewLocalization.text(store.isPlaying ? .pause : .play))
            .ttButtonHelp(TTZipAudioPreviewLocalization.text(store.isPlaying ? .pause : .play))

            MiniTransportButton(
                systemImage: "forward.fill",
                helpText: TTZipAudioPreviewLocalization.text(.nextOrSeekForwardHelp)
            ) { store.seekBy(15.0) }

            MiniTransportButton(
                systemImage: volumeIconName,
                helpText: TTZipAudioPreviewLocalization.text(store.isMuted ? .unmute : .mute)
            ) { store.toggleMute() }

            MiniTransportButton(
                systemImage: "arrow.down.right.and.arrow.up.left",
                helpText: TTZipAudioPreviewLocalization.text(.restoreToMainWindowHelp),
                action: onRestore
            )
        }
    }

    private var volumeIconName: String {
        if store.isMuted || store.volume <= 0.001 {
            return "speaker.slash.fill"
        }
        if store.volume < 0.35 {
            return "speaker.wave.1.fill"
        }
        if store.volume < 0.75 {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.3.fill"
    }

    private func seekBack() {
        if store.currentTime > 3.0 {
            store.seek(to: 0.0)
        } else {
            store.seekBy(-5.0)
        }
    }
}

private struct MiniTransportButton: View {
    let systemImage: String
    let helpText: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(isHovering ? 1.0 : 0.78))
                .frame(width: 24, height: 24)
                .background(.white.opacity(isHovering ? 0.16 : 0), in: Circle())
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(helpText)
        .ttButtonHelp(helpText)
        .onHover { isHovering = $0 }
    }
}

private struct VinylArtworkThumbnailView: View {
    let artwork: NSImage?
    let isPlaying: Bool

    init(artwork: NSImage?, isPlaying: Bool) {
        self.artwork = artwork
        self.isPlaying = isPlaying
    }

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2

                let vinylRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                let vinylPath = Path(roundedRect: vinylRect, cornerRadius: 8)
                context.fill(vinylPath, with: .color(Color(white: 0.12)))

                for inset in stride(from: 3.0, to: radius - 4.0, by: 4.0) {
                    let grooveRect = vinylRect.insetBy(dx: inset, dy: inset)
                    let groovePath = Path(roundedRect: grooveRect, cornerRadius: max(2, 8 - inset * 0.4))
                    context.stroke(groovePath, with: .color(Color.white.opacity(0.04)), lineWidth: 0.5)
                }
            }
            .overlay(
                Group {
                    if let artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "music.note")
                                .font(.title3.weight(.light))
                                .foregroundColor(Color.white.opacity(0.65))
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            )
            .rotationEffect(.degrees(currentRotation(for: timeline.date)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: TTZipTheme.Layout.hairlineBorderWidth)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 3, x: 0, y: 1.5)
        }
    }

    private func currentRotation(for date: Date) -> Double {
        guard isPlaying else { return 0.0 }
        let seconds = date.timeIntervalSinceReferenceDate
        return (seconds.truncatingRemainder(dividingBy: 16.0) / 16.0) * 360.0
    }
}


private struct MarqueeTextView: View {
    let text: String
    let font: Font
    let color: Color

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var marqueeTask: Task<Void, Never>? = nil

    init(text: String, font: Font, color: Color) {
        self.text = text
        self.font = font
        self.color = color
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize()
                    .background(
                        GeometryReader { textGeo in
                            Color.clear.preference(key: TextWidthPreferenceKey.self, value: textGeo.size.width)
                        }
                    )
                    .hidden()

                Text(text)
                    .font(font)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: -offset)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            .onPreferenceChange(TextWidthPreferenceKey.self) { measuredWidth in
                textWidth = measuredWidth
                containerWidth = geo.size.width
                restartMarqueeIfNeeded(overflow: max(0, measuredWidth - geo.size.width))
            }
            .onChange(of: text) { _, _ in
                offset = 0
                marqueeTask?.cancel()
            }
            .onDisappear {
                marqueeTask?.cancel()
            }
        }
    }

    private func restartMarqueeIfNeeded(overflow: CGFloat) {
        marqueeTask?.cancel()
        offset = 0
        guard overflow > 4.0 else { return }

        marqueeTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard !Task.isCancelled else { break }

                let scrollDuration = Double(overflow) / 25.0
                withAnimation(.easeInOut(duration: scrollDuration)) {
                    offset = overflow + 6.0
                }

                try? await Task.sleep(nanoseconds: UInt64((scrollDuration + 1.5) * 1_000_000_000))
                guard !Task.isCancelled else { break }

                withAnimation(.easeInOut(duration: scrollDuration * 0.8)) {
                    offset = 0
                }

                try? await Task.sleep(nanoseconds: UInt64((scrollDuration * 0.8) * 1_000_000_000))
            }
        }
    }
}

private struct TextWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


private struct InteractiveMicroScrubber: View {
    let currentTime: Double
    let duration: Double
    let cacheProgress: Double
    @Binding var isHovered: Bool
    let onSeek: (Double) -> Void

    init(
        currentTime: Double,
        duration: Double,
        cacheProgress: Double,
        isHovered: Binding<Bool>,
        onSeek: @escaping (Double) -> Void
    ) {
        self.currentTime = currentTime
        self.duration = duration
        self.cacheProgress = cacheProgress
        self._isHovered = isHovered
        self.onSeek = onSeek
    }

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let safeDuration = max(duration, 0.001)
            let progressRatio = max(0.0, min(1.0, currentTime / safeDuration))
            let activeWidth = totalWidth * CGFloat(progressRatio)
            let bufferWidth = totalWidth * CGFloat(max(0.0, min(1.0, cacheProgress)))
            let trackHeight: CGFloat = isHovered ? 5.0 : 3.0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: trackHeight)

                if bufferWidth > 0 {
                    Capsule()
                        .fill(Color.white.opacity(0.24))
                        .frame(width: max(0, bufferWidth), height: trackHeight)
                }

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.85), Color.white],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, activeWidth), height: trackHeight)

                if isHovered {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .shadow(color: Color.black.opacity(0.4), radius: 2, x: 0, y: 1)
                        .offset(x: max(0, min(totalWidth - 8, activeWidth - 4)))
                }
            }
            .frame(height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard totalWidth > 0 else { return }
                        let clampedX = max(0, min(totalWidth, value.location.x))
                        let ratio = clampedX / totalWidth
                        let targetSeconds = Double(ratio) * safeDuration
                        onSeek(targetSeconds)
                    }
            )
        }
    }
}
