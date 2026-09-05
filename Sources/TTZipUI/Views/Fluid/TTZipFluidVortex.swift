// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.
// Module: TTZipFluidVortex — Domain models, vortex descriptors, and configuration.

import SwiftUI
import Foundation
import CoreGraphics

/// Fluid rendering and appearance mode.
public enum TTZipFluidMode: Sendable, Hashable {
    /// Flagship organic fluid using TTZip signature Bamboo Green & Kintsugi Gold (default).
    case organic
    /// Pure monochrome fluid dynamically derived from COMPANY_DESIGN_WHITEPAPER.md §6.
    case monochrome
    /// Legacy mode supporting tinted custom base color for backward compatibility.
    case tinted(Color)
}

/// A vortex core descriptor defining local momentum and potential energy in Layer 2 fluid dynamics.
/// Mathematical reference: COMPANY_DESIGN_WHITEPAPER.md §4.1 & §4.3.
public struct TTZipFluidVortex: Sendable, Identifiable {
    public let id: Int
    /// Normalized static weight contribution (sum of all vortices in constellation = 1.0).
    public let baseWeight: Double
    /// Normalized core radius as a fraction of viewport minimum dimension (0.25 ~ 0.55).
    public let baseRadiusFraction: Double
    /// Normalized center of orbital trajectory (fraction of viewport width and height).
    public let orbitCenterFraction: CGPoint
    /// Horizontal orbit radius (fraction of viewport width).
    public let orbitRadiusXFraction: Double
    /// Vertical orbit radius (fraction of viewport height).
    public let orbitRadiusYFraction: Double
    /// Angular orbital velocity (radians per second).
    public let angularVelocity: Double
    /// Initial orbital phase offset (radians).
    public let phaseOffset: Double
    /// Thermodynamic breathing frequency multiplier.
    public let breathingFrequency: Double
    /// Thermodynamic breathing phase offset (radians).
    public let breathingPhase: Double
    
    public init(
        id: Int,
        baseWeight: Double,
        baseRadiusFraction: Double,
        orbitCenterFraction: CGPoint,
        orbitRadiusXFraction: Double,
        orbitRadiusYFraction: Double,
        angularVelocity: Double,
        phaseOffset: Double,
        breathingFrequency: Double = 1.0,
        breathingPhase: Double = 0.0
    ) {
        self.id = id
        self.baseWeight = baseWeight
        self.baseRadiusFraction = baseRadiusFraction
        self.orbitCenterFraction = orbitCenterFraction
        self.orbitRadiusXFraction = orbitRadiusXFraction
        self.orbitRadiusYFraction = orbitRadiusYFraction
        self.angularVelocity = angularVelocity
        self.phaseOffset = phaseOffset
        self.breathingFrequency = breathingFrequency
        self.breathingPhase = breathingPhase
    }
}

/// Dynamic calculated snapshot of a fluid vortex evaluated at timestamp `t`.
public struct TTZipVortexInstance: Sendable {
    /// Center coordinates in the target spatial domain.
    public let position: CGPoint
    /// Dynamic radius adjusted by thermodynamic breathing.
    public let radius: CGFloat
    /// Normalized dynamic weight contribution (strictly summing to 1.0 across all instances).
    public let weight: Double
    
    public init(position: CGPoint, radius: CGFloat, weight: Double) {
        self.position = position
        self.radius = radius
        self.weight = weight
    }
}

/// Production configuration tuning parameters for the fluid dynamic engine and renderer.
public struct TTZipFluidConfiguration: Sendable {
    /// Orbital flow speed multiplier (default: 0.35).
    public var speed: Double
    /// Thermodynamic expansion/contraction breathing amplitude (default: 0.15).
    public var breathingAmplitude: Double
    /// Downscale ratio for hardware rasterization (default: 4.0 for minimal GPU overhead).
    public var downscaleRatio: CGFloat
    /// Gaussian diffusion blur radius (default: 48.0pt).
    public var blurRadius: CGFloat
    /// Micro-surface sheen opacity multiplier (default: 1.0).
    public var sheenIntensity: Double
    /// Target timeline minimum frame interval (default: 1/120 for ProMotion displays).
    public var minimumFrameInterval: Double
    
    public init(
        speed: Double = 0.35,
        breathingAmplitude: Double = 0.15,
        downscaleRatio: CGFloat = 4.0,
        blurRadius: CGFloat = 48.0,
        sheenIntensity: Double = 1.0,
        minimumFrameInterval: Double = 1.0 / 120.0
    ) {
        self.speed = speed
        self.breathingAmplitude = breathingAmplitude
        self.downscaleRatio = downscaleRatio
        self.blurRadius = blurRadius
        self.sheenIntensity = sheenIntensity
        self.minimumFrameInterval = minimumFrameInterval
    }
    
    public static let productionDefault = TTZipFluidConfiguration()
}
