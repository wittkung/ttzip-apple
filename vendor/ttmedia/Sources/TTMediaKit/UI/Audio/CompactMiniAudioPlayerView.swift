// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

// MARK: - Mini Player Presenter & Panel

/// Dedicated macOS floating panel hosting the detached mini audio player bar.
@MainActor
public final class TTAudioMiniPlayerPanel: NSPanel {
    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 72),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isFloatingPanel = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.animationBehavior = .utilityWindow
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

/// Standalone presenter orchestrating the floating mini audio player bar across workspace windows.
@MainActor
public final class TTAudioMiniPlayerPresenter: NSObject, @unchecked Sendable {
    public static let shared = TTAudioMiniPlayerPresenter()

    private var panel: TTAudioMiniPlayerPanel?
    private var windowCloseObserver: (any NSObjectProtocol)?

    public var isPresented: Bool {
        panel?.isVisible == true
    }

    public func present(
        store: MPVAudioEngine,
        title: String,
        artist: String? = nil,
        artwork: NSImage? = nil,
        parentWindow: NSWindow? = nil,
        onPrevious: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        onRestore: (() -> Void)? = nil
    ) {
        dismiss()

        let targetPanel = TTAudioMiniPlayerPanel()
        self.panel = targetPanel

        let miniWidth: CGFloat = 380
        let miniHeight: CGFloat = 72
        targetPanel.minSize = CGSize(width: miniWidth, height: miniHeight)
        targetPanel.maxSize = CGSize(width: miniWidth, height: miniHeight)

        let screen = parentWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let originX = visibleFrame.maxX - miniWidth - 24
        let originY = visibleFrame.minY + 24
        targetPanel.setFrame(NSRect(x: originX, y: originY, width: miniWidth, height: miniHeight), display: true)

        let miniView = CompactMiniAudioPlayerView(
            store: store,
            title: title,
            artist: artist,
            artwork: artwork,
            onPrevious: onPrevious,
            onNext: onNext,
            onRestore: { [weak self] in
                onRestore?()
                self?.dismiss()
            }
        )

        let hostingView = NSHostingView(rootView: miniView)
        hostingView.frame = NSRect(x: 0, y: 0, width: miniWidth, height: miniHeight)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 14.0
        hostingView.layer?.masksToBounds = true

        targetPanel.contentView = hostingView
        targetPanel.orderFrontRegardless()

        if let parentWin = parentWindow {
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: parentWin,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.dismiss()
                }
            }
        }
    }

    public func dismiss() {
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowCloseObserver = nil
        }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

// MARK: - Compact Mini Audio Player View

/// Compact 72pt desktop floating mini audio player bar adhering to Apple HIG and optical principles.
///
/// Features an ultra-thin frosted glass backing, 48x48 vinyl artwork with continuous micro-rotation,
/// dual-line marquee text for overflowing metadata, precision interactive micro-scrubber,
/// and transport control cluster.
public struct CompactMiniAudioPlayerView: View {
    @Bindable public var store: MPVAudioEngine
    public let title: String
    public let artist: String?
    public let artwork: NSImage?
    public let onPrevious: (() -> Void)?
    public let onNext: (() -> Void)?
    public let onRestore: () -> Void

    @State private var isScrubberHovered: Bool = false
    @State private var isVolumeHovered: Bool = false
    @State private var isVolumeSliderPresented: Bool = false

    public init(
        store: MPVAudioEngine,
        title: String,
        artist: String? = nil,
        artwork: NSImage? = nil,
        onPrevious: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil,
        onRestore: @escaping () -> Void
    ) {
        self.store = store
        self.title = title
        self.artist = artist
        self.artwork = artwork
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onRestore = onRestore
    }

    public var body: some View {
        ZStack {
            // Background drag responder passing window movements seamlessly
            WindowDragBackingView()

            // 72pt Compact Core Horizontal Layout
            HStack(spacing: 12) {
                // 1. Left: 48x48 Vinyl Album Art with Micro-Rotation
                VinylArtworkThumbnailView(
                    artwork: artwork,
                    isPlaying: store.isPlaying
                )
                .frame(width: 48, height: 48)

                // 2. Center: Metadata & Interactive Micro-Scrubber
                VStack(alignment: .leading, spacing: 3) {
                    // Song Title & Artist with Marquee Scroll Capability
                    VStack(alignment: .leading, spacing: 1) {
                        MarqueeTextView(
                            text: title.isEmpty ? AudioPreviewLocalization.text(.unknownTrack) : title,
                            font: .system(size: 13, weight: .semibold),
                            color: Color.white.opacity(0.92)
                        )
                        .frame(height: 16)

                        MarqueeTextView(
                            text: artist?.isEmpty == false ? artist! : AudioPreviewLocalization.text(.unknownArtist),
                            font: .system(size: 11, weight: .regular),
                            color: Color.white.opacity(0.55)
                        )
                        .frame(height: 14)
                    }

                    // Interactive Micro-Scrubber Bar
                    InteractiveMicroScrubber(
                        currentTime: store.currentTime,
                        duration: store.duration,
                        cacheProgress: store.demuxerCacheProgress,
                        isHovered: $isScrubberHovered,
                        onSeek: { targetTime in
                            store.seek(to: targetTime)
                        }
                    )
                    .frame(height: isScrubberHovered ? 8 : 4)
                    .animation(.easeInOut(duration: 0.16), value: isScrubberHovered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 3. Right: Minimal Transport Control Cluster
                HStack(spacing: 6) {
                    // Previous Track / Rewind
                    MiniTransportButton(
                        systemImage: "backward.fill",
                        size: 11,
                        helpText: AudioPreviewLocalization.text(.previousOrSeekBackHelp),
                        action: handlePrevious
                    )

                    // Play / Pause Primary Action
                    Button(action: {
                        store.togglePlayPause()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 28, height: 28)

                            Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .offset(x: store.isPlaying ? 0 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .ttButtonHelp(AudioPreviewLocalization.text(store.isPlaying ? .pause : .play))

                    // Next Track / Forward
                    MiniTransportButton(
                        systemImage: "forward.fill",
                        size: 11,
                        helpText: AudioPreviewLocalization.text(.nextOrSeekForwardHelp),
                        action: handleNext
                    )

                    // Mini Volume Slider / Mute Toggle
                    ZStack(alignment: .bottom) {
                        MiniTransportButton(
                            systemImage: volumeIconName,
                            size: 11,
                            helpText: AudioPreviewLocalization.text(.volumeMuteOrScrollHelp),
                            action: {
                                store.toggleMute()
                            }
                        )
                        .popover(isPresented: $isVolumeSliderPresented, arrowEdge: .top) {
                            MiniVolumePopoverView(
                                volume: Binding(
                                    get: { store.volume },
                                    set: { store.setVolume($0) }
                                ),
                                isMuted: store.isMuted,
                                onToggleMute: { store.toggleMute() }
                            )
                        }
                    }

                    // Docking / Restore to Main Window
                    MiniTransportButton(
                        systemImage: "arrow.down.right.and.arrow.up.left",
                        size: 11,
                        helpText: AudioPreviewLocalization.text(.restoreToMainWindowHelp),
                        action: onRestore
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 300, idealWidth: 360, minHeight: 72, maxHeight: 72)
        .background(
            ZStack {
                // Frost HUD Glass Backing
                VisualEffectBlurRepresentable(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.40)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.0)
        )
    }

    private var volumeIconName: String {
        if store.isMuted || store.volume <= 0.001 {
            return "speaker.slash.fill"
        } else if store.volume < 0.35 {
            return "speaker.wave.1.fill"
        } else if store.volume < 0.75 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private func handlePrevious() {
        if let onPrevious {
            onPrevious()
        } else if store.currentTime > 3.0 {
            store.seek(to: 0.0)
        } else {
            store.seekBy(-5.0)
        }
    }

    private func handleNext() {
        if let onNext {
            onNext()
        } else {
            store.seekBy(15.0)
        }
    }
}

// MARK: - Vinyl Artwork with Micro-Rotation

/// 48x48 Vinyl-stylized album artwork thumbnail executing continuous micro-rotation during playback.
public struct VinylArtworkThumbnailView: View {
    public let artwork: NSImage?
    public let isPlaying: Bool

    public init(artwork: NSImage?, isPlaying: Bool) {
        self.artwork = artwork
        self.isPlaying = isPlaying
    }

    public var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2

                // 1. Draw outer dark vinyl body
                let vinylRect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                let vinylPath = Path(roundedRect: vinylRect, cornerRadius: 8)
                context.fill(vinylPath, with: .color(Color(white: 0.12)))

                // 2. Draw subtle concentric vinyl groove highlights
                for inset in stride(from: 3.0, to: radius - 4.0, by: 4.0) {
                    let grooveRect = vinylRect.insetBy(dx: inset, dy: inset)
                    let groovePath = Path(roundedRect: grooveRect, cornerRadius: max(2, 8 - inset * 0.4))
                    context.stroke(groovePath, with: .color(Color.white.opacity(0.04)), lineWidth: 0.5)
                }
            }
            .overlay(
                // Artwork center disc
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
                                .font(.system(size: 18, weight: .light))
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
                // Specular border ring
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
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

// MARK: - Dual-line Marquee Text Component

/// Horizontal marquee text executing smooth back-and-forth oscillation when text overflows container width.
public struct MarqueeTextView: View {
    public let text: String
    public let font: Font
    public let color: Color

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var marqueeTask: Task<Void, Never>? = nil

    public init(text: String, font: Font, color: Color) {
        self.text = text
        self.font = font
        self.color = color
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Invisible measuring label
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

                // Visible text rendering with offset
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
                // Initial rest pause at start
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard !Task.isCancelled else { break }

                // Smooth scroll towards the end (speed: ~25 pt/sec)
                let scrollDuration = Double(overflow) / 25.0
                withAnimation(.easeInOut(duration: scrollDuration)) {
                    offset = overflow + 6.0
                }

                try? await Task.sleep(nanoseconds: UInt64((scrollDuration + 1.5) * 1_000_000_000))
                guard !Task.isCancelled else { break }

                // Smooth return to start
                withAnimation(.easeInOut(duration: scrollDuration * 0.8)) {
                    offset = 0
                }

                try? await Task.sleep(nanoseconds: UInt64((scrollDuration * 0.8) * 1_000_000_000))
            }
        }
    }
}

public struct TextWidthPreferenceKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Interactive Micro Scrubber

/// Precision micro-scrubber bar supporting hover height expansion and direct click-to-seek navigation.
public struct InteractiveMicroScrubber: View {
    public let currentTime: Double
    public let duration: Double
    public let cacheProgress: Double
    @Binding public var isHovered: Bool
    public let onSeek: (Double) -> Void

    public init(
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

    public var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let safeDuration = max(duration, 0.001)
            let progressRatio = max(0.0, min(1.0, currentTime / safeDuration))
            let activeWidth = totalWidth * CGFloat(progressRatio)
            let bufferWidth = totalWidth * CGFloat(max(0.0, min(1.0, cacheProgress)))
            let trackHeight: CGFloat = isHovered ? 5.0 : 3.0

            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: trackHeight)

                // Cache / Buffer Fill
                if bufferWidth > 0 {
                    Capsule()
                        .fill(Color.white.opacity(0.24))
                        .frame(width: max(0, bufferWidth), height: trackHeight)
                }

                // Active Playback Progress Fill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.85), Color.white],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, activeWidth), height: trackHeight)

                // Scrubber Knob appearing on Hover
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
                        let clampedX = max(0, min(totalWidth, value.location.x))
                        let ratio = clampedX / totalWidth
                        let targetSeconds = Double(ratio) * safeDuration
                        onSeek(targetSeconds)
                    }
            )
        }
    }
}

// MARK: - Mini Transport Control Button

public struct MiniTransportButton: View {
    public let systemImage: String
    public let size: CGFloat
    public let helpText: String
    public let action: () -> Void

    @State private var isHovering: Bool = false

    public init(
        systemImage: String,
        size: CGFloat,
        helpText: String,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.size = size
        self.helpText = helpText
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovering ? Color.white.opacity(0.16) : Color.clear)
                    .frame(width: 24, height: 24)

                Image(systemName: systemImage)
                    .font(.system(size: size, weight: .medium))
                    .foregroundColor(isHovering ? .white : Color.white.opacity(0.78))
            }
        }
        .buttonStyle(.plain)
        .ttButtonHelp(helpText)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Mini Volume Popover View

public struct MiniVolumePopoverView: View {
    @Binding public var volume: Double
    public let isMuted: Bool
    public let onToggleMute: () -> Void

    public init(
        volume: Binding<Double>,
        isMuted: Bool,
        onToggleMute: @escaping () -> Void
    ) {
        self._volume = volume
        self.isMuted = isMuted
        self.onToggleMute = onToggleMute
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)

            Slider(
                value: $volume,
                in: 0.0...1.0
            )
            .frame(width: 90)

            Text("\(Int(volume * 100))%")
                .font(.system(size: 10, weight: .regular))
                .monospacedDigit()
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 170)
    }
}

// MARK: - Window Dragging Backing View

/// Non-interactive AppKit view subclass triggering window-drag movement on mouseDown events.
public struct WindowDragBackingView: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> WindowDragResponderView {
        WindowDragResponderView()
    }

    public func updateNSView(_ nsView: WindowDragResponderView, context: Context) {}
}

public final class WindowDragResponderView: NSView {
    public override var mouseDownCanMoveWindow: Bool { true }

    public override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Visual Effect Blur Representable

public struct VisualEffectBlurRepresentable: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
