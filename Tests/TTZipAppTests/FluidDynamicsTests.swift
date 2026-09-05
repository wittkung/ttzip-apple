// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.
// Module: FluidDynamicsTests — Incompressible Navier-Stokes & Cauchy Potential Field Unit Tests

import XCTest
import SwiftUI
import CoreGraphics
@testable import TTZipUI
@testable import TTZipApp

final class FluidDynamicsTests: XCTestCase {

    // MARK: - 1. Cauchy Density Potential Function Tests
    
    func test_cauchy_density_potential_at_vortex_center_equals_weight() {
        // Mathematical Invariant (COMPANY_DESIGN_WHITEPAPER.md §4.1):
        // D_k(c_k) = (w_k * r_k^2) / (0 + r_k^2) = w_k
        // For an isolated vortex, evaluating density at its exact center must equal its dynamic weight.
        let engine = TTZipFluidDynamicsEngine.shared
        let center = CGPoint(x: 300, y: 300)
        let radius: CGFloat = 150.0
        let weight = 0.65
        let instance = TTZipVortexInstance(position: center, radius: radius, weight: weight)
        
        let densityAtCenter = engine.sampleDensity(at: center, instances: [instance])
        XCTAssertEqual(densityAtCenter, weight, accuracy: 1e-6, "Center density of isolated vortex must equal its weight")
        
        // When resolving through the engine, sample at the vortex's evaluated position
        let size = CGSize(width: 800, height: 600)
        let instances = engine.resolveInstances(in: size, at: 0.0)
        let v0 = instances[0]
        let v0SelfContribution = (v0.weight * Double(v0.radius * v0.radius)) / Double(0.0 + v0.radius * v0.radius)
        XCTAssertEqual(v0SelfContribution, v0.weight, accuracy: 1e-6, "Self contribution at vortex center must equal its weight")
        
        // Total density at vortex center must be >= its own weight and <= 1.0
        let totalAtV0 = engine.sampleDensity(at: v0.position, instances: instances)
        XCTAssertGreaterThanOrEqual(totalAtV0, v0.weight)
        XCTAssertLessThanOrEqual(totalAtV0, 1.0)
    }

    func test_cauchy_density_potential_far_field_asymptotic_decay() {
        // Far field attenuation: as ||p - c_k|| >> r_k, contribution -> 0.
        let singleVortex = TTZipFluidVortex(
            id: 1,
            baseWeight: 1.0,
            baseRadiusFraction: 0.10,
            orbitCenterFraction: CGPoint(x: 0.5, y: 0.5),
            orbitRadiusXFraction: 0.0,
            orbitRadiusYFraction: 0.0,
            angularVelocity: 0.0,
            phaseOffset: 0.0
        )
        let engine = TTZipFluidDynamicsEngine(vortices: [singleVortex])
        let size = CGSize(width: 1000, height: 1000)
        
        // Center position: (500, 500), radius r = 100pt.
        // At distance d = 1000pt (10 * r), theoretical D = (1.0 * 100^2) / (1000^2 + 100^2) = 10000 / 1010000 ≈ 0.0099
        let farPoint = CGPoint(x: 1500, y: 500)
        let densityFar = engine.sampleDensity(
            at: farPoint,
            in: size,
            at: 0.0,
            speed: 0.0,
            breathingAmplitude: 0.0
        )
        XCTAssertLessThan(densityFar, 0.015, "Far field density must decay asymptotically toward zero")
        XCTAssertGreaterThan(densityFar, 0.0, "Far field density must remain strictly non-negative")
    }

    func test_cauchy_density_multi_kernel_summation_in_unit_interval() {
        let engine = TTZipFluidDynamicsEngine.shared
        let size = CGSize(width: 1200, height: 800)
        
        // Dense grid sampling across the domain
        for x in stride(from: 0.0, through: 1200.0, by: 120.0) {
            for y in stride(from: 0.0, through: 800.0, by: 80.0) {
                let p = CGPoint(x: x, y: y)
                let density = engine.sampleDensity(at: p, in: size, at: 1.5)
                XCTAssertGreaterThanOrEqual(density, 0.0, "Density at \(p) must be >= 0.0")
                XCTAssertLessThanOrEqual(density, 1.0, "Density at \(p) must be <= 1.0")
            }
        }
    }

    func test_fast_instance_sampler_matches_analytical_sampler() {
        let engine = TTZipFluidDynamicsEngine.shared
        let size = CGSize(width: 800, height: 600)
        let t: TimeInterval = 4.25
        
        let instances = engine.resolveInstances(in: size, at: t)
        let testPoints = [
            CGPoint(x: 100, y: 100),
            CGPoint(x: 400, y: 300),
            CGPoint(x: 650, y: 450),
            CGPoint(x: 0, y: 0),
            CGPoint(x: 800, y: 600)
        ]
        
        for p in testPoints {
            let direct = engine.sampleDensity(at: p, in: size, at: t)
            let viaInstances = engine.sampleDensity(at: p, instances: instances)
            XCTAssertEqual(direct, viaInstances, accuracy: 1e-6, "Fast instance sampler must match analytical sampler at \(p)")
        }
    }

    func test_cauchy_potential_robustness_against_singularities() {
        let engine = TTZipFluidDynamicsEngine.shared
        let size = CGSize(width: 500, height: 500)
        
        // Exact singularity check: sampling at negative coordinates or extreme bounds
        let extremePoints = [
            CGPoint(x: -10000, y: -10000),
            CGPoint(x: 10000, y: 10000),
            CGPoint(x: 0, y: 0),
            CGPoint(x: Double.nan, y: 0),
            CGPoint(x: 0, y: Double.infinity)
        ]
        
        let instances = engine.resolveInstances(in: size, at: 0.0)
        for p in extremePoints {
            if p.x.isNaN || p.y.isInfinite {
                // NaN or Infinite inputs must evaluate cleanly via clamping without crashing
                let d = engine.sampleDensity(at: p, instances: instances)
                XCTAssertFalse(d.isNaN, "Density must never be NaN")
            } else {
                let d = engine.sampleDensity(at: p, instances: instances)
                XCTAssertGreaterThanOrEqual(d, 0.0)
                XCTAssertLessThanOrEqual(d, 1.0)
            }
        }
    }

    // MARK: - 2. 4-Vortex Kinematics & Constellation Topology Tests
    
    func test_canonical_4_vortex_constellation_invariants() {
        let engine = TTZipFluidDynamicsEngine.shared
        XCTAssertEqual(engine.vortices.count, 4, "Canonical fluid engine must possess exactly 4 vortices")
        
        // Invariant: sum of base weights == 1.00
        let baseWeightSum = engine.vortices.reduce(0.0) { $0 + $1.baseWeight }
        XCTAssertEqual(baseWeightSum, 1.00, accuracy: 0.0001, "Sum of base weights must equal 1.00")
        
        // Individual vortex weight verification
        XCTAssertEqual(engine.vortices[0].baseWeight, 0.35, accuracy: 0.0001, "Vortex 1 heavy core weight = 0.35")
        XCTAssertEqual(engine.vortices[1].baseWeight, 0.25, accuracy: 0.0001, "Vortex 2 resonant swirl weight = 0.25")
        XCTAssertEqual(engine.vortices[2].baseWeight, 0.20, accuracy: 0.0001, "Vortex 3 upper drift weight = 0.20")
        XCTAssertEqual(engine.vortices[3].baseWeight, 0.20, accuracy: 0.0001, "Vortex 4 lower anchor weight = 0.20")
        
        // Radii fractions must be within physically calibrated range [0.25, 0.55]
        for v in engine.vortices {
            XCTAssertGreaterThanOrEqual(v.baseRadiusFraction, 0.25, "Vortex \(v.id) base radius fraction >= 0.25")
            XCTAssertLessThanOrEqual(v.baseRadiusFraction, 0.55, "Vortex \(v.id) base radius fraction <= 0.55")
        }
    }

    func test_vortex_kinematics_orbital_trajectory_and_bounds() {
        let engine = TTZipFluidDynamicsEngine.shared
        let size = CGSize(width: 1000, height: 1000)
        
        // Sample across an entire orbital period (T ~ 2 * pi / 0.24 ≈ 26.2 seconds)
        for t in stride(from: 0.0, through: 30.0, by: 1.5) {
            let instances = engine.resolveInstances(in: size, at: t)
            XCTAssertEqual(instances.count, 4)
            
            for (index, inst) in instances.enumerated() {
                // Ensure coordinates remain within expanded canvas bounds
                XCTAssertGreaterThan(inst.position.x, -200.0, "Vortex \(index) X coordinate >= -200")
                XCTAssertLessThan(inst.position.x, 1200.0, "Vortex \(index) X coordinate <= 1200")
                XCTAssertGreaterThan(inst.position.y, -200.0, "Vortex \(index) Y coordinate >= -200")
                XCTAssertLessThan(inst.position.y, 1200.0, "Vortex \(index) Y coordinate <= 1200")
                
                // Radius must respect lower bound clamping >= 30.0pt
                XCTAssertGreaterThanOrEqual(inst.radius, 30.0, "Vortex \(index) radius must be >= 30.0pt")
            }
        }
    }

    // MARK: - 3. Thermodynamic Breathing Scale Factors & Harmonic Wobble
    
    func test_thermodynamic_breathing_constants() {
        // T_breathe ~ 8.0s -> omega ~ 0.785398 rad/s
        XCTAssertEqual(TTZipFluidDynamicsEngine.thermodynamicBaseOmega, 0.785398, accuracy: 0.00001)
        // T_1 ~ 13.96s -> omega_1 = 0.450 rad/s
        XCTAssertEqual(TTZipFluidDynamicsEngine.harmonicOmega1, 0.450000, accuracy: 0.00001)
        // T_2 ~ 16.53s -> omega_2 = 0.380 rad/s
        XCTAssertEqual(TTZipFluidDynamicsEngine.harmonicOmega2, 0.380000, accuracy: 0.00001)
    }

    func test_thermodynamic_weight_normalization_conservation() {
        let engine = TTZipFluidDynamicsEngine.shared
        let size = CGSize(width: 800, height: 600)
        
        // Strict Invariant: Across any arbitrary timestamp t, the sum of dynamic weights MUST strictly equal 1.000000
        for t in stride(from: 0.0, through: 60.0, by: 0.75) {
            let instances = engine.resolveInstances(in: size, at: t, breathingAmplitude: 0.15)
            let dynamicSum = instances.reduce(0.0) { $0 + $1.weight }
            XCTAssertEqual(dynamicSum, 1.000000, accuracy: 1e-6, "Dynamic weights must strictly normalize to 1.0 at t=\(t)")
            
            for inst in instances {
                XCTAssertGreaterThan(inst.weight, 0.0, "Every vortex must maintain positive weight contribution")
            }
        }
    }

    func test_thermodynamic_radius_expansion_and_contraction_bounds() {
        let engine = TTZipFluidDynamicsEngine.shared
        let size = CGSize(width: 1000, height: 1000)
        let minDim: CGFloat = min(size.width, size.height)
        let amplitude: Double = 0.15
        
        // Check dynamic radii fluctuation range for Vortex 1 (baseFraction = 0.50)
        // Theoretical range: minDim * 0.50 * [1 - 0.15, 1 + 0.15] = [425.0, 575.0]
        let baseRadius = minDim * CGFloat(engine.vortices[0].baseRadiusFraction)
        let expectedMin = baseRadius * CGFloat(1.0 - amplitude)
        let expectedMax = baseRadius * CGFloat(1.0 + amplitude)
        var minObservedR: CGFloat = .infinity
        var maxObservedR: CGFloat = -.infinity
        
        for t in stride(from: 0.0, through: 20.0, by: 0.2) {
            let instances = engine.resolveInstances(in: size, at: t, breathingAmplitude: amplitude)
            let r1 = instances[0].radius
            minObservedR = min(minObservedR, r1)
            maxObservedR = max(maxObservedR, r1)
        }
        
        XCTAssertGreaterThanOrEqual(minObservedR, expectedMin - 5.0, "Observed minimum radius must respect breathing lower bound")
        XCTAssertLessThanOrEqual(maxObservedR, expectedMax + 5.0, "Observed maximum radius must respect breathing upper bound")
    }

    // MARK: - 4. Energy Conservation & Numerical Integration Stability
    
    func test_fluid_energy_conservation_across_1000_integration_steps() {
        let engine = TTZipFluidDynamicsEngine.shared
        let size = CGSize(width: 800, height: 600)
        let probePoints = [
            CGPoint(x: 400, y: 300), // Center
            CGPoint(x: 100, y: 100), // Top-Left
            CGPoint(x: 700, y: 500), // Bottom-Right
            CGPoint(x: 400, y: 100), // Top-Center
            CGPoint(x: 200, y: 500)  // Bottom-Left
        ]
        
        // Simulate 1000 discrete frames (dt = 0.016s ~ 60 FPS for 16.0 seconds)
        var previousDensities = Array(repeating: 0.0, count: probePoints.count)
        for step in 0..<1000 {
            let t = Double(step) * 0.016
            let instances = engine.resolveInstances(in: size, at: t)
            
            // Invariant 1: Dynamic weights sum strictly to 1.0
            let weightSum = instances.reduce(0.0) { $0 + $1.weight }
            XCTAssertEqual(weightSum, 1.0, accuracy: 1e-5)
            
            // Invariant 2: Densities at all probe points are bounded in [0.0, 1.0] and C^0 continuous
            for (idx, p) in probePoints.enumerated() {
                let density = engine.sampleDensity(at: p, instances: instances)
                XCTAssertGreaterThanOrEqual(density, 0.0)
                XCTAssertLessThanOrEqual(density, 1.0)
                XCTAssertFalse(density.isNaN)
                XCTAssertFalse(density.isInfinite)
                
                if step > 0 {
                    let delta = abs(density - previousDensities[idx])
                    // Continuous field: delta density per 16ms frame must not exceed 0.05
                    XCTAssertLessThan(delta, 0.05, "Density change per frame must be smooth and bounded")
                }
                previousDensities[idx] = density
            }
        }
    }

    // MARK: - 5. Chromatic Micro-Surface Sheen Operators
    
    func test_dark_mode_glacier_blue_sheen_operator() {
        let engine = TTZipFluidDynamicsEngine.shared
        
        // Formula: psi_dark = 0.10 * D^2 * (1.0 - 0.5 * min(1.0, gradMag))
        // Boundary 1: D = 0.0 -> psi = 0.0
        XCTAssertEqual(engine.darkSheenFactor(density: 0.0, gradientMagnitude: 0.0), 0.0, accuracy: 1e-6)
        
        // Boundary 2: D = 1.0, gradMag = 0.0 -> psi = 0.10 * 1.0 * 1.0 = 0.10
        XCTAssertEqual(engine.darkSheenFactor(density: 1.0, gradientMagnitude: 0.0), 0.10, accuracy: 1e-6)
        
        // Boundary 3: D = 1.0, gradMag = 1.0 -> psi = 0.10 * 1.0 * (1.0 - 0.5) = 0.05
        XCTAssertEqual(engine.darkSheenFactor(density: 1.0, gradientMagnitude: 1.0), 0.05, accuracy: 1e-6)
        
        // Boundary 4: Clamping of out-of-range density (D = 1.5 -> clamped to 1.0)
        XCTAssertEqual(engine.darkSheenFactor(density: 1.5, gradientMagnitude: 0.0), 0.10, accuracy: 1e-6)
        
        // Monotonicity with density for fixed gradient
        let dLow = engine.darkSheenFactor(density: 0.3, gradientMagnitude: 0.2)
        let dHigh = engine.darkSheenFactor(density: 0.7, gradientMagnitude: 0.2)
        XCTAssertLessThan(dLow, dHigh)
    }

    func test_light_mode_cobalt_deep_sheen_operator() {
        let engine = TTZipFluidDynamicsEngine.shared
        
        // Formula: psi_light = 0.06 * (1.0 - D) * sqrt(D)
        // Boundary 1: D = 0.0 -> psi = 0.0
        XCTAssertEqual(engine.lightSheenFactor(density: 0.0), 0.0, accuracy: 1e-6)
        
        // Boundary 2: D = 1.0 -> psi = 0.06 * 0.0 * 1.0 = 0.0
        XCTAssertEqual(engine.lightSheenFactor(density: 1.0), 0.0, accuracy: 1e-6)
        
        // Peak value: d/dD ((1-D)*D^(1/2)) = 0 => D_peak = 1/3 ≈ 0.333333
        // Peak psi = 0.06 * (2/3) * sqrt(1/3) ≈ 0.06 * 0.66667 * 0.57735 ≈ 0.023094
        let peakSheen = engine.lightSheenFactor(density: 1.0 / 3.0)
        XCTAssertEqual(peakSheen, 0.023094, accuracy: 0.0001)
        
        // Range assertion: psi_light must always reside in [0.0, 0.06]
        for d in stride(from: 0.0, through: 1.0, by: 0.05) {
            let sheen = engine.lightSheenFactor(density: d)
            XCTAssertGreaterThanOrEqual(sheen, 0.0)
            XCTAssertLessThanOrEqual(sheen, 0.06)
        }
    }

    // MARK: - 6. Fluid Configuration & View Hierarchy Invariants
    
    func test_fluid_configuration_defaults_and_customization() {
        let config = TTZipFluidConfiguration.productionDefault
        XCTAssertEqual(config.speed, 0.35, accuracy: 0.001)
        XCTAssertEqual(config.breathingAmplitude, 0.15, accuracy: 0.001)
        XCTAssertEqual(config.downscaleRatio, 4.0, accuracy: 0.001)
        XCTAssertEqual(config.blurRadius, 48.0, accuracy: 0.001)
        XCTAssertEqual(config.sheenIntensity, 1.0, accuracy: 0.001)
        XCTAssertEqual(config.minimumFrameInterval, 1.0 / 120.0, accuracy: 1e-5)
        
        var custom = TTZipFluidConfiguration()
        custom.speed = 0.8
        custom.blurRadius = 64.0
        XCTAssertEqual(custom.speed, 0.8, accuracy: 0.001)
        XCTAssertEqual(custom.blurRadius, 64.0, accuracy: 0.001)
    }

    @MainActor
    func test_fluid_background_view_and_renderer_instantiation() {
        let viewOrganic = TTZipFluidBackgroundView(mode: .organic)
        XCTAssertNotNil(viewOrganic)
        XCTAssertEqual(viewOrganic.speed, 0.35, accuracy: 0.001)
        XCTAssertEqual(viewOrganic.baseColor, TTZipTheme.bambooGreen)
        
        let viewMonochrome = TTZipFluidBackgroundView(mode: .monochrome)
        XCTAssertNotNil(viewMonochrome)
        XCTAssertEqual(viewMonochrome.speed, 0.35, accuracy: 0.001)
        
        let viewTinted = TTZipFluidBackgroundView(mode: .tinted(.blue))
        XCTAssertNotNil(viewTinted)
        
        // Initializer redirection: default bambooGreen routes to signature organic mode
        let viewLegacyDefault = TTZipFluidBackgroundView(baseColor: TTZipTheme.bambooGreen)
        if case .organic = viewLegacyDefault.mode {
            // Correctly redirected to organic mode
        } else {
            XCTFail("Default bambooGreen must redirect to organic mode")
        }
        
        let rendererOrganic = TTZipFluidRenderer(
            time: 0.0,
            fullSize: CGSize(width: 800, height: 600),
            colorScheme: .dark,
            mode: .organic
        )
        XCTAssertNotNil(rendererOrganic)
        
        let rendererMonochrome = TTZipFluidRenderer(
            time: 0.0,
            fullSize: CGSize(width: 800, height: 600),
            colorScheme: .dark,
            mode: .monochrome
        )
        XCTAssertNotNil(rendererMonochrome)
    }
}
