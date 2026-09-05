// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.
// Module: TTZipUniversalTokens — Universal Design Token System

import SwiftUI
import AppKit

/// Unified, publication-grade design token system for TTZip,
/// rigorously derived from COMPANY_DESIGN_WHITEPAPER.md §6.
public enum TTZipUniversalTokens: Sendable {
    
    // MARK: - Layer 1: Emitter Base (OLED True Black & Solar Pure White)
    
    public enum Canvas {
        /// Dark: OLED true black (#000000FF), Light: Solar pure white (#FFFFFFFF).
        public static var emitter: Color {
            Color(nsColor: emitterNSColor)
        }
        
        /// AppKit dynamic provider for Layer 1 Base Emitter.
        public static var emitterNSColor: NSColor {
            NSColor(name: "canvas.emitter.base", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
                    : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            })
        }
    }
    
    // MARK: - Layer 2: Deep Viscous Fluid Dynamics
    
    public enum Fluid {
        /// Fluid body core: Luminous opal white (#FAFAFC) in Dark, Deep obsidian ink (#0A0A0C) in Light.
        public static var bodyCore: Color {
            Color(nsColor: bodyCoreNSColor)
        }
        
        /// AppKit dynamic provider for Layer 2 Fluid Core.
        public static var bodyCoreNSColor: NSColor {
            NSColor(name: "fluid.body.core", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 250.0 / 255.0, green: 250.0 / 255.0, blue: 252.0 / 255.0, alpha: 1.0)
                    : NSColor(srgbRed: 10.0 / 255.0, green: 10.0 / 255.0, blue: 12.0 / 255.0, alpha: 1.0)
            })
        }
        
        /// Micro-surface dispersion sheen: 10% Glacier Blue (#0A84FF1A) in Dark, 6% Deep Cobalt (#0022440F) in Light.
        public static var sheenDispersion: Color {
            Color(nsColor: sheenDispersionNSColor)
        }
        
        /// AppKit dynamic provider for Layer 2 Chromatic Sheen Dispersion.
        public static var sheenDispersionNSColor: NSColor {
            NSColor(name: "fluid.sheen.dispersion", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(displayP3Red: 0.1490, green: 0.5100, blue: 0.9800, alpha: 0.10)
                    : NSColor(displayP3Red: 0.0240, green: 0.1310, blue: 0.2600, alpha: 0.06)
            })
        }
        
        /// Flagship organic fluid core: Bamboo Green (#8FA876 in Dark, #789262 in Light).
        public static var organicCore: Color {
            Color(nsColor: organicCoreNSColor)
        }
        
        /// AppKit dynamic provider for Layer 2 Organic Fluid Core.
        public static var organicCoreNSColor: NSColor {
            NSColor(name: "fluid.organic.core", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(red: 143.0 / 255.0, green: 168.0 / 255.0, blue: 118.0 / 255.0, alpha: 1.0)
                    : NSColor(red: 120.0 / 255.0, green: 146.0 / 255.0, blue: 98.0 / 255.0, alpha: 1.0)
            })
        }
    }
    
    // MARK: - Layer 3: Nested Frosted Glass Plates
    
    public enum Plate {
        /// Level 1: Canvas base plate (Dark: 55% #1C1C1E, Light: 70% #FFFFFF).
        public static var surfaceL1: Color {
            Color(nsColor: surfaceL1NSColor)
        }
        
        public static var surfaceL1NSColor: NSColor {
            NSColor(name: "plate.lens.surface.l1", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 28.0 / 255.0, green: 28.0 / 255.0, blue: 30.0 / 255.0, alpha: 0.55)
                    : NSColor(srgbRed: 1.0000, green: 1.0000, blue: 1.0000, alpha: 0.70)
            })
        }
        
        /// Level 2: Sidebar & Miller columns (Dark: 72% #262629, Light: 78% #F5F5F7).
        public static var surfaceL2: Color {
            Color(nsColor: surfaceL2NSColor)
        }
        
        public static var surfaceL2NSColor: NSColor {
            NSColor(name: "plate.lens.surface.l2", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 38.0 / 255.0, green: 38.0 / 255.0, blue: 41.0 / 255.0, alpha: 0.72)
                    : NSColor(srgbRed: 245.0 / 255.0, green: 245.0 / 255.0, blue: 247.0 / 255.0, alpha: 0.78)
            })
        }
        
        /// Level 3: Suspended Omnibar & Modal sheet (Dark: 85% #323236, Light: 90% #EBEBF0).
        public static var surfaceL3: Color {
            Color(nsColor: surfaceL3NSColor)
        }
        
        public static var surfaceL3NSColor: NSColor {
            NSColor(name: "plate.lens.surface.l3", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 50.0 / 255.0, green: 50.0 / 255.0, blue: 54.0 / 255.0, alpha: 0.85)
                    : NSColor(srgbRed: 235.0 / 255.0, green: 235.0 / 255.0, blue: 240.0 / 255.0, alpha: 0.90)
            })
        }
    }
    
    // MARK: - Layer 3 Bevel: 0.5pt Specular Hairline Borders
    
    public enum Border {
        /// 0.5pt specular hairline: 14% pure white in Dark, 8% pure black in Light.
        public static var specularHairline: Color {
            Color(nsColor: specularHairlineNSColor)
        }
        
        /// AppKit dynamic provider for 0.5pt specular Fresnel hairline border.
        public static var specularHairlineNSColor: NSColor {
            NSColor(name: "border.specular.hairline", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.14)
                    : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.08)
            })
        }
        
        /// Fixed hairline stroke width (0.5pt).
        public static let width: CGFloat = Dimensions.hairlineWidth
    }
    
    // MARK: - Layer 4: Singular Interactive Action Anchor
    
    public enum Action {
        /// Singular action anchor: Electric Azure (#0A84FF) in Dark, Cupertino Blue (#0071E3) in Light.
        /// Strict Invariant: At most 1 active instance per viewport plate.
        public static var anchor: Color {
            Color(nsColor: anchorNSColor)
        }
        
        /// AppKit dynamic provider for singular action anchor.
        public static var anchorNSColor: NSColor {
            NSColor(name: "action.anchor.primary", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 10.0 / 255.0, green: 132.0 / 255.0, blue: 255.0 / 255.0, alpha: 1.0)
                    : NSColor(srgbRed: 0.0 / 255.0, green: 113.0 / 255.0, blue: 227.0 / 255.0, alpha: 1.0)
            })
        }
    }
    
    // MARK: - Layer 4: Photonic Typography Tokens
    
    public enum Text {
        /// Static primary text: Pure White (#FFFFFF) in Dark, Pure Black (#000000) in Light.
        public static var primary: Color {
            Color(nsColor: primaryNSColor)
        }
        
        /// AppKit dynamic provider for primary text glyphs.
        public static var primaryNSColor: NSColor {
            NSColor(name: "text.photonic.primary", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
                    : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
            })
        }
        
        /// Dialectically inverted text: Pure Black (#000000) in Dark, Pure White (#FFFFFF) in Light.
        public static var inverted: Color {
            Color(nsColor: invertedNSColor)
        }
        
        /// AppKit dynamic provider for sublated inverted text glyphs.
        public static var invertedNSColor: NSColor {
            NSColor(name: "text.photonic.inverted", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
                    : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            })
        }
    }
    
    // MARK: - Semantic Natural Mineral Spectrum (CIELAB L* = 65.0 / 75.0 ± 1.5)
    
    public enum Mineral {
        /// Raw Kintsugi Gold: Visual/Images media.
        /// Dark: L* = 76.2 (#DEB84B, 222, 184, 75); Light: L* = 65.1 (#BF9936, 191, 153, 54).
        public static var gold: Color {
            Color(nsColor: goldNSColor)
        }
        
        public static var goldNSColor: NSColor {
            NSColor(name: "mineral.gold.asset", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 222.0 / 255.0, green: 184.0 / 255.0, blue: 75.0 / 255.0, alpha: 1.0)
                    : NSColor(srgbRed: 191.0 / 255.0, green: 153.0 / 255.0, blue: 54.0 / 255.0, alpha: 1.0)
            })
        }
        
        /// Celadon Bamboo: Documents & Code.
        /// Dark: L* = 74.8 (#91C596, 145, 197, 150); Light: L* = 64.5 (#73A979, 115, 169, 121).
        public static var bamboo: Color {
            Color(nsColor: bambooNSColor)
        }
        
        public static var bambooNSColor: NSColor {
            NSColor(name: "mineral.bamboo.system", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 145.0 / 255.0, green: 197.0 / 255.0, blue: 150.0 / 255.0, alpha: 1.0)
                    : NSColor(srgbRed: 115.0 / 255.0, green: 169.0 / 255.0, blue: 121.0 / 255.0, alpha: 1.0)
            })
        }
        
        /// Archival Amber: Archives & Packages.
        /// Dark: L* = 75.5 (#FFA727, 255, 167, 39); Light: L* = 65.8 (#E78915, 231, 137, 21).
        public static var amber: Color {
            Color(nsColor: amberNSColor)
        }
        
        public static var amberNSColor: NSColor {
            NSColor(name: "mineral.amber.archive", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 255.0 / 255.0, green: 167.0 / 255.0, blue: 39.0 / 255.0, alpha: 1.0)
                    : NSColor(srgbRed: 231.0 / 255.0, green: 137.0 / 255.0, blue: 21.0 / 255.0, alpha: 1.0)
            })
        }
        
        /// Cinnabar Red: Destruction, Alerts & Video.
        /// Dark: L* = 74.4 (255, 158, 130); Light: L* = 64.8 (#FE715F, 254, 113, 95).
        public static var cinnabar: Color {
            Color(nsColor: cinnabarNSColor)
        }
        
        public static var cinnabarNSColor: NSColor {
            NSColor(name: "mineral.cinnabar.danger", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 255.0 / 255.0, green: 158.0 / 255.0, blue: 130.0 / 255.0, alpha: 1.0)
                    : NSColor(srgbRed: 254.0 / 255.0, green: 113.0 / 255.0, blue: 95.0 / 255.0, alpha: 1.0)
            })
        }
        
        /// Amethyst Cold Slate: Acoustic & Audio media.
        /// Dark: L* = 75.2 (#ACB4FF, 172, 180, 255); Light: L* = 65.3 (#9495F5, 148, 149, 245).
        public static var amethyst: Color {
            Color(nsColor: amethystNSColor)
        }
        
        public static var amethystNSColor: NSColor {
            NSColor(name: "mineral.amethyst.audio", dynamicProvider: { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 172.0 / 255.0, green: 180.0 / 255.0, blue: 255.0 / 255.0, alpha: 1.0)
                    : NSColor(srgbRed: 148.0 / 255.0, green: 149.0 / 255.0, blue: 245.0 / 255.0, alpha: 1.0)
            })
        }
    }
    
    // MARK: - Physical Dimensions & Optical Radii
    
    public enum Dimensions {
        /// Standard specular hairline border width (0.5pt).
        public static let hairlineWidth: CGFloat = 0.5
        
        /// Optical Gaussian blur radius for Layer 3 Level 1 Canvas plate (28.0pt).
        public static let lensBlurL1: CGFloat = 28.0
        
        /// Optical Gaussian blur radius for Layer 3 Level 2 Columns plate (36.0pt).
        public static let lensBlurL2: CGFloat = 36.0
        
        /// Optical Gaussian blur radius for Layer 3 Level 3 Modal/Omnibar plate (48.0pt).
        public static let lensBlurL3: CGFloat = 48.0
    }
    
    // MARK: - Colorimetric Helpers (CIELAB D65)
    
    /// Computes the genuine CIE 1976 L* (perceptual lightness) from non-linear sRGB components in [0.0, 1.0].
    /// Standard CIE D65 reference white point (Yn = 1.00000).
    public static func cielabLStar(red: Double, green: Double, blue: Double) -> Double {
        let linearize = { (c: Double) -> Double in
            if c <= 0.04045 {
                return c / 12.92
            } else {
                return pow((c + 0.055) / 1.055, 2.4)
            }
        }
        
        let rLin = linearize(max(0.0, min(1.0, red)))
        let gLin = linearize(max(0.0, min(1.0, green)))
        let bLin = linearize(max(0.0, min(1.0, blue)))
        
        // Rec. 709 / sRGB D65 luminance coefficients
        let y = 0.2126729 * rLin + 0.7151522 * gLin + 0.0721750 * bLin
        
        let epsilon = pow(24.0 / 116.0, 3.0) // ~0.008856
        let fy: Double
        if y > epsilon {
            fy = cbrt(y)
        } else {
            fy = (841.0 / 108.0) * y + (16.0 / 116.0)
        }
        
        return 116.0 * fy - 16.0
    }
}
