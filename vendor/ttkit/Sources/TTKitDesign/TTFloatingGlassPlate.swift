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

private struct GlassSurfaceStyle: Sendable {
    enum Border: Sendable {
        case gradient([Color])
        case solid(Color)
    }

    let tint: Color
    let border: Border

    static func liquidBase(for colorScheme: ColorScheme) -> GlassSurfaceStyle {
        if colorScheme == .dark {
            return GlassSurfaceStyle(
                tint: Color.black.opacity(0.12),
                border: .gradient([Color.white.opacity(0.16), Color.white.opacity(0.04)])
            )
        }
        return GlassSurfaceStyle(
            tint: Color.white.opacity(0.16),
            border: .gradient([Color.white.opacity(0.60), Color.black.opacity(0.06)])
        )
    }

    static func liquidElevated(for colorScheme: ColorScheme) -> GlassSurfaceStyle {
        if colorScheme == .dark {
            return GlassSurfaceStyle(
                tint: Color.black.opacity(0.14),
                border: .gradient([Color.white.opacity(0.24), Color.white.opacity(0.06)])
            )
        }
        return GlassSurfaceStyle(
            tint: Color.white.opacity(0.18),
            border: .gradient([Color.white.opacity(0.70), Color.black.opacity(0.08)])
        )
    }

    static func legacy(tier: TTGlassTier, colorScheme: ColorScheme) -> GlassSurfaceStyle {
        let isDark = colorScheme == .dark
        let opacity: Double
        switch (isDark, tier) {
        case (true, .base): opacity = 0.08
        case (true, .primary): opacity = 0.14
        case (true, .overlay): opacity = 0.25
        case (false, .base): opacity = 0.10
        case (false, .primary): opacity = 0.18
        case (false, .overlay): opacity = 0.35
        }
        return GlassSurfaceStyle(
            tint: (isDark ? Color.black : Color.white).opacity(opacity),
            border: .solid(isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.07))
        )
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

    internal func resolvedTier(forParentDepth parentDepth: Int) -> TTGlassTier {
        if let specified = specifiedTier {
            return specified
        }
        let nextDepth = parentDepth + 1
        switch nextDepth {
        case 1:
            return .base
        case 2:
            return .primary
        default:
            return .overlay
        }
    }

    internal func resolvedDepth(
        forParentDepth parentDepth: Int
    ) -> (rawDepth: Int, clampedDepth: Int, isViolation: Bool) {
        let depth = max(parentDepth + 1, specifiedTier?.rawValue ?? 0)
        return (rawDepth: depth, clampedDepth: min(depth, 3), isViolation: depth > 3)
    }

    private var effectiveTier: TTGlassTier {
        resolvedTier(forParentDepth: currentDepth)
    }

    private var nextDepthValue: Int {
        let resolution = resolvedDepth(forParentDepth: currentDepth)
        if resolution.isViolation {
            #if DEBUG
            print("[TTKitDesign Warning] Axiom IV Violation: Stacking depth \(resolution.rawDepth) exceeds maximum limit of 3 layers.")
            #endif
        }
        return resolution.clampedDepth
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        styledSurface(for: content, tier: effectiveTier, shape: shape)
            .clipShape(shape)
            .environment(\.ttGlassPlateDepth, nextDepthValue)
    }

    @MainActor
    @ViewBuilder
    private func styledSurface(
        for content: Content,
        tier: TTGlassTier,
        shape: RoundedRectangle
    ) -> some View {
        if #available(macOS 26.0, *) {
            if tier == .base {
                liquidGlassBaseSurface(for: content, shape: shape)
            } else {
                liquidGlassElevatedSurface(for: content, tier: tier, shape: shape)
            }
        } else {
            legacyMaterialSurface(for: content, tier: tier, shape: shape)
        }
    }

    @MainActor
    @available(macOS 26.0, *)
    private func liquidGlassBaseSurface(
        for content: Content,
        shape: RoundedRectangle
    ) -> some View {
        let style = GlassSurfaceStyle.liquidBase(for: colorScheme)
        return content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(style.tint))
            }
            .overlay {
                borderOverlay(shape: shape, border: style.border)
            }
    }

    @MainActor
    @available(macOS 26.0, *)
    private func liquidGlassElevatedSurface(
        for content: Content,
        tier: TTGlassTier,
        shape: RoundedRectangle
    ) -> some View {
        let style = GlassSurfaceStyle.liquidElevated(for: colorScheme)
        return content
            .background {
                shape.fill(style.tint)
            }
            .glassEffect(tier == .overlay ? .regular.interactive() : .regular, in: shape)
            .overlay {
                borderOverlay(shape: shape, border: style.border)
            }
    }

    @MainActor
    private func legacyMaterialSurface(
        for content: Content,
        tier: TTGlassTier,
        shape: RoundedRectangle
    ) -> some View {
        let style = GlassSurfaceStyle.legacy(tier: tier, colorScheme: colorScheme)
        return content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(style.tint))
            }
            .overlay {
                borderOverlay(shape: shape, border: style.border)
            }
    }

    @MainActor
    @ViewBuilder
    private func borderOverlay(
        shape: RoundedRectangle,
        border: GlassSurfaceStyle.Border
    ) -> some View {
        if hasBorder {
            switch border {
            case .gradient(let colors):
                shape.strokeBorder(
                    LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5
                )
            case .solid(let color):
                shape.strokeBorder(color, lineWidth: 0.5)
            }
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
