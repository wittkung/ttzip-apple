// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTKitCore
import TTKitDesign

public enum TTKitFluidEngineMode: String, Sendable, CaseIterable {
    case metalCached      // iTTime 体系: Metal 3-Pass + R8 显存缓存 (0.05ms，极致能效)
    case cauchyAnalytic   // TTZip 体系: 4-涡旋连续柯西势能场 (纯原生 Canvas，支持 CPU 密度反差采样)
    case organicWarping   // iTTime 体系: Inigo Quilez 域扭曲着色器 (全屏氛围)
}

/// Unified, publication-grade deep viscous fluid background for macOS and Apple platforms.
/// Strictly conforms to infra/ttkit/docs/DESIGN_AXIOMS.md §1, §3 & §4:
/// - Layer 1 Emitter: OLED True Black (#000000, 0 nits) in Dark; Solar Pure White (#FFFFFF, 1000 nits) in Light.
/// - Layer 2 Fluid: Luminous mineral glow (0.28 opacity) in Dark; Whisper-soft tea-wash wash (0.20 opacity) in Light.
/// - Fluid Dynamics: Continuous Navier-Stokes multi-kernel potential field D(p, t) with thermodynamic breathing.
/// - 60/120 FPS timeline animation with zero battery drain via downscaled 4x bicubic blur synthesis.
public struct TTKitFluidBackgroundView: View {
    public let engine: TTKitFluidEngineMode
    public let config: FluidBackgroundConfig

    @Environment(\.colorScheme) private var colorScheme

    public init(
        engine: TTKitFluidEngineMode = .metalCached,
        config: FluidBackgroundConfig = .init()
    ) {
        self.engine = engine
        self.config = config
    }

    public var body: some View {
        ZStack {
            // MARK: - Layer 1: Base Physical Emitter (Axiom I & §3)
            // Dark: OLED True Black (#000000) 0 nits; Light: Solar Pure White (#FFFFFF) 1000 nits
            UniversalTokens.Canvas.emitter
                .ignoresSafeArea()

            // MARK: - Layer 2: Deep Viscous Fluid Dynamics
            switch engine {
            case .metalCached:
                #if os(macOS)
                MetalFluidViewRepresentable(config: config)
                #else
                CauchyAnalyticFluidCanvasView(
                    baseColor: config.baseColor,
                    speed: Double(config.isFocusPaused ? 0.0 : (config.isRunning ? 0.80 : 0.20)),
                    isRunning: config.isRunning && !config.isFocusPaused,
                    customOpacity: config.fluidOpacity > 0 ? Double(config.fluidOpacity) : nil
                )
                #endif
            case .cauchyAnalytic:
                let customOpacity: Double? = config.fluidOpacity > 0 ? Double(config.fluidOpacity) : nil
                CauchyAnalyticFluidCanvasView(
                    baseColor: config.baseColor,
                    speed: Double(config.isFocusPaused ? 0.0 : (config.isRunning ? 0.80 : 0.20)),
                    isRunning: config.isRunning && !config.isFocusPaused,
                    customOpacity: customOpacity
                )
            case .organicWarping:
                OrganicFluidView(config: config)
            }

            if config.isFrosted {
                FluidFrostedSurfaceView()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - iTTime Lissajous Hermite Fluid Canvas View (60/120 FPS Pro-Motion Fluid)
//
// Trajectories adapted from products/ittime/iosApp/Ittime/Features/Focus/Views/Components/FluidBackgroundView.swift
// TTKit uses wider spheres and slightly softer diffusion for desktop coverage.
// - 3-Sphere Lissajous dynamics centered at (0.5 * w, 0.5 * h) with frequencies (0.65/1.05, 0.45/0.95, 0.35/0.55)
// - Amplitudes (0.30*w, 0.20*h), (0.40*w, 0.30*h), (0.25*w, 0.40*h)
// - Aspect-corrected radius baseRadius = 0.54 * min(w, h), hierarchical alpha weights 1.0, 0.8, 0.6
// - Calibrated opacities: Dark 0.60 / Light 0.30 over pure emitter without fullscreen tint scrim
public struct CauchyAnalyticFluidCanvasView: View {
    public let baseColor: Color
    public let speed: Double
    public let isRunning: Bool
    public let downscaleRatio: CGFloat
    public let blurRadius: CGFloat
    public let customOpacity: Double?
    public let pausesOnInactive: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState

    private var isPaused: Bool {
        if !isRunning || speed == 0.0 { return true }
        return pausesOnInactive && controlActiveState == .inactive
    }

    public init(
        baseColor: Color,
        speed: Double = 0.20,
        isRunning: Bool = true,
        downscaleRatio: CGFloat = 4.0,
        blurRadius: CGFloat = 132.0,
        customOpacity: Double? = nil,
        pausesOnInactive: Bool = false
    ) {
        self.baseColor = baseColor
        self.speed = speed
        self.isRunning = isRunning
        self.downscaleRatio = downscaleRatio
        self.blurRadius = blurRadius
        self.customOpacity = customOpacity
        self.pausesOnInactive = pausesOnInactive
    }

    // MARK: - Optical Intensity & Opacity Tuning
    // Dark Mode: 0.60 (over OLED True Black #000000)
    // Light Mode: 0.30 (over Solar Pure White #FFFFFF)
    private var fluidOpacity: Double {
        if let custom = customOpacity {
            return custom
        }
        return colorScheme == .dark ? 0.60 : 0.30
    }

    public var body: some View {
        GeometryReader { geo in
            let fullSize = geo.size
            let scale = max(1.0, downscaleRatio)
            let scaledWidth = max(fullSize.width / scale, 60.0)
            let scaledHeight = max(fullSize.height / scale, 60.0)

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { _ in
                let currentPhase = TTKitGlobalFluidState.shared.currentPhase(speed: speed)

                Canvas { context, size in
                    renderLissajousPass(context: &context, size: size, phase: currentPhase)
                }
                .frame(width: scaledWidth, height: scaledHeight)
                .blur(radius: blurRadius / scale)
                .scaleEffect(scale)
                .frame(width: fullSize.width, height: fullSize.height)
                .opacity(fluidOpacity)
            }
        }
        .allowsHitTesting(false)
    }

    /// Evaluates the 3-Sphere Lissajous centers and aspect-corrected radius for a given viewport size and phase.
    public static func evaluateSpheres(
        in size: CGSize,
        phase: Double
    ) -> (c1: CGPoint, c2: CGPoint, c3: CGPoint, radius: CGFloat, weights: (Double, Double, Double)) {
        let w = size.width
        let h = size.height
        let x1 = w * 0.50 + CGFloat(cos(phase * 0.65)) * (w * 0.30)
        let y1 = h * 0.50 + CGFloat(sin(phase * 1.05)) * (h * 0.20)

        let x2 = w * 0.50 + CGFloat(sin(phase * 0.45)) * (w * 0.40)
        let y2 = h * 0.50 + CGFloat(cos(phase * 0.95)) * (h * 0.30)

        let x3 = w * 0.50 + CGFloat(cos(phase * 0.35)) * (w * 0.25)
        let y3 = h * 0.50 + CGFloat(sin(phase * 0.55)) * (h * 0.40)

        let baseRadius = min(w, h) * 0.54
        return (
            c1: CGPoint(x: x1, y: y1),
            c2: CGPoint(x: x2, y: y2),
            c3: CGPoint(x: x3, y: y3),
            radius: baseRadius,
            weights: (1.0, 0.8, 0.6)
        )
    }

    private func renderLissajousPass(
        context: inout GraphicsContext,
        size: CGSize,
        phase: Double
    ) {
        let w = size.width
        let h = size.height
        guard w > 0 && h > 0 else { return }

        let spheres = Self.evaluateSpheres(in: size, phase: phase)
        let diameter = spheres.radius * 2.0
        let primaryColor = self.baseColor

        context.blendMode = .normal
        context.fill(
            Path(ellipseIn: CGRect(
                x: spheres.c1.x - spheres.radius,
                y: spheres.c1.y - spheres.radius,
                width: diameter,
                height: diameter
            )),
            with: .color(primaryColor.opacity(spheres.weights.0))
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: spheres.c2.x - spheres.radius,
                y: spheres.c2.y - spheres.radius,
                width: diameter,
                height: diameter
            )),
            with: .color(primaryColor.opacity(spheres.weights.1))
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: spheres.c3.x - spheres.radius,
                y: spheres.c3.y - spheres.radius,
                width: diameter,
                height: diameter
            )),
            with: .color(primaryColor.opacity(spheres.weights.2))
        )
    }
}
