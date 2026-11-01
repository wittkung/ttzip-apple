// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// Fluid background rendering configuration model (Builder pattern).
public struct FluidBackgroundConfig: Equatable, Sendable {
    public var baseColor: Color
    public var isRunning: Bool
    public var isFocusPaused: Bool
    public var isSystemPaused: Bool
    public var isActive: Bool
    public var isDarkMode: Bool
    public var fluidOpacity: Float
    public var focusMode: Float
    public var focusProgress: Float
    public var breathSeed: Float
    /// Adds a stationary film-frosted surface below foreground content.
    public var isFrosted: Bool

    public init(
        baseColor: Color = .blue,
        isRunning: Bool = false,
        isFocusPaused: Bool = false,
        isSystemPaused: Bool = false,
        isActive: Bool = true,
        isDarkMode: Bool = true,
        fluidOpacity: Float = 1.0,
        focusMode: Float = 0.0,
        focusProgress: Float = 0.0,
        breathSeed: Float = 0.0,
        isFrosted: Bool = false
    ) {
        self.baseColor = baseColor
        self.isRunning = isRunning
        self.isFocusPaused = isFocusPaused
        self.isSystemPaused = isSystemPaused
        self.isActive = isActive
        self.isDarkMode = isDarkMode
        self.fluidOpacity = fluidOpacity
        self.focusMode = focusMode
        self.focusProgress = focusProgress
        self.breathSeed = breathSeed
        self.isFrosted = isFrosted
    }
}

/// Fluid background configuration builder.
public final class FluidBackgroundConfigBuilder {
    private var config: FluidBackgroundConfig

    public init(baseColor: Color = .blue, isRunning: Bool = false) {
        self.config = FluidBackgroundConfig(baseColor: baseColor, isRunning: isRunning)
    }

    public init(initialConfig: FluidBackgroundConfig) {
        self.config = initialConfig
    }

    @discardableResult
    public func baseColor(_ color: Color) -> Self {
        config.baseColor = color
        return self
    }

    @discardableResult
    public func isRunning(_ running: Bool) -> Self {
        config.isRunning = running
        return self
    }

    @discardableResult
    public func isFocusPaused(_ paused: Bool) -> Self {
        config.isFocusPaused = paused
        return self
    }

    @discardableResult
    public func isSystemPaused(_ paused: Bool) -> Self {
        config.isSystemPaused = paused
        return self
    }

    @discardableResult
    public func isActive(_ active: Bool) -> Self {
        config.isActive = active
        return self
    }

    @discardableResult
    public func isDarkMode(_ darkMode: Bool) -> Self {
        config.isDarkMode = darkMode
        return self
    }

    @discardableResult
    public func fluidOpacity(_ opacity: Float) -> Self {
        config.fluidOpacity = opacity
        return self
    }

    @discardableResult
    public func focusMode(_ mode: Float) -> Self {
        config.focusMode = mode
        return self
    }

    @discardableResult
    public func focusProgress(_ progress: Float) -> Self {
        config.focusProgress = progress
        return self
    }

    @discardableResult
    public func breathSeed(_ seed: Float) -> Self {
        config.breathSeed = seed
        return self
    }

    @discardableResult
    public func isFrosted(_ frosted: Bool) -> Self {
        config.isFrosted = frosted
        return self
    }

    public func build() -> FluidBackgroundConfig {
        return config
    }
}

extension FluidBackgroundConfig {
    public static func build(
        baseColor: Color = .blue,
        isRunning: Bool = false,
        configure: (FluidBackgroundConfigBuilder) -> Void
    ) -> FluidBackgroundConfig {
        let builder = FluidBackgroundConfigBuilder(baseColor: baseColor, isRunning: isRunning)
        configure(builder)
        return builder.build()
    }
}
