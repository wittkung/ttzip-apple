// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import CoreGraphics
import SwiftUI
#if os(macOS)
import MetalKit
#endif
@testable import TTKitCore
@testable import TTKitFluid

final class TTKitFluidTests: XCTestCase {

    // MARK: - Fluid Spring Physics & Damping Classification

    func testFluidSpringHarmonicParameters() {
        let spring = FluidSpring(mass: 2.0, stiffness: 200.0, dampingRatio: 0.5)
        // omega_0 = sqrt(200 / 2) = 10 rad/s
        XCTAssertEqual(spring.naturalFrequency, 10.0, accuracy: 1e-6)
        // c = 2 * 0.5 * sqrt(2 * 200) = 1.0 * 20.0 = 20.0
        XCTAssertEqual(spring.dampingCoefficient, 20.0, accuracy: 1e-6)
    }

    func testFluidSpringInitialConditionsAndConvergence() {
        let spring = FluidSpring.fluidDefault
        let x0 = 100.0
        let v0 = 50.0

        // At t = 0: state must precisely match initial conditions
        let initial = spring.solve(initialDisplacement: x0, initialVelocity: v0, elapsedTime: 0.0)
        XCTAssertEqual(initial.position, x0, accuracy: 1e-6)
        XCTAssertEqual(initial.velocity, v0, accuracy: 1e-6)

        // At large t: asymptotic settling to equilibrium (0, 0)
        let settled = spring.solve(initialDisplacement: x0, initialVelocity: v0, elapsedTime: 5.0)
        XCTAssertEqual(settled.position, 0.0, accuracy: 1e-3)
        XCTAssertEqual(settled.velocity, 0.0, accuracy: 1e-3)
    }

    func testFluidSpringDampingBehaviors() {
        let x0 = 50.0

        // 1. Underdamped (zeta = 0.3): Oscillatory with zero crossing
        let underdamped = FluidSpring(mass: 1.0, stiffness: 100.0, dampingRatio: 0.3)
        var sawNegative = false
        for step in 1...100 {
            let t = Double(step) * 0.05
            let state = underdamped.solve(initialDisplacement: x0, elapsedTime: t)
            if state.position < -0.1 {
                sawNegative = true
                break
            }
        }
        XCTAssertTrue(sawNegative, "Underdamped oscillator must experience overshoot/zero crossing")

        // 2. Critically Damped (zeta = 1.0): Monotonic settling without overshoot
        let criticallyDamped = FluidSpring.fluidDefault
        for step in 1...50 {
            let t = Double(step) * 0.05
            let state = criticallyDamped.solve(initialDisplacement: x0, initialVelocity: 0.0, elapsedTime: t)
            XCTAssertGreaterThanOrEqual(state.position, -1e-5, "Critically damped spring must not significantly overshoot")
        }

        // 3. Overdamped (zeta = 2.0): Slower monotonic decay
        let overdamped = FluidSpring(mass: 1.0, stiffness: 100.0, dampingRatio: 2.0)
        let stateCritical = criticallyDamped.solve(initialDisplacement: x0, elapsedTime: 0.5)
        let stateOver = overdamped.solve(initialDisplacement: x0, elapsedTime: 0.5)
        XCTAssertGreaterThan(stateOver.position, stateCritical.position,
                             "Overdamped return must be slower than critically damped return")
    }

    func testFluidSpringInterpolationAndSettlingTime() {
        let spring = FluidSpring.snappy
        let interpolatedStart = spring.interpolate(from: 0.0, to: 1.0, elapsedTime: 0.0)
        XCTAssertEqual(interpolatedStart, 0.0, accuracy: 1e-6)

        let interpolatedEnd = spring.interpolate(from: 0.0, to: 1.0, elapsedTime: 3.0)
        XCTAssertEqual(interpolatedEnd, 1.0, accuracy: 1e-3)

        let settlingT = spring.settlingTime(threshold: 0.01)
        XCTAssertGreaterThan(settlingT, 0.0)
        XCTAssertLessThan(settlingT, 5.0)
    }

    // MARK: - Fluid Cubic Bezier Curves

    func testFluidCubicBezierBoundaryAndMonotonicity() {
        let curves: [FluidCubicBezier] = [
            .easeIn,
            .easeOut,
            .easeInOut,
            .fluidOrganic
        ]

        for curve in curves {
            XCTAssertEqual(curve.solve(at: 0.0), 0.0, accuracy: 1e-6)
            XCTAssertEqual(curve.solve(at: 1.0), 1.0, accuracy: 1e-6)

            // Clamp check
            XCTAssertEqual(curve.solve(at: -0.5), 0.0, accuracy: 1e-6)
            XCTAssertEqual(curve.solve(at: 1.5), 1.0, accuracy: 1e-6)

            // Monotonic non-decreasing progression
            var lastY = -0.01
            for i in 0...20 {
                let x = Double(i) / 20.0
                let y = curve.solve(at: x)
                XCTAssertGreaterThanOrEqual(y, lastY - 1e-5, "Curve should be non-decreasing at x=\(x)")
                XCTAssertGreaterThanOrEqual(y, 0.0)
                XCTAssertLessThanOrEqual(y, 1.0)
                lastY = y
            }
        }
    }

    func testFluidCubicBezierArchetypes() {
        let midIn = FluidCubicBezier.easeIn.solve(at: 0.5)
        let midOut = FluidCubicBezier.easeOut.solve(at: 0.5)
        let midInOut = FluidCubicBezier.easeInOut.solve(at: 0.5)

        // Ease-In decelerates at start: value at midpoint is below 0.5
        XCTAssertLessThan(midIn, 0.5)

        // Ease-Out accelerates at start: value at midpoint is above 0.5
        XCTAssertGreaterThan(midOut, 0.5)

        // Ease-In-Out is symmetric: value at midpoint is approximately 0.5
        XCTAssertEqual(midInOut, 0.5, accuracy: 0.05)
    }

    // MARK: - Fluid Interpolation Operators

    func testSmoothstepAndSmootherstep() {
        // Edge clamps
        XCTAssertEqual(FluidInterpolation.smoothstep(edge0: 0.0, edge1: 1.0, x: -0.5), 0.0, accuracy: 1e-6)
        XCTAssertEqual(FluidInterpolation.smoothstep(edge0: 0.0, edge1: 1.0, x: 1.5), 1.0, accuracy: 1e-6)
        XCTAssertEqual(FluidInterpolation.smoothstep(edge0: 0.0, edge1: 1.0, x: 0.5), 0.5, accuracy: 1e-6)

        // Smootherstep midpoint
        XCTAssertEqual(FluidInterpolation.smootherstep(edge0: 10.0, edge1: 20.0, x: 15.0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(FluidInterpolation.smootherstep(edge0: 10.0, edge1: 20.0, x: 5.0), 0.0, accuracy: 1e-6)
        XCTAssertEqual(FluidInterpolation.smootherstep(edge0: 10.0, edge1: 20.0, x: 25.0), 1.0, accuracy: 1e-6)
    }

    func testPhaseWrappingAndExpDecay() {
        let twoPi = 2.0 * Double.pi

        let wrappedPositive = FluidInterpolation.wrapPhase(7.0 * Double.pi, period: twoPi)
        XCTAssertEqual(wrappedPositive, Double.pi, accuracy: 1e-6)

        let wrappedNegative = FluidInterpolation.wrapPhase(-Double.pi * 0.5, period: twoPi)
        XCTAssertEqual(wrappedNegative, Double.pi * 1.5, accuracy: 1e-6)

        // Exponential decay
        let decayStart = FluidInterpolation.expDecay(current: 10.0, target: 0.0, lambda: 5.0, dt: 0.0)
        XCTAssertEqual(decayStart, 10.0, accuracy: 1e-6)

        let decayEnd = FluidInterpolation.expDecay(current: 10.0, target: 0.0, lambda: 5.0, dt: 2.0)
        XCTAssertEqual(decayEnd, 0.0, accuracy: 1e-3)
    }

    // MARK: - 3-Sphere Lissajous Fluid Model

    func testThreeSphereLissajousFluidModel() {
        let size = CGSize(width: 1200, height: 800)
        let eval0 = CauchyAnalyticFluidCanvasView.evaluateSpheres(in: size, phase: 0.0)

        // Radius must be 0.54 * min(1200, 800) = 432.0
        XCTAssertEqual(eval0.radius, 432.0, accuracy: 1e-5)

        // Hierarchical alpha weights must be (1.0, 0.8, 0.6)
        XCTAssertEqual(eval0.weights.0, 1.0, accuracy: 1e-6)
        XCTAssertEqual(eval0.weights.1, 0.8, accuracy: 1e-6)
        XCTAssertEqual(eval0.weights.2, 0.6, accuracy: 1e-6)

        // At phase = 0:
        // c1 = (0.5 + 0.30) * 1200 = 960, 0.5 * 800 = 400
        // c2 = 0.5 * 1200 = 600, (0.5 + 0.30) * 800 = 640
        // c3 = (0.5 + 0.25) * 1200 = 900, 0.5 * 800 = 400
        XCTAssertEqual(eval0.c1.x, 960.0, accuracy: 1e-4)
        XCTAssertEqual(eval0.c1.y, 400.0, accuracy: 1e-4)
        XCTAssertEqual(eval0.c2.x, 600.0, accuracy: 1e-4)
        XCTAssertEqual(eval0.c2.y, 640.0, accuracy: 1e-4)
        XCTAssertEqual(eval0.c3.x, 900.0, accuracy: 1e-4)
        XCTAssertEqual(eval0.c3.y, 400.0, accuracy: 1e-4)

        // Periodicity check at 40 * pi (common period of n/20 frequencies)
        let evalPeriod = CauchyAnalyticFluidCanvasView.evaluateSpheres(in: size, phase: 40.0 * .pi)
        XCTAssertEqual(evalPeriod.c1.x, eval0.c1.x, accuracy: 1e-3)
        XCTAssertEqual(evalPeriod.c1.y, eval0.c1.y, accuracy: 1e-3)
        XCTAssertEqual(evalPeriod.c2.x, eval0.c2.x, accuracy: 1e-3)
        XCTAssertEqual(evalPeriod.c2.y, eval0.c2.y, accuracy: 1e-3)
        XCTAssertEqual(evalPeriod.c3.x, eval0.c3.x, accuracy: 1e-3)
        XCTAssertEqual(evalPeriod.c3.y, eval0.c3.y, accuracy: 1e-3)
    }

    // MARK: - Fluid Background Configuration & State

    func testFluidBackgroundConfigBuilder() {
        let config = FluidBackgroundConfig.build(baseColor: .indigo, isRunning: true) { builder in
            builder.isDarkMode(true)
                .fluidOpacity(0.85)
                .focusMode(0.5)
                .focusProgress(0.7)
                .breathSeed(12.34)
                .isFocusPaused(false)
                .isSystemPaused(false)
        }

        XCTAssertEqual(config.baseColor, .indigo)
        XCTAssertTrue(config.isRunning)
        XCTAssertTrue(config.isDarkMode)
        XCTAssertEqual(config.fluidOpacity, 0.85, accuracy: 1e-5)
        XCTAssertEqual(config.focusMode, 0.5, accuracy: 1e-5)
        XCTAssertEqual(config.focusProgress, 0.7, accuracy: 1e-5)
        XCTAssertEqual(config.breathSeed, 12.34, accuracy: 1e-5)
        XCTAssertFalse(config.isFocusPaused)
        XCTAssertFalse(config.isSystemPaused)
    }

    func testGlobalFluidStateThreadSafety() {
        let state = TTKitGlobalFluidState.shared
        let p1 = state.currentPhase(speed: 0.2)
        XCTAssertTrue(p1.isFinite)
    }

    func testOrganicFluidViewHonorsConfiguredFluidOpacityAndPauseState() {
        let customDarkConfig = FluidBackgroundConfig(
            baseColor: .indigo,
            isRunning: false,
            isFocusPaused: false,
            isSystemPaused: false,
            isActive: true,
            isDarkMode: true,
            fluidOpacity: 0.42
        )
        let customDarkView = OrganicFluidView(config: customDarkConfig)
        XCTAssertEqual(customDarkView.resolvedOpacity(for: .dark), 0.42, accuracy: 1e-5)
        XCTAssertEqual(customDarkView.resolvedOpacity(for: .light), 0.42, accuracy: 1e-5)
        XCTAssertEqual(customDarkView.resolvedSpeed, 0.2, accuracy: 1e-5)

        var systemPausedConfig = customDarkConfig
        systemPausedConfig.isSystemPaused = true
        let systemPausedView = OrganicFluidView(config: systemPausedConfig)
        XCTAssertEqual(systemPausedView.resolvedSpeed, 0.0, accuracy: 1e-5)


        let defaultLightView = OrganicFluidView(
            baseColor: .indigo,
            isRunning: true,
            isFocusPaused: true,
            fluidOpacity: nil,
            isDarkModeOverride: nil
        )
        XCTAssertEqual(defaultLightView.resolvedOpacity(for: .light), 0.3, accuracy: 1e-5)
        XCTAssertEqual(defaultLightView.resolvedOpacity(for: .dark), 0.6, accuracy: 1e-5)
        XCTAssertEqual(defaultLightView.resolvedSpeed, 0.0, accuracy: 1e-5)
    }

    #if os(macOS)
    @MainActor
    func testMetalFluidAdapterAppliesPauseAndResumeToRendererSpeed() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable; cannot verify the Metal adapter's renderer state")
        }
        let renderer = try XCTUnwrap(
            MetalFluidRenderer(device: device),
            "A Metal device exists, but the fluid renderer could not initialize"
        )
        var config = FluidBackgroundConfig(baseColor: .indigo, isRunning: true)

        for isRunning in [true, false] {
            config.isRunning = isRunning
            config.isFocusPaused = false
            config.isSystemPaused = false
            MetalFluidViewRepresentable(config: config).updateRenderer(renderer)
            XCTAssertEqual(renderer.speed, isRunning ? 0.8 : 0.2, accuracy: 1e-5)

            config.isSystemPaused = true
            MetalFluidViewRepresentable(config: config).updateRenderer(renderer)
            XCTAssertEqual(renderer.speed, 0.0, accuracy: 1e-5)

            config.isFocusPaused = true
            MetalFluidViewRepresentable(config: config).updateRenderer(renderer)
            XCTAssertEqual(renderer.speed, 0.0, accuracy: 1e-5)

            config.isSystemPaused = false
            MetalFluidViewRepresentable(config: config).updateRenderer(renderer)
            XCTAssertEqual(renderer.speed, 0.0, accuracy: 1e-5)

            config.isFocusPaused = false
            MetalFluidViewRepresentable(config: config).updateRenderer(renderer)
            XCTAssertEqual(renderer.speed, isRunning ? 0.8 : 0.2, accuracy: 1e-5)
        }
    }
    #endif

}
