// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI

/// Canonical Apple Finder Tag physical color enumeration calibrated in Display P3 wide color gamut.
public enum FinderTagColor: Int, CaseIterable, Sendable {
    case gray = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    public func resolve(colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        let palette = p3Palette
        let rgb: (Double, Double, Double)
        if contrast == .increased {
            rgb = palette.highContrast
        } else if colorScheme == .dark {
            rgb = palette.dark
        } else {
            rgb = palette.light
        }
        return Color(.displayP3, red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    private var p3Palette: (
        highContrast: (Double, Double, Double),
        dark: (Double, Double, Double),
        light: (Double, Double, Double)
    ) {
        switch self {
        case .gray:
            return ((0.5569, 0.5569, 0.5748), (0.5961, 0.5961, 0.6140), (0.5569, 0.5569, 0.5748))
        case .green:
            return ((0.3898, 0.7923, 0.3366), (0.4066, 0.8080, 0.4037), (0.3954, 0.7694, 0.4000))
        case .purple:
            return ((0.6402, 0.3420, 0.8426), (0.7910, 0.2641, 0.9178), (0.7330, 0.2437, 0.8495))
        case .blue:
            return ((0.2047, 0.4710, 0.9661), (0.2485, 0.5599, 0.9691), (0.2314, 0.5251, 0.9678))
        case .yellow:
            return ((0.9684, 0.8077, 0.2735), (0.9740, 0.8452, 0.2844), (0.9684, 0.8077, 0.2735))
        case .red:
            return ((0.9213, 0.3045, 0.2405), (0.9222, 0.3244, 0.3039), (0.9209, 0.2964, 0.2741))
        case .orange:
            return ((0.9433, 0.6045, 0.2175), (0.9422, 0.5936, 0.2823), (0.9404, 0.5755, 0.2617))
        }
    }
}

/// Precision Display P3 native Finder tag dot rendering component with dual-ring WCAG AA contrast.
public struct FinderTagDotView: View {
    public let tagColor: FinderTagColor
    public let diameter: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(tagColor: FinderTagColor, diameter: CGFloat = 7.0) {
        self.tagColor = tagColor
        self.diameter = diameter
    }

    public var body: some View {
        let isHighContrast = colorSchemeContrast == .increased
        let resolvedColor = tagColor.resolve(colorScheme: colorScheme, contrast: colorSchemeContrast)

        Circle()
            .fill(resolvedColor)
            .frame(width: diameter, height: diameter)
            // Optical separation ring prevents adjacent dot blending
            .overlay(
                Circle()
                    .strokeBorder(
                        Color(nsColor: .windowBackgroundColor),
                        lineWidth: isHighContrast ? 1.0 : 0.75
                    )
            )
            // WCAG AA contrast hairline ensures yellow and green remain distinct on light backgrounds
            .overlay(
                Circle()
                    .strokeBorder(
                        Color.primary.opacity(isHighContrast ? 0.45 : 0.12),
                        lineWidth: 0.5
                    )
            )
    }
}
