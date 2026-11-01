// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Injectable brand theme protocol allowing client applications (e.g. TTZip, iTTime)
/// to define and inject customized optical brand tokens across the view hierarchy.
public protocol TTUIBrandTheme: Sendable {
    /// Human-readable brand identity name.
    var brandName: String { get }

    /// Primary brand accent color.
    var primaryAccent: Color { get }

    /// Secondary brand accent color.
    var secondaryAccent: Color { get }

    /// Signature natural mineral color.
    var signatureMineral: Color { get }

    // MARK: - Layer 1: Emitter Base

    /// Resolves Layer 1 Emitter background color for the given color scheme.
    func canvasEmitter(for colorScheme: ColorScheme) -> Color

    // MARK: - Layer 2: Viscous Fluid

    /// Resolves Layer 2 Fluid body core color.
    func fluidBodyCore(for colorScheme: ColorScheme) -> Color

    /// Resolves Layer 2 Micro-surface sheen dispersion color.
    func fluidSheenDispersion(for colorScheme: ColorScheme) -> Color

    /// Resolves Layer 2 Organic fluid core accent.
    func fluidOrganicCore(for colorScheme: ColorScheme) -> Color

    // MARK: - Layer 3: Plates & Borders

    /// Resolves Layer 3 frosted surface plate color for hierarchical depth level (1, 2, or 3).
    func plateSurface(level: Int, for colorScheme: ColorScheme) -> Color

    /// Resolves Layer 3 0.5pt specular Fresnel hairline border color.
    func specularHairlineBorder(for colorScheme: ColorScheme) -> Color

    // MARK: - Layer 4: Action & Typography

    /// Resolves singular interactive action anchor color.
    func actionAnchor(for colorScheme: ColorScheme) -> Color

    /// Resolves primary photonic typography color.
    func textPhotonicPrimary(for colorScheme: ColorScheme) -> Color

    /// Resolves inverted contrast typography color.
    func textPhotonicInverted(for colorScheme: ColorScheme) -> Color
}

// MARK: - Default Protocol Implementation

public extension TTUIBrandTheme {
    func canvasEmitter(for colorScheme: ColorScheme) -> Color {
        UniversalTokens.Canvas.emitter
    }

    func fluidBodyCore(for colorScheme: ColorScheme) -> Color {
        UniversalTokens.Fluid.bodyCore
    }

    func fluidSheenDispersion(for colorScheme: ColorScheme) -> Color {
        UniversalTokens.Fluid.sheenDispersion
    }

    func fluidOrganicCore(for colorScheme: ColorScheme) -> Color {
        signatureMineral
    }

    func plateSurface(level: Int, for colorScheme: ColorScheme) -> Color {
        switch level {
        case 1:
            return UniversalTokens.Plate.surfaceL1
        case 2:
            return UniversalTokens.Plate.surfaceL2
        default:
            return UniversalTokens.Plate.surfaceL3
        }
    }

    func specularHairlineBorder(for colorScheme: ColorScheme) -> Color {
        UniversalTokens.Border.specularHairline
    }

    func actionAnchor(for colorScheme: ColorScheme) -> Color {
        primaryAccent
    }

    func textPhotonicPrimary(for colorScheme: ColorScheme) -> Color {
        UniversalTokens.Text.primary
    }

    func textPhotonicInverted(for colorScheme: ColorScheme) -> Color {
        UniversalTokens.Text.inverted
    }
}

// MARK: - Default Brand Theme Implementation

/// Default publication-grade brand theme using signature Kintsugi Gold & Bamboo Green.
public struct DefaultTTUIBrandTheme: TTUIBrandTheme {
    public let brandName: String = "TTKit Standard"
    public let primaryAccent: Color = UniversalTokens.Mineral.bamboo
    public let secondaryAccent: Color = UniversalTokens.Mineral.gold
    public let signatureMineral: Color = UniversalTokens.Mineral.bamboo

    public init() {}
}

// MARK: - SwiftUI Environment Injection

private struct TTUIBrandThemeKey: EnvironmentKey {
    static let defaultValue: any TTUIBrandTheme = DefaultTTUIBrandTheme()
}

public extension EnvironmentValues {
    /// Injected brand theme conforming to `TTUIBrandTheme`.
    var ttuiBrandTheme: any TTUIBrandTheme {
        get { self[TTUIBrandThemeKey.self] }
        set { self[TTUIBrandThemeKey.self] = newValue }
    }
}

public extension View {
    /// Injects a custom brand theme conforming to `TTUIBrandTheme` into this view subtree.
    func ttuiBrandTheme(_ theme: any TTUIBrandTheme) -> some View {
        environment(\.ttuiBrandTheme, theme)
    }
}
