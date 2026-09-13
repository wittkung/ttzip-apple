// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import os
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Throttled event publisher aligning high-frequency engine events to display refresh rates.
public final class ThrottledProgressPublisher: Sendable {
    public let intervalNanoseconds: UInt64
    private let state: OSAllocatedUnfairLock<UInt64>
    
    /// Initializes throttler with maximum frequency (Hz), defaulting to 60.0Hz (~16.6ms).
    public init(maxFrequencyHz: Double = 60.0) {
        let clampedHz = max(1.0, min(120.0, maxFrequencyHz))
        self.intervalNanoseconds = UInt64(1_000_000_000.0 / clampedHz)
        self.state = OSAllocatedUnfairLock(initialState: 0)
    }
    
    /// Evaluates whether current timestamp qualifies for frame emission.
    public func shouldEmit(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        return state.withLock { lastEmittedTimestamp in
            if lastEmittedTimestamp == 0 || (now >= lastEmittedTimestamp && (now - lastEmittedTimestamp) >= intervalNanoseconds) {
                lastEmittedTimestamp = now
                return true
            }
            return false
        }
    }
    
    /// Forces emission timestamp update.
    public func forceEmit(now: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        state.withLock { lastEmittedTimestamp in
            lastEmittedTimestamp = now
        }
    }
    
    /// Resets throttler state.
    public func reset() {
        state.withLock { lastEmittedTimestamp in
            lastEmittedTimestamp = 0
        }
    }
}
