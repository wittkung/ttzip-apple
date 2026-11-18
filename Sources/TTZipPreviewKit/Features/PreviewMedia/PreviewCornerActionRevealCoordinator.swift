// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Observation
import SwiftUI
import TTMediaKit

/// Shared on-demand visibility policy and coordinator for corner action overlays and video window controls
/// (`PreviewCornerActionOverlayView`, `VideoWindowCornerControlClusterView`, and `StandalonePlaybackTrafficLightsController`).
///
/// Architectural Contract:
/// 1. **Hidden by default**: `0` opacity and non-hit-testing when pointer is outside the corner sensor and unfocused.
/// 2. **Direct reveal intent vs. keep-alive lock**:
///    - Direct reveal sources (`isZoneHovered`, `isButtonHovered`, `isButtonFocused`) can reveal a hidden control.
///    - `isExternallyLocked` is a **keep-alive lock** for an already-revealed control (`isDelayedVisible == true`)
///      owned by the same window/viewport; it never wakes a hidden control on its own.
/// 3. **Grace fade-out & generation invalidation**:
///    Fades out after `hideDelay` (`260ms` by default) once active presence ends, cancelling stale tasks via `generation`.
@MainActor
@Observable
public final class PreviewCornerActionRevealCoordinator {
    public typealias Now = MediaControlsVisibility.Now
    public typealias Wait = MediaControlsVisibility.Wait

    public nonisolated static let defaultHideDelay: Duration = .milliseconds(260)
    public nonisolated static let defaultSensorSize = CGSize(width: 88.0, height: 72.0)

    public private(set) var isZoneHovered = false
    public private(set) var isButtonHovered = false
    public private(set) var isButtonFocused = false
    public private(set) var isExternallyLocked = false
    public private(set) var isDelayedVisible = false
    public var onVisibilityChanged: (@MainActor () -> Void)?

    private let hideDelay: Duration
    private let now: Now
    private let wait: Wait
    private var hideTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        hideDelay: Duration = PreviewCornerActionRevealCoordinator.defaultHideDelay,
        now: @escaping Now = { ContinuousClock.now },
        wait: @escaping Wait = { try await Task.sleep(for: $0) }
    ) {
        self.hideDelay = hideDelay
        self.now = now
        self.wait = wait
    }

    /// True when a direct user reveal source (pointer in sensor zone, pointer on button, or keyboard focus) is active.
    public var hasDirectRevealIntent: Bool {
        isZoneHovered || isButtonHovered || isButtonFocused
    }

    /// True when the control is either actively revealed by direct user intent
    /// or kept alive after reveal by an owned external interaction/menu lock.
    public var isHoldingActivePresence: Bool {
        hasDirectRevealIntent || (isExternallyLocked && isDelayedVisible)
    }

    public var isVisible: Bool {
        isPresented()
    }

    /// Evaluates whether the corner button and its glass plate should currently be visible.
    public static func shouldShowButton(
        explicitState: TTTextFloatingToolsPresentationState? = nil,
        isZoneHovered: Bool,
        isButtonHovered: Bool,
        isButtonFocused: Bool,
        isExternallyLocked: Bool,
        isDelayedVisible: Bool
    ) -> Bool {
        if let explicitState {
            return explicitState != .quietReading
        }
        let hasDirectReveal = isZoneHovered || isButtonHovered || isButtonFocused
        let isKeptAliveByLock = isExternallyLocked && isDelayedVisible
        return hasDirectReveal || isKeptAliveByLock || isDelayedVisible
    }

    /// Evaluates whether `point` (in a flipped top-left coordinate space of `containerSize`)
    /// lies inside the bottom-trailing proximity sensor rect of `sensorSize`.
    public static func isPointInBottomTrailingSensor(
        point: CGPoint,
        containerSize: CGSize,
        sensorSize: CGSize = defaultSensorSize
    ) -> Bool {
        guard containerSize.width > 0, containerSize.height > 0 else { return false }
        let width = min(sensorSize.width, containerSize.width)
        let height = min(sensorSize.height, containerSize.height)
        let rect = CGRect(
            x: containerSize.width - width,
            y: containerSize.height - height,
            width: width,
            height: height
        )
        return rect.contains(point)
    }

    public func isPresented(explicitState: TTTextFloatingToolsPresentationState? = nil) -> Bool {
        Self.shouldShowButton(
            explicitState: explicitState,
            isZoneHovered: isZoneHovered,
            isButtonHovered: isButtonHovered,
            isButtonFocused: isButtonFocused,
            isExternallyLocked: isExternallyLocked,
            isDelayedVisible: isDelayedVisible
        )
    }

    public func setZoneHovered(_ hovered: Bool) {
        guard isZoneHovered != hovered else { return }
        isZoneHovered = hovered
        reconcileVisibility()
    }

    public func setButtonHovered(_ hovered: Bool) {
        guard isButtonHovered != hovered else { return }
        isButtonHovered = hovered
        reconcileVisibility()
    }

    public func setButtonFocused(_ focused: Bool) {
        guard isButtonFocused != focused else { return }
        isButtonFocused = focused
        reconcileVisibility()
    }

    public func setExternallyLocked(_ locked: Bool) {
        guard isExternallyLocked != locked else { return }
        isExternallyLocked = locked
        reconcileVisibility()
    }

    public func tearDown() {
        cancelPendingHide()
        let wasVisible = isDelayedVisible || isZoneHovered || isButtonHovered || isButtonFocused
        isZoneHovered = false
        isButtonHovered = false
        isButtonFocused = false
        isExternallyLocked = false
        isDelayedVisible = false
        if wasVisible {
            onVisibilityChanged?()
        }
    }

    private func reconcileVisibility() {
        if hasDirectRevealIntent {
            cancelPendingHide()
            let changed = !isDelayedVisible
            isDelayedVisible = true
            if changed {
                onVisibilityChanged?()
            }
            return
        }
        guard isDelayedVisible else { return }
        if isExternallyLocked {
            cancelPendingHide()
            return
        }
        scheduleDelayedHide()
    }

    private func scheduleDelayedHide() {
        cancelPendingHide()
        let token = generation
        let delay = hideDelay
        let nowFn = now
        let waitFn = wait
        let expectedDeadline = nowFn().advanced(by: delay)
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
                  self.generation == token,
                  !self.isHoldingActivePresence,
                  nowFn() >= expectedDeadline else {
                return
            }
            self.isDelayedVisible = false
            self.hideTask = nil
            self.onVisibilityChanged?()
        }
    }

    private func cancelPendingHide() {
        generation &+= 1
        hideTask?.cancel()
        hideTask = nil
    }
}

public struct TTPreviewHostWindowNumberReader: NSViewRepresentable {
    @Binding public var windowNumber: Int?

    public init(windowNumber: Binding<Int?>) {
        self._windowNumber = windowNumber
    }

    public func makeNSView(context: Context) -> NSView {
        let view = WindowTrackingNSView()
        view.onWindowChange = { [weak view] in
            let number = view?.window?.windowNumber
            if windowNumber != number {
                windowNumber = number
            }
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        let number = nsView.window?.windowNumber
        if windowNumber != number {
            DispatchQueue.main.async {
                if self.windowNumber != number {
                    self.windowNumber = number
                }
            }
        }
    }

    private final class WindowTrackingNSView: NSView {
        var onWindowChange: (@MainActor () -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }
    }
}
