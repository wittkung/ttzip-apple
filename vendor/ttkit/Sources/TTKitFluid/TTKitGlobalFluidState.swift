// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import QuartzCore

/// Thread-safe global fluid animation state ensuring cross-view phase coherence and synchronization.
public final class TTKitGlobalFluidState: @unchecked Sendable {
    public static let shared = TTKitGlobalFluidState()

    private let lock = NSLock()
    private var phase: Double = Double.random(in: 0...100)
    private var lastTime: Double = CACurrentMediaTime()

    private init() {}

    /// Advances and returns the synchronized phase angle given the flow speed multiplier.
    public func currentPhase(speed: Double = 0.3) -> Double {
        lock.lock()
        defer { lock.unlock() }

        let now = CACurrentMediaTime()
        let delta = now - lastTime
        if delta > 0.005 {
            phase += min(delta, 0.1) * speed
            lastTime = now
        }
        return phase
    }
}
