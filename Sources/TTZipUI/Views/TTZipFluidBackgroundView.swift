// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.
// Module: TTZipFluidBackgroundView — Layer 1 Emitter Base & Layer 2 Fluid Dynamic Canvas.

import SwiftUI
import AppKit

/// Global fluid animation state ensuring cross-view fluid phase coherence and backward compatibility.
@MainActor
public final class TTZipGlobalFluidState {
    public static let shared = TTZipGlobalFluidState()
    
    private var phase: Double = Double.random(in: 0...100)
    private var lastTime: Double = CACurrentMediaTime()
    
    private init() {}
    
    public func currentPhase(speed: Double = 0.3) -> Double {
        let now = CACurrentMediaTime()
        let delta = now - lastTime
        if delta > 0.005 {
            phase += min(delta, 0.1) * speed
            lastTime = now
        }
        return phase
    }
}

/// Unified, publication-grade deep viscous fluid background.
/// Fully conforms to COMPANY_DESIGN_WHITEPAPER.md §3, §4 & §6:
/// - Layer 1 Emitter: OLED true black (#000000, 0 nits) in Dark; Solar pure white (#FFFFFF, 1000 nits) in Light.
/// - Layer 2 Fluid: Luminous opal white with 10% Glacier Blue sheen in Dark; Deep obsidian black with 6% Cobalt tint in Light.
/// - Fluid Dynamics: Continuous Navier-Stokes multi-kernel potential field D(p, t) with thermodynamic breathing.
/// - 60/120 FPS timeline animation with zero battery drain via downscaled bicubic blur synthesis.
public struct TTZipFluidBackgroundView: View {
    public let mode: TTZipFluidMode
    public let config: TTZipFluidConfiguration
    
    @Environment(\.colorScheme) private var colorScheme
    
    /// Backward-compatible property exposing the effective base color.
    public var baseColor: Color {
        switch mode {
        case .organic:
            return TTZipTheme.bambooGreen
        case .monochrome:
            return TTZipUniversalTokens.Fluid.bodyCore
        case .tinted(let color):
            return color
        }
    }
    
    /// Backward-compatible property exposing the simulation speed.
    public var speed: Double {
        config.speed
    }
    
    /// Primary initializer defaulting to the signature organic Bamboo Green fluid theme.
    public init(
        mode: TTZipFluidMode = .organic,
        config: TTZipFluidConfiguration = .productionDefault
    ) {
        self.mode = mode
        self.config = config
    }
    
    /// Backward-compatible initializer for legacy call sites (e.g. MainView.swift).
    /// If `baseColor` matches `TTZipTheme.bambooGreen` or default, seamlessly activates
    /// the signature organic Bamboo Green fluid theme; otherwise preserves tinted mode.
    public init(
        baseColor: Color = TTZipTheme.bambooGreen,
        speed: Double = 0.35
    ) {
        var cfg = TTZipFluidConfiguration.productionDefault
        cfg.speed = speed
        self.config = cfg
        
        if baseColor == TTZipTheme.bambooGreen {
            self.mode = .organic
        } else {
            self.mode = .tinted(baseColor)
        }
    }
    
    public var body: some View {
        ZStack {
            // MARK: - Layer 1: Base Physical Emitter
            // Dark: OLED True Black (#000000) 0 nits; Light: Solar Pure White (#FFFFFF) 1000 nits
            TTZipUniversalTokens.Canvas.emitter
                .ignoresSafeArea()
            
            // MARK: - Layer 2: Deep Viscous Fluid Potential Field
            GeometryReader { geo in
                let size = geo.size
                TimelineView(.animation(minimumInterval: config.minimumFrameInterval)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    TTZipFluidRenderer(
                        time: time,
                        fullSize: size,
                        colorScheme: colorScheme,
                        mode: mode,
                        config: config
                    )
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
