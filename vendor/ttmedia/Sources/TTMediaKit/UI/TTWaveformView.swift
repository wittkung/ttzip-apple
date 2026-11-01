// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Visual rendering style for `TTWaveformView`.
public enum TTWaveformRenderStyle: String, Sendable, Equatable {
    /// Legacy discrete vertical bars separated by `barSpacing` (default for backward compatibility).
    case discreteBars
    /// Dense, thin, vertically symmetric rounded vertical ticks inspired by Voice Memos,
    /// rendering silence/pauses (`<= 0.0001`) as `1.5pt` centered baseline dots and audible signals (`> 0.0001`) as proportional symmetric vertical lines.
    case voiceMemosTicks
}

/// Declarative, high-performance audio waveform visualizer supporting interactive scrubbing and seeking.
public struct TTWaveformView: View {
    /// Silence threshold (`-80 dBFS`) strictly aligned with `AudioWaveformExtractor.silencePeakFloor`.
    public static let silenceAmplitudeThreshold: Float = 0.0001
    /// Baseline dot height (`1.5pt`, i.e. `0.75pt` half-height) rendered when a slot is silent (`<= 0.0001`).
    public static let silenceDotHeight: CGFloat = 1.5
    /// Minimum vertical tick height (`3.2pt`) rendered for any non-silent audible signal (`> 0.0001`),
    /// ensuring quiet signals are visually distinct from `1.5pt` silence baseline dots.
    public static let minAudibleTickHeight: CGFloat = 3.2

    public let waveformPeaks: [Float]
    public let progress: Double
    public var onSeek: (@MainActor @Sendable (Double) -> Void)?
    public var activeColor: Color
    public var inactiveColor: Color
    public var playheadColor: Color
    public var barWidth: CGFloat
    public var barSpacing: CGFloat
    public var cornerRadius: CGFloat
    public var isInteractive: Bool
    public var renderStyle: TTWaveformRenderStyle

    @State private var isDragging: Bool = false
    @State private var dragProgress: Double?
    @State private var hoveredX: CGFloat?

    public init(
        waveformPeaks: [Float],
        progress: Double,
        onSeek: (@MainActor @Sendable (Double) -> Void)? = nil,
        activeColor: Color = .accentColor,
        inactiveColor: Color = Color.secondary.opacity(0.32),
        playheadColor: Color = .primary,
        barWidth: CGFloat = 3.0,
        barSpacing: CGFloat = 2.0,
        cornerRadius: CGFloat = 1.5,
        isInteractive: Bool = true,
        renderStyle: TTWaveformRenderStyle = .discreteBars
    ) {
        self.waveformPeaks = waveformPeaks
        self.progress = max(0.0, min(1.0, progress))
        self.onSeek = onSeek
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.playheadColor = playheadColor
        self.barWidth = max(1.0, barWidth)
        self.barSpacing = max(0.5, barSpacing)
        self.cornerRadius = cornerRadius
        self.isInteractive = isInteractive
        self.renderStyle = renderStyle
    }

    private var effectiveProgress: Double {
        dragProgress ?? progress
    }

    /// Computes the vertically symmetric tick height for `.voiceMemosTicks` style.
    /// - Slots with `abs(amplitude) <= 0.0001` render as `1.5pt` centered baseline dots.
    /// - Slots with `abs(amplitude) > 0.0001` scale monotonically from `3.2pt` up to `canvasHeight * 0.90`.
    public static func resolveVoiceMemosTickHeight(amplitude: Float, canvasHeight: CGFloat) -> CGFloat {
        guard amplitude.isFinite, canvasHeight > 0 else { return silenceDotHeight }
        let mag = abs(amplitude)
        guard mag > silenceAmplitudeThreshold else {
            return min(canvasHeight, silenceDotHeight)
        }
        let clamped = CGFloat(min(1.0, max(0.0, mag)))
        let maxTickHeight = max(minAudibleTickHeight, canvasHeight * 0.90)
        return min(canvasHeight, minAudibleTickHeight + clamped * (maxTickHeight - minAudibleTickHeight))
    }

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .leading) {
                Canvas { context, canvasSize in
                    let activeBoundaryX = CGFloat(effectiveProgress) * canvasSize.width
                    switch renderStyle {
                    case .discreteBars:
                        drawDiscreteBars(in: &context, canvasSize: canvasSize, activeBoundaryX: activeBoundaryX)
                    case .voiceMemosTicks:
                        drawVoiceMemosTicks(in: &context, canvasSize: canvasSize, activeBoundaryX: activeBoundaryX)
                    }
                    drawPlayheadNeedle(in: &context, canvasSize: canvasSize, activeBoundaryX: activeBoundaryX)
                }

                #if os(macOS)
                if let hoverX = hoveredX, isInteractive && !isDragging {
                    Rectangle()
                        .fill(playheadColor.opacity(0.35))
                        .frame(width: 1.0, height: size.height)
                        .offset(x: hoverX)
                        .allowsHitTesting(false)
                }
                #endif
            }
            .contentShape(Rectangle())
            #if os(macOS)
            .onContinuousHover { phase in
                guard isInteractive else { return }
                switch phase {
                case .active(let location):
                    hoveredX = max(0, min(size.width, location.x))
                case .ended:
                    hoveredX = nil
                }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isInteractive, size.width > 0 else { return }
                        isDragging = true
                        let ratio = Double(max(0, min(size.width, value.location.x)) / size.width)
                        dragProgress = ratio
                        onSeek?(ratio)
                    }
                    .onEnded { value in
                        guard isInteractive, size.width > 0 else { return }
                        let ratio = Double(max(0, min(size.width, value.location.x)) / size.width)
                        dragProgress = nil
                        isDragging = false
                        onSeek?(ratio)
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio Waveform")
        .accessibilityValue("\(Int(effectiveProgress * 100)) percent")
    }

    private func drawDiscreteBars(
        in context: inout GraphicsContext,
        canvasSize: CGSize,
        activeBoundaryX: CGFloat
    ) {
        let slotWidth = barWidth + barSpacing
        let totalBars = max(1, Int(canvasSize.width / slotWidth))
        let resampled = resamplePeaks(waveformPeaks, targetCount: totalBars)
        let height = canvasSize.height
        let midY = height / 2.0

        for (index, peak) in resampled.enumerated() {
            let barX = CGFloat(index) * slotWidth
            let normalizedAmplitude = CGFloat(max(0.06, min(1.0, peak)))
            let barHeight = max(4.0, normalizedAmplitude * height * 0.92)
            let barY = midY - (barHeight / 2.0)
            let rect = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
            let path = Path(roundedRect: rect, cornerRadius: cornerRadius)

            if barX + barWidth <= activeBoundaryX {
                context.fill(path, with: .color(activeColor))
            } else if barX >= activeBoundaryX {
                context.fill(path, with: .color(inactiveColor))
            } else {
                let splitRatio = (activeBoundaryX - barX) / barWidth
                let leftWidth = barWidth * splitRatio
                let rightWidth = barWidth - leftWidth
                let leftRect = CGRect(x: barX, y: barY, width: leftWidth, height: barHeight)
                let rightRect = CGRect(x: barX + leftWidth, y: barY, width: rightWidth, height: barHeight)
                context.fill(Path(roundedRect: leftRect, cornerRadius: cornerRadius), with: .color(activeColor))
                context.fill(Path(roundedRect: rightRect, cornerRadius: cornerRadius), with: .color(inactiveColor))
            }
        }
    }

    private func drawVoiceMemosTicks(
        in context: inout GraphicsContext,
        canvasSize: CGSize,
        activeBoundaryX: CGFloat
    ) {
        let width = canvasSize.width
        let height = canvasSize.height
        guard width > 1.0, height > 1.0 else { return }

        let tickW = min(barWidth, 2.0)
        let tickGap = min(barSpacing, 1.8)
        let slotPitch = max(2.2, tickW + tickGap)
        let totalTicks = max(1, Int(width / slotPitch))
        let resampled = waveformPeaks.isEmpty
            ? Array(repeating: Float(0.0), count: totalTicks)
            : resamplePeaks(waveformPeaks, targetCount: totalTicks)
        let midY = height * 0.5
        let radius = tickW * 0.5

        for (index, peak) in resampled.enumerated() {
            let tickX = CGFloat(index) * slotPitch
            let tickH = Self.resolveVoiceMemosTickHeight(amplitude: peak, canvasHeight: height)
            let tickY = midY - (tickH * 0.5)
            let rect = CGRect(x: tickX, y: tickY, width: tickW, height: tickH)
            let path = Path(roundedRect: rect, cornerRadius: radius)
            let isSilenceDot = abs(peak) <= Self.silenceAmplitudeThreshold

            if tickX + (tickW * 0.5) <= activeBoundaryX {
                let color = isSilenceDot ? activeColor.opacity(0.62) : activeColor
                context.fill(path, with: .color(color))
            } else {
                let color = isSilenceDot ? inactiveColor.opacity(0.68) : inactiveColor
                context.fill(path, with: .color(color))
            }
        }
    }

    private func drawPlayheadNeedle(
        in context: inout GraphicsContext,
        canvasSize: CGSize,
        activeBoundaryX: CGFloat
    ) {
        guard effectiveProgress > 0.0 && effectiveProgress < 1.0 else { return }
        let needleRect = CGRect(
            x: activeBoundaryX - 1.0,
            y: 0,
            width: 2.0,
            height: canvasSize.height
        )
        context.fill(Path(roundedRect: needleRect, cornerRadius: 1.0), with: .color(playheadColor))
    }

    /// Resamples an arbitrary length peak envelope array into fixed bucket count using peak-hold aggregation.
    public func resamplePeaks(_ source: [Float], targetCount: Int) -> [Float] {
        guard targetCount > 0 else { return [] }
        guard !source.isEmpty else {
            return Array(repeating: renderStyle == .discreteBars ? 0.15 : 0.0, count: targetCount)
        }
        if source.count == targetCount {
            return source
        }

        var result = [Float](repeating: 0.0, count: targetCount)
        let step = Double(source.count) / Double(targetCount)

        for i in 0..<targetCount {
            let startIdx = Int(Double(i) * step)
            let endIdx = min(source.count, max(startIdx + 1, Int(Double(i + 1) * step)))
            var maxVal: Float = 0.0
            for j in startIdx..<endIdx {
                let v = abs(source[j])
                if v > maxVal { maxVal = v }
            }
            result[i] = maxVal
        }
        return result
    }
}
