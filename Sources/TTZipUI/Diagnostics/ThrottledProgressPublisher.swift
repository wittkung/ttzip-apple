// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os

/// Throttled event publisher aligning high-frequency engine events to display refresh rates (60FPS / 120FPS ProMotion).
///
/// Provides monotonic timestamp rate-gating, lossless terminal frame delivery, `@MainActor` lossy coalescing,
/// and `DispatchSourceTimer` periodic polling to prevent RunLoop task flooding and UI frame hitching.
public final class ThrottledProgressPublisher: Sendable {
    public let intervalNanoseconds: UInt64
    private let state: OSAllocatedUnfairLock<UInt64>
    
    /// Thread-safe state for coalescing high-frequency updates onto @MainActor.
    private struct CoalesceState {
        var pendingValue: (any Sendable)?
        var isScheduled: Bool = false
    }
    private let coalesceState = OSAllocatedUnfairLock(initialState: CoalesceState())
    
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
        coalesceState.withLock { s in
            s.pendingValue = nil
            s.isScheduled = false
        }
    }

    // MARK: - @MainActor UI Frame Coalescing

    /// Coalesces high-frequency updates onto `@MainActor`, ensuring at most one scheduled main actor task
    /// is active at any given time, preventing RunLoop flooding and 60Hz/120Hz display frame drops.
    ///
    /// When intermediate updates arrive faster than the UI thread can process them, they are collapsed in-place.
    /// The `@MainActor` block is guaranteed to receive the freshest pending value when it executes.
    public func coalesceOnMain<T: Sendable>(
        value: T,
        force: Bool = false,
        action: @escaping @MainActor (T) -> Void
    ) {
        if force {
            coalesceState.withLock { s in
                s.pendingValue = nil
                s.isScheduled = false
            }
            Task { @MainActor in
                action(value)
            }
            return
        }

        let shouldSchedule: Bool = coalesceState.withLock { s in
            s.pendingValue = value
            if !s.isScheduled {
                s.isScheduled = true
                return true
            }
            return false
        }

        if shouldSchedule {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let latest: T? = self.coalesceState.withLock { s in
                    s.isScheduled = false
                    let val = s.pendingValue as? T
                    s.pendingValue = nil
                    return val
                }
                if let latest {
                    action(latest)
                }
            }
        }
    }

    // MARK: - DispatchSourceTimer Polling Loop

    /// Subscription handle for an active timer-based progress polling loop.
    public final class ThrottledPollingSubscription: Sendable {
        private let isCancelled = OSAllocatedUnfairLock(initialState: false)
        private let timer: DispatchSourceTimer

        init(timer: DispatchSourceTimer) {
            self.timer = timer
        }

        /// Cancels the polling timer and releases background dispatch resources.
        public func cancel() {
            let shouldCancel = isCancelled.withLock { cancelled in
                if !cancelled {
                    cancelled = true
                    return true
                }
                return false
            }
            if shouldCancel {
                timer.cancel()
            }
        }

        deinit {
            cancel()
        }
    }

    /// Starts a 60FPS (16.6ms) DispatchSourceTimer periodic polling loop that samples an atomic state provider
    /// and dispatches coalesced updates directly to `@MainActor` without reverse FFI callbacks or UI lock contention.
    public static func startPolling<T: Sendable & Equatable>(
        frequencyHz: Double = 60.0,
        poll: @escaping @Sendable () -> T?,
        isTerminal: @escaping @Sendable (T) -> Bool = { _ in false },
        onUpdate: @escaping @MainActor (T) -> Void
    ) -> ThrottledPollingSubscription {
        let clampedHz = max(1.0, min(120.0, frequencyHz))
        let intervalNs = UInt64(1_000_000_000.0 / clampedHz)
        let leeway = DispatchTimeInterval.milliseconds(1)

        let queue = DispatchQueue(
            label: "com.metastudyline.ttzip.ui-progress-sampler",
            qos: .userInitiated
        )
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        let subscription = ThrottledPollingSubscription(timer: timer)

        let lastEmitted = OSAllocatedUnfairLock<T?>(initialState: nil)
        let coalescer = ThrottledProgressPublisher(maxFrequencyHz: clampedHz)

        timer.schedule(
            deadline: .now() + .nanoseconds(Int(intervalNs)),
            repeating: .nanoseconds(Int(intervalNs)),
            leeway: leeway
        )

        timer.setEventHandler { [weak subscription] in
            guard let subscription, let snapshot = poll() else { return }

            let changed = lastEmitted.withLock { last in
                if last != snapshot {
                    last = snapshot
                    return true
                }
                return false
            }

            let terminal = isTerminal(snapshot)
            if changed || terminal {
                coalescer.coalesceOnMain(value: snapshot, force: terminal) { value in
                    onUpdate(value)
                }
            }

            if terminal {
                subscription.cancel()
            }
        }

        timer.resume()
        return subscription
    }
}
