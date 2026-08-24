// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore

/// DAW-grade Physical Audio Waveform Visualizer (DaVinci Resolve / Adobe Audition style).
/// Renders true bipolar time-domain acoustic amplitude peaks around a central 0dB zero-axis baseline,
/// with real-time playhead needle scrubbing, played gradient mask, and decibel level grid lines.
public struct AudioWaveformVisualizerView: View {
    public let url: URL?
    public let isPlaying: Bool
    public let currentTime: Double
    public let duration: Double
    public var sampleCount: Int = 1600
    public var onSeek: ((Double) -> Void)? = nil
    
    @State private var waveformPeaks: [CGFloat] = []
    @State private var hoverLocationX: CGFloat? = nil
    @State private var isHovering: Bool = false
    
    public init(
        url: URL? = nil,
        isPlaying: Bool,
        currentTime: Double = 0,
        duration: Double = 0,
        sampleCount: Int = 1600,
        onSeek: ((Double) -> Void)? = nil
    ) {
        self.url = url
        self.isPlaying = isPlaying
        self.currentTime = currentTime
        self.duration = duration
        self.sampleCount = sampleCount
        self.onSeek = onSeek
    }
    
    private var progressRatio: Double {
        guard duration > 0 else { return 0 }
        return max(0.0, min(1.0, currentTime / duration))
    }
    
    public var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                let height = geo.size.height
                let playheadX = CGFloat(progressRatio) * width
                
                ZStack(alignment: .topLeading) {
                    // 1. Studio DAW Track Background (DaVinci Fairlight Deep Slate Forest)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.14, green: 0.25, blue: 0.20),
                                    Color(red: 0.10, green: 0.18, blue: 0.14)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                        )
                    
                    // 2. dB Level Reference Grid
                    Canvas { context, size in
                        let w = size.width
                        let h = size.height
                        let mY = h / 2.0
                        let halfH = (h - 8.0) / 2.0
                        
                        // Upper +6 dB reference guide line
                        var upperLine = Path()
                        upperLine.move(to: CGPoint(x: 0, y: mY - halfH * 0.72))
                        upperLine.addLine(to: CGPoint(x: w, y: mY - halfH * 0.72))
                        context.stroke(upperLine, with: .color(Color.white.opacity(0.15)), style: StrokeStyle(lineWidth: 0.5))
                        
                        // Lower -6 dB reference guide line
                        var lowerLine = Path()
                        lowerLine.move(to: CGPoint(x: 0, y: mY + halfH * 0.72))
                        lowerLine.addLine(to: CGPoint(x: w, y: mY + halfH * 0.72))
                        context.stroke(lowerLine, with: .color(Color.white.opacity(0.15)), style: StrokeStyle(lineWidth: 0.5))
                        
                        // Center 0 dB Zero-Axis Baseline (hairline)
                        var centerLine = Path()
                        centerLine.move(to: CGPoint(x: 0, y: mY))
                        centerLine.addLine(to: CGPoint(x: w, y: mY))
                        context.stroke(centerLine, with: .color(Color.white.opacity(0.35)), lineWidth: 0.8)
                    }
                    
                    // 3. Continuous Physical Waveform (Unplayed Base Layer - Solid Mint / Sage White)
                    Canvas { context, size in
                        drawContinuousWaveform(
                            context: context,
                            size: size,
                            peaks: waveformPeaks,
                            fillColor: Color(red: 0.88, green: 0.95, blue: 0.91).opacity(0.95),
                            gradient: nil
                        )
                    }
                    
                    // 4. Continuous Physical Waveform (Played Fairlight High-Energy Mask)
                    Canvas { context, size in
                        drawContinuousWaveform(
                            context: context,
                            size: size,
                            peaks: waveformPeaks,
                            fillColor: .clear,
                            gradient: Gradient(
                                colors: [
                                    Color(red: 0.68, green: 0.92, blue: 0.35),
                                    TTZipTheme.kintsugiGold,
                                    Color(red: 0.68, green: 0.92, blue: 0.35)
                                ]
                            )
                        )
                    }
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle()
                                .frame(width: max(0, playheadX))
                            Spacer(minLength: 0)
                        }
                    )
                    
                    // 5. DAW Playhead Needle (Scrubber Line & Top Marker)
                    if duration > 0 {
                        ZStack(alignment: .top) {
                            // Vertical needle line
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            TTZipTheme.kintsugiGold,
                                            Color.white,
                                            TTZipTheme.bambooGreen
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 1.5, height: height)
                                .shadow(color: Color.white.opacity(0.6), radius: 2, x: 0, y: 0)
                            
                            // Needle top handle (inverted triangle)
                            NeedleHeadShape()
                                .fill(TTZipTheme.kintsugiGold)
                                .frame(width: 8, height: 6)
                                .offset(y: 0)
                                .shadow(color: Color.black.opacity(0.4), radius: 1.5, x: 0, y: 1)
                        }
                        .offset(x: max(0, min(width - 1.5, playheadX - 0.75)))
                        .allowsHitTesting(false)
                    }
                    
                    // 6. Hover Scrub Timecode Tooltip
                    if let hX = hoverLocationX, duration > 0 {
                        let hoverTime = max(0.0, min(duration, Double(hX / width) * duration))
                        VStack(spacing: 2) {
                            Text(formatTimePrecise(hoverTime))
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.black.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(TTZipTheme.kintsugiGold.opacity(0.5), lineWidth: 0.5)
                                    )
                        }
                        .offset(x: max(10, min(width - 60, hX - 25)), y: 4)
                        .allowsHitTesting(false)
                    }
                    
                    // 7. Decibel Scale Marks (Top Right & Center Right)
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("+0 dB")
                                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.45))
                            Spacer()
                            Text("-6 dB")
                                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.35))
                            Spacer()
                            Text("-∞")
                                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.35))
                        }
                        .padding(.trailing, 6)
                        .padding(.vertical, 3)
                        .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        hoverLocationX = loc.x
                        isHovering = true
                    case .ended:
                        hoverLocationX = nil
                        isHovering = false
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            let ratio = max(0.0, min(1.0, value.location.x / width))
                            let targetSec = ratio * duration
                            onSeek?(targetSec)
                        }
                )
            }
            .frame(height: 60)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            
            // Bottom precise timecode row
            HStack {
                Text(formatTimePrecise(currentTime))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Spacer()
                Text("Continuous Physical Waveform (DAW Oscillogram)")
                    .font(.system(size: 9, weight: .medium, design: .serif))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                Spacer()
                Text(formatTimePrecise(duration))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        }
        .task(id: url) {
            await loadWaveform()
        }
    }
    
    private func drawContinuousWaveform(
        context: GraphicsContext,
        size: CGSize,
        peaks: [CGFloat],
        fillColor: Color,
        gradient: Gradient?
    ) {
        guard !peaks.isEmpty else { return }
        let count = peaks.count
        let w = size.width
        let h = size.height
        let midY = h / 2.0
        let maxHalfH = max(4.0, (h - 8.0) / 2.0)
        let sliceWidth = w / CGFloat(count)
        
        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY))
        
        // 1. Top step contour (Left to Right) with perceptual dynamic expansion
        for i in 0..<count {
            let x1 = CGFloat(i) * sliceWidth
            let x2 = CGFloat(i + 1) * sliceWidth
            let peak = peaks[i]
            let amp: CGFloat
            if peak < 0.012 {
                amp = 0.5
            } else {
                amp = max(0.8, pow(peak, 0.58) * maxHalfH)
            }
            let topY = midY - amp
            
            path.addLine(to: CGPoint(x: x1, y: topY))
            path.addLine(to: CGPoint(x: x2, y: topY))
        }
        
        path.addLine(to: CGPoint(x: w, y: midY))
        
        // 2. Bottom step contour (Right to Left)
        for i in stride(from: count - 1, through: 0, by: -1) {
            let x1 = CGFloat(i) * sliceWidth
            let x2 = CGFloat(i + 1) * sliceWidth
            let peak = peaks[i]
            let amp: CGFloat
            if peak < 0.012 {
                amp = 0.5
            } else {
                amp = max(0.8, pow(peak, 0.58) * maxHalfH)
            }
            let bottomY = midY + amp
            
            path.addLine(to: CGPoint(x: x2, y: bottomY))
            path.addLine(to: CGPoint(x: x1, y: bottomY))
        }
        
        path.closeSubpath()
        
        if let grad = gradient {
            context.fill(
                path,
                with: .linearGradient(
                    grad,
                    startPoint: CGPoint(x: 0, y: midY - maxHalfH),
                    endPoint: CGPoint(x: 0, y: midY + maxHalfH)
                )
            )
            context.stroke(
                path,
                with: .color(Color(red: 0.68, green: 0.92, blue: 0.35).opacity(0.8)),
                lineWidth: 0.5
            )
        } else {
            context.fill(path, with: .color(fillColor))
            context.stroke(
                path,
                with: .color(Color.white.opacity(0.40)),
                lineWidth: 0.5
            )
        }
    }
    
    private func loadWaveform() async {
        guard let u = url else {
            let def = await AudioWaveformExtractor.shared.defaultWaveform(count: sampleCount)
            await MainActor.run {
                self.waveformPeaks = def
            }
            return
        }
        
        let peaks = await AudioWaveformExtractor.shared.extractWaveform(from: u, targetSampleCount: sampleCount)
        await MainActor.run {
            self.waveformPeaks = peaks
        }
    }
    
    private func formatTimePrecise(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let totalSec = Int(seconds)
        let mins = totalSec / 60
        let secs = totalSec % 60
        let millis = Int((seconds - Double(totalSec)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, millis)
    }
}

/// Inverted triangle playhead needle top marker.
private struct NeedleHeadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
