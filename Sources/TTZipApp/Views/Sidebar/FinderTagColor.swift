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
        let isHighContrast = contrast == .increased
        let isDark = colorScheme == .dark

        switch self {
        case .gray:
            if isHighContrast {
                return Color(.displayP3, red: 0.5569, green: 0.5569, blue: 0.5748)
            }
            return isDark
                ? Color(.displayP3, red: 0.5961, green: 0.5961, blue: 0.6140)
                : Color(.displayP3, red: 0.5569, green: 0.5569, blue: 0.5748)

        case .green:
            if isHighContrast {
                return Color(.displayP3, red: 0.3898, green: 0.7923, blue: 0.3366)
            }
            return isDark
                ? Color(.displayP3, red: 0.4066, green: 0.8080, blue: 0.4037)
                : Color(.displayP3, red: 0.3954, green: 0.7694, blue: 0.4000)

        case .purple:
            if isHighContrast {
                return Color(.displayP3, red: 0.6402, green: 0.3420, blue: 0.8426)
            }
            return isDark
                ? Color(.displayP3, red: 0.7910, green: 0.2641, blue: 0.9178)
                : Color(.displayP3, red: 0.7330, green: 0.2437, blue: 0.8495)

        case .blue:
            if isHighContrast {
                return Color(.displayP3, red: 0.2047, green: 0.4710, blue: 0.9661)
            }
            return isDark
                ? Color(.displayP3, red: 0.2485, green: 0.5599, blue: 0.9691)
                : Color(.displayP3, red: 0.2314, green: 0.5251, blue: 0.9678)

        case .yellow:
            if isHighContrast {
                return Color(.displayP3, red: 0.9684, green: 0.8077, blue: 0.2735)
            }
            return isDark
                ? Color(.displayP3, red: 0.9740, green: 0.8452, blue: 0.2844)
                : Color(.displayP3, red: 0.9684, green: 0.8077, blue: 0.2735)

        case .red:
            if isHighContrast {
                return Color(.displayP3, red: 0.9213, green: 0.3045, blue: 0.2405)
            }
            return isDark
                ? Color(.displayP3, red: 0.9222, green: 0.3244, blue: 0.3039)
                : Color(.displayP3, red: 0.9209, green: 0.2964, blue: 0.2741)

        case .orange:
            if isHighContrast {
                return Color(.displayP3, red: 0.9433, green: 0.6045, blue: 0.2175)
            }
            return isDark
                ? Color(.displayP3, red: 0.9422, green: 0.5936, blue: 0.2823)
                : Color(.displayP3, red: 0.9404, green: 0.5755, blue: 0.2617)
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
