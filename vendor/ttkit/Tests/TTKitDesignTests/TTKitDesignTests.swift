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
        _ = TTKitTheme.celestialPurple
        _ = TTKitTheme.jadeCyan
        _ = UniversalTokens.Mineral.jadeCyan
        _ = TTKitTheme.paperWhite
        _ = TTKitTheme.porcelainGray
        _ = TTKitTheme.obsidianBlack
        _ = TTKitTheme.inkCharcoal
        _ = TTKitTheme.hairlineBorder
    }

    // MARK: - Segmented Switch Semantic Tokens & Contrast Gates

    func testSegmentedSwitchSemanticTokens() {
        XCTAssertEqual(UniversalTokens.SegmentedSwitch.hairlineWidth, 0.5)
        XCTAssertEqual(UniversalTokens.SegmentedSwitch.hairlineWidth, UniversalTokens.Border.width)
        XCTAssertEqual(UniversalTokens.SegmentedSwitch.trackSurfaceOpacity, 0.55, accuracy: 1e-6)
        XCTAssertEqual(UniversalTokens.SegmentedSwitch.hoverSurfaceOpacity, 0.55, accuracy: 1e-6)
        XCTAssertEqual(UniversalTokens.SegmentedSwitch.activeTintFillOpacityDark, 0.22, accuracy: 1e-6)
        XCTAssertEqual(UniversalTokens.SegmentedSwitch.activeTintFillOpacityLight, 0.16, accuracy: 1e-6)
        XCTAssertEqual(UniversalTokens.SegmentedSwitch.activeTintBorderOpacityDark, 0.55, accuracy: 1e-6)
        XCTAssertEqual(UniversalTokens.SegmentedSwitch.activeTintBorderOpacityLight, 0.42, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(UniversalTokens.SegmentedSwitch.minHitTargetMacOS, 28.0)
        XCTAssertGreaterThanOrEqual(UniversalTokens.SegmentedSwitch.minHitTargetCompactMacOS, 24.0)
        XCTAssertGreaterThanOrEqual(UniversalTokens.SegmentedSwitch.minHitTargetIOS, 44.0)
        XCTAssertGreaterThanOrEqual(UniversalTokens.SegmentedSwitch.minActiveContrastRatio, 3.0)

        _ = UniversalTokens.SegmentedSwitch.trackSurface
        _ = UniversalTokens.SegmentedSwitch.activeIndicatorSurface
        _ = UniversalTokens.SegmentedSwitch.hoverSurface
        _ = UniversalTokens.SegmentedSwitch.activeText
        _ = UniversalTokens.SegmentedSwitch.inactiveText
        _ = UniversalTokens.SegmentedSwitch.hairlineBorder
        _ = UniversalTokens.SegmentedSwitch.activeIndicatorTintFill(for: TTKitTheme.kintsugiGold, colorScheme: .dark)
        _ = UniversalTokens.SegmentedSwitch.activeIndicatorTintFill(for: TTKitTheme.kintsugiGold, colorScheme: .light)
        _ = UniversalTokens.SegmentedSwitch.activeIndicatorTintBorder(for: TTKitTheme.jadeCyan, colorScheme: .dark)
        _ = UniversalTokens.SegmentedSwitch.activeIndicatorTintBorder(for: TTKitTheme.jadeCyan, colorScheme: .light)
    }

    func testSegmentedSwitchWCAGContrastInvariants() {
        let darkActiveContrast = UniversalTokens.SegmentedSwitch.activeTextContrastRatio(for: .dark)
        let lightActiveContrast = UniversalTokens.SegmentedSwitch.activeTextContrastRatio(for: .light)
        XCTAssertGreaterThanOrEqual(
            darkActiveContrast,
            UniversalTokens.SegmentedSwitch.minActiveContrastRatio,
            "Dark mode active segmented switch text contrast must be >= 3.0:1"
        )
        XCTAssertGreaterThanOrEqual(
            lightActiveContrast,
            UniversalTokens.SegmentedSwitch.minActiveContrastRatio,
            "Light mode active segmented switch text contrast must be >= 3.0:1"
        )

        let darkInactiveContrast = UniversalTokens.SegmentedSwitch.inactiveTextContrastRatio(for: .dark)
        let lightInactiveContrast = UniversalTokens.SegmentedSwitch.inactiveTextContrastRatio(for: .light)
        XCTAssertGreaterThanOrEqual(
            darkInactiveContrast,
            UniversalTokens.SegmentedSwitch.minActiveContrastRatio,
            "Dark mode inactive segmented switch text contrast must be >= 3.0:1"
        )
        XCTAssertGreaterThanOrEqual(
            lightInactiveContrast,
            UniversalTokens.SegmentedSwitch.minActiveContrastRatio,
            "Light mode inactive segmented switch text contrast must be >= 3.0:1"
        )

        let jadeDarkL = CIELAB.cielabLStar(red: 94.0 / 255.0, green: 234.0 / 255.0, blue: 212.0 / 255.0)
        let jadeLightL = CIELAB.cielabLStar(red: 13.0 / 255.0, green: 148.0 / 255.0, blue: 136.0 / 255.0)
        XCTAssertGreaterThan(jadeDarkL, jadeLightL)
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

    func testFloatingGlassPlateExplicitOverlayAndOverLimitDepthResolution() {
        let env = EnvironmentValues()
        XCTAssertEqual(env.ttGlassPlateDepth, 0)

        let explicitBase = TTFloatingGlassPlateModifier(tier: .base)
        let explicitPrimary = TTFloatingGlassPlateModifier(tier: .primary)
        let explicitOverlay = TTFloatingGlassPlateModifier(tier: .overlay)
        let autoPlate = TTFloatingGlassPlateModifier()

        let standaloneOverlay = explicitOverlay.resolvedDepth(forParentDepth: 0)
        XCTAssertEqual(explicitOverlay.resolvedTier(forParentDepth: 0), .overlay)
        XCTAssertEqual(standaloneOverlay.rawDepth, 3)
        XCTAssertEqual(standaloneOverlay.clampedDepth, 3)
        XCTAssertFalse(standaloneOverlay.isViolation)

        let baseAtRoot = explicitBase.resolvedDepth(forParentDepth: 0)
        XCTAssertEqual(explicitBase.resolvedTier(forParentDepth: 0), .base)
        XCTAssertEqual(baseAtRoot.rawDepth, 1)
        XCTAssertEqual(baseAtRoot.clampedDepth, 1)
        XCTAssertFalse(baseAtRoot.isViolation)

        let primaryInsideBase = explicitPrimary.resolvedDepth(forParentDepth: baseAtRoot.clampedDepth)
        XCTAssertEqual(explicitPrimary.resolvedTier(forParentDepth: baseAtRoot.clampedDepth), .primary)
        XCTAssertEqual(primaryInsideBase.rawDepth, 2)
        XCTAssertEqual(primaryInsideBase.clampedDepth, 2)
        XCTAssertFalse(primaryInsideBase.isViolation)

        let overlayInsidePrimary = explicitOverlay.resolvedDepth(forParentDepth: primaryInsideBase.clampedDepth)
        XCTAssertEqual(explicitOverlay.resolvedTier(forParentDepth: primaryInsideBase.clampedDepth), .overlay)
        XCTAssertEqual(overlayInsidePrimary.rawDepth, 3)
        XCTAssertEqual(overlayInsidePrimary.clampedDepth, 3)
        XCTAssertFalse(overlayInsidePrimary.isViolation)

        let autoL1 = autoPlate.resolvedDepth(forParentDepth: 0)
        XCTAssertEqual(autoPlate.resolvedTier(forParentDepth: 0), .base)
        XCTAssertEqual(autoL1.clampedDepth, 1)
        XCTAssertFalse(autoL1.isViolation)

        let autoL2 = autoPlate.resolvedDepth(forParentDepth: autoL1.clampedDepth)
        XCTAssertEqual(autoPlate.resolvedTier(forParentDepth: autoL1.clampedDepth), .primary)
        XCTAssertEqual(autoL2.clampedDepth, 2)
        XCTAssertFalse(autoL2.isViolation)

        let autoL3 = autoPlate.resolvedDepth(forParentDepth: autoL2.clampedDepth)
        XCTAssertEqual(autoPlate.resolvedTier(forParentDepth: autoL2.clampedDepth), .overlay)
        XCTAssertEqual(autoL3.clampedDepth, 3)
        XCTAssertFalse(autoL3.isViolation)

        for fourthLayer in [autoPlate, explicitBase, explicitPrimary, explicitOverlay] {
            let overLimit = fourthLayer.resolvedDepth(forParentDepth: standaloneOverlay.clampedDepth)
            XCTAssertEqual(overLimit.rawDepth, 4)
            XCTAssertEqual(overLimit.clampedDepth, 3)
            XCTAssertTrue(overLimit.isViolation)
        }
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

