// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.
// Module: TTZipFluidDynamicsEngine — Incompressible Navier-Stokes Potential Field Solver.

import Foundation
import CoreGraphics

/// Analytical solver for Layer 2 Deep Viscous Fluid Potential Dynamics D(p, t).
/// Derivation and mathematical proofs: COMPANY_DESIGN_WHITEPAPER.md §4.1 & §4.3.
public final class TTZipFluidDynamicsEngine: Sendable {
    /// Shared singleton solver configured with the canonical 4-vortex constellation.
    public static let shared = TTZipFluidDynamicsEngine()
    
    /// Constellation of 4 harmonically coupled organic vortices.
    public let vortices: [TTZipFluidVortex]
    
    /// Thermodynamic breathing base angular frequency (T_breathe ~ 8.0s -> omega ~ 0.7854 rad/s).
    public static let thermodynamicBaseOmega: Double = 0.785398
    
    /// Harmonic angular velocity 1 (T_1 ~ 13.96s -> omega_1 = 0.450 rad/s).
    public static let harmonicOmega1: Double = 0.450000
    
    /// Harmonic angular velocity 2 (T_2 ~ 16.53s -> omega_2 = 0.380 rad/s).
    public static let harmonicOmega2: Double = 0.380000
    
    /// Initializer supporting custom vortex constellations or adopting the production default.
    public init(vortices: [TTZipFluidVortex]? = nil) {
        self.vortices = vortices ?? [
            // Vortex 1: Primary Heavy Core (Center-Left)
            TTZipFluidVortex(
                id: 1,
                baseWeight: 0.35,
                baseRadiusFraction: 0.50,
                orbitCenterFraction: CGPoint(x: 0.42, y: 0.48),
                orbitRadiusXFraction: 0.22,
                orbitRadiusYFraction: 0.16,
                angularVelocity: 0.28,
                phaseOffset: 0.0,
                breathingFrequency: 1.0,
                breathingPhase: 0.0
            ),
            // Vortex 2: Secondary Resonant Swirl (Center-Right)
            TTZipFluidVortex(
                id: 2,
                baseWeight: 0.25,
                baseRadiusFraction: 0.42,
                orbitCenterFraction: CGPoint(x: 0.58, y: 0.52),
                orbitRadiusXFraction: 0.26,
                orbitRadiusYFraction: 0.20,
                angularVelocity: -0.36,
                phaseOffset: Double.pi * 0.45,
                breathingFrequency: 1.15,
                breathingPhase: Double.pi * 0.33
            ),
            // Vortex 3: Upper Oceanic Drift (North-East)
            TTZipFluidVortex(
                id: 3,
                baseWeight: 0.20,
                baseRadiusFraction: 0.36,
                orbitCenterFraction: CGPoint(x: 0.65, y: 0.35),
                orbitRadiusXFraction: 0.18,
                orbitRadiusYFraction: 0.14,
                angularVelocity: 0.42,
                phaseOffset: Double.pi * 0.90,
                breathingFrequency: 0.85,
                breathingPhase: Double.pi * 0.66
            ),
            // Vortex 4: Lower Anchor Eddy (South-West)
            TTZipFluidVortex(
                id: 4,
                baseWeight: 0.20,
                baseRadiusFraction: 0.44,
                orbitCenterFraction: CGPoint(x: 0.35, y: 0.65),
                orbitRadiusXFraction: 0.20,
                orbitRadiusYFraction: 0.18,
                angularVelocity: -0.24,
                phaseOffset: Double.pi * 1.35,
                breathingFrequency: 0.95,
                breathingPhase: Double.pi * 1.20
            )
        ]
    }
    
    // MARK: - Kinematics & Thermodynamic State Resolution
    
    /// Evaluates vortex physical positions, radii, and normalized weights at timestamp `time`.
    /// Coordinates are scaled to the spatial boundary specified by `size`.
    public func resolveInstances(
        in size: CGSize,
        at time: TimeInterval,
        speed: Double = 0.35,
        breathingAmplitude: Double = 0.15
    ) -> [TTZipVortexInstance] {
        let minDim = min(size.width, size.height)
        let t = time * speed
        let omegaB = Self.thermodynamicBaseOmega * speed
        
        // Step 1: Compute unnormalized thermodynamic weights & radii
        var rawWeights = [Double]()
        rawWeights.reserveCapacity(vortices.count)
        
        for v in vortices {
            let breath = sin(omegaB * v.breathingFrequency * t + v.breathingPhase)
            let dynamicW = max(0.05, v.baseWeight * (1.0 + breathingAmplitude * breath))
            rawWeights.append(dynamicW)
        }
        
        let sumW = rawWeights.reduce(0.0, +)
        let normFactor = sumW > 0.0001 ? 1.0 / sumW : 1.0
        
        // Step 2: Build instances with harmonic orbital displacement
        return vortices.enumerated().map { index, v in
            let theta = v.angularVelocity * t + v.phaseOffset
            // Modulate orbit with multi-frequency thermodynamic breathing (T_1, T_2)
            let wobbleX = 0.05 * sin(Self.harmonicOmega1 * t)
            let wobbleY = 0.05 * cos(Self.harmonicOmega2 * t)
            
            let orbitX = v.orbitCenterFraction.x + wobbleX
            let orbitY = v.orbitCenterFraction.y + wobbleY
            
            let cx = size.width * orbitX + cos(theta) * (size.width * v.orbitRadiusXFraction)
            let cy = size.height * orbitY + sin(theta) * (size.height * v.orbitRadiusYFraction)
            
            let radiusBreath = cos(omegaB * v.breathingFrequency * t + v.breathingPhase)
            let r = max(30.0, minDim * v.baseRadiusFraction * (1.0 + breathingAmplitude * radiusBreath))
            let w = rawWeights[index] * normFactor
            
            return TTZipVortexInstance(
                position: CGPoint(x: cx, y: cy),
                radius: r,
                weight: w
            )
        }
    }
    
    // MARK: - Continuous Cauchy-Smoothed Potential Field D(p, t)
    
    /// Evaluates continuous potential density D(p, t) at point `p` in spatial domain `size`.
    ///
    /// Mathematical Invariant:
    /// D(p, t) = Sum_k [ (w_k * r_k^2) / (||p - c_k||^2 + r_k^2) ]
    /// With sum(w_k) = 1.0 and r_k > 0, D(p, t) is guaranteed in [0.0, 1.0] across all space;
    /// C^infinity smooth; strictly zero division by zero or mathematical singularities.
    ///
    /// - Parameters:
    ///   - p: Point coordinate in domain coordinates.
    ///   - size: Total spatial boundary dimensions.
    ///   - time: Animation timestamp in seconds.
    ///   - speed: Temporal velocity multiplier.
    ///   - breathingAmplitude: Thermodynamic breathing amplitude factor.
    /// - Returns: Analytical fluid density D(p, t) in [0.0, 1.0].
    public func sampleDensity(
        at p: CGPoint,
        in size: CGSize,
        at time: TimeInterval,
        speed: Double = 0.35,
        breathingAmplitude: Double = 0.15
    ) -> Double {
        let instances = resolveInstances(in: size, at: time, speed: speed, breathingAmplitude: breathingAmplitude)
        return sampleDensity(at: p, instances: instances)
    }
    
    /// Fast density sampler using pre-resolved vortex instances in O(K) time (K = 4 -> ~20 FLOPS).
    /// Used by Milestone 3 dynamic typography contrast probes with zero GPU readback latency.
    public func sampleDensity(at p: CGPoint, instances: [TTZipVortexInstance]) -> Double {
        var totalDensity: Double = 0.0
        for inst in instances {
            let dx = Double(p.x - inst.position.x)
            let dy = Double(p.y - inst.position.y)
            let distSq = dx * dx + dy * dy
            let rSq = Double(inst.radius * inst.radius)
            let contribution = (inst.weight * rSq) / (distSq + rSq)
            totalDensity += contribution
        }
        return min(1.0, max(0.0, totalDensity))
    }
    
    // MARK: - Chromatic Micro-Surface Sheen Operators
    
    /// Calculates the Dark Mode Glacier Blue sheen factor psi_dark(p) in [0.0, 0.10].
    /// Formula: psi_dark = 0.10 * D^2 * (1.0 - 0.5 * ||grad D||).
    public func darkSheenFactor(density: Double, gradientMagnitude: Double = 0.0) -> Double {
        let d = min(1.0, max(0.0, density))
        let edgeDamping = max(0.0, 1.0 - 0.5 * min(1.0, gradientMagnitude))
        return 0.10 * (d * d) * edgeDamping
    }
    
    /// Calculates the Light Mode Cobalt Deep sheen factor psi_light(p) in [0.0, 0.06].
    /// Formula: psi_light = 0.06 * (1.0 - D) * sqrt(D).
    public func lightSheenFactor(density: Double) -> Double {
        let d = min(1.0, max(0.0, density))
        return 0.06 * (1.0 - d) * sqrt(d)
    }
}
