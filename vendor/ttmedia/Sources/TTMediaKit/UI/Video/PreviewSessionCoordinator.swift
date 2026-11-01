// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreMedia
import Observation

// MARK: - Preview Session Coordinator

/// Coordinates preview sessions conforming to ADR-048 and Spec §6.10.
/// Provides an 80ms physical debounce window and monotonic generation counters
/// to eliminate decoder leaks during rapid keyboard navigation.
@MainActor
@Observable
public final class PreviewSessionCoordinator {
    public static let shared = PreviewSessionCoordinator()

    public private(set) var activeGeneration: UInt64 = 0
    private var activeTargetURL: URL?

    public init() {}

    /// A departing viewport can only cancel the generation it actually acquired.
    public func cancelSession(generation: UInt64) {
        guard generation == activeGeneration else { return }
        cancelCurrentSession()
    }

    /// Begins a new preview session for the given target URL.
    /// Increments the generation counter, waits for the 80ms debounce interval,
    /// and cancels prior active sessions.
    ///
    /// - Parameter targetURL: Target file URL requested for preview.
    /// - Returns: Monotonic generation token assigned to this session.
    public func beginSession(targetURL: URL) async -> UInt64 {
        activeGeneration &+= 1
        let currentGen = activeGeneration
        activeTargetURL = targetURL

        // 80ms physical debounce window per ADR-048 / Spec §6.10
        try? await Task.sleep(nanoseconds: 80_000_000)

        guard activeGeneration == currentGen else {
            return currentGen
        }

        return currentGen
    }

    /// Verifies whether the specified generation is still the active session.
    ///
    /// - Parameter generation: Generation token to check.
    /// - Returns: `true` if generation matches `activeGeneration`.
    public func isSessionActive(generation: UInt64) -> Bool {
        generation == activeGeneration
    }

    /// Explicitly cancels the current session, incrementing generation counters.
    public func cancelCurrentSession() {
        activeGeneration &+= 1
        activeTargetURL = nil
    }
}
