// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTKitFluid
import TTKitDesign

// MARK: - Fluid Progress Spring Solver

/// Analytical second-order spring-damper progress animator eliminating linear stutter.
public struct TTZipFluidProgressSolver: Sendable {
    public let spring: FluidSpring
    
    public init(spring: FluidSpring = .snappy) {
        self.spring = spring
    }
    
    /// Evaluates smooth interpolated progress value at elapsed time `t`.
    public func evaluate(
        from current: Double,
        to target: Double,
        initialVelocity: Double = 0.0,
        elapsedTime t: Double
    ) -> (value: Double, velocity: Double) {
        let displacement = current - target
        let (offset, velocity) = spring.solve(
            initialDisplacement: displacement,
            initialVelocity: initialVelocity,
            elapsedTime: t
        )
        return (min(1.0, max(0.0, target + offset)), velocity)
    }
}

// MARK: - Fluid Progress Bar View

/// Zen glassmorphic progress bar driven by analytical fluid physics.
public struct TTZipFluidProgressBar: View {
    public let value: Double
    public let accentColor: Color
    public let height: CGFloat
    
    public init(
        value: Double,
        accentColor: Color = TTZipTheme.bambooGreen,
        height: CGFloat = 6.0
    ) {
        self.value = min(1.0, max(0.0, value))
        self.accentColor = accentColor
        self.height = height
    }
    
    public var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let clampedProgress = min(1.0, max(0.0, value))
            let fillWidth = totalWidth * CGFloat(clampedProgress)
            
            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: height)
                
                // Active fluid progress fill
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accentColor, accentColor.opacity(0.85)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(fillWidth, fillWidth > 0 ? height : 0), height: height)
                    .animation(.snappy(duration: 0.35, extraBounce: 0.05), value: value)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Fluid Drawer Physics Solver

/// Spring physics solver calculating sliding drawer displacement and overshoot decay.
public struct TTZipFluidDrawerSolver: Sendable {
    public let spring: FluidSpring
    
    /// Production preset optimized for responsive edge drawers with subtle natural bounce.
    public static let drawerPreset = FluidSpring(mass: 1.0, stiffness: 240.0, dampingRatio: 0.88)
    
    public init(spring: FluidSpring = drawerPreset) {
        self.spring = spring
    }
    
    /// Evaluates offset position for an open/closed transition given elapsed time `t`.
    ///
    /// - Parameters:
    ///   - isOpen: Target open state.
    ///   - drawerWidth: Total width of the drawer in points.
    ///   - elapsedTime: Time elapsed since gesture release or transition trigger.
    /// - Returns: Translation offset in points (0 = fully opened, `drawerWidth` = fully hidden).
    public func evaluateOffset(
        isOpen: Bool,
        drawerWidth: Double,
        elapsedTime t: Double
    ) -> Double {
        let initialDisplacement = isOpen ? drawerWidth : -drawerWidth
        let (offset, _) = spring.solve(initialDisplacement: initialDisplacement, elapsedTime: t)
        let base = isOpen ? 0.0 : drawerWidth
        return max(0.0, min(drawerWidth, base + offset))
    }
}
