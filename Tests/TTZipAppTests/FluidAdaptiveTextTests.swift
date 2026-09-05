// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.
// Module: FluidAdaptiveTextTests — Mathematical & Architectural Unit Tests

import XCTest
import SwiftUI
import CoreGraphics
@testable import TTZipUI
@testable import TTZipApp

@MainActor
final class FluidAdaptiveTextTests: XCTestCase {

    // MARK: - 1. Mathematical Constants & Boundary Tokens
    
    func test_photonic_flux_constants_values_and_bounds() {
        // Derived from COMPANY_DESIGN_WHITEPAPER.md §5.1 & §5.2
        XCTAssertEqual(PhotonicFluxConstants.optimalThresholdAA, 0.180, accuracy: 0.0001)
        XCTAssertEqual(PhotonicFluxConstants.thresholdAAMin, 0.175, accuracy: 0.0001)
        XCTAssertEqual(PhotonicFluxConstants.thresholdAAMax, 0.18333, accuracy: 0.0001)
        XCTAssertEqual(PhotonicFluxConstants.thresholdAAAMin, 0.100, accuracy: 0.0001)
        XCTAssertEqual(PhotonicFluxConstants.thresholdAAAMax, 0.300, accuracy: 0.0001)
        XCTAssertEqual(PhotonicFluxConstants.microHaloStrokeWidth, 0.50, accuracy: 0.001)
        XCTAssertEqual(PhotonicFluxConstants.defaultTransitionWidth, 24.0, accuracy: 0.01)
        XCTAssertEqual(PhotonicFluxConstants.minTransitionWidth, 16.0, accuracy: 0.01)
        XCTAssertEqual(PhotonicFluxConstants.maxTransitionWidth, 32.0, accuracy: 0.01)
        XCTAssertEqual(PhotonicFluxConstants.transitionThresholdMin, 0.350, accuracy: 0.001)
        XCTAssertEqual(PhotonicFluxConstants.transitionThresholdMax, 0.650, accuracy: 0.001)
        XCTAssertEqual(PhotonicFluxConstants.diffusionSigma, 18.0, accuracy: 0.01)
        XCTAssertEqual(PhotonicFluxConstants.specularAlphaDark, 0.140, accuracy: 0.001)
        XCTAssertEqual(PhotonicFluxConstants.specularAlphaLight, 0.080, accuracy: 0.001)
    }

    // MARK: - 2. Cubic Hermite Smoothstep Evaluator Tests
    
    func test_hermite_smoothstep_boundary_and_monotonicity() {
        let edge0: CGFloat = 0.35
        let edge1: CGFloat = 0.65
        
        // Exact boundary evaluation
        XCTAssertEqual(TTZipFluidPotentialField.smoothstep(edge0: edge0, edge1: edge1, x: 0.10), 0.0)
        XCTAssertEqual(TTZipFluidPotentialField.smoothstep(edge0: edge0, edge1: edge1, x: 0.35), 0.0)
        XCTAssertEqual(TTZipFluidPotentialField.smoothstep(edge0: edge0, edge1: edge1, x: 0.65), 1.0)
        XCTAssertEqual(TTZipFluidPotentialField.smoothstep(edge0: edge0, edge1: edge1, x: 0.90), 1.0)
        
        // Midpoint evaluation: S(0.5) = 3(0.5)^2 - 2(0.5)^3 = 3(0.25) - 2(0.125) = 0.75 - 0.25 = 0.50
        let mid = TTZipFluidPotentialField.smoothstep(edge0: edge0, edge1: edge1, x: 0.50)
        XCTAssertEqual(mid, 0.50, accuracy: 0.001)
        
        // Strict Monotonicity check across the transition range [edge0, edge1]
        var prevValue: CGFloat = -1.0
        for x in stride(from: edge0, through: edge1, by: 0.01) {
            let s = TTZipFluidPotentialField.smoothstep(edge0: edge0, edge1: edge1, x: x)
            XCTAssertGreaterThanOrEqual(s, prevValue, "Smoothstep must be monotonically increasing at x=\(x)")
            XCTAssertGreaterThanOrEqual(s, 0.0)
            XCTAssertLessThanOrEqual(s, 1.0)
            prevValue = s
        }
        
        // Degenerate edges edge0 == edge1
        XCTAssertEqual(TTZipFluidPotentialField.smoothstep(edge0: 0.5, edge1: 0.5, x: 0.4), 0.0)
        XCTAssertEqual(TTZipFluidPotentialField.smoothstep(edge0: 0.5, edge1: 0.5, x: 0.5), 1.0)
        XCTAssertEqual(TTZipFluidPotentialField.smoothstep(edge0: 0.5, edge1: 0.5, x: 0.6), 1.0)
    }

    func test_hermite_smoothstep_derivative_boundary_tangents() {
        // Mathematical Invariant: S'(0) = 0 and S'(1) = 0 (zero velocity at boundaries)
        let edge0: CGFloat = 0.0
        let edge1: CGFloat = 1.0
        let h: CGFloat = 1e-5
        
        // Numerical derivative near x = 0: (S(h) - S(0)) / h -> 0
        let s0 = TTZipFluidPotentialField.smoothstep(edge0: edge0, edge1: edge1, x: 0.0)
        let sH = TTZipFluidPotentialField.smoothstep(edge0: edge0, edge1: edge1, x: h)
        let derivAt0 = (sH - s0) / h
        XCTAssertEqual(derivAt0, 0.0, accuracy: 1e-4, "Left boundary derivative S'(0) must be 0")
        
        // Numerical derivative near x = 1: (S(1) - S(1 - h)) / h -> 0
        let s1 = TTZipFluidPotentialField.smoothstep(edge0: edge0, edge1: edge1, x: 1.0)
        let s1MinusH = TTZipFluidPotentialField.smoothstep(edge0: edge0, edge1: edge1, x: 1.0 - h)
        let derivAt1 = (s1 - s1MinusH) / h
        XCTAssertEqual(derivAt1, 0.0, accuracy: 1e-4, "Right boundary derivative S'(1) must be 0")
    }

    // MARK: - 3. Luminance Thresholding & Effective Luminance Mapping
    
    func test_effective_luminance_mapping() {
        // Dark Mode: D=0 -> L_bg=0.0 (OLED Black), D=1 -> L_bg≈0.9804 (Opal White)
        XCTAssertEqual(TTZipFluidPotentialField.effectiveLuminance(density: 0.0, isDark: true), 0.0, accuracy: 0.001)
        XCTAssertEqual(TTZipFluidPotentialField.effectiveLuminance(density: 1.0, isDark: true), 0.9804, accuracy: 0.001)
        
        // Light Mode: D=0 -> L_bg=1.0 (Solar White), D=1 -> L_bg≈0.0392 (Obsidian Ink)
        XCTAssertEqual(TTZipFluidPotentialField.effectiveLuminance(density: 0.0, isDark: false), 1.0, accuracy: 0.001)
        XCTAssertEqual(TTZipFluidPotentialField.effectiveLuminance(density: 1.0, isDark: false), 0.0392, accuracy: 0.001)
        
        // Clamping check for out-of-range density values
        XCTAssertEqual(TTZipFluidPotentialField.effectiveLuminance(density: -0.5, isDark: true), 0.0, accuracy: 0.001)
        XCTAssertEqual(TTZipFluidPotentialField.effectiveLuminance(density: 1.5, isDark: true), 0.9804, accuracy: 0.001)
    }

    func test_luminance_single_threshold_interval_mathematical_bounds() {
        // Analytical Proof (COMPANY_DESIGN_WHITEPAPER.md §5.2 Part 1):
        // White Inscription Bound: (1.0 + 0.05) / (L + 0.05) >= 4.5 => L <= 11/60 ≈ 0.183333
        let maxWhiteLuminance = (1.05 / 4.50) - 0.05
        XCTAssertEqual(maxWhiteLuminance, PhotonicFluxConstants.thresholdAAMax, accuracy: 0.0001)
        
        // Black Inscription Bound: (L + 0.05) / (0.0 + 0.05) >= 4.5 => L >= 0.175000
        let minBlackLuminance = (4.50 * 0.05) - 0.05
        XCTAssertEqual(minBlackLuminance, PhotonicFluxConstants.thresholdAAMin, accuracy: 0.0001)
        
        // Valid continuous threshold switching interval non-emptiness: [0.17500, 0.18333]
        XCTAssertLessThan(PhotonicFluxConstants.thresholdAAMin, PhotonicFluxConstants.thresholdAAMax)
        let intervalWidth = PhotonicFluxConstants.thresholdAAMax - PhotonicFluxConstants.thresholdAAMin
        XCTAssertGreaterThan(intervalWidth, 0.008, "Valid switching interval width must be non-empty")
        
        // Optimal Threshold AA (L* = 0.18000) must strictly reside within the interval
        XCTAssertGreaterThanOrEqual(PhotonicFluxConstants.optimalThresholdAA, PhotonicFluxConstants.thresholdAAMin)
        XCTAssertLessThanOrEqual(PhotonicFluxConstants.optimalThresholdAA, PhotonicFluxConstants.thresholdAAMax)
    }

    // MARK: - 4. Continuous WCAG 2.1 AA/AAA Contrast Calculus Proof
    
    func test_wcag_contrast_ratio_formula_invariants() {
        // Pure White (L=1.0) vs Pure Black (L=0.0): CR = (1.05) / 0.05 = 21.0:1
        let maxCR = TTZipFluidPotentialField.contrastRatio(l1: 1.0, l2: 0.0)
        XCTAssertEqual(maxCR, 21.0, accuracy: 0.001)
        
        // Commutative symmetry invariant: CR(l1, l2) == CR(l2, l1)
        let crA = TTZipFluidPotentialField.contrastRatio(l1: 0.35, l2: 0.85)
        let crB = TTZipFluidPotentialField.contrastRatio(l1: 0.85, l2: 0.35)
        XCTAssertEqual(crA, crB, accuracy: 1e-6)
        
        // Identity invariant: CR(l, l) == 1.0:1
        let crIdent = TTZipFluidPotentialField.contrastRatio(l1: 0.42, l2: 0.42)
        XCTAssertEqual(crIdent, 1.0, accuracy: 1e-6)
    }

    func test_wcag_aa_continuous_calculus_proof_across_10000_samples() {
        // Continuous Calculus Proof (COMPANY_DESIGN_WHITEPAPER.md §5.2):
        // Sweep across 10,000 equidistant points in L_bg in [0.0, 1.0].
        // At each point, with optimal binary switching at L* = 0.180 evaluated
        // via production binaryTypographyState and binaryThresholdAlpha:
        // Assert: CR >= 4.5652:1 >= 4.5000:1 across 100.0% of the domain in both Dark and Light modes.
        
        let sampleCount = 10000
        
        for isDark in [true, false] {
            var globalInfimumCR: CGFloat = .infinity
            var infimumLuminance: CGFloat = 0.0
            
            for i in 0...sampleCount {
                let lBg = CGFloat(i) / CGFloat(sampleCount)
                let state = TTZipFluidPotentialField.binaryTypographyState(luminance: lBg, isDark: isDark)
                let textLuminance = state.textLuminance
                let cr = TTZipFluidPotentialField.contrastRatio(l1: textLuminance, l2: lBg)
                
                XCTAssertGreaterThanOrEqual(
                    cr, 4.5000,
                    "WCAG AA compliance violation (CR < 4.5:1) at L_bg = \(lBg), isDark = \(isDark), CR = \(cr)"
                )
                
                if cr < globalInfimumCR {
                    globalInfimumCR = cr
                    infimumLuminance = lBg
                }
            }
            
            // Exact Theoretical Infimum at L_bg = 0.180:
            // White text: CR = (1.0 + 0.05) / (0.180 + 0.05) = 1.05 / 0.230 ≈ 4.565217:1
            XCTAssertEqual(globalInfimumCR, 4.5652, accuracy: 0.005)
            XCTAssertEqual(infimumLuminance, PhotonicFluxConstants.optimalThresholdAA, accuracy: 0.001)
        }
    }

    func test_wcag_aaa_dead_zone_and_micro_halo_proof() {
        // Level AAA requirement: CR >= 7.0:1
        // White requires: L_bg <= (1.05 / 7.0) - 0.05 = 0.15 - 0.05 = 0.100
        // Black requires: L_bg >= (7.0 * 0.05) - 0.05 = 0.35 - 0.05 = 0.300
        // Dead zone interval: (0.100, 0.300) where single-layer unstroked glyphs cannot reach 7.0:1.
        
        let deadZoneMid: CGFloat = 0.200
        let crWhiteAtMid = TTZipFluidPotentialField.contrastRatio(l1: 1.0, l2: deadZoneMid)
        let crBlackAtMid = TTZipFluidPotentialField.contrastRatio(l1: 0.0, l2: deadZoneMid)
        
        XCTAssertLessThan(crWhiteAtMid, 7.00, "Unstroked white text drops below AAA in dead zone")
        XCTAssertLessThan(crBlackAtMid, 7.00, "Unstroked black text drops below AAA in dead zone")
        
        // Micro-Halo Solution: Core-to-Halo contrast ratio invariant
        // Inscription Core (White L=1.0) against Outer Micro-Halo (Black L=0.0)
        let crCoreToHalo = TTZipFluidPotentialField.contrastRatio(l1: 1.0, l2: 0.0)
        XCTAssertEqual(crCoreToHalo, 21.0, accuracy: 0.001, "Core-to-Halo contrast strictly guarantees 21.0:1 >> 7.0:1")
        
        // Halo-to-Background contrast at critical midpoint L_bg = 0.200:
        // Halo (Black L=0.0) vs Background (L=0.200): CR = (0.20 + 0.05) / (0.00 + 0.05) = 0.25 / 0.05 = 5.0:1 >= 4.5:1
        let crHaloToBg = TTZipFluidPotentialField.contrastRatio(l1: 0.0, l2: deadZoneMid)
        XCTAssertEqual(crHaloToBg, 5.0, accuracy: 0.001, "Micro-halo provides 5.0:1 >= 4.5:1 boundary edge contrast")
    }

    // MARK: - 4.1 Narrow Text Binary Alpha & Dynamic Micro-Halo Tests (Milestone 4 Remediation)
    
    func test_narrow_text_binary_alpha_and_continuous_wcag_aa_across_domain() {
        // Verifies Defect 1 fix: Narrow text elements (width <= transitionWidth)
        // must strictly evaluate to binary alpha (0.0 or 1.0) with zero intermediate mid-gray blending,
        // continuously guaranteeing WCAG AA CR >= 4.5652:1 across all background luminances.
        let sampleCount = 10000
        
        for isDark in [true, false] {
            var minCR: CGFloat = .infinity
            
            for i in 0...sampleCount {
                let lBg = CGFloat(i) / CGFloat(sampleCount)
                let alpha = TTZipFluidPotentialField.binaryThresholdAlpha(luminance: lBg, isDark: isDark)
                
                // Assert strict binary switching: alpha must be exactly 0.0 or 1.0
                XCTAssertTrue(
                    alpha == 0.0 || alpha == 1.0,
                    "Narrow element alpha must be strictly binary at L_bg = \(lBg), got \(alpha)"
                )
                
                // In Dark mode: Layer A is White (L=1.0), Layer B is Black (L=0.0)
                // In Light mode: Layer A is Black (L=0.0), Layer B is White (L=1.0)
                let textL: CGFloat
                if isDark {
                    textL = alpha == 1.0 ? 0.0 : 1.0
                } else {
                    textL = alpha == 1.0 ? 1.0 : 0.0
                }
                
                // Assert no intermediate gray
                XCTAssertTrue(textL == 0.0 || textL == 1.0)
                
                let cr = TTZipFluidPotentialField.contrastRatio(l1: textL, l2: lBg)
                XCTAssertGreaterThanOrEqual(
                    cr, 4.5000,
                    "Narrow text CR violation (< 4.5:1) at L_bg = \(lBg), isDark = \(isDark), CR = \(cr)"
                )
                
                if cr < minCR {
                    minCR = cr
                }
            }
            
            // Global infimum must match theoretical 4.5652:1 (never dip to 1.0008:1)
            XCTAssertEqual(minCR, 4.5652, accuracy: 0.005)
        }
    }
    
    func test_dynamic_micro_halo_inversion_and_core_to_halo_contrast() {
        // Verifies Defect 2 fix: Micro-halo stroke color must dynamically oppose
        // the rendered glyph color (White text gets Black halo, Black text gets White halo),
        // fulfilling COMPANY_DESIGN_WHITEPAPER.md §5.2 Part 2.
        let sampleCount = 1000
        
        for isDark in [true, false] {
            for i in 0...sampleCount {
                let lBg = CGFloat(i) / CGFloat(sampleCount)
                let state = TTZipFluidPotentialField.binaryTypographyState(luminance: lBg, isDark: isDark)
                
                // Core-to-Halo contrast must strictly be 21.0:1 everywhere
                let crCoreHalo = TTZipFluidPotentialField.contrastRatio(l1: state.textLuminance, l2: state.haloLuminance)
                XCTAssertEqual(
                    crCoreHalo, 21.0, accuracy: 0.001,
                    "Core-to-Halo contrast must be 21.0:1 at L_bg = \(lBg), isDark = \(isDark)"
                )
                
                // Strict opposition invariant
                if state.textLuminance == 1.0 {
                    XCTAssertEqual(state.haloLuminance, 0.0, "White text must have pure Black micro-halo")
                } else {
                    XCTAssertEqual(state.haloLuminance, 1.0, "Black text must have pure White micro-halo")
                }
                
                // In Dark mode with fluid brightened (L_bg > 0.180), text is Black and halo is Pure White
                if isDark && lBg > PhotonicFluxConstants.optimalThresholdAA {
                    XCTAssertEqual(state.textLuminance, 0.0)
                    XCTAssertEqual(state.haloLuminance, 1.0)
                }
                
                // In Light mode with fluid darkened (L_bg <= 0.180), text is White and halo is Pure Black
                if !isDark && lBg <= PhotonicFluxConstants.optimalThresholdAA {
                    XCTAssertEqual(state.textLuminance, 1.0)
                    XCTAssertEqual(state.haloLuminance, 0.0)
                }
            }
        }
    }
    
    func test_spatiotemporal_fluid_simulation_narrow_text_no_contrast_collapse() {
        // Verifies Challenger 2 empirical simulation (4,410 spatio-temporal evaluation points):
        // Container: 800x600, t in [0, 10], x in [0, 800], y in [0, 600].
        // Under binary threshold switching, exactly 0 points fall below 4.5:1 (remedying the 106 failures).
        let containerSize = CGSize(width: 800, height: 600)
        var totalPoints = 0
        var darkFailures = 0
        var lightFailures = 0
        var darkInfimumCR: CGFloat = .infinity
        var lightInfimumCR: CGFloat = .infinity
        
        for t in stride(from: 0.0, to: 10.0, by: 1.0) {
            for x in stride(from: 0.0, through: 800.0, by: 40.0) {
                for y in stride(from: 0.0, through: 600.0, by: 30.0) {
                    totalPoints += 1
                    let pt = CGPoint(x: x, y: y)
                    let density = TTZipFluidPotentialField.evaluate(
                        at: pt,
                        containerSize: containerSize,
                        time: t
                    )
                    
                    // Dark mode evaluation
                    let lDark = TTZipFluidPotentialField.effectiveLuminance(density: density, isDark: true)
                    let stateDark = TTZipFluidPotentialField.binaryTypographyState(luminance: lDark, isDark: true)
                    let crDark = TTZipFluidPotentialField.contrastRatio(l1: stateDark.textLuminance, l2: lDark)
                    if crDark < 4.5000 {
                        darkFailures += 1
                    }
                    if crDark < darkInfimumCR {
                        darkInfimumCR = crDark
                    }
                    
                    // Light mode evaluation
                    let lLight = TTZipFluidPotentialField.effectiveLuminance(density: density, isDark: false)
                    let stateLight = TTZipFluidPotentialField.binaryTypographyState(luminance: lLight, isDark: false)
                    let crLight = TTZipFluidPotentialField.contrastRatio(l1: stateLight.textLuminance, l2: lLight)
                    if crLight < 4.5000 {
                        lightFailures += 1
                    }
                    if crLight < lightInfimumCR {
                        lightInfimumCR = crLight
                    }
                }
            }
        }
        
        // Assert full coverage of the 4,410 simulation points
        XCTAssertEqual(totalPoints, 4410)
        XCTAssertEqual(darkFailures, 0, "Zero contrast failures allowed across 4,410 spatio-temporal points in Dark Mode")
        XCTAssertEqual(lightFailures, 0, "Zero contrast failures allowed across 4,410 spatio-temporal points in Light Mode")
        XCTAssertGreaterThanOrEqual(darkInfimumCR, 4.5652)
        XCTAssertGreaterThanOrEqual(lightInfimumCR, 4.5652)
    }

    // MARK: - 5. Target Alpha Transition & Smoothstep Compensation
    
    func test_target_alpha_directional_monotonicity_in_dark_and_light() {
        let transitionW = PhotonicFluxConstants.defaultTransitionWidth
        
        // Dark Mode: as luminance increases (fluid brightens with opal white),
        // text transitions from White (alpha=0 for Layer B) to Black (alpha=1 for Layer B).
        let alphaLowDark = TTZipFluidPotentialField.targetAlpha(luminance: 0.10, isDark: true, transitionWidth: transitionW)
        let alphaMidDark = TTZipFluidPotentialField.targetAlpha(luminance: 0.18, isDark: true, transitionWidth: transitionW)
        let alphaHighDark = TTZipFluidPotentialField.targetAlpha(luminance: 0.26, isDark: true, transitionWidth: transitionW)
        
        XCTAssertLessThanOrEqual(alphaLowDark, alphaMidDark)
        XCTAssertLessThanOrEqual(alphaMidDark, alphaHighDark)
        XCTAssertEqual(alphaLowDark, 0.0, accuracy: 0.01)
        XCTAssertEqual(alphaHighDark, 1.0, accuracy: 0.01)
        
        // Light Mode: as luminance decreases (fluid darkens with obsidian ink),
        // text transitions from Black (alpha=0 for Layer B) to White (alpha=1 for Layer B).
        let alphaHighLight = TTZipFluidPotentialField.targetAlpha(luminance: 0.26, isDark: false, transitionWidth: transitionW)
        let alphaMidLight = TTZipFluidPotentialField.targetAlpha(luminance: 0.18, isDark: false, transitionWidth: transitionW)
        let alphaLowLight = TTZipFluidPotentialField.targetAlpha(luminance: 0.10, isDark: false, transitionWidth: transitionW)
        
        XCTAssertLessThanOrEqual(alphaHighLight, alphaMidLight)
        XCTAssertLessThanOrEqual(alphaMidLight, alphaLowLight)
        XCTAssertEqual(alphaHighLight, 0.0, accuracy: 0.01)
        XCTAssertEqual(alphaLowLight, 1.0, accuracy: 0.01)
    }

    // MARK: - 6. Fluid Potential Field Analytical Evaluator Tests
    
    func test_fluid_potential_field_evaluation_bounds() {
        let size = CGSize(width: 800, height: 600)
        
        for t in stride(from: 0.0, through: 10.0, by: 1.0) {
            let pCenter = CGPoint(x: 400, y: 300)
            let valCenter = TTZipFluidPotentialField.evaluate(at: pCenter, containerSize: size, time: t)
            XCTAssertGreaterThanOrEqual(valCenter, 0.0)
            XCTAssertLessThanOrEqual(valCenter, 1.0)
            
            let pCorner = CGPoint(x: 0, y: 0)
            let valCorner = TTZipFluidPotentialField.evaluate(at: pCorner, containerSize: size, time: t)
            XCTAssertGreaterThanOrEqual(valCorner, 0.0)
            XCTAssertLessThanOrEqual(valCorner, 1.0)
        }
    }
    
    func test_fluid_potential_fallback_on_zero_or_negative_container_size() {
        // Geometry size unmeasured or collapsed
        let zeroVal = TTZipFluidPotentialField.evaluate(at: .zero, containerSize: .zero, time: 0.0)
        XCTAssertEqual(zeroVal, 0.0, "Zero container size must return 0.0 fallback density")
        
        let negVal = TTZipFluidPotentialField.evaluate(
            at: CGPoint(x: 100, y: 100),
            containerSize: CGSize(width: -500, height: 400),
            time: 1.0
        )
        XCTAssertEqual(negVal, 0.0, "Negative width must return 0.0 fallback density")
        
        let negHeightVal = TTZipFluidPotentialField.evaluate(
            at: CGPoint(x: 100, y: 100),
            containerSize: CGSize(width: 500, height: -400),
            time: 1.0
        )
        XCTAssertEqual(negHeightVal, 0.0, "Negative height must return 0.0 fallback density")
    }

    // MARK: - 7. TTZipFluidAdaptiveText View & ViewModifier Architecture Tests
    
    @MainActor
    func test_fluid_adaptive_text_view_and_modifier_instantiations() {
        // String-based initializers
        let viewWithString = TTZipFluidAdaptiveText(
            "Universal Archive Canvas",
            font: .title2,
            weight: .medium,
            localProbe: CGPoint(x: 150, y: 50),
            tracking: 0.5,
            lineSpacing: 6.0,
            transitionWidth: 28.0,
            showsMicroHalo: true
        )
        XCTAssertNotNil(viewWithString)
        
        // LocalizedKey-based initializer
        let viewWithKey = TTZipFluidAdaptiveText(
            localized: "common.archive",
            font: .body,
            weight: .regular,
            showsMicroHalo: false
        )
        XCTAssertNotNil(viewWithKey)
        
        // Coordinate Space Name Token
        XCTAssertEqual(TTZipFluidCoordinateSpace.name, "TTZipFluidCoordinateSpace")
        
        // FluidPotentialSpatialMask instantiation
        let spatialMask = FluidPotentialSpatialMask(
            localBounds: CGRect(x: 0, y: 0, width: 200, height: 40),
            globalFrame: CGRect(x: 100, y: 200, width: 200, height: 40),
            transitionWidth: 24.0,
            localProbe: CGPoint(x: 100, y: 20)
        )
        XCTAssertNotNil(spatialMask)
        
        // SwiftUI ViewModifier extension call
        let modifiedText = Text("Sensory Inscription")
            .fluidAdaptive(
                font: .headline,
                weight: .bold,
                transitionWidth: 20.0,
                showsMicroHalo: true
            )
        XCTAssertNotNil(modifiedText)
    }

    func test_transition_width_clamping_to_physical_limits() {
        // Clamping to [minTransitionWidth (16.0), maxTransitionWidth (32.0)]
        let textUnder = TTZipFluidAdaptiveText("Under", transitionWidth: 8.0)
        XCTAssertNotNil(textUnder)
        
        let textOver = TTZipFluidAdaptiveText("Over", transitionWidth: 64.0)
        XCTAssertNotNil(textOver)
        
        let maskUnder = FluidPotentialSpatialMask(
            localBounds: .zero,
            globalFrame: .zero,
            transitionWidth: 4.0
        )
        XCTAssertEqual(maskUnder.transitionWidth, PhotonicFluxConstants.minTransitionWidth)
        
        let maskOver = FluidPotentialSpatialMask(
            localBounds: .zero,
            globalFrame: .zero,
            transitionWidth: 100.0
        )
        XCTAssertEqual(maskOver.transitionWidth, PhotonicFluxConstants.maxTransitionWidth)
    }
}
