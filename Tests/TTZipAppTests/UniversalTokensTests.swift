// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
import TTZipUI
@testable import TTZipApp

@MainActor
final class UniversalTokensTests: XCTestCase {
    
    private var aquaAppearance: NSAppearance {
        guard let app = NSAppearance(named: .aqua) else {
            fatalError("Aqua appearance must be available")
        }
        return app
    }
    
    private var darkAquaAppearance: NSAppearance {
        guard let app = NSAppearance(named: .darkAqua) else {
            fatalError("DarkAqua appearance must be available")
        }
        return app
    }
    
    // MARK: - Helper Methods
    
    private func resolveSRGB(color: NSColor, in appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }
    
    // MARK: - 1. Layer 1: Base Emitter Invariants
    
    func test_oled_base_emitter_dark_and_light_values() {
        let emitterNSColor = TTZipUniversalTokens.Canvas.emitterNSColor
        
        let darkColor = resolveSRGB(color: emitterNSColor, in: darkAquaAppearance)
        XCTAssertEqual(darkColor.redComponent, 0.0, accuracy: 0.001, "Dark mode emitter must be OLED true black R=0")
        XCTAssertEqual(darkColor.greenComponent, 0.0, accuracy: 0.001, "Dark mode emitter must be OLED true black G=0")
        XCTAssertEqual(darkColor.blueComponent, 0.0, accuracy: 0.001, "Dark mode emitter must be OLED true black B=0")
        XCTAssertEqual(darkColor.alphaComponent, 1.0, accuracy: 0.001, "Dark mode emitter must be 100% opaque")
        
        let lightColor = resolveSRGB(color: emitterNSColor, in: aquaAppearance)
        XCTAssertEqual(lightColor.redComponent, 1.0, accuracy: 0.001, "Light mode emitter must be Solar pure white R=1")
        XCTAssertEqual(lightColor.greenComponent, 1.0, accuracy: 0.001, "Light mode emitter must be Solar pure white G=1")
        XCTAssertEqual(lightColor.blueComponent, 1.0, accuracy: 0.001, "Light mode emitter must be Solar pure white B=1")
        XCTAssertEqual(lightColor.alphaComponent, 1.0, accuracy: 0.001, "Light mode emitter must be 100% opaque")
        
        // Verify TTZipTheme alias
        XCTAssertEqual(Color(nsColor: emitterNSColor), TTZipTheme.canvasEmitter)
    }
    
    // MARK: - 2. Layer 2: Fluid Dynamics Invariants
    
    func test_fluid_core_and_sheen_dispersion_tokens() {
        let bodyCoreNS = TTZipUniversalTokens.Fluid.bodyCoreNSColor
        let darkBody = resolveSRGB(color: bodyCoreNS, in: darkAquaAppearance)
        let lightBody = resolveSRGB(color: bodyCoreNS, in: aquaAppearance)
        
        // Opal White in Dark (#FAFAFC)
        XCTAssertEqual(darkBody.redComponent, 250.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(darkBody.greenComponent, 250.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(darkBody.blueComponent, 252.0 / 255.0, accuracy: 0.01)
        
        // Obsidian Ink in Light (#0A0A0C)
        XCTAssertEqual(lightBody.redComponent, 10.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(lightBody.greenComponent, 10.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(lightBody.blueComponent, 12.0 / 255.0, accuracy: 0.01)
        
        let sheenNS = TTZipUniversalTokens.Fluid.sheenDispersionNSColor
        let darkSheen = resolveSRGB(color: sheenNS, in: darkAquaAppearance)
        let lightSheen = resolveSRGB(color: sheenNS, in: aquaAppearance)
        
        // 10% Glacier Blue in Dark, 6% Deep Cobalt in Light
        XCTAssertEqual(darkSheen.alphaComponent, 0.10, accuracy: 0.01, "Dark fluid sheen opacity must be 10%")
        XCTAssertEqual(lightSheen.alphaComponent, 0.06, accuracy: 0.01, "Light fluid sheen opacity must be 6%")
    }
    
    // MARK: - 3. Layer 3: Specular Hairline Border & Fresnel Physics
    
    func test_specular_hairline_border_width_and_fresnel_opacities() {
        // Line width invariant: 0.5pt fixed
        XCTAssertEqual(TTZipUniversalTokens.Border.width, 0.5, "Border width must be exactly 0.5pt")
        XCTAssertEqual(TTZipUniversalTokens.Dimensions.hairlineWidth, 0.5, "Dimensions hairlineWidth must be 0.5pt")
        XCTAssertEqual(TTZipTheme.Layout.hairlineBorderWidth, 0.5, "TTZipTheme.Layout hairlineBorderWidth must be 0.5pt")
        
        let hairlineNS = TTZipUniversalTokens.Border.specularHairlineNSColor
        let darkHairline = resolveSRGB(color: hairlineNS, in: darkAquaAppearance)
        let lightHairline = resolveSRGB(color: hairlineNS, in: aquaAppearance)
        
        // Dark: 14% pure white (#FFFFFF24)
        XCTAssertEqual(darkHairline.redComponent, 1.0, accuracy: 0.01, "Dark hairline base must be white")
        XCTAssertEqual(darkHairline.greenComponent, 1.0, accuracy: 0.01, "Dark hairline base must be white")
        XCTAssertEqual(darkHairline.blueComponent, 1.0, accuracy: 0.01, "Dark hairline base must be white")
        XCTAssertEqual(darkHairline.alphaComponent, 0.14, accuracy: 0.005, "Dark hairline alpha must be exactly 14% (0.14)")
        
        // Light: 8% pure black (#00000014)
        XCTAssertEqual(lightHairline.redComponent, 0.0, accuracy: 0.01, "Light hairline base must be black")
        XCTAssertEqual(lightHairline.greenComponent, 0.0, accuracy: 0.01, "Light hairline base must be black")
        XCTAssertEqual(lightHairline.blueComponent, 0.0, accuracy: 0.01, "Light hairline base must be black")
        XCTAssertEqual(lightHairline.alphaComponent, 0.08, accuracy: 0.005, "Light hairline alpha must be exactly 8% (0.08)")
        
        // Verify TTZipTheme redirection
        XCTAssertEqual(Color(nsColor: hairlineNS), TTZipTheme.hairlineBorder)
        XCTAssertEqual(Color(nsColor: hairlineNS), TTZipTheme.specularHairline)
    }
    
    // MARK: - 4. Layer 4: Singular Action Anchor Invariants
    
    func test_action_anchor_colors_in_dark_and_light_mode() {
        let anchorNS = TTZipUniversalTokens.Action.anchorNSColor
        let darkAnchor = resolveSRGB(color: anchorNS, in: darkAquaAppearance)
        let lightAnchor = resolveSRGB(color: anchorNS, in: aquaAppearance)
        
        // Dark: Electric Azure (#0A84FF = 10, 132, 255)
        XCTAssertEqual(darkAnchor.redComponent, 10.0 / 255.0, accuracy: 0.01, "Electric Azure Red channel")
        XCTAssertEqual(darkAnchor.greenComponent, 132.0 / 255.0, accuracy: 0.01, "Electric Azure Green channel")
        XCTAssertEqual(darkAnchor.blueComponent, 255.0 / 255.0, accuracy: 0.01, "Electric Azure Blue channel")
        XCTAssertEqual(darkAnchor.alphaComponent, 1.0, accuracy: 0.001)
        
        // Light: Cupertino Blue (#0071E3 = 0, 113, 227)
        XCTAssertEqual(lightAnchor.redComponent, 0.0 / 255.0, accuracy: 0.01, "Cupertino Blue Red channel")
        XCTAssertEqual(lightAnchor.greenComponent, 113.0 / 255.0, accuracy: 0.01, "Cupertino Blue Green channel")
        XCTAssertEqual(lightAnchor.blueComponent, 227.0 / 255.0, accuracy: 0.01, "Cupertino Blue Blue channel")
        XCTAssertEqual(lightAnchor.alphaComponent, 1.0, accuracy: 0.001)
        
        // Verify TTZipTheme alias
        XCTAssertEqual(Color(nsColor: anchorNS), TTZipTheme.actionAnchor)
    }
    
    // MARK: - 5. Layer 4: Photonic Typography Invariants
    
    func test_photonic_text_primary_and_inverted_tokens() {
        let primaryNS = TTZipUniversalTokens.Text.primaryNSColor
        let invertedNS = TTZipUniversalTokens.Text.invertedNSColor
        
        let darkPrimary = resolveSRGB(color: primaryNS, in: darkAquaAppearance)
        let lightPrimary = resolveSRGB(color: primaryNS, in: aquaAppearance)
        let darkInverted = resolveSRGB(color: invertedNS, in: darkAquaAppearance)
        let lightInverted = resolveSRGB(color: invertedNS, in: aquaAppearance)
        
        // Primary text: Pure white in dark, pure black in light
        XCTAssertEqual(darkPrimary.redComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(darkPrimary.greenComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(darkPrimary.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(lightPrimary.redComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(lightPrimary.greenComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(lightPrimary.blueComponent, 0.0, accuracy: 0.001)
        
        // Inverted text: Pure black in dark, pure white in light
        XCTAssertEqual(darkInverted.redComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(darkInverted.greenComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(darkInverted.blueComponent, 0.0, accuracy: 0.001)
        XCTAssertEqual(lightInverted.redComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(lightInverted.greenComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(lightInverted.blueComponent, 1.0, accuracy: 0.001)
    }
    
    // MARK: - 6. CIELAB Equal-Perceptual-Luminance Invariants (L* = 65.0 / 75.0 ± 1.5)
    
    func test_cielab_lstar_equal_luminance_assertions_for_all_five_minerals() {
        let minerals: [(name: String, nsColor: NSColor)] = [
            ("gold", TTZipUniversalTokens.Mineral.goldNSColor),
            ("bamboo", TTZipUniversalTokens.Mineral.bambooNSColor),
            ("amber", TTZipUniversalTokens.Mineral.amberNSColor),
            ("cinnabar", TTZipUniversalTokens.Mineral.cinnabarNSColor),
            ("amethyst", TTZipUniversalTokens.Mineral.amethystNSColor)
        ]
        
        // A. Dark Appearance Calibration: Target L* = 75.0 ± 1.5 (Range [73.5, 76.5])
        var darkLValues: [Double] = []
        for mineral in minerals {
            let srgb = resolveSRGB(color: mineral.nsColor, in: darkAquaAppearance)
            let lStar = TTZipUniversalTokens.cielabLStar(
                red: Double(srgb.redComponent),
                green: Double(srgb.greenComponent),
                blue: Double(srgb.blueComponent)
            )
            darkLValues.append(lStar)
            
            XCTAssertGreaterThanOrEqual(
                lStar, 73.5,
                "Mineral \(mineral.name) in Dark appearance must satisfy L* >= 73.5 (actual: \(String(format: "%.2f", lStar)))"
            )
            XCTAssertLessThanOrEqual(
                lStar, 76.5,
                "Mineral \(mineral.name) in Dark appearance must satisfy L* <= 76.5 (actual: \(String(format: "%.2f", lStar)))"
            )
        }
        
        // Assert equal-luminance planar calmness: spread across all 5 minerals <= 3.0
        let darkMin = darkLValues.min() ?? 0.0
        let darkMax = darkLValues.max() ?? 0.0
        XCTAssertLessThanOrEqual(
            darkMax - darkMin, 3.0,
            "Dark appearance mineral luminance spread must remain <= 3.0 across the spectrum (actual spread: \(String(format: "%.2f", darkMax - darkMin)))"
        )
        
        // B. Light Appearance Calibration: Target L* = 65.0 ± 1.5 (Range [63.5, 66.5])
        var lightLValues: [Double] = []
        for mineral in minerals {
            let srgb = resolveSRGB(color: mineral.nsColor, in: aquaAppearance)
            let lStar = TTZipUniversalTokens.cielabLStar(
                red: Double(srgb.redComponent),
                green: Double(srgb.greenComponent),
                blue: Double(srgb.blueComponent)
            )
            lightLValues.append(lStar)
            
            XCTAssertGreaterThanOrEqual(
                lStar, 63.5,
                "Mineral \(mineral.name) in Light appearance must satisfy L* >= 63.5 (actual: \(String(format: "%.2f", lStar)))"
            )
            XCTAssertLessThanOrEqual(
                lStar, 66.5,
                "Mineral \(mineral.name) in Light appearance must satisfy L* <= 66.5 (actual: \(String(format: "%.2f", lStar)))"
            )
        }
        
        let lightMin = lightLValues.min() ?? 0.0
        let lightMax = lightLValues.max() ?? 0.0
        XCTAssertLessThanOrEqual(
            lightMax - lightMin, 3.0,
            "Light appearance mineral luminance spread must remain <= 3.0 across the spectrum (actual spread: \(String(format: "%.2f", lightMax - lightMin)))"
        )
    }
    
    // MARK: - 7. Backward Compatibility Preservation
    
    func test_backward_compatibility_preserves_legacy_theme_colors() {
        // Ensure legacy colors are intact and non-breaking for existing call sites
        XCTAssertNotNil(TTZipTheme.bambooGreen)
        XCTAssertNotNil(TTZipTheme.kintsugiGold)
        XCTAssertNotNil(TTZipTheme.cinnabarRed)
        XCTAssertNotNil(TTZipTheme.archiveAmber)
        XCTAssertNotNil(TTZipTheme.cardBackground)
        XCTAssertNotNil(TTZipTheme.subtleFill)
        
        // Ensure new aliases resolve correctly
        XCTAssertEqual(TTZipTheme.mineralGold, TTZipUniversalTokens.Mineral.gold)
        XCTAssertEqual(TTZipTheme.mineralBamboo, TTZipUniversalTokens.Mineral.bamboo)
        XCTAssertEqual(TTZipTheme.mineralAmber, TTZipUniversalTokens.Mineral.amber)
        XCTAssertEqual(TTZipTheme.mineralCinnabar, TTZipUniversalTokens.Mineral.cinnabar)
        XCTAssertEqual(TTZipTheme.mineralAmethyst, TTZipUniversalTokens.Mineral.amethyst)
    }
}
