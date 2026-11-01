// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreGraphics
import SwiftUI
import TTKitDesign

/// A stationary optical finish, composed below all foreground content.
struct FluidFrostedSurfaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(UniversalTokens.Fluid.frostMaterialOpacity)

            if let grain = Self.grain {
                Image(decorative: grain, scale: max(displayScale, 1))
                    .resizable(resizingMode: .tile)
                    .interpolation(.none)
                    .blendMode(.softLight)
                    .opacity(colorScheme == .dark
                        ? UniversalTokens.Fluid.frostGrainDarkOpacity
                        : UniversalTokens.Fluid.frostGrainLightOpacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One immutable tile; its fixed seed prevents animated noise and redraw work.
    private static let grain: CGImage? = {
        let side = 256
        var state: UInt32 = 0x54544B49
        let pixels = (0..<(side * side)).map { _ -> UInt8 in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(truncatingIfNeeded: state)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side, height: side,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
    }()
}
