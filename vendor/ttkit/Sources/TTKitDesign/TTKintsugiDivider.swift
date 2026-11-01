// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Canonical 0.5pt Kintsugi Gold Divider representing physical lacquer seams
/// between floating glass plates and editorial section boundaries.
/// Conforms to Design Axiom I (Optical Realism) and Axiom IV (Suspended Glass Stacking).
public struct TTKintsugiDivider: View {
    public enum Orientation: Sendable {
        case horizontal
        case vertical
    }

    private let orientation: Orientation
    private let falloff: Bool

    @Environment(\.colorScheme) private var colorScheme

    public init(
        _ orientation: Orientation = .horizontal,
        falloff: Bool = true
    ) {
        self.orientation = orientation
        self.falloff = falloff
    }

    public var body: some View {
        Group {
            if orientation == .horizontal {
                Rectangle()
                    .fill(gradient)
                    .frame(height: UniversalTokens.Dimensions.hairlineWidth)
            } else {
                Rectangle()
                    .fill(gradient)
                    .frame(width: UniversalTokens.Dimensions.hairlineWidth)
            }
        }
    }

    private var gradient: LinearGradient {
        let isDark = colorScheme == .dark
        let peakColor = isDark
            ? Color(red: 229.0 / 255.0, green: 193.0 / 255.0, blue: 88.0 / 255.0).opacity(0.48)
            : Color(red: 191.0 / 255.0, green: 153.0 / 255.0, blue: 54.0 / 255.0).opacity(0.35)
        let baseColor = isDark
            ? Color(red: 180.0 / 255.0, green: 145.0 / 255.0, blue: 60.0 / 255.0).opacity(0.20)
            : Color(red: 160.0 / 255.0, green: 125.0 / 255.0, blue: 45.0 / 255.0).opacity(0.14)

        let stops: [Gradient.Stop]
        if falloff {
            stops = [
                .init(color: baseColor.opacity(0.0), location: 0.0),
                .init(color: baseColor, location: 0.15),
                .init(color: peakColor, location: 0.50),
                .init(color: baseColor, location: 0.85),
                .init(color: baseColor.opacity(0.0), location: 1.0)
            ]
        } else {
            stops = [
                .init(color: baseColor, location: 0.0),
                .init(color: peakColor, location: 0.50),
                .init(color: baseColor, location: 1.0)
            ]
        }

        if orientation == .horizontal {
            return LinearGradient(
                stops: stops,
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            return LinearGradient(
                stops: stops,
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - ViewModifier for Kintsugi Seam Edges

public struct TTKintsugiSeamModifier: ViewModifier {
    public let edge: Edge
    public let falloff: Bool

    public init(edge: Edge, falloff: Bool = true) {
        self.edge = edge
        self.falloff = falloff
    }

    public func body(content: Content) -> some View {
        content.overlay(alignment: alignment(for: edge)) {
            TTKintsugiDivider(
                edge == .leading || edge == .trailing ? .vertical : .horizontal,
                falloff: falloff
            )
        }
    }

    private func alignment(for edge: Edge) -> Alignment {
        switch edge {
        case .top: return .top
        case .leading: return .leading
        case .bottom: return .bottom
        case .trailing: return .trailing
        }
    }
}

public extension View {
    /// Applies a 0.5pt specular Kintsugi Gold lacquer seam along the specified edge.
    func kintsugiSeam(
        edge: Edge = .trailing,
        falloff: Bool = true
    ) -> some View {
        modifier(TTKintsugiSeamModifier(edge: edge, falloff: falloff))
    }
}
