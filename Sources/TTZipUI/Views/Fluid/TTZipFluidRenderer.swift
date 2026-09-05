// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.
// Module: TTZipFluidRenderer — High-efficiency 60/120 FPS Canvas Compositor.

import SwiftUI
import AppKit

/// High-performance GPU-accelerated canvas compositor for Layer 2 Deep Viscous Fluid.
/// Implements 60/120 FPS downscaled rasterization with Gaussian diffusion and Cauchy chromatic sheen.
/// Architectural reference: COMPANY_DESIGN_WHITEPAPER.md §4.2, §5.4 & §6.1.
public struct TTZipFluidRenderer: View {
    public let time: TimeInterval
    public let fullSize: CGSize
    public let colorScheme: ColorScheme
    public let mode: TTZipFluidMode
    public let config: TTZipFluidConfiguration
    
    public init(
        time: TimeInterval,
        fullSize: CGSize,
        colorScheme: ColorScheme,
        mode: TTZipFluidMode = .organic,
        config: TTZipFluidConfiguration = .productionDefault
    ) {
        self.time = time
        self.fullSize = fullSize
        self.colorScheme = colorScheme
        self.mode = mode
        self.config = config
    }
    
    public var body: some View {
        let scale = max(1.0, config.downscaleRatio)
        let scaledWidth = max(fullSize.width / scale, 60.0)
        let scaledHeight = max(fullSize.height / scale, 60.0)
        let scaledSize = CGSize(width: scaledWidth, height: scaledHeight)
        
        let instances = TTZipFluidDynamicsEngine.shared.resolveInstances(
            in: scaledSize,
            at: time,
            speed: config.speed,
            breathingAmplitude: config.breathingAmplitude
        )
        
        Canvas { context, size in
            renderFluidPass(context: &context, size: size, instances: instances)
        }
        .frame(width: scaledWidth, height: scaledHeight)
        .blur(radius: config.blurRadius / scale)
        .scaleEffect(scale)
        .frame(width: fullSize.width, height: fullSize.height)
        .opacity(fluidOpacity)
    }
    
    // MARK: - Optical Intensity & Opacity Tuning
    
    private var fluidOpacity: Double {
        switch mode {
        case .organic:
            // Luminous Bamboo Green over OLED true black (#000000) achieves deep emerald vitality;
            // over Solar pure white (#FFFFFF) achieves an elegant, subtle tea-wash tint.
            return colorScheme == .dark ? 0.40 : 0.22
        case .monochrome:
            // High-luminance opal in dark needs soft diffusion; obsidian ink in light needs presence
            return colorScheme == .dark ? 0.38 : 0.22
        case .tinted:
            return colorScheme == .dark ? 0.35 : 0.18
        }
    }
    
    // MARK: - Multi-Pass Composition
    
    private func renderFluidPass(
        context: inout GraphicsContext,
        size: CGSize,
        instances: [TTZipVortexInstance]
    ) {
        context.blendMode = .normal
        
        // Pass 1: Viscous Fluid Core Body
        for (index, inst) in instances.enumerated() {
            let r = inst.radius
            let rect = CGRect(
                x: inst.position.x - r,
                y: inst.position.y - r,
                width: r * 2.0,
                height: r * 2.0
            )
            
            let gradient = fluidCoreGradient(weight: inst.weight, vortexIndex: index)
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    gradient,
                    center: inst.position,
                    startRadius: 0.0,
                    endRadius: r
                )
            )
        }
        
        // Pass 2: Cauchy Micro-Surface Chromatic Sheen Dispersion
        if config.sheenIntensity > 0.001 {
            renderSheenPass(context: &context, size: size, instances: instances)
        }
    }
    
    private func renderSheenPass(
        context: inout GraphicsContext,
        size: CGSize,
        instances: [TTZipVortexInstance]
    ) {
        // Micro-surface sheen sits on top of fluid core with plusLighter blend in Dark, normal in Light
        context.blendMode = colorScheme == .dark ? .plusLighter : .normal
        
        for inst in instances {
            let r = inst.radius * 0.85
            let rect = CGRect(
                x: inst.position.x - r,
                y: inst.position.y - r,
                width: r * 2.0,
                height: r * 2.0
            )
            
            let sheenColor: Color = {
                if colorScheme == .dark {
                    // 10% Glacier Blue (#0A84FF)
                    return Color(.displayP3, red: 0.1490, green: 0.5100, blue: 0.9800, opacity: 1.0)
                        .opacity(0.10 * inst.weight * config.sheenIntensity)
                } else {
                    // 6% Deep Cobalt (#002244)
                    return Color(.displayP3, red: 0.0240, green: 0.1310, blue: 0.2600, opacity: 1.0)
                        .opacity(0.06 * inst.weight * config.sheenIntensity)
                }
            }()
            
            let gradient = Gradient(stops: [
                .init(color: sheenColor, location: 0.0),
                .init(color: sheenColor.opacity(0.50), location: 0.40),
                .init(color: .clear, location: 1.0)
            ])
            
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    gradient,
                    center: inst.position,
                    startRadius: 0.0,
                    endRadius: r
                )
            )
        }
    }
    
    private func fluidCoreGradient(weight: Double, vortexIndex: Int) -> Gradient {
        let baseColor: Color = {
            switch mode {
            case .organic:
                // Primary vortices (0, 1, 2) flow Bamboo Green; 4th vortex (3) adds a warm touch of Kintsugi Gold
                if vortexIndex == 3 {
                    return TTZipTheme.kintsugiGold
                }
                return TTZipTheme.bambooGreen
            case .monochrome:
                // Dark: Opal White (#FAFAFC); Light: Obsidian Ink (#0A0A0C)
                return TTZipUniversalTokens.Fluid.bodyCore
            case .tinted(let tint):
                return tint
            }
        }()
        
        let centerOpacity = min(1.0, 0.90 * weight * 2.5)
        let midOpacity = centerOpacity * 0.55
        
        return Gradient(stops: [
            .init(color: baseColor.opacity(centerOpacity), location: 0.0),
            .init(color: baseColor.opacity(midOpacity), location: 0.45),
            .init(color: baseColor.opacity(0.0), location: 1.0)
        ])
    }
}
