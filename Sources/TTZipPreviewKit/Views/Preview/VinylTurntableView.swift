// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// Audiophile Vinyl Turntable component with animated tone arm, groove reflections, and album art spindle.
///
/// Automatically scales across compact and expanded viewports, animating tonearm drop/lift
/// and vinyl record rotational inertia in strict synchronization with audio engine playback.
public struct VinylTurntableView: View {
    public let diameter: CGFloat
    public let isPlaying: Bool
    public let rotationAngle: Double
    public let albumArt: NSImage?
    public let onTogglePlayPause: () -> Void

    @State private var isHovering = false

    public init(
        diameter: CGFloat,
        isPlaying: Bool,
        rotationAngle: Double,
        albumArt: NSImage?,
        onTogglePlayPause: @escaping () -> Void
    ) {
        self.diameter = max(120, diameter)
        self.isPlaying = isPlaying
        self.rotationAngle = rotationAngle
        self.albumArt = albumArt
        self.onTogglePlayPause = onTogglePlayPause
    }

    private var scaleRatio: CGFloat {
        diameter / 220.0
    }

    public var body: some View {
        ZStack {
            // 1. Ambient Dynamic Glow Halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            isPlaying ? TTZipTheme.bambooGreen.opacity(0.35) : TTZipTheme.kintsugiGold.opacity(0.16),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: diameter * 0.15,
                        endRadius: diameter * 0.65
                    )
                )
                .frame(width: diameter * 1.3, height: diameter * 1.3)
                .blur(radius: isPlaying ? 16 : 8)
                .allowsHitTesting(false)

            // 2. Turntable Deck Plinth (Brushed Obsidian Glass)
            RoundedRectangle(cornerRadius: 18 * scaleRatio, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.10, blue: 0.12),
                            Color(red: 0.05, green: 0.06, blue: 0.07)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: diameter + 42 * scaleRatio, height: diameter + 20 * scaleRatio)
                .overlay(
                    RoundedRectangle(cornerRadius: 18 * scaleRatio, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.14),
                                    TTZipTheme.kintsugiGold.opacity(0.25),
                                    Color.white.opacity(0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.0
                        )
                )
                .shadow(color: Color.black.opacity(0.55), radius: 14 * scaleRatio, x: 0, y: 6 * scaleRatio)

            // 3. Metallic Platter Rim
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.28, green: 0.30, blue: 0.32),
                            Color(red: 0.12, green: 0.13, blue: 0.15),
                            Color(red: 0.24, green: 0.26, blue: 0.28)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: diameter + 4 * scaleRatio, height: diameter + 4 * scaleRatio)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                )

            // 4. Rotating Vinyl Record Platter
            vinylPlatterView
                .rotationEffect(.degrees(rotationAngle))
                .offset(x: -8 * scaleRatio)

            // 5. High-Precision Mechanical ToneArm
            ToneArmView(
                isPlaying: isPlaying,
                scale: scaleRatio
            )
            .offset(x: diameter * 0.44 - 8 * scaleRatio, y: -diameter * 0.38)
            .allowsHitTesting(false)
        }
        .frame(width: diameter + 46 * scaleRatio, height: diameter + 24 * scaleRatio)
        .contentShape(Rectangle())
        .onTapGesture {
            onTogglePlayPause()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovering = hovering
            }
        }
        .help(isPlaying ? "Click to pause playback" : "Click to start playback")
    }

    // MARK: - Vinyl Platter Subview

    private var vinylPlatterView: some View {
        ZStack {
            // Dark grooved body
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.14, green: 0.15, blue: 0.17),
                            Color(red: 0.06, green: 0.07, blue: 0.08),
                            Color(red: 0.02, green: 0.03, blue: 0.03)
                        ],
                        center: .center,
                        startRadius: diameter * 0.2,
                        endRadius: diameter * 0.5
                    )
                )
                .frame(width: diameter, height: diameter)
                .shadow(color: Color.black.opacity(0.65), radius: 8 * scaleRatio, x: 0, y: 4 * scaleRatio)

            // Realistic Micro-Grooves (Concentric sound tracks)
            Group {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 1.0).frame(width: diameter * 0.92, height: diameter * 0.92)
                Circle().stroke(Color.white.opacity(0.06), lineWidth: 0.8).frame(width: diameter * 0.84, height: diameter * 0.84)
                Circle().stroke(Color.white.opacity(0.05), lineWidth: 0.8).frame(width: diameter * 0.76, height: diameter * 0.76)
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 0.8).frame(width: diameter * 0.68, height: diameter * 0.68)
                Circle().stroke(TTZipTheme.kintsugiGold.opacity(0.20), lineWidth: 0.8).frame(width: diameter * 0.60, height: diameter * 0.60)
                Circle().stroke(Color.white.opacity(0.05), lineWidth: 0.7).frame(width: diameter * 0.52, height: diameter * 0.52)
                Circle().stroke(Color.white.opacity(0.06), lineWidth: 0.7).frame(width: diameter * 0.44, height: diameter * 0.44)
            }

            // Dual Sheen Angular Reflection Cross
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            Color.white.opacity(0.08),
                            Color.clear,
                            Color.white.opacity(0.08),
                            Color.clear,
                            Color.white.opacity(0.08),
                            Color.clear,
                            Color.white.opacity(0.08),
                            Color.clear
                        ],
                        center: .center
                    )
                )
                .frame(width: diameter * 0.98, height: diameter * 0.98)

            // Center Spindle Label & Album Artwork
            centerLabelView
        }
    }

    // MARK: - Center Label & Spindle

    private var centerLabelView: some View {
        let labelSize = diameter * 0.34
        return ZStack {
            if let albumArt {
                Image(nsImage: albumArt)
                    .resizable()
                    .scaledToFill()
                    .frame(width: labelSize, height: labelSize)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(TTZipTheme.kintsugiGold, lineWidth: 1.5 * scaleRatio)
                    )
                    .shadow(color: Color.black.opacity(0.5), radius: 4 * scaleRatio)
            } else {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                TTZipTheme.bambooGreen,
                                TTZipTheme.kintsugiGold
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: labelSize, height: labelSize)
                    .overlay(
                        Circle()
                            .strokeBorder(TTZipTheme.kintsugiGold, lineWidth: 1.5 * scaleRatio)
                    )
                    .shadow(color: TTZipTheme.bambooGreen.opacity(0.4), radius: 6 * scaleRatio)

                Image(systemName: isPlaying ? "wave.3.forward" : "music.note")
                    .font(.system(size: max(12, 18 * scaleRatio), weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: Color.black.opacity(0.4), radius: 2)
            }

            // Center Gold Spindle Ring and Core Hole
            Circle()
                .fill(Color(red: 0.06, green: 0.07, blue: 0.08))
                .frame(width: max(8, 14 * scaleRatio), height: max(8, 14 * scaleRatio))
                .overlay(
                    Circle()
                        .strokeBorder(TTZipTheme.kintsugiGold.opacity(0.9), lineWidth: 1.2 * scaleRatio)
                )
        }
    }
}

// MARK: - Mechanical ToneArm View

/// Precision-engineered mechanical tone arm with animated stylus drop and rest cradle.
public struct ToneArmView: View {
    public let isPlaying: Bool
    public let scale: CGFloat

    public init(isPlaying: Bool, scale: CGFloat = 1.0) {
        self.isPlaying = isPlaying
        self.scale = scale
    }

    /// Stylus position angle: resting on armrest (~ -3 deg) vs playing on record groove (~ 24 deg).
    private var armAngle: Double {
        isPlaying ? 24.0 : -3.0
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // 1. Pivot Gimbal Base Plate
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.28, green: 0.30, blue: 0.32),
                            Color(red: 0.14, green: 0.15, blue: 0.17)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 22 * scale, height: 22 * scale)
                .overlay(
                    Circle().strokeBorder(TTZipTheme.kintsugiGold.opacity(0.6), lineWidth: 1.0 * scale)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 3 * scale)

            // 2. Gimbal Gold Center Screw
            Circle()
                .fill(TTZipTheme.kintsugiGold)
                .frame(width: 8 * scale, height: 8 * scale)

            // 3. Rotating Arm Assembly (Pivot anchored at top center)
            ZStack(alignment: .top) {
                // Counterweight (Extending upward behind pivot)
                RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.35, green: 0.38, blue: 0.40),
                                Color(red: 0.20, green: 0.22, blue: 0.24)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 10 * scale, height: 16 * scale)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3 * scale, style: .continuous)
                            .strokeBorder(TTZipTheme.kintsugiGold.opacity(0.4), lineWidth: 0.6)
                    )
                    .offset(y: -14 * scale)

                // Arm Rod (Metallic Chrome/Silver shaft)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.85, green: 0.88, blue: 0.90),
                                Color(red: 0.55, green: 0.58, blue: 0.62)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 2.8 * scale, height: 85 * scale)
                    .offset(y: 4 * scale)

                // Cartridge & Headshell (Angled stylus head)
                ZStack {
                    RoundedRectangle(cornerRadius: 2 * scale, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.15, green: 0.17, blue: 0.19),
                                    Color(red: 0.08, green: 0.09, blue: 0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 7 * scale, height: 18 * scale)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2 * scale, style: .continuous)
                                .strokeBorder(TTZipTheme.kintsugiGold, lineWidth: 0.8 * scale)
                        )

                    // Tiny Stylus Needle Indicator
                    Circle()
                        .fill(TTZipTheme.bambooGreen)
                        .frame(width: 2.5 * scale, height: 2.5 * scale)
                        .offset(y: 6 * scale)
                }
                .rotationEffect(.degrees(-15))
                .offset(x: -2 * scale, y: 84 * scale)
            }
            .rotationEffect(.degrees(armAngle), anchor: .top)
            .animation(.spring(response: 0.7, dampingFraction: 0.75, blendDuration: 0.2), value: armAngle)
        }
        .frame(width: 32 * scale, height: 110 * scale, alignment: .top)
    }
}
