// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// TTKit Organic Fluid Background View — SwiftUI Native Metal Shader Pipeline
public struct OrganicFluidView: View {
    public let baseColor: Color
    public let isRunning: Bool
    public var isFocusPaused: Bool
    public var isSystemPaused: Bool
    public var focusMode: Float
    public var focusProgress: Float
    public var fluidOpacity: Float?
    public var isDarkModeOverride: Bool?

    @Environment(\.colorScheme) private var colorScheme

    private static let hasStitchableDefaultMetallib: Bool = {
        Bundle.main.url(forResource: "default", withExtension: "metallib") != nil
    }()

    public init(
        baseColor: Color,
        isRunning: Bool = true,
        isFocusPaused: Bool = false,
        isSystemPaused: Bool = false,
        focusMode: Float = 0.0,
        focusProgress: Float = 0.0,
        fluidOpacity: Float? = nil,
        isDarkModeOverride: Bool? = nil
    ) {
        self.baseColor = baseColor
        self.isRunning = isRunning
        self.isFocusPaused = isFocusPaused
        self.isSystemPaused = isSystemPaused
        self.focusMode = focusMode
        self.focusProgress = focusProgress
        self.fluidOpacity = fluidOpacity
        self.isDarkModeOverride = isDarkModeOverride
    }

    public init(config: FluidBackgroundConfig) {
        self.init(
            baseColor: config.baseColor,
            isRunning: config.isRunning,
            isFocusPaused: config.isFocusPaused,
            isSystemPaused: config.isSystemPaused,
            focusMode: config.focusMode,
            focusProgress: config.focusProgress,
            fluidOpacity: config.fluidOpacity > 0 ? config.fluidOpacity : nil,
            isDarkModeOverride: config.isDarkMode
        )
    }

    public func resolvedIsDarkMode(for scheme: ColorScheme) -> Bool {
        isDarkModeOverride ?? (scheme == .dark)
    }

    public func resolvedOpacity(for scheme: ColorScheme) -> Float {
        if let custom = fluidOpacity, custom > 0 {
            return min(max(custom, 0.0), 1.0)
        }
        return resolvedIsDarkMode(for: scheme) ? 0.6 : 0.3
    }

    public var resolvedSpeed: Float {
        (isFocusPaused || isSystemPaused) ? 0.0 : (isRunning ? 0.8 : 0.2)
    }

    public var body: some View {
        let activeOpacity = resolvedOpacity(for: colorScheme)
        let activeIsDark = resolvedIsDarkMode(for: colorScheme)
        let speed = resolvedSpeed

        Group {
            if Self.hasStitchableDefaultMetallib {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: speed == 0)) { timeline in
                    GeometryReader { geo in
                        let time = timeline.date.timeIntervalSinceReferenceDate

                        Rectangle()
                            .fill(baseColor)
                            .colorEffect(
                                ShaderLibrary.organicFluid(
                                    .float2(geo.size.width, geo.size.height),
                                    .float(Float(time)),
                                    .color(baseColor),
                                    .float(speed),
                                    .float(activeOpacity),
                                    .float(activeIsDark ? 1.0 : 0.0)
                                )
                            )
                    }
                }
            } else {
                #if os(macOS)
                MetalFluidViewRepresentable(
                    config: FluidBackgroundConfig(
                        baseColor: baseColor,
                        isRunning: isRunning,
                        isFocusPaused: isFocusPaused,
                        isSystemPaused: isSystemPaused,
                        isActive: true,
                        isDarkMode: activeIsDark,
                        fluidOpacity: activeOpacity,
                        focusMode: focusMode,
                        focusProgress: focusProgress
                    )
                )
                #else
                CauchyAnalyticFluidCanvasView(
                    baseColor: baseColor,
                    speed: Double(speed),
                    isRunning: speed > 0,
                    customOpacity: Double(activeOpacity)
                )
                #endif
            }
        }
        .ignoresSafeArea()
    }
}
