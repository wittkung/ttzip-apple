// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitDesign
import TTZipCore
import TTZipUI

// MARK: - Health State Semantic Colors

public extension SidebarItemHealthState {
    /// Semantic indicator dot / badge color conforming strictly to TTKitTheme mineral palette.
    var semanticColor: Color {
        switch self {
        case .accessible:
            return TTKitTheme.bambooGreen // 翡翠绿 (Bamboo Green)
        case .warning:
            return TTKitTheme.kintsugiGold // 赤金 (Kintsugi Gold)
        case .unmountedVolume:
            return TTKitTheme.porcelainGray // 冷灰 (Porcelain Gray)
        case .mounting:
            return TTKitTheme.archivalAmber // 挂载中 / 琥珀 (Archival Amber)
        case .missing:
            return TTKitTheme.cinnabarRed // 朱砂红 (Cinnabar Red)
        case .datalessCloud:
            return TTKitTheme.acousticIndigo // 声学黛青 (Acoustic Indigo)
        }
    }
}

// MARK: - Health Indicator Dot & Micro-Badge

/// Dedicated micro-badge and status indicator for sidebar health states.
/// Features TTKitTheme mineral semantic colors, gentle breathing glow, and a 0.5pt specular hairline border.
public struct SidebarHealthIndicatorDot: View {
    public let state: SidebarItemHealthState
    public var diameter: CGFloat = 6.5

    @State private var isBreathing: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: SidebarItemHealthState, diameter: CGFloat = 6.5) {
        self.state = state
        self.diameter = diameter
    }

    public var body: some View {
        ZStack {
            if shouldBreathe && !reduceMotion {
                Circle()
                    .fill(semanticColor.opacity(isBreathing ? 0.38 : 0.12))
                    .frame(width: diameter + 4, height: diameter + 4)
            }

            Circle()
                .fill(semanticColor.opacity(shouldBreathe && !reduceMotion ? (isBreathing ? 0.98 : 0.72) : 0.90))
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle()
                        .strokeBorder(
                            UniversalTokens.Border.specularHairline,
                            lineWidth: UniversalTokens.Dimensions.hairlineWidth
                        )
                )
        }
        .onAppear {
            if shouldBreathe && !reduceMotion {
                withAnimation(
                    .easeInOut(duration: 1.8).repeatForever(autoreverses: true)
                ) {
                    isBreathing = true
                }
            }
        }
    }

    private var semanticColor: Color {
        state.semanticColor
    }

    private var shouldBreathe: Bool {
        switch state {
        case .mounting, .warning, .missing, .datalessCloud(isDownloading: true):
            return true
        case .accessible, .unmountedVolume, .datalessCloud(isDownloading: false):
            return false
        }
    }
}
