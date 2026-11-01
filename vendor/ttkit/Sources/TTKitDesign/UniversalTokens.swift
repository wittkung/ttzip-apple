// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitCore

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Unified, publication-grade 4-layer optical design token system.
/// Rigorously designed for macOS 14+, iOS 17+, watchOS 10+, and visionOS 1+.
public enum UniversalTokens: Sendable {

    // MARK: - Dynamic Color Resolution Helper

    /// Resolves a dynamic SwiftUI Color adapting automatically to Light and Dark mode appearances.
    public static func dynamicColor(
        lightRed: Double, lightGreen: Double, lightBlue: Double, lightAlpha: Double = 1.0,
        darkRed: Double, darkGreen: Double, darkBlue: Double, darkAlpha: Double = 1.0
    ) -> Color {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(srgbRed: darkRed, green: darkGreen, blue: darkBlue, alpha: darkAlpha)
            } else {
                return NSColor(srgbRed: lightRed, green: lightGreen, blue: lightBlue, alpha: lightAlpha)
            }
        }))
        #elseif canImport(UIKit)
        return Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(red: darkRed, green: darkGreen, blue: darkBlue, alpha: darkAlpha)
            } else {
                return UIColor(red: lightRed, green: lightGreen, blue: lightBlue, alpha: lightAlpha)
            }
        })
        #else
        return Color(red: darkRed, green: darkGreen, blue: darkBlue, opacity: darkAlpha)
        #endif
    }

    /// Dynamic Display P3 color provider.
    public static func dynamicDisplayP3(
        lightRed: Double, lightGreen: Double, lightBlue: Double, lightAlpha: Double = 1.0,
        darkRed: Double, darkGreen: Double, darkBlue: Double, darkAlpha: Double = 1.0
    ) -> Color {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(displayP3Red: darkRed, green: darkGreen, blue: darkBlue, alpha: darkAlpha)
            } else {
                return NSColor(displayP3Red: lightRed, green: lightGreen, blue: lightBlue, alpha: lightAlpha)
            }
        }))
        #elseif canImport(UIKit)
        return Color(uiColor: UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                return UIColor(displayP3Red: darkRed, green: darkGreen, blue: darkBlue, alpha: darkAlpha)
            } else {
                return UIColor(displayP3Red: lightRed, green: lightGreen, blue: lightBlue, alpha: lightAlpha)
            }
        })
        #else
        return Color(.displayP3, red: darkRed, green: darkGreen, blue: darkBlue, opacity: darkAlpha)
        #endif
    }

    // MARK: - Layer 1: Emitter Base (OLED True Black & Solar Pure White)

    public enum Canvas {
        /// Dark: OLED true black (#000000, 0 nits); Light: Solar pure white (#FFFFFF, 1000 nits).
        public static var emitter: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: emitterNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 1.0, lightGreen: 1.0, lightBlue: 1.0, lightAlpha: 1.0,
                darkRed: 0.0, darkGreen: 0.0, darkBlue: 0.0, darkAlpha: 1.0
            )
            #endif
        }
    }

    // MARK: - Layer 2: Deep Viscous Fluid Dynamics

    public enum Fluid {
        /// Restrained diffusion and stationary micrograin for the film-frosted substrate.
        public static let frostMaterialOpacity: Double = 0.16
        public static let frostGrainDarkOpacity: Double = 0.18
        public static let frostGrainLightOpacity: Double = 0.12

        /// Fluid body core: Luminous opal white (#FAFAFC) in Dark, Deep obsidian ink (#0A0A0C) in Light.
        public static var bodyCore: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: bodyCoreNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 10.0 / 255.0, lightGreen: 10.0 / 255.0, lightBlue: 12.0 / 255.0, lightAlpha: 1.0,
                darkRed: 250.0 / 255.0, darkGreen: 250.0 / 255.0, darkBlue: 252.0 / 255.0, darkAlpha: 1.0
            )
            #endif
        }

        /// Micro-surface dispersion sheen: 10% Glacier Blue in Dark, 6% Deep Cobalt in Light.
        public static var sheenDispersion: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: sheenDispersionNSColor)
            #else
            return UniversalTokens.dynamicDisplayP3(
                lightRed: 0.0240, lightGreen: 0.1310, lightBlue: 0.2600, lightAlpha: 0.06,
                darkRed: 0.1490, darkGreen: 0.5100, darkBlue: 0.9800, darkAlpha: 0.10
            )
            #endif
        }

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        public static let organicCoreNSColor: NSColor = NSColor(name: "fluid.organic.core", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 143.0 / 255.0, green: 168.0 / 255.0, blue: 118.0 / 255.0, alpha: 1.0)
                : NSColor(srgbRed: 120.0 / 255.0, green: 146.0 / 255.0, blue: 98.0 / 255.0, alpha: 1.0)
        })
        #endif

        /// Flagship organic fluid core: Bamboo Green (#8FA876 in Dark, #789262 in Light).
        public static var organicCore: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: organicCoreNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 120.0 / 255.0, lightGreen: 146.0 / 255.0, lightBlue: 98.0 / 255.0, lightAlpha: 1.0,
                darkRed: 143.0 / 255.0, darkGreen: 168.0 / 255.0, darkBlue: 118.0 / 255.0, darkAlpha: 1.0
            )
            #endif
        }
    }

    // MARK: - Layer 3: Nested Frosted Glass Plates

    public enum Plate {
        /// Level 1: Canvas base plate (Dark: 55% #1C1C1E, Light: 70% #FFFFFF).
        public static var surfaceL1: Color {
            UniversalTokens.dynamicColor(
                lightRed: 1.0, lightGreen: 1.0, lightBlue: 1.0, lightAlpha: 0.70,
                darkRed: 28.0 / 255.0, darkGreen: 28.0 / 255.0, darkBlue: 30.0 / 255.0, darkAlpha: 0.55
            )
        }

        /// Level 2: Sidebar & Columns plate (Dark: 72% #262629, Light: 78% #F5F5F7).
        public static var surfaceL2: Color {
            UniversalTokens.dynamicColor(
                lightRed: 245.0 / 255.0, lightGreen: 245.0 / 255.0, lightBlue: 247.0 / 255.0, lightAlpha: 0.78,
                darkRed: 38.0 / 255.0, darkGreen: 38.0 / 255.0, darkBlue: 41.0 / 255.0, darkAlpha: 0.72
            )
        }

        /// Level 3: Suspended floating sheet & Modal plate (Dark: 85% #323236, Light: 90% #EBEBF0).
        public static var surfaceL3: Color {
            UniversalTokens.dynamicColor(
                lightRed: 235.0 / 255.0, lightGreen: 235.0 / 255.0, lightBlue: 240.0 / 255.0, lightAlpha: 0.90,
                darkRed: 50.0 / 255.0, darkGreen: 50.0 / 255.0, darkBlue: 54.0 / 255.0, darkAlpha: 0.85
            )
        }
    }

    // MARK: - Layer 3 Bevel: 0.5pt Specular Hairline Borders

    public enum Border {
        /// 0.5pt specular hairline: 14% pure white in Dark, 8% pure black in Light.
        public static var specularHairline: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: specularHairlineNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 0.0, lightGreen: 0.0, lightBlue: 0.0, lightAlpha: 0.08,
                darkRed: 1.0, darkGreen: 1.0, darkBlue: 1.0, darkAlpha: 0.14
            )
            #endif
        }

        /// Fixed hairline stroke width (0.5pt).
        public static let width: CGFloat = 0.5

        /// Subtle hairline boundary alias (0.5pt specular hairline).
        public static var subtle: Color {
            specularHairline
        }

        /// 0.5pt Kintsugi Gold hairline border (Dynamic specular gold seam).
        public static var kintsugi: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: kintsugiGoldNSColor)
            #else
            return UniversalTokens.dynamicDisplayP3(
                lightRed: 197.0 / 255.0, lightGreen: 160.0 / 255.0, lightBlue: 89.0 / 255.0, lightAlpha: 0.45,
                darkRed: 229.0 / 255.0, darkGreen: 193.0 / 255.0, darkBlue: 88.0 / 255.0, darkAlpha: 0.60
            )
            #endif
        }
    }

    // MARK: - Layer 4: Singular Interactive Action Anchor

    public enum Action {
        /// Singular action anchor: Electric Azure (#0A84FF) in Dark, Cupertino Blue (#0071E3) in Light.
        public static var anchor: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: anchorNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 0.0 / 255.0, lightGreen: 113.0 / 255.0, lightBlue: 227.0 / 255.0, lightAlpha: 1.0,
                darkRed: 10.0 / 255.0, darkGreen: 132.0 / 255.0, darkBlue: 255.0 / 255.0, darkAlpha: 1.0
            )
            #endif
        }
    }

    // MARK: - Layer 4: Photonic Typography Tokens

    public enum Text {
        /// Static primary text: Pure White (#FFFFFF) in Dark, Pure Black (#000000) in Light.
        public static var primary: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: primaryNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 0.0, lightGreen: 0.0, lightBlue: 0.0, lightAlpha: 1.0,
                darkRed: 1.0, darkGreen: 1.0, darkBlue: 1.0, darkAlpha: 1.0
            )
            #endif
        }

        /// Inverted contrast text: Pure Black (#000000) in Dark, Pure White (#FFFFFF) in Light.
        public static var inverted: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: invertedNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 1.0, lightGreen: 1.0, lightBlue: 1.0, lightAlpha: 1.0,
                darkRed: 0.0, darkGreen: 0.0, darkBlue: 0.0, darkAlpha: 1.0
            )
            #endif
        }
    }

    // MARK: - Semantic Natural Mineral Spectrum (CIELAB L* = 65.0 / 75.0 ± 1.5)

    public enum Mineral {
        /// Raw Kintsugi Gold (金缮金): Visual/Asset media.
        /// Dark: L* = 76.2 (#DEB84B, 222, 184, 75); Light: L* = 65.1 (#BF9936, 191, 153, 54).
        public static var gold: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: goldNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 191.0 / 255.0, lightGreen: 153.0 / 255.0, lightBlue: 54.0 / 255.0, lightAlpha: 1.0,
                darkRed: 222.0 / 255.0, darkGreen: 184.0 / 255.0, darkBlue: 75.0 / 255.0, darkAlpha: 1.0
            )
            #endif
        }

        /// High-contrast Editorial Kintsugi Gold: Golden rule lines and title accents.
        /// Dark: L* = 78.4 (#E6C35C, 230, 195, 92); Light: Deep mineral gold #8C6D23 (140, 109, 35, WCAG 4.88:1 vs pure white).
        public static var goldEditorial: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: goldEditorialNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 140.0 / 255.0, lightGreen: 109.0 / 255.0, lightBlue: 35.0 / 255.0, lightAlpha: 1.0,
                darkRed: 230.0 / 255.0, darkGreen: 195.0 / 255.0, darkBlue: 92.0 / 255.0, darkAlpha: 1.0
            )
            #endif
        }

        /// Celadon Bamboo (竹青色): System & Documents.
        /// Dark: L* = 74.8 (#91C596, 145, 197, 150); Light: L* = 64.5 (#73A979, 115, 169, 121).
        public static var bamboo: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: bambooNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 115.0 / 255.0, lightGreen: 169.0 / 255.0, lightBlue: 121.0 / 255.0, lightAlpha: 1.0,
                darkRed: 145.0 / 255.0, darkGreen: 197.0 / 255.0, darkBlue: 150.0 / 255.0, darkAlpha: 1.0
            )
            #endif
        }

        /// Archival Amber (琥珀色): Archives & Compression Packages.
        /// Dark: L* = 75.5 (#FFA727, 255, 167, 39); Light: L* = 65.8 (#E78915, 231, 137, 21).
        public static var amber: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: amberNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 231.0 / 255.0, lightGreen: 137.0 / 255.0, lightBlue: 21.0 / 255.0, lightAlpha: 1.0,
                darkRed: 255.0 / 255.0, darkGreen: 167.0 / 255.0, darkBlue: 39.0 / 255.0, darkAlpha: 1.0
            )
            #endif
        }

        /// Cinnabar Red (朱砂红): Alerts, Destruction & Motion.
        /// Dark: L* = 74.4 (#FF9E82, 255, 158, 130); Light: L* = 64.8 (#FE715F, 254, 113, 95).
        public static var cinnabar: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: cinnabarNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 254.0 / 255.0, lightGreen: 113.0 / 255.0, lightBlue: 95.0 / 255.0, lightAlpha: 1.0,
                darkRed: 255.0 / 255.0, darkGreen: 158.0 / 255.0, darkBlue: 130.0 / 255.0, darkAlpha: 1.0
            )
            #endif
        }

        /// Acoustic Indigo & Amethyst (声学黛青 / 紫水晶): Audio & Resonant Media.
        /// Dark: L* = 75.2 (#ACB4FF, 172, 180, 255); Light: L* = 65.3 (#9495F5, 148, 149, 245).
        public static var acousticIndigo: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: amethystNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 148.0 / 255.0, lightGreen: 149.0 / 255.0, lightBlue: 245.0 / 255.0, lightAlpha: 1.0,
                darkRed: 172.0 / 255.0, darkGreen: 180.0 / 255.0, darkBlue: 255.0 / 255.0, darkAlpha: 1.0
            )
            #endif
        }

        /// Backward-compatible alias for acousticIndigo / amethyst.
        public static var amethyst: Color {
            acousticIndigo
        }

        /// Celestial Purple (苍穹紫 / 群青紫): Taroturn & Spiritual Media.
        /// Dark: L* = 61.2 (#A78BFA, 167, 139, 250); Light: L* = 34.5 (#6D28D9, 109, 40, 217).
        public static var celestialPurple: Color {
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            return Color(nsColor: celestialPurpleNSColor)
            #else
            return UniversalTokens.dynamicColor(
                lightRed: 109.0 / 255.0, lightGreen: 40.0 / 255.0, lightBlue: 217.0 / 255.0, lightAlpha: 1.0,
                darkRed: 167.0 / 255.0, darkGreen: 139.0 / 255.0, darkBlue: 250.0 / 255.0, darkAlpha: 1.0
            )
            #endif
        }

        /// Paper White (和纸白): Pristine Zen paper substrate (#FBFBF9).
        public static let paperWhite = Color(red: 251.0 / 255.0, green: 251.0 / 255.0, blue: 249.0 / 255.0)

        /// Porcelain Gray (瓷灰): Calibrated neutral surface tone (#F2F2EF).
        public static let porcelainGray = Color(red: 242.0 / 255.0, green: 242.0 / 255.0, blue: 239.0 / 255.0)

        /// Obsidian Black (曜石纯黑): Absolute deep shadow.
        public static let obsidianBlack = Color(red: 0.0, green: 0.0, blue: 0.0)

        /// Ink Charcoal (水墨炭黑): Traditional inkwash dark tone (#1C1C1E).
        public static let inkCharcoal = Color(red: 28.0 / 255.0, green: 28.0 / 255.0, blue: 30.0 / 255.0)
    }

    // MARK: - Physical Dimensions & Optical Blur Radii

    public enum Dimensions {
        /// Standard specular hairline border width (0.5pt).
        public static let hairlineWidth: CGFloat = 0.5

        /// Optical Gaussian blur radius for Layer 3 Level 1 Canvas plate (28.0pt).
        public static let lensBlurL1: CGFloat = 28.0

        /// Optical Gaussian blur radius for Layer 3 Level 2 Columns plate (36.0pt).
        public static let lensBlurL2: CGFloat = 36.0

        /// Optical Gaussian blur radius for Layer 3 Level 3 Modal sheet plate (48.0pt).
        public static let lensBlurL3: CGFloat = 48.0
    }

    // MARK: - Structural Layout Tokens

    public enum Layout {
        public static let headerBarHeight: CGFloat = 52.0
        public static let topBarOffset: CGFloat = 0.0
        public static let goldenBaselineY: CGFloat = 52.0
        public static let goldenRuleLineThickness: CGFloat = UniversalTokens.Dimensions.hairlineWidth // 0.5
        public static let sidebarWidth: CGFloat = 200.0
        public static let minContentWidth: CGFloat = 450.0
        public static let inspectorWidth: CGFloat = 280.0
    }

    // MARK: - Motion & Fluid Spring Dynamics

    /// Semantic fluid spring motion tokens matching `tokens.json` specification.
    public enum Motion: Sendable {
        /// Micro-interactions: buttons, toggles, icon feedback, key states (response: 0.28s, dampingFraction: 0.82).
        public static let microResponse: Double = 0.28
        public static let microDampingFraction: Double = 0.82
        public static var micro: Animation {
            .spring(response: microResponse, dampingFraction: microDampingFraction)
        }

        /// Layout re-arrangements: columns, tabs, sidebars, panes (response: 0.42s, dampingFraction: 0.88).
        public static let layoutResponse: Double = 0.42
        public static let layoutDampingFraction: Double = 0.88
        public static var layout: Animation {
            .spring(response: layoutResponse, dampingFraction: layoutDampingFraction)
        }

        /// Snappy popovers, tooltips, dialogs, Omnibar results (response: 0.35s, dampingFraction: 0.80).
        public static let snapResponse: Double = 0.35
        public static let snapDampingFraction: Double = 0.80
        public static var snap: Animation {
            .spring(response: snapResponse, dampingFraction: snapDampingFraction)
        }

        /// Large modal sheets and full-canvas transitions (response: 0.50s, dampingFraction: 0.84).
        public static let sheetResponse: Double = 0.50
        public static let sheetDampingFraction: Double = 0.84
        public static var sheet: Animation {
            .spring(response: sheetResponse, dampingFraction: sheetDampingFraction)
        }
    }
}

// MARK: - Semantic SwiftUI Animation Extensions

public extension Animation {
    /// Semantic spring animation for micro-interactions (response: 0.28s, damping: 0.82).
    static var ttMicro: Animation { UniversalTokens.Motion.micro }

    /// Semantic spring animation for structural layout transitions (response: 0.42s, damping: 0.88).
    static var ttLayout: Animation { UniversalTokens.Motion.layout }

    /// Semantic spring animation for snappy popovers and dialogs (response: 0.35s, damping: 0.80).
    static var ttSnap: Animation { UniversalTokens.Motion.snap }

    /// Semantic spring animation for sheets and modal canvases (response: 0.50s, damping: 0.84).
    static var ttSheet: Animation { UniversalTokens.Motion.sheet }
}

