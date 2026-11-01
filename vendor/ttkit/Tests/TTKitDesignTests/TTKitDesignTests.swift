// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
@testable import TTKitCore
@testable import TTKitDesign

final class TTKitDesignTests: XCTestCase {

    // MARK: - Geometric Specifications & Spatial Tokens

    func testGeometricSpecifications() {
        XCTAssertEqual(UniversalTokens.Border.width, 0.5)
        XCTAssertEqual(UniversalTokens.Dimensions.hairlineWidth, 0.5)

        // Strict monotonic progression of hierarchical Gaussian blur radii
        XCTAssertEqual(UniversalTokens.Dimensions.lensBlurL1, 28.0)
        XCTAssertEqual(UniversalTokens.Dimensions.lensBlurL2, 36.0)
        XCTAssertEqual(UniversalTokens.Dimensions.lensBlurL3, 48.0)

        XCTAssertLessThan(UniversalTokens.Dimensions.lensBlurL1, UniversalTokens.Dimensions.lensBlurL2)
        XCTAssertLessThan(UniversalTokens.Dimensions.lensBlurL2, UniversalTokens.Dimensions.lensBlurL3)

        // Structural layout tokens baseline invariants
        XCTAssertEqual(UniversalTokens.Layout.headerBarHeight, 52.0)
        XCTAssertEqual(UniversalTokens.Layout.topBarOffset, 0.0)
        XCTAssertEqual(UniversalTokens.Layout.goldenBaselineY, 52.0)
        XCTAssertEqual(UniversalTokens.Layout.goldenRuleLineThickness, 0.5)
        XCTAssertEqual(UniversalTokens.Layout.goldenRuleLineThickness, UniversalTokens.Dimensions.hairlineWidth)
        XCTAssertEqual(UniversalTokens.Layout.sidebarWidth, 200.0)
        XCTAssertEqual(UniversalTokens.Layout.minContentWidth, 450.0)
        XCTAssertEqual(UniversalTokens.Layout.inspectorWidth, 280.0)
        XCTAssertEqual(
            UniversalTokens.Layout.topBarOffset + UniversalTokens.Layout.headerBarHeight,
            UniversalTokens.Layout.goldenBaselineY,
            "Golden baseline Y must strictly equal topBarOffset + headerBarHeight (0 + 52 = 52)"
        )
    }

    // MARK: - Mineral Spectrum CIELAB Color Space Calibration

    func testMineralSpectrumPerceptualLightnessCalibration() {
        // Specifications defined in UniversalTokens:
        // Dark Mode Target L* = 75.0 ± 2.0
        // Light Mode Target L* = 65.0 ± 2.0

        struct MineralSpec {
            let name: String
            let darkRGB: (Double, Double, Double)
            let lightRGB: (Double, Double, Double)
        }

        let minerals: [MineralSpec] = [
            MineralSpec(name: "Kintsugi Gold",
                        darkRGB: (222.0 / 255.0, 184.0 / 255.0, 75.0 / 255.0),
                        lightRGB: (191.0 / 255.0, 153.0 / 255.0, 54.0 / 255.0)),
            MineralSpec(name: "Celadon Bamboo",
                        darkRGB: (145.0 / 255.0, 197.0 / 255.0, 150.0 / 255.0),
                        lightRGB: (115.0 / 255.0, 169.0 / 255.0, 121.0 / 255.0)),
            MineralSpec(name: "Archival Amber",
                        darkRGB: (255.0 / 255.0, 167.0 / 255.0, 39.0 / 255.0),
                        lightRGB: (231.0 / 255.0, 137.0 / 255.0, 21.0 / 255.0)),
            MineralSpec(name: "Cinnabar Red",
                        darkRGB: (255.0 / 255.0, 158.0 / 255.0, 130.0 / 255.0),
                        lightRGB: (254.0 / 255.0, 113.0 / 255.0, 95.0 / 255.0)),
            MineralSpec(name: "Acoustic Indigo",
                        darkRGB: (172.0 / 255.0, 180.0 / 255.0, 255.0 / 255.0),
                        lightRGB: (148.0 / 255.0, 149.0 / 255.0, 245.0 / 255.0))
        ]

        for spec in minerals {
            let darkL = CIELAB.cielabLStar(red: spec.darkRGB.0, green: spec.darkRGB.1, blue: spec.darkRGB.2)
            XCTAssertEqual(darkL, 75.0, accuracy: 2.0,
                           "\(spec.name) Dark mode L* (\(darkL)) must be calibrated within 75.0 ± 2.0")

            let lightL = CIELAB.cielabLStar(red: spec.lightRGB.0, green: spec.lightRGB.1, blue: spec.lightRGB.2)
            XCTAssertEqual(lightL, 65.0, accuracy: 2.0,
                           "\(spec.name) Light mode L* (\(lightL)) must be calibrated within 65.0 ± 2.0")

            XCTAssertGreaterThan(darkL, lightL,
                                 "\(spec.name) Dark mode tone must possess higher L* than Light mode tone")
        }
    }

    func testNeutralSubstratesPhotometry() {
        let inkCharcoalL = CIELAB.cielabLStar(red: 28.0 / 255.0, green: 28.0 / 255.0, blue: 30.0 / 255.0)
        XCTAssertGreaterThan(inkCharcoalL, 10.0)
        XCTAssertLessThan(inkCharcoalL, 15.0)

        let blackL = CIELAB.cielabLStar(red: 0.0, green: 0.0, blue: 0.0)
        XCTAssertEqual(blackL, 0.0, accuracy: 1e-6)

        let paperWhiteL = CIELAB.cielabLStar(red: 251.0 / 255.0, green: 251.0 / 255.0, blue: 249.0 / 255.0)
        XCTAssertGreaterThan(paperWhiteL, 95.0)
    }

    // MARK: - Brand Theme Protocol & Resolution

    func testDefaultBrandThemeResolution() {
        let theme = DefaultTTUIBrandTheme()
        XCTAssertEqual(theme.brandName, "TTKit Standard")

        // Layer 1 Emitter
        _ = theme.canvasEmitter(for: .dark)
        _ = theme.canvasEmitter(for: .light)

        // Layer 2 Fluid
        _ = theme.fluidBodyCore(for: .dark)
        _ = theme.fluidSheenDispersion(for: .dark)
        _ = theme.fluidOrganicCore(for: .dark)

        // Layer 3 Plates & Borders
        _ = theme.plateSurface(level: 1, for: .dark)
        _ = theme.plateSurface(level: 2, for: .dark)
        _ = theme.plateSurface(level: 3, for: .dark)
        _ = theme.specularHairlineBorder(for: .dark)

        // Layer 4 Typography & Actions
        _ = theme.actionAnchor(for: .dark)
        _ = theme.textPhotonicPrimary(for: .dark)
        _ = theme.textPhotonicInverted(for: .dark)
    }

    func testCustomBrandThemePolymorphicOverride() {
        struct CustomAppTheme: TTUIBrandTheme {
            let brandName: String = "CustomStudio"
            let primaryAccent: Color = .purple
            let secondaryAccent: Color = .orange
            let signatureMineral: Color = .purple

            func actionAnchor(for colorScheme: ColorScheme) -> Color {
                .red
            }
        }

        let customTheme = CustomAppTheme()
        XCTAssertEqual(customTheme.brandName, "CustomStudio")
        XCTAssertEqual(customTheme.primaryAccent, .purple)
        XCTAssertEqual(customTheme.actionAnchor(for: .dark), .red)

        // Default implementation fallbacks work for non-overridden requirements
        _ = customTheme.canvasEmitter(for: .dark)
        _ = customTheme.fluidBodyCore(for: .dark)
        _ = customTheme.plateSurface(level: 1, for: .dark)
        _ = customTheme.plateSurface(level: 2, for: .dark)
        _ = customTheme.plateSurface(level: 3, for: .dark)
    }

    // MARK: - TTKitTheme Convenience Accessors

    func testTTKitThemeAccessors() {
        _ = TTKitTheme.kintsugiGold
        _ = TTKitTheme.kintsugiGoldEditorial
        _ = UniversalTokens.Mineral.goldEditorial
        _ = TTKitTheme.bambooGreen
        _ = TTKitTheme.archivalAmber
        _ = TTKitTheme.cinnabarRed
        _ = TTKitTheme.acousticIndigo
        _ = TTKitTheme.paperWhite
        _ = TTKitTheme.porcelainGray
        _ = TTKitTheme.obsidianBlack
        _ = TTKitTheme.inkCharcoal
        _ = TTKitTheme.hairlineBorder
    }

    // MARK: - Dynamic Color Providers

    func testDynamicColorConstructors() {
        let srgbDynamic = UniversalTokens.dynamicColor(
            lightRed: 0.2, lightGreen: 0.4, lightBlue: 0.6,
            darkRed: 0.8, darkGreen: 0.6, darkBlue: 0.4
        )
        _ = srgbDynamic

        let p3Dynamic = UniversalTokens.dynamicDisplayP3(
            lightRed: 0.1, lightGreen: 0.3, lightBlue: 0.5,
            darkRed: 0.9, darkGreen: 0.7, darkBlue: 0.3
        )
        _ = p3Dynamic
    }

    // MARK: - Axiom IV: Floating Glass Plate Tests

    @MainActor
    func testFloatingGlassPlateTiers() {
        XCTAssertTrue(TTGlassTier.base < TTGlassTier.primary)
        XCTAssertTrue(TTGlassTier.primary < TTGlassTier.overlay)
        XCTAssertEqual(TTGlassTier.base.rawValue, 1)
        XCTAssertEqual(TTGlassTier.primary.rawValue, 2)
        XCTAssertEqual(TTGlassTier.overlay.rawValue, 3)

        // Verify background plates can be instantiated
        _ = TTGlassTier.base.backgroundPlate
        _ = TTGlassTier.primary.backgroundPlate
        _ = TTGlassTier.overlay.backgroundPlate

        // Verify View modifier extensions
        let sampleView = Text("Test View")
            .ttFloatingGlassPlate(tier: .primary, cornerRadius: 16)
            .ttPrimaryGlassPlate()
            .ttOverlayGlassPlate()
        _ = sampleView
    }

    // MARK: - Kintsugi Gold Divider & Seam Tests

    @MainActor
    func testKintsugiDividerAndBorderTokens() {
        // UniversalTokens.Border.kintsugi resolution
        _ = UniversalTokens.Border.kintsugi
        XCTAssertEqual(UniversalTokens.Border.width, 0.5)

        // Instantiate horizontal and vertical TTKintsugiDivider
        let hDivider = TTKintsugiDivider(.horizontal, falloff: true)
        let vDivider = TTKintsugiDivider(.vertical, falloff: false)
        _ = hDivider
        _ = vDivider

        // Verify kintsugiSeam modifier
        let seamedView = Text("Kintsugi Plate")
            .kintsugiSeam(edge: .trailing, falloff: true)
            .kintsugiSeam(edge: .bottom, falloff: false)
        _ = seamedView
    }
}

