// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

extension UnifiedAudioPlayerView {
    
    // MARK: - Apple Music-Aligned Artwork Card View
    
    @ViewBuilder
    public func artworkCardView(
        image: NSImage,
        size: CGFloat,
        cornerRadius: CGFloat,
        shadowRadius: CGFloat
    ) -> some View {
        let isPlaying = audioEngine.isPlaying
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.38), radius: shadowRadius, x: 0, y: shadowRadius * 0.5)
            .contentShape(Rectangle())
            .onTapGesture { audioEngine.togglePlayPause() }
            .ttButtonHelp(AudioPreviewLocalization.text(isPlaying ? .clickToPauseHelp : .clickToPlayHelp))
    }

    // MARK: - Compact Vinyl Turntable Fallback (When No Artwork Present)

    @ViewBuilder
    public func compactVinylHeroView(diameter: CGFloat) -> some View {
        let isPlaying = audioEngine.isPlaying
        let labelSize = diameter * 0.38
        let needleColor = isPlaying ? TTAudioTheme.bambooGreen : TTAudioTheme.kintsugiGold

        ZStack {
            // Ambient dynamic glow halo
            Circle()
                .fill(RadialGradient(
                    colors: [
                        isPlaying ? TTAudioTheme.bambooGreen.opacity(0.32) : TTAudioTheme.kintsugiGold.opacity(0.14),
                        .clear
                    ],
                    center: .center,
                    startRadius: diameter * 0.15,
                    endRadius: diameter * 0.65
                ))
                .frame(width: diameter * 1.25, height: diameter * 1.25)
                .blur(radius: isPlaying ? 10 : 5)
                .allowsHitTesting(false)

            // Vinyl Record Disc
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [
                            Color(red: 0.15, green: 0.16, blue: 0.18),
                            Color(red: 0.07, green: 0.08, blue: 0.09),
                            Color(red: 0.02, green: 0.03, blue: 0.03)
                        ],
                        center: .center,
                        startRadius: diameter * 0.2,
                        endRadius: diameter * 0.5
                    ))
                    .frame(width: diameter, height: diameter)
                    .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 3)

                ForEach([0.88, 0.74, 0.58], id: \.self) { r in
                    Circle()
                        .stroke(Color.white.opacity(r == 0.58 ? 0.12 : 0.06), lineWidth: 0.7)
                        .frame(width: diameter * r, height: diameter * r)
                }

                Circle()
                    .fill(AngularGradient(
                        colors: [.white.opacity(0.09), .clear, .white.opacity(0.09), .clear],
                        center: .center
                    ))
                    .frame(width: diameter * 0.96, height: diameter * 0.96)

                // Center Artwork & Spindle
                ZStack {
                    if let albumArtImage {
                        Image(nsImage: albumArtImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: labelSize, height: labelSize)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(TTAudioTheme.kintsugiGold, lineWidth: 1.2))
                    } else {
                        Circle()
                            .fill(LinearGradient(
                                colors: [TTAudioTheme.bambooGreen, TTAudioTheme.kintsugiGold],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: labelSize, height: labelSize)
                            .overlay(Circle().strokeBorder(TTAudioTheme.kintsugiGold, lineWidth: 1.2))

                        Image(systemName: isPlaying ? "wave.3.forward" : "music.note")
                            .font(.system(size: max(8, diameter * 0.06), weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Circle()
                        .fill(Color(red: 0.06, green: 0.07, blue: 0.08))
                        .frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(TTAudioTheme.kintsugiGold.opacity(0.9), lineWidth: 1.0))
                }
            }
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(
                isSpinning
                    ? .linear(duration: 2.2).repeatForever(autoreverses: false)
                    : .easeOut(duration: 0.6),
                value: isSpinning
            )

            // Integrated compact stylus needle
            Circle()
                .fill(needleColor)
                .frame(width: 4.5, height: 4.5)
                .shadow(color: needleColor.opacity(0.7), radius: 3)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 0.6))
                .offset(x: diameter * 0.38, y: -diameter * 0.36)
        }
        .frame(width: diameter + 8, height: diameter + 4)
        .contentShape(Rectangle())
        .onTapGesture { audioEngine.togglePlayPause() }
        .ttButtonHelp(AudioPreviewLocalization.text(isPlaying ? .clickToPauseHelp : .clickToPlayHelp))
    }
}
