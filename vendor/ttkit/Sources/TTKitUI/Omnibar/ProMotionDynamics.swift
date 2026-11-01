// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreGraphics

// MARK: - ProMotion 120Hz Dynamics Configuration

/// Physical spring configuration tuned for 120Hz Apple ProMotion displays.
/// Solves the continuous second-order differential equation:
/// m * x''(t) + c * x'(t) + k * x(t) = 0
/// with sub-millisecond precision.
public struct ProMotionSpringConfiguration: Sendable, Hashable {
    /// Dimensionless damping ratio (zeta).
    /// - zeta = 1.0: Critically damped (zero overshoot, boundary convergence).
    /// - zeta = 0.82: Underdamped (calibrated micro-interaction elastic feedback).
    public let dampingRatio: Double

    /// Response duration in seconds (T = 2 * pi / omega_0).
    public let responseDuration: Double

    /// Virtual particle mass (kg, normalized to 1.0).
    public let mass: Double

    /// Undamped natural angular frequency: omega_0 = 2 * pi / T (rad/s).
    public var naturalFrequency: Double {
        guard responseDuration > 0.0 else { return 0.0 }
        return (2.0 * Double.pi) / responseDuration
    }

    /// Spring stiffness: k = mass * omega_0^2 (N/m).
    public var stiffness: Double {
        let omega0 = naturalFrequency
        return mass * omega0 * omega0
    }

    /// Damping coefficient: c = 2 * zeta * sqrt(mass * stiffness) = 2 * zeta * mass * omega_0 (N·s/m).
    public var dampingCoefficient: Double {
        2.0 * dampingRatio * mass * naturalFrequency
    }

    public init(dampingRatio: Double = 1.0, responseDuration: Double = 0.35, mass: Double = 1.0) {
        precondition(dampingRatio >= 0.0, "Damping ratio must be non-negative.")
        precondition(responseDuration > 0.0, "Response duration must be strictly positive.")
        precondition(mass > 0.0, "Mass must be strictly positive.")
        self.dampingRatio = dampingRatio
        self.responseDuration = responseDuration
        self.mass = mass
    }

    // MARK: - Standard Presets

    /// 120Hz ProMotion critically damped preset for layout boundary convergence (zeta = 1.0, T = 0.35s).
    public static let critical120Hz = ProMotionSpringConfiguration(
        dampingRatio: 1.0,
        responseDuration: 0.35,
        mass: 1.0
    )

    /// 120Hz ProMotion elastic feedback preset for micro-interactions (zeta = 0.82, T = 0.28s).
    public static let elastic120Hz = ProMotionSpringConfiguration(
        dampingRatio: 0.82,
        responseDuration: 0.28,
        mass: 1.0
    )

    /// High-frequency Omnibar command palette transition preset (zeta = 0.80, T = 0.16s).
    /// Complies with the 160ms High-Frequency Zero-Animation Invariant.
    public static let snappyOmnibar = ProMotionSpringConfiguration(
        dampingRatio: 0.80,
        responseDuration: 0.16,
        mass: 1.0
    )

    /// Large modal sheet transition preset (zeta = 0.84, T = 0.50s).
    public static let fluidSheet = ProMotionSpringConfiguration(
        dampingRatio: 0.84,
        responseDuration: 0.50,
        mass: 1.0
    )
}

// MARK: - Dynamic Phase State

/// Phase space state tracking position, velocity, and energy at sub-millisecond precision.
public struct DynamicPhaseState: Sendable, Equatable {
    /// Instantaneous displacement from equilibrium x(t).
    public let displacement: Double

    /// Instantaneous velocity v(t) = x'(t).
    public let velocity: Double

    /// Instantaneous acceleration a(t) = x''(t).
    public let acceleration: Double

    /// Elapsed time since motion start in seconds.
    public let elapsedTime: Double

    /// Phase angle in normalized phase space: theta = atan2(v / omega_0, x).
    public let phaseAngle: Double

    /// Phase trajectory radius: R = sqrt(x^2 + (v / omega_0)^2).
    public let phaseRadius: Double

    /// Instantaneous mechanical energy: E = 0.5 * k * x^2 + 0.5 * m * v^2.
    public let totalEnergy: Double

    /// Indicates whether the oscillator has settled below physical threshold.
    public let isSettled: Bool

    public init(
        displacement: Double,
        velocity: Double,
        acceleration: Double,
        elapsedTime: Double,
        phaseAngle: Double,
        phaseRadius: Double,
        totalEnergy: Double,
        isSettled: Bool
    ) {
        self.displacement = displacement
        self.velocity = velocity
        self.acceleration = acceleration
        self.elapsedTime = elapsedTime
        self.phaseAngle = phaseAngle
        self.phaseRadius = phaseRadius
        self.totalEnergy = totalEnergy
        self.isSettled = isSettled
    }
}

// MARK: - ProMotion Dynamics Solver

/// Analytical and frame-stepped physical solver for 120Hz Apple ProMotion interfaces.
public enum ProMotionDynamicsSolver: Sendable {
    /// Nominal frame interval for 120Hz ProMotion displays (8.333333 ms).
    public static let proMotion120HzDeltaTime: Double = 1.0 / 120.0

    /// Threshold below which an oscillation is deemed settled (0.001 points).
    public static let settlingDisplacementThreshold: Double = 0.001

    /// Velocity threshold for motion settling (0.001 points / second).
    public static let settlingVelocityThreshold: Double = 0.001

    // MARK: - Analytical Closed-Form Evaluation

    /// Evaluates the exact physical phase state at time `elapsedTime` in closed-form.
    ///
    /// - Parameters:
    ///   - initialDisplacement: Initial offset from equilibrium x_0.
    ///   - initialVelocity: Initial particle velocity v_0.
    ///   - elapsedTime: Time delta elapsed in seconds (t >= 0).
    ///   - configuration: Physical spring parameters.
    /// - Returns: Complete `DynamicPhaseState` at timestamp `elapsedTime`.
    public static func evaluate(
        initialDisplacement x0: Double,
        initialVelocity v0: Double = 0.0,
        elapsedTime t: Double,
        configuration: ProMotionSpringConfiguration
    ) -> DynamicPhaseState {
        guard t > 0.0 else {
            let omega0 = configuration.naturalFrequency
            let k = configuration.stiffness
            let m = configuration.mass
            let a0 = -(k * x0 + configuration.dampingCoefficient * v0) / m
            let radius = sqrt(x0 * x0 + (omega0 > 0 ? pow(v0 / omega0, 2) : 0))
            let angle = omega0 > 0 ? atan2(v0 / omega0, x0) : 0
            let energy = 0.5 * k * x0 * x0 + 0.5 * m * v0 * v0
            let settled = abs(x0) < settlingDisplacementThreshold && abs(v0) < settlingVelocityThreshold

            return DynamicPhaseState(
                displacement: x0,
                velocity: v0,
                acceleration: a0,
                elapsedTime: 0.0,
                phaseAngle: angle,
                phaseRadius: radius,
                totalEnergy: energy,
                isSettled: settled
            )
        }

        let omega0 = configuration.naturalFrequency
        let zeta = configuration.dampingRatio
        let gamma = zeta * omega0
        let k = configuration.stiffness
        let m = configuration.mass

        let x: Double
        let v: Double

        if abs(zeta - 1.0) < 1e-6 {
            // Case 1: Critically Damped (zeta == 1.0)
            let decay = exp(-omega0 * t)
            let c1 = x0
            let c2 = v0 + omega0 * x0
            x = decay * (c1 + c2 * t)
            v = decay * (v0 - omega0 * c2 * t)
        } else if zeta < 1.0 {
            // Case 2: Underdamped (0 <= zeta < 1.0)
            let omegaD = omega0 * sqrt(1.0 - zeta * zeta)
            let decay = exp(-gamma * t)
            let cosTerm = cos(omegaD * t)
            let sinTerm = sin(omegaD * t)

            x = decay * (x0 * cosTerm + ((v0 + gamma * x0) / omegaD) * sinTerm)
            let vCoeff = -(gamma * v0 + omega0 * omega0 * x0) / omegaD
            v = decay * (v0 * cosTerm + vCoeff * sinTerm)
        } else {
            // Case 3: Overdamped (zeta > 1.0)
            let mu = omega0 * sqrt(zeta * zeta - 1.0)
            let r1 = -gamma + mu
            let r2 = -gamma - mu

            let c1 = (v0 - r2 * x0) / (r1 - r2)
            let c2 = (r1 * x0 - v0) / (r1 - r2)

            let exp1 = exp(r1 * t)
            let exp2 = exp(r2 * t)

            x = c1 * exp1 + c2 * exp2
            v = c1 * r1 * exp1 + c2 * r2 * exp2
        }

        // Acceleration from Newton's Second Law: a = -(k * x + c * v) / m
        let a = -(k * x + configuration.dampingCoefficient * v) / m
        let phaseRad = sqrt(x * x + (omega0 > 0 ? pow(v / omega0, 2) : 0))
        let phaseAng = omega0 > 0 ? atan2(v / omega0, x) : 0
        let energy = 0.5 * k * x * x + 0.5 * m * v * v
        let settled = abs(x) < settlingDisplacementThreshold && abs(v) < settlingVelocityThreshold

        return DynamicPhaseState(
            displacement: x,
            velocity: v,
            acceleration: a,
            elapsedTime: t,
            phaseAngle: phaseAng,
            phaseRadius: phaseRad,
            totalEnergy: energy,
            isSettled: settled
        )
    }

    // MARK: - Discrete 120Hz Step Simulation

    /// Simulates a single ProMotion 120Hz discrete frame step.
    ///
    /// - Parameters:
    ///   - currentDisplacement: Displacement before frame step.
    ///   - currentVelocity: Velocity before frame step.
    ///   - deltaTime: Frame interval (defaults to 1/120s).
    ///   - configuration: Spring configuration.
    /// - Returns: Updated phase state after deltaTime.
    public static func step(
        currentDisplacement: Double,
        currentVelocity: Double,
        deltaTime: Double = proMotion120HzDeltaTime,
        configuration: ProMotionSpringConfiguration
    ) -> DynamicPhaseState {
        evaluate(
            initialDisplacement: currentDisplacement,
            initialVelocity: currentVelocity,
            elapsedTime: deltaTime,
            configuration: configuration
        )
    }

    // MARK: - Kinematic Utilities

    /// Computes Apple HIG logarithmic rubber-band resistance for boundary overscroll.
    /// Formula: R(x, d, c) = (x * d * c) / (d + c * |x|)
    public static func rubberBandResistance(
        offset: Double,
        dimension: Double = 300.0,
        coefficient: Double = 0.55
    ) -> Double {
        guard dimension > 0 else { return 0.0 }
        let absOffset = abs(offset)
        let resistance = (absOffset * dimension * coefficient) / (dimension + coefficient * absOffset)
        return offset < 0 ? -resistance : resistance
    }

    /// Computes Apple exponential momentum projection from initial release velocity.
    /// Formula: P(v, d) = (v / 1000) * (d / (1 - d))
    public static func projectMomentum(
        initialVelocity: Double,
        decelerationRate: Double = 0.998
    ) -> Double {
        guard decelerationRate > 0 && decelerationRate < 1.0 else { return 0.0 }
        return (initialVelocity / 1000.0) * (decelerationRate / (1.0 - decelerationRate))
    }

    /// Evaluates whether a user control satisfies the 160ms High-Frequency Invariant.
    public static func respectsHighFrequencyGate(responseDuration: Double) -> Bool {
        responseDuration <= 0.160
    }
}
