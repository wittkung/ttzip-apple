// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Structural stacking hierarchy for floating frosted glass plates.
/// Enforces Axiom IV: Max 3 Stacking Layers.
public enum TTGlassTier: Int, Comparable, Sendable {
    /// Layer 1: Ambient base plate directly above the fluid canvas.
    case base = 1
    /// Layer 2: Primary functional floating plate (e.g. sidebar, main view canvas).
    case primary = 2
    /// Layer 3: Overlay floating plate (e.g. modal sheets, popovers, contextual inspectors).
    case overlay = 3

    public static func < (lhs: TTGlassTier, rhs: TTGlassTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Resolves background tint and opacity for the given tier.
    @MainActor
    public var backgroundPlate: some View {
        switch self {
        case .base:
            return UniversalTokens.Plate.surfaceL1
        case .primary:
            return UniversalTokens.Plate.surfaceL2
        case .overlay:
            return UniversalTokens.Plate.surfaceL3
        }
    }
}

// MARK: - Environment Depth Tracking

private struct TTGlassPlateDepthKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

public extension EnvironmentValues {
    /// Current stacking depth of nested floating glass plates.
    var ttGlassPlateDepth: Int {
        get { self[TTGlassPlateDepthKey.self] }
        set { self[TTGlassPlateDepthKey.self] = newValue }
    }
}

// MARK: - Floating Glass Plate ViewModifier

public struct TTFloatingGlassPlateModifier: ViewModifier {
    @Environment(\.ttGlassPlateDepth) private var currentDepth
    @Environment(\.colorScheme) private var colorScheme

    public let specifiedTier: TTGlassTier?
    public let cornerRadius: CGFloat
    public let hasBorder: Bool

    public init(
        tier: TTGlassTier? = nil,
        cornerRadius: CGFloat = 16,
        hasBorder: Bool = true
    ) {
        self.specifiedTier = tier
        self.cornerRadius = cornerRadius
        self.hasBorder = hasBorder
    }

    private var effectiveTier: TTGlassTier {
        if let specified = specifiedTier {
            return specified
        }
        let nextDepth = currentDepth + 1
        switch nextDepth {
        case 1:
            return .base
        case 2:
            return .primary
        default:
            return .overlay
        }
    }

    private var nextDepthValue: Int {
        let depth = (specifiedTier?.rawValue ?? currentDepth) + 1
        if depth > 3 {
            #if DEBUG
            print("[TTKitDesign Warning] Axiom IV Violation: Stacking depth \(depth) exceeds maximum limit of 3 layers.")
            #endif
        }
        return min(depth, 3)
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            if effectiveTier == .base {
                // Tier 1 (Base Structural Canvas): Calm, non-distracting ultra-thin lens base
                content
                    .background {
                        shape
                            .fill(.ultraThinMaterial)
                            .overlay(
                                shape
                                    .fill(
                                        colorScheme == .dark
                                            ? Color.black.opacity(0.12)
                                            : Color.white.opacity(0.16)
                                    )
                            )
                    }
                    .overlay {
                        if hasBorder {
                            shape
                                .strokeBorder(
                                    LinearGradient(
                                        colors: colorScheme == .dark
                                            ? [Color.white.opacity(0.16), Color.white.opacity(0.04)]
                                            : [Color.white.opacity(0.60), Color.black.opacity(0.06)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        }
                    }
                    .clipShape(shape)
                    .environment(\.ttGlassPlateDepth, nextDepthValue)
            } else {
                // Tier 2 (Primary Floating Plates) & Tier 3 (Overlay Modal Sheets): Active Apple Liquid Glass
                content
                    .background {
                        shape
                            .fill(
                                colorScheme == .dark
                                    ? Color.black.opacity(0.14)
                                    : Color.white.opacity(0.18)
                            )
                    }
                    .glassEffect(effectiveTier == .overlay ? .regular.interactive() : .regular, in: shape)
                    .overlay {
                        if hasBorder {
                            shape
                                .strokeBorder(
                                    LinearGradient(
                                        colors: colorScheme == .dark
                                            ? [Color.white.opacity(0.24), Color.white.opacity(0.06)]
                                            : [Color.white.opacity(0.70), Color.black.opacity(0.08)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.5
                                )
                        }
                    }
                    .clipShape(shape)
                    .environment(\.ttGlassPlateDepth, nextDepthValue)
            }
        } else {
            content
                .background {
                    // Fallback for macOS 14 / 15: UltraThinMaterial + Translucent Tint
                    shape
                        .fill(.ultraThinMaterial)
                        .overlay(
                            shape
                                .fill(
                                    colorScheme == .dark
                                        ? Color.black.opacity(effectiveTier == .overlay ? 0.25 : (effectiveTier == .primary ? 0.14 : 0.08))
                                        : Color.white.opacity(effectiveTier == .overlay ? 0.35 : (effectiveTier == .primary ? 0.18 : 0.10))
                                )
                        )
                }
                .overlay {
                    if hasBorder {
                        shape
                            .strokeBorder(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.14)
                                    : Color.black.opacity(0.07),
                                lineWidth: 0.5
                            )
                    }
                }
                .clipShape(shape)
                .environment(\.ttGlassPlateDepth, nextDepthValue)
        }
    }
}

// MARK: - View Extension Ergonomics

public extension View {
    /// Wraps the view in a floating frosted glass plate adhering to the 3-Layer Stacking Gate.
    ///
    /// - Parameters:
    ///   - tier: Explicit glass tier (defaults to automatic hierarchical increment).
    ///   - cornerRadius: Apple continuous corner radius (defaults to 16pt).
    ///   - hasBorder: Whether to render the 0.5pt specular Fresnel hairline border.
    func ttFloatingGlassPlate(
        tier: TTGlassTier? = nil,
        cornerRadius: CGFloat = 16,
        hasBorder: Bool = true
    ) -> some View {
        modifier(TTFloatingGlassPlateModifier(tier: tier, cornerRadius: cornerRadius, hasBorder: hasBorder))
    }

    /// Encloses child floating glass plates within a unified GlassEffectContainer
    /// on macOS 26.0+ to enable hardware-accelerated single-pass rendering and fluid morphing.
    @ViewBuilder
    func ttGlassEffectContainer(spacing: CGFloat = 14) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                self
            }
        } else {
            self
        }
    }

    /// Convenience wrapper for primary structural plates (sidebars, work surfaces).
    func ttPrimaryGlassPlate(cornerRadius: CGFloat = 16) -> some View {
        ttFloatingGlassPlate(tier: .primary, cornerRadius: cornerRadius, hasBorder: true)
    }

    /// Convenience wrapper for overlay sheets and modal inspectors.
    func ttOverlayGlassPlate(cornerRadius: CGFloat = 18) -> some View {
        ttFloatingGlassPlate(tier: .overlay, cornerRadius: cornerRadius, hasBorder: true)
    }

    /// Applies native Liquid Glass button style on macOS 26.0+, falling back to standard bordered button style.
    @ViewBuilder
    func applyGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Applies native Liquid Glass prominent button style on macOS 26.0+, falling back to standard prominent button style.
    @ViewBuilder
    func applyGlassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
