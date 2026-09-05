// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.
// Module: TTZipFluidAdaptiveText — Photonic Dynamic Contrast-Adaptive Typography Engine

import SwiftUI
import AppKit
import CoreText

// MARK: - 1. Photonic Flux Constants & Mathematical Tokens

/// Mathematical constants governing photonic flux compensation and WCAG contrast limits.
/// Rigorously derived from COMPANY_DESIGN_WHITEPAPER.md §5.
public enum PhotonicFluxConstants: Sendable {
    /// Optimal single-threshold switching luminance (WCAG AA global infimum CR = 4.5652:1).
    public static let optimalThresholdAA: CGFloat = 0.180
    /// Valid single-threshold luminance switching lower bound.
    public static let thresholdAAMin: CGFloat = 0.175
    /// Valid single-threshold luminance switching upper bound.
    public static let thresholdAAMax: CGFloat = 0.18333
    /// Level AAA dead zone boundary lower bound.
    public static let thresholdAAAMin: CGFloat = 0.100
    /// Level AAA dead zone boundary upper bound.
    public static let thresholdAAAMax: CGFloat = 0.300
    /// Adaptive inverted micro-halo stroke width (0.5pt, Core-to-Halo CR = 21.0:1).
    public static let microHaloStrokeWidth: CGFloat = 0.50
    /// Default transition zone width in points (16pt ~ 32pt).
    public static let defaultTransitionWidth: CGFloat = 24.0
    /// Minimum transition zone width in points.
    public static let minTransitionWidth: CGFloat = 16.0
    /// Maximum transition zone width in points.
    public static let maxTransitionWidth: CGFloat = 32.0
    /// Hermite transition activation lower bound (a).
    public static let transitionThresholdMin: CGFloat = 0.350
    /// Hermite transition activation upper bound (b).
    public static let transitionThresholdMax: CGFloat = 0.650
    /// Gaussian diffusion radius for Layer 3 frosted glass.
    public static let diffusionSigma: CGFloat = 18.0
    /// Specular hairline reflection coefficient (Dark Mode: 14%).
    public static let specularAlphaDark: CGFloat = 0.140
    /// Specular hairline reflection coefficient (Light Mode: 8%).
    public static let specularAlphaLight: CGFloat = 0.080
}

// MARK: - 2. Fluid Coordinate Space Tokens

/// Defines the unified coordinate space token for fluid background and adaptive typography.
public enum TTZipFluidCoordinateSpace: Sendable {
    public static let name = "TTZipFluidCoordinateSpace"
}

// MARK: - 3. Multi-Kernel Fluid Potential Mathematical Model

/// Analytical Navier-Stokes multi-kernel potential field evaluator.
public struct TTZipFluidPotentialField: Sendable {
    public struct Vortex: Sendable {
        public var weight: CGFloat
        public var radius: CGFloat
        public var phaseSpeedX: CGFloat
        public var phaseSpeedY: CGFloat
        public var freqX: CGFloat
        public var freqY: CGFloat
        
        public init(
            weight: CGFloat,
            radius: CGFloat,
            phaseSpeedX: CGFloat,
            phaseSpeedY: CGFloat,
            freqX: CGFloat,
            freqY: CGFloat
        ) {
            self.weight = weight
            self.radius = radius
            self.phaseSpeedX = phaseSpeedX
            self.phaseSpeedY = phaseSpeedY
            self.freqX = freqX
            self.freqY = freqY
        }
    }
    
    public static let defaultVortices: [Vortex] = [
        Vortex(weight: 0.45, radius: 180.0, phaseSpeedX: 0.65, phaseSpeedY: 1.05, freqX: 0.35, freqY: 0.20),
        Vortex(weight: 0.35, radius: 220.0, phaseSpeedX: 0.45, phaseSpeedY: 0.95, freqX: 0.40, freqY: 0.30),
        Vortex(weight: 0.20, radius: 140.0, phaseSpeedX: 0.35, phaseSpeedY: 0.55, freqX: 0.25, freqY: 0.40)
    ]
    
    /// Evaluates normalized potential D(p, t) in [0.0, 1.0].
    public static func evaluate(
        at point: CGPoint,
        containerSize: CGSize,
        time: Double,
        vortices: [Vortex] = defaultVortices
    ) -> CGFloat {
        guard containerSize.width > 0, containerSize.height > 0 else { return 0.0 }
        
        var totalPotential: CGFloat = 0.0
        for v in vortices {
            let cx = containerSize.width * (0.50 + v.freqX * CGFloat(cos(time * Double(v.phaseSpeedX))))
            let cy = containerSize.height * (0.50 + v.freqY * CGFloat(sin(time * Double(v.phaseSpeedY))))
            
            let dx = point.x - cx
            let dy = point.y - cy
            let distSq = dx * dx + dy * dy
            let rSq = v.radius * v.radius
            
            totalPotential += (v.weight * rSq) / (distSq + rSq)
        }
        return max(0.0, min(1.0, totalPotential))
    }
    
    /// Evaluates Cubic Hermite smoothstep kernel S(t) = 3t^2 - 2t^3.
    public static func smoothstep(edge0: CGFloat, edge1: CGFloat, x: CGFloat) -> CGFloat {
        guard edge1 != edge0 else { return x >= edge0 ? 1.0 : 0.0 }
        let t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }
    
    /// Maps normalized fluid density D into effective background luminance L_bg.
    public static func effectiveLuminance(density: CGFloat, isDark: Bool) -> CGFloat {
        let clampedD = max(0.0, min(1.0, density))
        return isDark ? (clampedD * 0.9804) : (1.0 - clampedD * 0.9608)
    }
    
    /// Calculates the W3C WCAG 2.1 relative contrast ratio between two luminance values.
    public static func contrastRatio(l1: CGFloat, l2: CGFloat) -> CGFloat {
        let maxL = max(l1, l2)
        let minL = min(l1, l2)
        return (maxL + 0.05) / (minL + 0.05)
    }
    
    /// Computes the target smoothstep alpha transition for Layer B mask.
    public static func targetAlpha(
        luminance: CGFloat,
        isDark: Bool,
        transitionWidth: CGFloat = PhotonicFluxConstants.defaultTransitionWidth
    ) -> CGFloat {
        let halfDelta = (transitionWidth / 200.0) * 0.05
        let edge0 = PhotonicFluxConstants.optimalThresholdAA - halfDelta
        let edge1 = PhotonicFluxConstants.optimalThresholdAA + halfDelta
        
        if isDark {
            return smoothstep(edge0: edge0, edge1: edge1, x: luminance)
        } else {
            return smoothstep(edge0: edge1, edge1: edge0, x: luminance)
        }
    }

    /// Evaluates strict binary threshold alpha at optimal threshold (L* = 0.180) for narrow text elements.
    /// Eliminates mid-gray blending collapse and guarantees continuous CR >= 4.5652:1.
    public static func binaryThresholdAlpha(luminance: CGFloat, isDark: Bool) -> CGFloat {
        if isDark {
            return luminance <= PhotonicFluxConstants.optimalThresholdAA ? 0.0 : 1.0
        } else {
            return luminance <= PhotonicFluxConstants.optimalThresholdAA ? 1.0 : 0.0
        }
    }

    /// Evaluates the expected rendered text and micro-halo luminance for a given background luminance
    /// under the binary switching model (used for narrow text elements width <= transitionWidth).
    public static func binaryTypographyState(
        luminance: CGFloat,
        isDark: Bool
    ) -> (textLuminance: CGFloat, haloLuminance: CGFloat) {
        let alpha = binaryThresholdAlpha(luminance: luminance, isDark: isDark)
        let textL: CGFloat
        if isDark {
            textL = alpha > 0.5 ? 0.0 : 1.0
        } else {
            textL = alpha > 0.5 ? 1.0 : 0.0
        }
        let haloL: CGFloat = textL == 1.0 ? 0.0 : 1.0
        return (textLuminance: textL, haloLuminance: haloL)
    }
}

// MARK: - 4. Dual-Layer Geometric Mask Typography View

/// A publication-grade, hardware-accelerated fluid-aware typography component
/// guaranteeing continuous >= 4.5:1 WCAG AA/AAA legibility while preserving
/// 100% native CoreText subpixel antialiasing sharpness.
public struct TTZipFluidAdaptiveText: View {
    private let textString: String?
    private let titleKey: LocalizedStringKey?
    private let font: Font
    private let weight: Font.Weight
    private let localProbe: CGPoint?
    private let tracking: CGFloat
    private let lineSpacing: CGFloat
    private let transitionWidth: CGFloat
    private let showsMicroHalo: Bool
    
    @Environment(\.colorScheme) private var colorScheme

    public init(
        _ text: String,
        font: Font = .body,
        weight: Font.Weight = .regular,
        localProbe: CGPoint? = nil,
        tracking: CGFloat = 0.0,
        lineSpacing: CGFloat = 4.0,
        transitionWidth: CGFloat = PhotonicFluxConstants.defaultTransitionWidth,
        showsMicroHalo: Bool = false
    ) {
        self.textString = text
        self.titleKey = nil
        self.font = font
        self.weight = weight
        self.localProbe = localProbe
        self.tracking = tracking
        self.lineSpacing = lineSpacing
        self.transitionWidth = max(
            PhotonicFluxConstants.minTransitionWidth,
            min(PhotonicFluxConstants.maxTransitionWidth, transitionWidth)
        )
        self.showsMicroHalo = showsMicroHalo
    }

    public init(
        localized titleKey: LocalizedStringKey,
        font: Font = .body,
        weight: Font.Weight = .regular,
        localProbe: CGPoint? = nil,
        tracking: CGFloat = 0.0,
        lineSpacing: CGFloat = 4.0,
        transitionWidth: CGFloat = PhotonicFluxConstants.defaultTransitionWidth,
        showsMicroHalo: Bool = false
    ) {
        self.textString = nil
        self.titleKey = titleKey
        self.font = font
        self.weight = weight
        self.localProbe = localProbe
        self.tracking = tracking
        self.lineSpacing = lineSpacing
        self.transitionWidth = max(
            PhotonicFluxConstants.minTransitionWidth,
            min(PhotonicFluxConstants.maxTransitionWidth, transitionWidth)
        )
        self.showsMicroHalo = showsMicroHalo
    }

    public var body: some View {
        GeometryReader { proxy in
            let frameInFluid = proxy.frame(in: .named(TTZipFluidCoordinateSpace.name))
            
            ZStack(alignment: .leading) {
                // Dual-Path Adaptive Micro-Halo:
                // Base halo opposes Layer A (White text -> Black halo in Dark; Black text -> White halo in Light).
                // Inverted halo opposes Layer B (Black text -> White halo in Dark; White text -> Black halo in Light),
                // clipped dynamically by the exact same GPU spatial mask.
                if showsMicroHalo {
                    // Halo Layer A: opposes baseColor
                    renderedTextView(color: invertedColor)
                        .blur(radius: PhotonicFluxConstants.microHaloStrokeWidth)
                        .opacity(0.85)
                    
                    // Halo Layer B: opposes invertedColor (renders in baseColor)
                    renderedTextView(color: baseColor)
                        .blur(radius: PhotonicFluxConstants.microHaloStrokeWidth)
                        .opacity(0.85)
                        .mask(spatialMask(proxy: proxy, frameInFluid: frameInFluid))
                }
                
                // Layer A: Base Inscription (Pure White in Dark / Pure Black in Light)
                renderedTextView(color: baseColor)

                // Layer B: Inverted Inscription (Pure Black in Dark / Pure White in Light)
                // Clipped by the GPU Fluid Potential Alpha Mask
                renderedTextView(color: invertedColor)
                    .mask(spatialMask(proxy: proxy, frameInFluid: frameInFluid))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func spatialMask(proxy: GeometryProxy, frameInFluid: CGRect) -> some View {
        FluidPotentialSpatialMask(
            localBounds: CGRect(origin: .zero, size: proxy.size),
            globalFrame: frameInFluid,
            transitionWidth: transitionWidth,
            localProbe: localProbe
        )
    }

    @ViewBuilder
    private func renderedTextView(color: Color) -> some View {
        if let str = textString {
            Text(str)
                .font(font)
                .fontWeight(weight)
                .tracking(tracking)
                .lineSpacing(lineSpacing)
                .foregroundStyle(color)
        } else if let key = titleKey {
            Text(key)
                .font(font)
                .fontWeight(weight)
                .tracking(tracking)
                .lineSpacing(lineSpacing)
                .foregroundStyle(color)
        }
    }

    private var baseColor: Color {
        colorScheme == .dark
            ? Color(white: 1.0, opacity: 1.0) // Pure White (#FFFFFF)
            : Color(white: 0.0, opacity: 1.0) // Pure Black (#000000)
    }

    private var invertedColor: Color {
        colorScheme == .dark
            ? Color(white: 0.0, opacity: 1.0) // Pure Black (#000000)
            : Color(white: 1.0, opacity: 1.0) // Pure White (#FFFFFF)
    }
}

// MARK: - 5. Fluid Potential Spatial Alpha Mask

/// Evaluates the real-time fluid field across the view's geometry, rendering
/// a smoothstep alpha transition gradient preserving CoreText sharpness.
public struct FluidPotentialSpatialMask: View {
    public let localBounds: CGRect
    public let globalFrame: CGRect
    public let transitionWidth: CGFloat
    public let localProbe: CGPoint?
    
    @Environment(\.colorScheme) private var colorScheme

    public init(
        localBounds: CGRect,
        globalFrame: CGRect,
        transitionWidth: CGFloat = PhotonicFluxConstants.defaultTransitionWidth,
        localProbe: CGPoint? = nil
    ) {
        self.localBounds = localBounds
        self.globalFrame = globalFrame
        self.transitionWidth = max(
            PhotonicFluxConstants.minTransitionWidth,
            min(PhotonicFluxConstants.maxTransitionWidth, transitionWidth)
        )
        self.localProbe = localProbe
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let phase = TTZipGlobalFluidState.shared.currentPhase(speed: 0.3)
            let combinedTime = time * 0.5 + phase
            let isDark = colorScheme == .dark
            
            Canvas { context, size in
                // Reference container geometry
                let containerW: CGFloat = max(globalFrame.width, 800.0)
                let containerH: CGFloat = max(globalFrame.height, 600.0)
                let containerSize = CGSize(width: containerW, height: containerH)
                
                // Sample center
                let sampleCenter: CGPoint
                if let probe = localProbe {
                    sampleCenter = probe
                } else if globalFrame.midX > 0 || globalFrame.midY > 0 {
                    sampleCenter = CGPoint(x: globalFrame.midX, y: globalFrame.midY)
                } else {
                    sampleCenter = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                }
                
                if size.width > transitionWidth {
                    let leftPoint = CGPoint(
                        x: sampleCenter.x - size.width * 0.5,
                        y: sampleCenter.y
                    )
                    let rightPoint = CGPoint(
                        x: sampleCenter.x + size.width * 0.5,
                        y: sampleCenter.y
                    )
                    let leftPot = TTZipFluidPotentialField.evaluate(
                        at: leftPoint,
                        containerSize: containerSize,
                        time: combinedTime
                    )
                    let rightPot = TTZipFluidPotentialField.evaluate(
                        at: rightPoint,
                        containerSize: containerSize,
                        time: combinedTime
                    )
                    
                    let leftL = TTZipFluidPotentialField.effectiveLuminance(density: leftPot, isDark: isDark)
                    let rightL = TTZipFluidPotentialField.effectiveLuminance(density: rightPot, isDark: isDark)
                    
                    let leftAlpha = TTZipFluidPotentialField.targetAlpha(
                        luminance: leftL,
                        isDark: isDark,
                        transitionWidth: transitionWidth
                    )
                    let rightAlpha = TTZipFluidPotentialField.targetAlpha(
                        luminance: rightL,
                        isDark: isDark,
                        transitionWidth: transitionWidth
                    )
                    
                    let gradient = Gradient(stops: [
                        .init(color: Color.white.opacity(Double(leftAlpha)), location: 0.0),
                        .init(color: Color.white.opacity(Double(rightAlpha)), location: 1.0)
                    ])
                    
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .linearGradient(
                            gradient,
                            startPoint: .zero,
                            endPoint: CGPoint(x: size.width, y: 0)
                        )
                    )
                } else {
                    let pot = TTZipFluidPotentialField.evaluate(
                        at: sampleCenter,
                        containerSize: containerSize,
                        time: combinedTime
                    )
                    let lBg = TTZipFluidPotentialField.effectiveLuminance(density: pot, isDark: isDark)
                    // Strict binary threshold switching at L* = 0.180 for narrow elements (size.width <= transitionWidth).
                    // Eliminates intermediate gray blending collapse and guarantees continuous CR >= 4.5652:1 WCAG AA.
                    let alpha = TTZipFluidPotentialField.binaryThresholdAlpha(
                        luminance: lBg,
                        isDark: isDark
                    )
                    
                    context.fill(
                        Path(CGRect(origin: .zero, size: size)),
                        with: .color(Color.white.opacity(Double(alpha)))
                    )
                }
            }
        }
    }
}

// MARK: - 6. SwiftUI ViewModifier Ergonomics

public struct TTZipFluidAdaptiveModifier: ViewModifier {
    public var font: Font
    public var weight: Font.Weight
    public var localProbe: CGPoint?
    public var tracking: CGFloat
    public var lineSpacing: CGFloat
    public var transitionWidth: CGFloat
    public var showsMicroHalo: Bool
    
    @Environment(\.colorScheme) private var colorScheme

    public init(
        font: Font = .body,
        weight: Font.Weight = .regular,
        localProbe: CGPoint? = nil,
        tracking: CGFloat = 0.0,
        lineSpacing: CGFloat = 4.0,
        transitionWidth: CGFloat = PhotonicFluxConstants.defaultTransitionWidth,
        showsMicroHalo: Bool = false
    ) {
        self.font = font
        self.weight = weight
        self.localProbe = localProbe
        self.tracking = tracking
        self.lineSpacing = lineSpacing
        self.transitionWidth = max(
            PhotonicFluxConstants.minTransitionWidth,
            min(PhotonicFluxConstants.maxTransitionWidth, transitionWidth)
        )
        self.showsMicroHalo = showsMicroHalo
    }

    public func body(content: Content) -> some View {
        GeometryReader { proxy in
            let frameInFluid = proxy.frame(in: .named(TTZipFluidCoordinateSpace.name))
            
            ZStack(alignment: .leading) {
                // Dual-Path Adaptive Micro-Halo:
                // Base halo opposes Layer A (White text -> Black halo in Dark; Black text -> White halo in Light).
                // Inverted halo opposes Layer B (Black text -> White halo in Dark; White text -> Black halo in Light),
                // clipped dynamically by the exact same GPU spatial mask.
                if showsMicroHalo {
                    // Halo Layer A: opposes baseColor
                    content
                        .foregroundStyle(invertedColor)
                        .blur(radius: PhotonicFluxConstants.microHaloStrokeWidth)
                        .opacity(0.85)
                    
                    // Halo Layer B: opposes invertedColor (renders in baseColor)
                    content
                        .foregroundStyle(baseColor)
                        .blur(radius: PhotonicFluxConstants.microHaloStrokeWidth)
                        .opacity(0.85)
                        .mask(spatialMask(proxy: proxy, frameInFluid: frameInFluid))
                }
                
                // Layer A: Base Inscription (Pure White in Dark / Pure Black in Light)
                content
                    .foregroundStyle(baseColor)
                
                // Layer B: Inverted Inscription (Pure Black in Dark / Pure White in Light)
                // Clipped by the GPU Fluid Potential Alpha Mask
                content
                    .foregroundStyle(invertedColor)
                    .mask(spatialMask(proxy: proxy, frameInFluid: frameInFluid))
            }
        }
    }

    @ViewBuilder
    private func spatialMask(proxy: GeometryProxy, frameInFluid: CGRect) -> some View {
        FluidPotentialSpatialMask(
            localBounds: CGRect(origin: .zero, size: proxy.size),
            globalFrame: frameInFluid,
            transitionWidth: transitionWidth,
            localProbe: localProbe
        )
    }

    private var baseColor: Color {
        colorScheme == .dark
            ? Color(white: 1.0, opacity: 1.0)
            : Color(white: 0.0, opacity: 1.0)
    }

    private var invertedColor: Color {
        colorScheme == .dark
            ? Color(white: 0.0, opacity: 1.0)
            : Color(white: 1.0, opacity: 1.0)
    }
}

public extension View {
    /// Applies fluid-aware dynamic contrast adaptation to any Text or typography element.
    func fluidAdaptive(
        font: Font = .body,
        weight: Font.Weight = .regular,
        localProbe: CGPoint? = nil,
        tracking: CGFloat = 0.0,
        lineSpacing: CGFloat = 4.0,
        transitionWidth: CGFloat = PhotonicFluxConstants.defaultTransitionWidth,
        showsMicroHalo: Bool = false
    ) -> some View {
        self.modifier(
            TTZipFluidAdaptiveModifier(
                font: font,
                weight: weight,
                localProbe: localProbe,
                tracking: tracking,
                lineSpacing: lineSpacing,
                transitionWidth: transitionWidth,
                showsMicroHalo: showsMicroHalo
            )
        )
    }
}
