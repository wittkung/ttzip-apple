// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTMediaKit

struct TTZipAudioWaveformTimeline: View {
    let url: URL
    let audioEngine: MPVAudioEngine
    let peaks: [Float]
    let isCompact: Bool
    let tileCache: AudioWindowedWaveformTileCache

    @State private var scrubPreviewTime: Double?
    @State private var dragStartTime: Double?

    private var currentTime: Double { scrubPreviewTime ?? audioEngine.currentTime }

    var body: some View {
        GeometryReader { geometry in
            let resolution = AudioScrollingTimelineMapper.resolveVisibleTicks(
                currentTime: currentTime,
                duration: audioEngine.duration,
                canvasWidth: geometry.size.width,
                slotPitch: isCompact ? 3.0 : 3.4,
                wholeTrackPeaks: peaks,
                tileCache: tileCache,
                hasWindowedProvider: true,
                resourceURL: url,
                loadGeneration: audioEngine.activeLoadGeneration
            )
            WaveformCanvas(ticks: visibleTicks(resolution), tickWidth: isCompact ? 1.6 : 1.8)
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: geometry.size.width))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TTZipAudioPreviewLocalization.text(.scrollingWaveformAccessibilityLabel))
        }
        .frame(minHeight: isCompact ? 22 : 28)
        .onChange(of: currentTime) { _, time in
            prefetchTiles(at: time)
        }
        .onAppear {
            prefetchTiles(at: currentTime)
        }
    }

    private func visibleTicks(_ resolution: AudioScrollingWindowResolutionState) -> [AudioScrollingWaveformTick] {
        switch resolution {
        case .highResolutionTiles(let ticks), .denseWholeTrackPeaks(let ticks), .loadingWindowTile(let ticks):
            return ticks
        case .awaitingHighResTileProvider:
            return []
        }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard audioEngine.duration.isFinite, audioEngine.duration > 0, width > 1 else { return }
                let anchor = dragStartTime ?? currentTime
                dragStartTime = anchor
                scrubPreviewTime = seekTarget(for: value, width: width, anchor: anchor)
                if let scrubPreviewTime {
                    prefetchTiles(at: scrubPreviewTime)
                }
            }
            .onEnded { value in
                guard audioEngine.duration.isFinite, audioEngine.duration > 0, width > 1 else { return }
                let target = seekTarget(for: value, width: width, anchor: dragStartTime ?? currentTime)
                dragStartTime = nil
                scrubPreviewTime = nil
                if let target {
                    audioEngine.seek(to: target)
                }
            }
    }

    private func seekTarget(for value: DragGesture.Value, width: CGFloat, anchor: Double) -> Double? {
        if abs(value.translation.width) < 1.5 {
            return AudioScrollingTimelineMapper.resolveClickTargetTime(
                currentTime: anchor,
                clickX: value.location.x,
                canvasWidth: width,
                duration: audioEngine.duration
            )
        }
        return AudioScrollingTimelineMapper.resolveDragPreviewTime(
            dragStartTime: anchor,
            translationX: value.translation.width,
            canvasWidth: width,
            duration: audioEngine.duration
        )
    }

    private func prefetchTiles(at time: Double) {
        tileCache.ensureVisibleTilesLoaded(
            currentTime: time,
            duration: audioEngine.duration,
            windowDuration: AudioScrollingTimelineMapper.defaultWindowDuration,
            resourceURL: url,
            loadGeneration: audioEngine.activeLoadGeneration,
            ownerSessionID: audioEngine.activeOwnerSessionID,
            stableReferencePeak: max(0.05, peaks.max() ?? 0.05),
            provider: AudioWaveformWindowExtractor.shared
        )
    }
}

private struct WaveformCanvas: View {
    let ticks: [AudioScrollingWaveformTick]
    let tickWidth: CGFloat

    var body: some View {
        Canvas { context, canvasSize in
            let midY = canvasSize.height * 0.5
            let centerPlayheadX = canvasSize.width * 0.5
            let axisRect = CGRect(x: 0, y: midY - 0.25, width: canvasSize.width, height: 0.5)
            context.fill(Path(axisRect), with: .color(WaveformColors.inactiveBar.opacity(0.28)))

            let radius = tickWidth * 0.5
            for tick in ticks {
                let height = tickHeight(amplitude: tick.amplitude, canvasHeight: canvasSize.height)
                let rect = CGRect(
                    x: tick.xPosition - radius,
                    y: midY - height * 0.5,
                    width: tickWidth,
                    height: height
                )
                let isSilenceDot = abs(tick.amplitude) <= AudioWaveformWindowLimits.silencePeakFloor
                let color = tick.isPlayed ? EmbeddedAudioColors.bambooGreen : WaveformColors.inactiveBar
                context.fill(
                    Path(roundedRect: rect, cornerRadius: radius),
                    with: .color(isSilenceDot ? color.opacity(0.62) : color)
                )
            }

            let needle = CGRect(x: centerPlayheadX - 0.9, y: 0, width: 1.8, height: canvasSize.height)
            let cap = CGRect(x: centerPlayheadX - 2.2, y: 0, width: 4.4, height: 2.2)
            context.fill(Path(roundedRect: needle, cornerRadius: 0.9), with: .color(EmbeddedAudioColors.kintsugiGold))
            context.fill(Path(roundedRect: cap, cornerRadius: 1.1), with: .color(EmbeddedAudioColors.kintsugiGold))
        }
    }

    private func tickHeight(amplitude: Float, canvasHeight: CGFloat) -> CGFloat {
        guard amplitude.isFinite, canvasHeight > 0 else { return 1.5 }
        let magnitude = abs(amplitude)
        guard magnitude > AudioWaveformWindowLimits.silencePeakFloor else {
            return min(canvasHeight, 1.5)
        }
        let minimum: CGFloat = 3.2
        let maximum = max(minimum, canvasHeight * 0.90)
        return min(canvasHeight, minimum + CGFloat(min(1, magnitude)) * (maximum - minimum))
    }
}

enum WaveformColors {
    static let trackSurface = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 0.08, green: 0.13, blue: 0.10, alpha: 0.90)
        }
        return NSColor(srgbRed: 0.89, green: 0.92, blue: 0.88, alpha: 0.92)
    }))

    static let trackBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.12)
        }
        return NSColor(srgbRed: 0.35, green: 0.46, blue: 0.32, alpha: 0.22)
    }))

    static let inactiveBar = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.32)
        }
        return NSColor(srgbRed: 0.28, green: 0.36, blue: 0.26, alpha: 0.34)
    }))
}
