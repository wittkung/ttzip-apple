// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Observation
import SwiftUI

/// Per-viewport visibility policy owner for video playback controls and cursor visibility.
///
/// Architectural Contract:
/// 1. **Playback state is an input, never a reveal request**:
///    `isPlaying` transitions (`play`/`pause`/`EOF`/seek completion) never manufacture pointer activity
///    or wake hidden UI chrome. Pausing restores a hidden system cursor without revealing controls.
/// 2. **Pointer presence vs. valid pointer activity**:
///    Stationary `isHovered == true` is not new mouse activity. Chrome visibility is derived from
///    explicit pointer entry/movement (`> 0.5pt`), explicit control bar interaction, active interaction
///    locks (`hasActiveInteractionLock`), or explicit keyboard focus (`isKeyboardFocused`).
/// 3. **Pause does not force permanent visibility**:
///    When paused, existing valid pointer activity retains only its remaining deadline (`activityDeadline`)
///    without resetting to a fresh timeout, and expires cleanly when the deadline elapses.
/// 4. **Lock release converges to existing deadline**:
///    Menus, scrubbing, popovers, and file pickers hold visibility locks. Releasing a lock never acts
///    as new pointer activity: if the prior pointer deadline already expired, chrome hides immediately;
///    otherwise it schedules auto-hide only for the remaining unexpired duration.
/// 5. **Single cancellable timer with generation invalidation**:
///    One `hideTask` guarded by `timerGeneration` and `activityDeadline` rejects stale wakeups and
///    invalidates cleanly on `resetForNewItem()` / `tearDown()`.
@MainActor
@Observable
public final class MediaControlsVisibility {
    public typealias Now = @Sendable () -> ContinuousClock.Instant
    public typealias Wait = @Sendable (Duration) async throws -> Void

    public nonisolated static let pointerJitterThreshold: CGFloat = 0.5

    public private(set) var isVisible = false
    public private(set) var isHovered = false
    public private(set) var isCursorHidden = false
    public private(set) var isScrubbing = false
    public private(set) var isKeyboardFocused = false
    public private(set) var lifecycleGeneration: UInt64 = 0

    /// Diagnostic counter incremented whenever an auto-hide task is scheduled.
    public private(set) var scheduledHideTimerCount: Int = 0

    public var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            reconcilePlaybackStateChange(wasPlaying: oldValue)
        }
    }

    public var cursorController = ViewportCursorVisibilityController()
    public var inactivityDuration: Duration = .seconds(3)

    private let now: Now
    private let wait: Wait
    private var hideTask: Task<Void, Never>?
    private var timerGeneration: UInt64 = 0
    private var interactionDepth = 0
    private var activeLockIDs: Set<AnyHashable> = []
    private var lastHoverPoint: CGPoint?
    private var activityDeadline: ContinuousClock.Instant?

    public var hasActiveInteractionLock: Bool {
        interactionDepth > 0 || !activeLockIDs.isEmpty || isScrubbing
    }

    public var isInteracting: Bool {
        hasActiveInteractionLock
    }

    public init(
        inactivityDuration: Duration = .seconds(3),
        cursorController: ViewportCursorVisibilityController? = nil,
        now: @escaping Now = { ContinuousClock.now },
        wait: @escaping Wait = { try await Task.sleep(for: $0) }
    ) {
        self.inactivityDuration = inactivityDuration
        if let cursorController {
            self.cursorController = cursorController
        }
        self.now = now
        self.wait = wait
    }

    public func setHovered(_ hovered: Bool) {
        if !hovered {
            lastHoverPoint = nil
            isHovered = false
            activityDeadline = nil
            cancelHideTask()
            restoreCursorIfNeeded()
            isVisible = hasActiveInteractionLock || isKeyboardFocused
            return
        }
        guard !isHovered else {
            // Stationary re-assertion of isHovered == true must never manufacture new pointer activity.
            return
        }
        isHovered = true
        recordPointerActivity()
    }

    public func recordMouseMove(at point: CGPoint) {
        if let prev = lastHoverPoint, isHovered {
            let distance = hypot(point.x - prev.x, point.y - prev.y)
            guard distance > Self.pointerJitterThreshold else { return }
        }
        lastHoverPoint = point
        isHovered = true
        recordPointerActivity()
    }

    /// Records an interaction with a visible host control.
    public func recordControlBarInteraction() {
        guard isHovered || isVisible || hasActiveInteractionLock || isKeyboardFocused else { return }
        recordPointerActivity()
    }

    public func setKeyboardFocused(_ focused: Bool) {
        guard isKeyboardFocused != focused else { return }
        isKeyboardFocused = focused
        if focused {
            cancelHideTask()
            restoreCursorIfNeeded()
            isVisible = true
        } else {
            convergeAfterLockOrFocusRelease()
        }
    }

    public func setScrubbing(_ scrubbing: Bool) {
        guard isScrubbing != scrubbing else { return }
        isScrubbing = scrubbing
        if scrubbing {
            acquireInteractionLock(id: "scrubbing")
        } else {
            releaseInteractionLock(id: "scrubbing")
        }
    }

    public func acquireInteractionLock(id: AnyHashable) {
        activeLockIDs.insert(id)
        cancelHideTask()
        restoreCursorIfNeeded()
        isVisible = true
    }

    public func releaseInteractionLock(id: AnyHashable) {
        guard activeLockIDs.remove(id) != nil else { return }
        convergeAfterLockOrFocusRelease()
    }

    public func beginInteraction() {
        interactionDepth += 1
        cancelHideTask()
        restoreCursorIfNeeded()
        isVisible = true
    }

    public func endInteraction() {
        guard interactionDepth > 0 else { return }
        interactionDepth -= 1
        convergeAfterLockOrFocusRelease()
    }

    /// Legacy entry point retained for compatibility; refreshes activity only when the pointer is inside
    /// and has not yet expired, or when an explicit lock/focus is held.
    public func interact() {
        if hasActiveInteractionLock || isKeyboardFocused {
            cancelHideTask()
            restoreCursorIfNeeded()
            isVisible = true
            return
        }
        guard isHovered else {
            cancelHideTask()
            restoreCursorIfNeeded()
            isVisible = false
            return
        }
        if activityDeadline == nil && !isVisible {
            recordPointerActivity()
        } else {
            convergeAfterLockOrFocusRelease()
        }
    }

    public func forceRestoreCursor() {
        cancelHideTask()
        restoreCursorIfNeeded()
        cursorController.forceRestoreCursor()
    }

    public func resetForNewItem() {
        lifecycleGeneration &+= 1
        TTMediaOwnedMenuRegistry.invalidateOwnedMenus(for: self)
        cancelHideTask()
        activeLockIDs.removeAll()
        interactionDepth = 0
        isScrubbing = false
        isKeyboardFocused = false
        activityDeadline = nil
        lastHoverPoint = nil
        isVisible = false
        restoreCursorIfNeeded()
    }

    public func tearDown() {
        lifecycleGeneration &+= 1
        TTMediaOwnedMenuRegistry.invalidateOwnedMenus(for: self)
        cancelHideTask()
        activeLockIDs.removeAll()
        interactionDepth = 0
        isScrubbing = false
        isKeyboardFocused = false
        isHovered = false
        activityDeadline = nil
        lastHoverPoint = nil
        isVisible = false
        isCursorHidden = false
        cursorController.forceRestoreCursor()
    }

    internal func hideForInactivity() {
        guard !hasActiveInteractionLock, !isKeyboardFocused else { return }
        activityDeadline = nil
        isVisible = false
        if isPlaying && isHovered {
            isCursorHidden = true
            cursorController.applyCursorHidden(true)
        } else {
            restoreCursorIfNeeded()
        }
    }

    // MARK: - Internal Policy Reconciliation

    private func recordPointerActivity() {
        let currentInstant = now()
        let deadline = currentInstant.advanced(by: inactivityDuration)
        activityDeadline = deadline
        restoreCursorIfNeeded()
        isVisible = true
        if !hasActiveInteractionLock && !isKeyboardFocused {
            scheduleHideTask(delay: inactivityDuration, expectedDeadline: deadline)
        } else {
            cancelHideTask()
        }
    }

    private func reconcilePlaybackStateChange(wasPlaying: Bool) {
        if !isPlaying {
            // Pausing restores a hidden cursor if needed, but NEVER reveals hidden UI or extends activityDeadline.
            restoreCursorIfNeeded()
            return
        }
        // Transitioned from paused -> playing:
        // Never reveal hidden UI; if already visible without locks, ensure remaining deadline is scheduled.
        if isVisible && !hasActiveInteractionLock && !isKeyboardFocused {
            convergeAfterLockOrFocusRelease()
        }
    }

    private func convergeAfterLockOrFocusRelease() {
        if hasActiveInteractionLock || isKeyboardFocused {
            cancelHideTask()
            restoreCursorIfNeeded()
            isVisible = true
            return
        }
        guard isHovered else {
            cancelHideTask()
            activityDeadline = nil
            restoreCursorIfNeeded()
            isVisible = false
            return
        }
        let currentInstant = now()
        if let deadline = activityDeadline, currentInstant < deadline {
            let remaining = currentInstant.duration(to: deadline)
            isVisible = true
            restoreCursorIfNeeded()
            scheduleHideTask(delay: remaining, expectedDeadline: deadline)
        } else {
            cancelHideTask()
            hideForInactivity()
        }
    }

    private func scheduleHideTask(delay: Duration, expectedDeadline: ContinuousClock.Instant) {
        cancelHideTask()
        let token = timerGeneration
        let waitFn = wait
        let nowFn = now
        scheduledHideTimerCount += 1
        hideTask = Task { @MainActor [weak self] in
            do {
                var firstPassDelay: Duration? = delay
                while !Task.isCancelled {
                    let remaining: Duration
                    if let initial = firstPassDelay {
                        firstPassDelay = nil
                        let deadlineRemaining = nowFn().duration(to: expectedDeadline)
                        remaining = min(initial, deadlineRemaining)
                    } else {
                        remaining = nowFn().duration(to: expectedDeadline)
                    }
                    if remaining <= .zero {
                        break
                    }
                    try await waitFn(remaining)
                }
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.timerGeneration == token,
                  !self.hasActiveInteractionLock,
                  !self.isKeyboardFocused,
                  nowFn() >= expectedDeadline else {
                return
            }
            if let currentDeadline = self.activityDeadline,
               nowFn() < currentDeadline {
                return
            }
            self.hideTask = nil
            self.hideForInactivity()
        }
    }

    private func cancelHideTask() {
        timerGeneration &+= 1
        hideTask?.cancel()
        hideTask = nil
    }

    private func restoreCursorIfNeeded() {
        if isCursorHidden {
            isCursorHidden = false
        }
        cursorController.applyCursorHidden(false)
    }
}

private struct MediaControlsVisibilityKey: EnvironmentKey {
    static let defaultValue: MediaControlsVisibility? = nil
}

extension EnvironmentValues {
    public var mediaControlsVisibility: MediaControlsVisibility? {
        get { self[MediaControlsVisibilityKey.self] }
        set { self[MediaControlsVisibilityKey.self] = newValue }
    }
}
