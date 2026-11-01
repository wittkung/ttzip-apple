// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreGraphics

// MARK: - Fluid Spring Simulation (Second-Order Damped Oscillator)

/// Spring physics configuration and analytical state solver for fluid motion transitions.
/// Solves the continuous differential equation: m * x'' + c * x' + k * x = 0.
public struct FluidSpring: Sendable, Equatable {
    /// Mass of the virtual fluid particle (kg, m > 0).
    public let mass: Double
    /// Spring stiffness coefficient (N/m, k > 0).
    public let stiffness: Double
    /// Dimensionless damping ratio (zeta = c / (2 * sqrt(m * k))).
    /// zeta < 1: underdamped (oscillatory decay)
    /// zeta = 1: critically damped (fastest return without overshoot)
    /// zeta > 1: overdamped (slow monotonic decay)
    public let dampingRatio: Double

    /// Undamped natural angular frequency: omega_0 = sqrt(k / m).
    public var naturalFrequency: Double {
        sqrt(stiffness / mass)
    }

    /// Damping coefficient: c = 2 * zeta * sqrt(m * k).
    public var dampingCoefficient: Double {
        2.0 * dampingRatio * sqrt(mass * stiffness)
    }

    public init(mass: Double = 1.0, stiffness: Double = 100.0, dampingRatio: Double = 1.0) {
        precondition(mass > 0.0, "Mass must be strictly positive.")
        precondition(stiffness > 0.0, "Stiffness must be strictly positive.")
        precondition(dampingRatio >= 0.0, "Damping ratio must be non-negative.")
        self.mass = mass
        self.stiffness = stiffness
        self.dampingRatio = dampingRatio
    }

    // MARK: - Standard Fluid Presets

    /// Smooth critically damped fluid transition (zeta = 1.0, no overshoot).
    public static let fluidDefault = FluidSpring(mass: 1.0, stiffness: 120.0, dampingRatio: 1.0)

    /// Responsive snappy spring for interactive fluid perturbations (zeta = 0.85).
    public static let snappy = FluidSpring(mass: 1.0, stiffness: 220.0, dampingRatio: 0.85)

    /// Organic resonant bounce with visible harmonic decay (zeta = 0.60).
    public static let bouncy = FluidSpring(mass: 1.0, stiffness: 80.0, dampingRatio: 0.60)

    // MARK: - Analytical Solver

    /// Evaluates the spring position x(t) and velocity v(t) given initial displacement and velocity.
    ///
    /// - Parameters:
    ///   - initialDisplacement: Initial offset from equilibrium x_0.
    ///   - initialVelocity: Initial particle velocity v_0.
    ///   - elapsedTime: Time delta elapsed from t = 0 (t >= 0).
    /// - Returns: A tuple `(position, velocity)` representing the exact physical state at time `elapsedTime`.
    public func solve(
        initialDisplacement x0: Double,
        initialVelocity v0: Double = 0.0,
        elapsedTime t: Double
    ) -> (position: Double, velocity: Double) {
        guard t > 0.0 else { return (x0, v0) }

        let omega0 = naturalFrequency
        let zeta = dampingRatio
        let gamma = zeta * omega0

        if abs(zeta - 1.0) < 1e-5 {
            // Critically Damped (zeta == 1)
            let decay = exp(-omega0 * t)
            let c1 = x0
            let c2 = v0 + omega0 * x0
            let x = decay * (c1 + c2 * t)
            let v = decay * (v0 - omega0 * c2 * t)
            return (x, v)
        } else if zeta < 1.0 {
            // Underdamped (zeta < 1): Oscillatory decaying motion
            let omegaD = omega0 * sqrt(1.0 - zeta * zeta)
            let decay = exp(-gamma * t)
            let cosTerm = cos(omegaD * t)
            let sinTerm = sin(omegaD * t)

            let x = decay * (x0 * cosTerm + ((v0 + gamma * x0) / omegaD) * sinTerm)
            let vCoeff = -(gamma * v0 + omega0 * omega0 * x0) / omegaD
            let v = decay * (v0 * cosTerm + vCoeff * sinTerm)
            return (x, v)
        } else {
            // Overdamped (zeta > 1): Dual exponential decay
            let mu = omega0 * sqrt(zeta * zeta - 1.0)
            let r1 = -gamma + mu
            let r2 = -gamma - mu

            let c1 = (v0 - r2 * x0) / (r1 - r2)
            let c2 = (r1 * x0 - v0) / (r1 - r2)

            let exp1 = exp(r1 * t)
            let exp2 = exp(r2 * t)

            let x = c1 * exp1 + c2 * exp2
            let v = c1 * r1 * exp1 + c2 * r2 * exp2
            return (x, v)
        }
    }

    /// Evaluates dynamic value transitioning from `from` to `to` over time `t`.
    public func interpolate(from: Double, to: Double, initialVelocity: Double = 0.0, elapsedTime t: Double) -> Double {
        let delta = from - to
        let (offset, _) = solve(initialDisplacement: delta, initialVelocity: initialVelocity, elapsedTime: t)
        return to + offset
    }

    /// Estimates the settling time required for amplitude to decay below `threshold * abs(x0)`.
    public func settlingTime(threshold: Double = 0.005) -> Double {
        guard threshold > 0.0 && threshold < 1.0 else { return 0.0 }
        let omega0 = naturalFrequency
        let zeta = dampingRatio

        if zeta < 1.0 {
            // Underdamped envelope decay: exp(-zeta * omega0 * t) <= threshold
            return -log(threshold) / (zeta * omega0)
        } else {
            // Critically damped / Overdamped dominant pole
            let dominantRoot = zeta == 1.0 ? omega0 : omega0 * (zeta - sqrt(zeta * zeta - 1.0))
            return -log(threshold) / dominantRoot
        }
    }
}

// MARK: - Fluid Cubic Bezier Timing Curves

/// Continuous cubic Bezier timing curve evaluator conforming to CSS transition-timing-function specifications.
public struct FluidCubicBezier: Sendable, Equatable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        precondition(x1 >= 0.0 && x1 <= 1.0, "Control point x1 must be within [0, 1].")
        precondition(x2 >= 0.0 && x2 <= 1.0, "Control point x2 must be within [0, 1].")
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    // MARK: - Presets

    /// Standard Ease-In curve (gradual start).
    public static let easeIn = FluidCubicBezier(x1: 0.42, y1: 0.0, x2: 1.0, y2: 1.0)

    /// Standard Ease-Out curve (gentle deceleration).
    public static let easeOut = FluidCubicBezier(x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0)

    /// Standard Ease-In-Out curve (symmetric acceleration and deceleration).
    public static let easeInOut = FluidCubicBezier(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0)

    /// Fluid organic timing curve optimized for viscous fluid flow transitions.
    public static let fluidOrganic = FluidCubicBezier(x1: 0.22, y1: 1.0, x2: 0.36, y2: 1.0)

    // MARK: - Evaluation

    /// Evaluates progress output y in [0, 1] for input normalized time progress x in [0, 1].
    public func solve(at x: Double) -> Double {
        let clampedX = min(1.0, max(0.0, x))
        if clampedX <= 0.0 { return 0.0 }
        if clampedX >= 1.0 { return 1.0 }

        // Find t for given x using Newton-Raphson iteration with bisection fallback
        var t = clampedX
        for _ in 0..<8 {
            let currentX = sampleX(t) - clampedX
            if abs(currentX) < 1e-6 {
                return sampleY(t)
            }
            let dx = sampleDerivativeX(t)
            if abs(dx) < 1e-6 { break }
            t -= currentX / dx
            t = min(1.0, max(0.0, t))
        }

        // Bisection fallback for extreme curvatures
        var t0: Double = 0.0
        var t1: Double = 1.0
        t = clampedX

        while t0 < t1 {
            let currentX = sampleX(t)
            if abs(currentX - clampedX) < 1e-6 {
                return sampleY(t)
            }
            if clampedX > currentX {
                t0 = t
            } else {
                t1 = t
            }
            t = (t1 - t0) * 0.5 + t0
        }

        return sampleY(t)
    }

    private func sampleX(_ t: Double) -> Double {
        // (1-t)^3 * 0 + 3(1-t)^2 * t * x1 + 3(1-t) * t^2 * x2 + t^3 * 1
        let oneMinusT = 1.0 - t
        return 3.0 * oneMinusT * oneMinusT * t * x1 + 3.0 * oneMinusT * t * t * x2 + t * t * t
    }

    private func sampleY(_ t: Double) -> Double {
        // (1-t)^3 * 0 + 3(1-t)^2 * t * y1 + 3(1-t) * t^2 * y2 + t^3 * 1
        let oneMinusT = 1.0 - t
        return 3.0 * oneMinusT * oneMinusT * t * y1 + 3.0 * oneMinusT * t * t * y2 + t * t * t
    }

    private func sampleDerivativeX(_ t: Double) -> Double {
        let oneMinusT = 1.0 - t
        return 3.0 * oneMinusT * oneMinusT * x1 + 6.0 * oneMinusT * t * (x2 - x1) + 3.0 * t * t * (1.0 - x2)
    }
}

// MARK: - Fluid Interpolation Operators

/// Mathematical operators for continuous fluid phase wrapping and smoothstep transitions.
public enum FluidInterpolation: Sendable {
    /// C^1 continuous Hermite smoothstep interpolation in [0, 1].
    public static func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
        guard edge0 < edge1 else { return 0.0 }
        let t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }

    /// C^2 continuous Ken Perlin smootherstep interpolation in [0, 1].
    public static func smootherstep(edge0: Double, edge1: Double, x: Double) -> Double {
        guard edge0 < edge1 else { return 0.0 }
        let t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
        return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
    }

    /// Wraps continuous phase angle `theta` into the primary periodic interval `[0, period)`.
    public static func wrapPhase(_ theta: Double, period: Double = 2.0 * .pi) -> Double {
        guard period > 0.0 else { return 0.0 }
        let remainder = theta.truncatingRemainder(dividingBy: period)
        return remainder < 0.0 ? remainder + period : remainder
    }

    /// Exponential smoothing decay toward target value (framerate-independent damping).
    ///
    /// - Parameters:
    ///   - current: Current dynamic value.
    ///   - target: Desired target value.
    ///   - lambda: Decay rate (higher = faster convergence).
    ///   - dt: Delta time in seconds.
    public static func expDecay(current: Double, target: Double, lambda: Double, dt: Double) -> Double {
        target + (current - target) * exp(-lambda * dt)
    }
}

// MARK: - Fluid Gesture & Boundary Kinematics

/// Apple WWDC & Emil Kowalski fluid gesture kinematics and boundary constraints.
/// Implements continuous non-linear rubber-banding, exponential momentum projection, and spring injection.
public enum FluidGesturePhysics: Sendable {

    /// Apple iOS standard continuous rubber-band boundary resistance formula.
    ///
    /// f(x, d, c) = (x * d * c) / (d + c * |x|)
    ///
    /// - Parameters:
    ///   - offset: Current continuous offset position.
    ///   - range: Allowable non-resisted translation range [min, max].
    ///   - dimension: Physical dimension of the viewport/container along the motion axis (d > 0).
    ///   - factor: Tangential resistance coefficient at boundary zero-point (c = 0.55 by default).
    /// - Returns: Clamped and smoothly damped continuous position coordinate.
    public static func rubberBandClamp(
        offset: Double,
        range: ClosedRange<Double>,
        dimension: Double,
        factor: Double = 0.55
    ) -> Double {
        precondition(dimension > 0.0, "Dimension must be strictly positive.")
        if offset < range.lowerBound {
            let overscroll = range.lowerBound - offset
            let damped = (overscroll * dimension * factor) / (dimension + factor * overscroll)
            return range.lowerBound - damped
        } else if offset > range.upperBound {
            let overscroll = offset - range.upperBound
            let damped = (overscroll * dimension * factor) / (dimension + factor * overscroll)
            return range.upperBound + damped
        }
        return offset
    }

    /// Apple WWDC continuous exponential decay momentum projection model.
    ///
    /// project(v, d) = (v / 1000) * (d / (1 - d))
    ///
    /// - Parameters:
    ///   - initialOffset: Starting position coordinate when gesture was released.
    ///   - velocity: Instantaneous gesture release velocity in points/second.
    ///   - decelerationRate: Continuous friction factor (0.998 for fluid scrolling, 0.99 for snappy).
    /// - Returns: Projected rest position coordinate without boundary collisions.
    public static func projectMomentum(
        initialOffset: Double,
        velocity: Double,
        decelerationRate: Double = 0.998
    ) -> Double {
        guard decelerationRate > 0.0 && decelerationRate < 1.0 else { return initialOffset }
        let projectedDelta = (velocity / 1000.0) * (decelerationRate / (1.0 - decelerationRate))
        return initialOffset + projectedDelta
    }

    /// Computes normalized initial velocity for injection into SwiftUI spring animations.
    ///
    /// v_rel = v_gesture / (x_target - x_current)
    ///
    /// - Parameters:
    ///   - gestureVelocity: Release velocity in points/second.
    ///   - currentOffset: Current starting offset.
    ///   - targetOffset: Final settling offset.
    /// - Returns: Dimensionless relative velocity vector for spring interpolation.
    public static func relativeVelocity(
        gestureVelocity: Double,
        currentOffset: Double,
        targetOffset: Double
    ) -> Double {
        let delta = targetOffset - currentOffset
        guard abs(delta) > 1e-4 else { return 0.0 }
        return gestureVelocity / delta
    }

    // MARK: - CGFloat Overloads for SwiftUI & AppKit Coordinate Geometry

    /// CGFloat overload for continuous rubber-band boundary resistance.
    public static func rubberBandClamp(
        offset: CGFloat,
        range: ClosedRange<CGFloat>,
        dimension: CGFloat,
        factor: CGFloat = 0.55
    ) -> CGFloat {
        CGFloat(rubberBandClamp(
            offset: Double(offset),
            range: Double(range.lowerBound)...Double(range.upperBound),
            dimension: Double(dimension),
            factor: Double(factor)
        ))
    }

    /// CGFloat overload for continuous exponential decay momentum projection.
    public static func projectMomentum(
        initialOffset: CGFloat,
        velocity: CGFloat,
        decelerationRate: CGFloat = 0.998
    ) -> CGFloat {
        CGFloat(projectMomentum(
            initialOffset: Double(initialOffset),
            velocity: Double(velocity),
            decelerationRate: Double(decelerationRate)
        ))
    }

    /// CGFloat overload for normalized spring velocity injection.
    public static func relativeVelocity(
        gestureVelocity: CGFloat,
        currentOffset: CGFloat,
        targetOffset: CGFloat
    ) -> CGFloat {
        CGFloat(relativeVelocity(
            gestureVelocity: Double(gestureVelocity),
            currentOffset: Double(currentOffset),
            targetOffset: Double(targetOffset)
        ))
    }
}
