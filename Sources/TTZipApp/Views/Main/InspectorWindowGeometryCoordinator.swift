// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Observation
import SwiftUI
import TTKitDesign
import TTZipUI

/// Physical disposition of a window geometry transition triggered by right inspector expand/collapse.
public enum InspectorWindowGeometryDisposition: String, Sendable, Equatable {
    /// Normal desktop window: `frame.minX` stays stationary, `frame.width` changes by exact `rightPane + gutter`,
    /// and `centerWidth` remains invariant.
    case resizedKeepingLeftEdge
    /// Expanding rightward would overflow `screen.visibleFrame.maxX`, but total target width fits on screen:
    /// window `frame.origin.x` was shifted leftward within `visibleFrame` so full target width (`centerWidth` + `rightPane`) is preserved.
    case shiftedLeftToFitScreen
    /// Target expanded width exceeds the entire `screen.visibleFrame.width`:
    /// window spans `visibleFrame.minX ..< visibleFrame.maxX`, clamping `rightPaneWidth` toward `minRightSidebarWidth` first to protect `centerWidth`.
    case clampedToScreenWidth
    /// Window is in macOS system full-screen, Full Screen Split View tile, live resize, miniaturized, non-resizable,
    /// or had its `setFrame` rejected/clamped by an external window manager:
    /// `NSWindow.setFrame` is not forced (or safely degraded on rejection), full-screen is not exited, and the inspector toggles in-place within the system viewport.
    case inPlaceConstrainedFullScreenOrTiled
    /// No window frame change was needed (e.g. target visibility already matched, or right panel is unavailable in Storage Inspector / Media Focus).
    case noChange
}

/// Verified macOS AppKit SDK system constraint reason preventing or rejecting an ordinary desktop `NSWindow.setFrame` transition.
public enum InspectorWindowSystemConstraintReason: String, Sendable, Equatable {
    /// `window.styleMask.contains(.fullScreen)` is active (covers both macOS native Full Screen and Full Screen Split View tiles per `NSWindowCollectionBehaviorFullScreenAllowsTiling`).
    case fullScreenStyleMask
    /// Window is between `willEnterFullScreenNotification` and `didEnterFullScreenNotification` (or `willExitFullScreenNotification` and `didExitFullScreenNotification`).
    case fullScreenTransition
    /// User or system is actively resizing the window (`window.inLiveResize` or between `willStartLiveResizeNotification` and `didEndLiveResizeNotification`).
    case liveResizeInProgress
    /// Window is miniaturized into the Dock (`window.isMiniaturized` or `willMiniaturizeNotification` / `didMiniaturizeNotification`).
    case miniaturized
    /// Window styleMask does not include `.resizable`.
    case nonResizableStyleMask
    /// Post-`setFrame` verification detected that the window manager / `NSWindowDelegate` rejected or clamped the requested frame width.
    /// Note: Public AppKit `NSWindow` APIs do not expose a pre-flight property for non-fullscreen desktop tiling (e.g. macOS WindowManager desktop tiles);
    /// if a desktop tile or external window manager locks the frame against `setFrame`, this post-`setFrame` check safely degrades in-place.
    case frameRejectedByWindowManager
}

/// Captured snapshot and outcome of a single right inspector expand/collapse transition.
public struct InspectorWindowGeometryTransitionOutcome: Sendable, Equatable {
    public let disposition: InspectorWindowGeometryDisposition
    public let systemConstraintReason: InspectorWindowSystemConstraintReason?
    public let previousFrame: CGRect
    public let appliedFrame: CGRect
    public let preTransitionCenterWidth: CGFloat
    public let postTransitionCenterWidth: CGFloat
    public let rightPaneWidth: CGFloat
    public let dividerGutterWidth: CGFloat

    public init(
        disposition: InspectorWindowGeometryDisposition,
        systemConstraintReason: InspectorWindowSystemConstraintReason? = nil,
        previousFrame: CGRect,
        appliedFrame: CGRect,
        preTransitionCenterWidth: CGFloat,
        postTransitionCenterWidth: CGFloat,
        rightPaneWidth: CGFloat,
        dividerGutterWidth: CGFloat
    ) {
        self.disposition = disposition
        self.systemConstraintReason = systemConstraintReason
        self.previousFrame = previousFrame
        self.appliedFrame = appliedFrame
        self.preTransitionCenterWidth = preTransitionCenterWidth
        self.postTransitionCenterWidth = postTransitionCenterWidth
        self.rightPaneWidth = rightPaneWidth
        self.dividerGutterWidth = dividerGutterWidth
    }

    public var totalRightFootprint: CGFloat {
        rightPaneWidth + dividerGutterWidth
    }
}

/// Window-local coordinator that preserves `centerWidth` and `window.frame.minX` when collapsing or expanding
/// the right inspector column. Bound 1:1 per window (`windowID`) without embedding `NSWindow` or `NSScreen`
/// into `NavigationState` or mutating global `@AppStorage` user preferences.
@MainActor
@Observable
public final class InspectorWindowGeometryCoordinator {
    /// Window-scoped registry mapping `AppViewState.windowID` to its local geometry coordinator.
    private static var coordinatorsByWindowID: [UUID: InspectorWindowGeometryCoordinator] = [:]

    /// Optional screen `visibleFrame` override for deterministic offscreen multi-display geometry tests.
    public var screenVisibleFrameOverride: CGRect?
    /// Test-only hook to neutralize `NSWindow.setFrame` for mutation-testing verification.
    public var isWindowFrameResizeNeutralizedForTesting: Bool = false

    public let windowID: UUID
    public private(set) var capturedRightPaneWidth: CGFloat?
    public private(set) var capturedRightGutterWidth: CGFloat = ResizableDividerHandle.gutterWidth
    public private(set) var lockedExpandedRightWidth: CGFloat?
    public private(set) var lastCoordinatedVisibility: Bool
    public private(set) var lastLiveRightPaneWidth: CGFloat = MainLayoutMetrics.defaultRightSidebarWidth
    public private(set) var lastLiveLeftSidebarWidth: CGFloat = MainLayoutMetrics.defaultLeftSidebarWidth
    public private(set) var lastLiveCenterWidth: CGFloat = 0
    public private(set) var lastObservedWindowWidth: CGFloat = 0
    public private(set) var effectiveMinimumContentWidth: CGFloat = 720.0
    public private(set) var lastTransitionOutcome: InspectorWindowGeometryTransitionOutcome?

    /// Real AppKit window lifecycle state tracked from `NSWindow` notifications.
    public private(set) var isInFullScreenTransition: Bool = false
    public private(set) var isSystemFullScreenActive: Bool = false
    public private(set) var isInLiveResizeSession: Bool = false
    public private(set) var isWindowMiniaturized: Bool = false

    private var isPerformingProgrammaticFrameChange: Bool = false
    private weak var observedWindow: NSWindow?
    private var windowLifecycleObservers: [NSObjectProtocol] = []

    public init(windowID: UUID, initialVisibility: Bool = true) {
        self.windowID = windowID
        self.lastCoordinatedVisibility = initialVisibility
        Self.installViewModelHookIfNeeded()
    }

    public static func installViewModelHookIfNeeded() {
        if AppViewState.windowInspectorVisibilityCoordinatorHook == nil {
            AppViewState.windowInspectorVisibilityCoordinatorHook = { state, isVisible in
                let coord = InspectorWindowGeometryCoordinator.coordinator(
                    for: state.windowID,
                    initialVisibility: state.navigationState.isInspectorVisible
                )
                _ = coord.setInspectorVisible(isVisible, for: state)
            }
        }
    }

    public static func coordinator(
        for windowID: UUID,
        initialVisibility: Bool = true
    ) -> InspectorWindowGeometryCoordinator {
        if let existing = coordinatorsByWindowID[windowID] {
            return existing
        }
        let created = InspectorWindowGeometryCoordinator(
            windowID: windowID,
            initialVisibility: initialVisibility
        )
        coordinatorsByWindowID[windowID] = created
        return created
    }

    public static func existingCoordinator(for windowID: UUID) -> InspectorWindowGeometryCoordinator? {
        coordinatorsByWindowID[windowID]
    }

    public static func unregister(windowID: UUID) {
        if let existing = coordinatorsByWindowID.removeValue(forKey: windowID) {
            existing.detachWindowLifecycleObservers()
        }
    }

    // MARK: - Real AppKit Window Constraint & Lifecycle Observation

    /// Attaches real `NSWindow` lifecycle observers (`willEnterFullScreen`, `didEnterFullScreen`, `willExitFullScreen`,
    /// `didExitFullScreen`, `willStartLiveResize`, `didEndLiveResize`, `willMiniaturize`, `didMiniaturize`, `didDeminiaturize`)
    /// so system-managed window states are tracked from authoritative AppKit notifications and live `NSWindow` properties.
    public func attachWindowLifecycleObservers(to window: NSWindow) {
        syncLiveWindowConstraintProperties(from: window)
        guard observedWindow !== window else { return }
        detachWindowLifecycleObservers()
        observedWindow = window

        let center = NotificationCenter.default
        let namesAndHandlers: [(Notification.Name, @MainActor (InspectorWindowGeometryCoordinator, NSWindow) -> Void)] = [
            (NSWindow.willEnterFullScreenNotification, { coord, _ in
                coord.isInFullScreenTransition = true
                coord.isSystemFullScreenActive = true
            }),
            (NSWindow.didEnterFullScreenNotification, { coord, win in
                coord.isInFullScreenTransition = false
                coord.isSystemFullScreenActive = true
                coord.lastObservedWindowWidth = win.frame.width
            }),
            (NSWindow.willExitFullScreenNotification, { coord, _ in
                coord.isInFullScreenTransition = true
            }),
            (NSWindow.didExitFullScreenNotification, { coord, win in
                coord.isInFullScreenTransition = false
                coord.isSystemFullScreenActive = win.styleMask.contains(.fullScreen)
                coord.lastObservedWindowWidth = win.frame.width
            }),
            (NSWindow.willStartLiveResizeNotification, { coord, _ in
                coord.isInLiveResizeSession = true
            }),
            (NSWindow.didEndLiveResizeNotification, { coord, win in
                coord.isInLiveResizeSession = false
                coord.lastObservedWindowWidth = win.frame.width
            }),
            (NSWindow.willMiniaturizeNotification, { coord, _ in
                coord.isWindowMiniaturized = true
            }),
            (NSWindow.didMiniaturizeNotification, { coord, _ in
                coord.isWindowMiniaturized = true
            }),
            (NSWindow.didDeminiaturizeNotification, { coord, win in
                coord.isWindowMiniaturized = win.isMiniaturized
            })
        ]

        for (notificationName, handler) in namesAndHandlers {
            let token = center.addObserver(forName: notificationName, object: window, queue: .main) { [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window else { return }
                    handler(self, window)
                }
            }
            windowLifecycleObservers.append(token)
        }
    }

    public func detachWindowLifecycleObservers() {
        let center = NotificationCenter.default
        for token in windowLifecycleObservers {
            center.removeObserver(token)
        }
        windowLifecycleObservers.removeAll()
        observedWindow = nil
    }

    private func syncLiveWindowConstraintProperties(from window: NSWindow) {
        if window.styleMask.contains(.fullScreen) {
            isSystemFullScreenActive = true
        } else if !isInFullScreenTransition {
            isSystemFullScreenActive = false
        }
        if window.inLiveResize {
            isInLiveResizeSession = true
        }
        if window.isMiniaturized {
            isWindowMiniaturized = true
        }
    }

    /// Evaluates authoritative AppKit `NSWindow` state and lifecycle flags to determine whether the window size
    /// is currently constrained/owned by the system.
    public func activeSystemConstraintReason(for window: NSWindow) -> InspectorWindowSystemConstraintReason? {
        if isInFullScreenTransition {
            return .fullScreenTransition
        }
        if window.styleMask.contains(.fullScreen) || isSystemFullScreenActive {
            return .fullScreenStyleMask
        }
        if window.inLiveResize || isInLiveResizeSession {
            return .liveResizeInProgress
        }
        if window.isMiniaturized || isWindowMiniaturized {
            return .miniaturized
        }
        if !window.styleMask.isEmpty && !window.styleMask.contains(.resizable) {
            return .nonResizableStyleMask
        }
        return nil
    }

    /// Synchronizes live layout metrics rendered by `MainView` so collapse always captures the exact active right width,
    /// and manual user window resize while expanded releases `lockedExpandedRightWidth` for proportional scaling.
    public func recordLiveLayout(
        windowWidth: CGFloat,
        leftSidebarWidth: CGFloat,
        metrics: MainLayoutMetrics,
        isRightVisible: Bool,
        isDraggingDivider: Bool
    ) {
        lastLiveLeftSidebarWidth = leftSidebarWidth
        if isDraggingDivider {
            lockedExpandedRightWidth = nil
        } else if isRightVisible,
                  !isPerformingProgrammaticFrameChange,
                  lastObservedWindowWidth > 0,
                  abs(windowWidth - lastObservedWindowWidth) > 1.0 {
            lockedExpandedRightWidth = nil
        }
        lastObservedWindowWidth = windowWidth
        if metrics.shouldShowRight && metrics.effectiveRightWidth > 0 {
            lastLiveRightPaneWidth = metrics.effectiveRightWidth
            capturedRightGutterWidth = ResizableDividerHandle.gutterWidth
        }
        lastLiveCenterWidth = metrics.centerWidth
    }

    /// Updates the coordinator when the user explicitly drags or double-clicks the right inspector divider.
    public func recordUserDividerCommit(clampedRightWidth: CGFloat) {
        lastLiveRightPaneWidth = clampedRightWidth
        capturedRightPaneWidth = clampedRightWidth
        lockedExpandedRightWidth = clampedRightWidth
    }

    /// Coordinates a transition of `navigationState.isInspectorVisible` and synchronously adjusts the window frame.
    @discardableResult
    public func setInspectorVisible(
        _ targetVisible: Bool,
        for viewModel: AppViewState,
        userRightRatio: CGFloat? = nil
    ) -> InspectorWindowGeometryTransitionOutcome {
        let currentVisible = viewModel.navigationState.isInspectorVisible
        if currentVisible == targetVisible && lastCoordinatedVisibility == targetVisible {
            let frame = resolveWindow(for: viewModel)?.frame ?? .zero
            let noOp = InspectorWindowGeometryTransitionOutcome(
                disposition: .noChange,
                previousFrame: frame,
                appliedFrame: frame,
                preTransitionCenterWidth: lastLiveCenterWidth,
                postTransitionCenterWidth: lastLiveCenterWidth,
                rightPaneWidth: lastLiveRightPaneWidth,
                dividerGutterWidth: capturedRightGutterWidth
            )
            lastTransitionOutcome = noOp
            return noOp
        }

        viewModel.navigationState.isInspectorVisible = targetVisible
        return synchronizeGeometryForCurrentVisibility(
            of: viewModel,
            userRightRatio: userRightRatio
        )
    }

    /// Reconciles window geometry if `navigationState.isInspectorVisible` was mutated directly or via `setInspectorVisible`.
    @discardableResult
    public func synchronizeGeometryForCurrentVisibility(
        of viewModel: AppViewState,
        userRightRatio: CGFloat? = nil
    ) -> InspectorWindowGeometryTransitionOutcome {
        let targetVisible = viewModel.navigationState.isInspectorVisible
        guard targetVisible != lastCoordinatedVisibility else {
            let frame = resolveWindow(for: viewModel)?.frame ?? .zero
            let noOp = InspectorWindowGeometryTransitionOutcome(
                disposition: .noChange,
                previousFrame: frame,
                appliedFrame: frame,
                preTransitionCenterWidth: lastLiveCenterWidth,
                postTransitionCenterWidth: lastLiveCenterWidth,
                rightPaneWidth: lastLiveRightPaneWidth,
                dividerGutterWidth: capturedRightGutterWidth
            )
            lastTransitionOutcome = noOp
            return noOp
        }

        lastCoordinatedVisibility = targetVisible
        let ratio = userRightRatio ?? resolveStoredRightRatio()
        guard let window = resolveWindow(for: viewModel) else {
            return coordinateWithoutMountedWindow(
                targetVisible: targetVisible,
                viewModel: viewModel,
                rightRatio: ratio
            )
        }
        attachWindowLifecycleObservers(to: window)

        if !isRightPanelEligibleInCurrentMode(viewModel: viewModel) {
            updateWindowMinimumSize(window: window, viewModel: viewModel, isRightVisible: targetVisible)
            let outcome = InspectorWindowGeometryTransitionOutcome(
                disposition: .noChange,
                previousFrame: window.frame,
                appliedFrame: window.frame,
                preTransitionCenterWidth: lastLiveCenterWidth,
                postTransitionCenterWidth: lastLiveCenterWidth,
                rightPaneWidth: 0,
                dividerGutterWidth: 0
            )
            lastTransitionOutcome = outcome
            return outcome
        }

        if let constraintReason = activeSystemConstraintReason(for: window) {
            return handleConstrainedWindowTransition(
                window: window,
                reason: constraintReason,
                targetVisible: targetVisible,
                viewModel: viewModel,
                rightRatio: ratio
            )
        }

        if targetVisible {
            return performExpandTransition(window: window, viewModel: viewModel, rightRatio: ratio)
        } else {
            return performCollapseTransition(window: window, viewModel: viewModel, rightRatio: ratio)
        }
    }

    // MARK: - Collapse & Expand Mechanics

    private func performCollapseTransition(
        window: NSWindow,
        viewModel: AppViewState,
        rightRatio: CGFloat
    ) -> InspectorWindowGeometryTransitionOutcome {
        let previousFrame = window.frame
        let currentSize = previousFrame.size
        let preMetrics = MainLayoutMetrics.compute(
            size: currentSize,
            viewModel: viewModel,
            isLeftVisible: viewModel.navigationState.isLeftSidebarVisible,
            isRightVisible: true,
            leftWidth: lastLiveLeftSidebarWidth,
            rightRatio: rightRatio,
            lockedRightWidth: lockedExpandedRightWidth
        )

        let actualRightWidth = preMetrics.effectiveRightWidth > 0 ? preMetrics.effectiveRightWidth : lastLiveRightPaneWidth
        let gutterWidth = ResizableDividerHandle.gutterWidth
        capturedRightPaneWidth = actualRightWidth
        capturedRightGutterWidth = gutterWidth
        lockedExpandedRightWidth = actualRightWidth

        let deltaWidth = actualRightWidth + gutterWidth
        updateWindowMinimumSize(window: window, viewModel: viewModel, isRightVisible: false)

        let minLegalCollapsedWidth = MainLayoutMetrics.minimumContentWidth(
            viewModel: viewModel,
            isLeftVisible: viewModel.navigationState.isLeftSidebarVisible,
            isRightVisible: false,
            leftWidth: lastLiveLeftSidebarWidth
        )
        let targetWidth = max(minLegalCollapsedWidth, previousFrame.width - deltaWidth)
        let targetFrame = CGRect(
            x: previousFrame.origin.x,
            y: previousFrame.origin.y,
            width: targetWidth,
            height: previousFrame.height
        )

        let frameAppliedCleanly = applyWindowFrame(targetFrame, to: window)
        let postSize = window.frame.size
        let postMetrics = MainLayoutMetrics.compute(
            size: postSize,
            viewModel: viewModel,
            isLeftVisible: viewModel.navigationState.isLeftSidebarVisible,
            isRightVisible: false,
            leftWidth: lastLiveLeftSidebarWidth,
            rightRatio: rightRatio
        )
        lastLiveCenterWidth = postMetrics.centerWidth

        let disposition: InspectorWindowGeometryDisposition = frameAppliedCleanly
            ? .resizedKeepingLeftEdge
            : .inPlaceConstrainedFullScreenOrTiled
        let reason: InspectorWindowSystemConstraintReason? = frameAppliedCleanly
            ? nil
            : .frameRejectedByWindowManager

        let outcome = InspectorWindowGeometryTransitionOutcome(
            disposition: disposition,
            systemConstraintReason: reason,
            previousFrame: previousFrame,
            appliedFrame: window.frame,
            preTransitionCenterWidth: preMetrics.centerWidth,
            postTransitionCenterWidth: postMetrics.centerWidth,
            rightPaneWidth: actualRightWidth,
            dividerGutterWidth: gutterWidth
        )
        lastTransitionOutcome = outcome
        return outcome
    }

    private func performExpandTransition(
        window: NSWindow,
        viewModel: AppViewState,
        rightRatio: CGFloat
    ) -> InspectorWindowGeometryTransitionOutcome {
        let previousFrame = window.frame
        let currentSize = previousFrame.size
        let preMetrics = MainLayoutMetrics.compute(
            size: currentSize,
            viewModel: viewModel,
            isLeftVisible: viewModel.navigationState.isLeftSidebarVisible,
            isRightVisible: false,
            leftWidth: lastLiveLeftSidebarWidth,
            rightRatio: rightRatio
        )

        let minRight = viewModel.navigationState.isCompressWorkspaceActive
            ? 280.0
            : MainLayoutMetrics.minRightSidebarWidth
        let desiredRightWidth = max(
            minRight,
            min(
                MainLayoutMetrics.maxRightInspectorErgonomicCap,
                capturedRightPaneWidth ?? lastLiveRightPaneWidth
            )
        )
        let gutterWidth = capturedRightGutterWidth > 0 ? capturedRightGutterWidth : ResizableDividerHandle.gutterWidth
        let deltaWidth = desiredRightWidth + gutterWidth
        let idealWidth = previousFrame.width + deltaWidth

        let (resolvedFrame, resolvedRightWidth, plannedDisposition) = resolveExpandedWindowFrame(
            previousFrame: previousFrame,
            idealWidth: idealWidth,
            desiredRightWidth: desiredRightWidth,
            minRightWidth: minRight,
            gutterWidth: gutterWidth,
            window: window
        )

        lockedExpandedRightWidth = resolvedRightWidth
        lastLiveRightPaneWidth = resolvedRightWidth
        let frameAppliedCleanly = applyWindowFrame(resolvedFrame, to: window)
        if !frameAppliedCleanly {
            // Safe degradation when an external window manager or desktop tile clamps/rejects `setFrame`:
            // release `lockedExpandedRightWidth` so `MainLayoutMetrics` fits both columns safely inside the actual window width.
            lockedExpandedRightWidth = nil
        }
        updateWindowMinimumSize(window: window, viewModel: viewModel, isRightVisible: true)

        let postSize = window.frame.size
        let postMetrics = MainLayoutMetrics.compute(
            size: postSize,
            viewModel: viewModel,
            isLeftVisible: viewModel.navigationState.isLeftSidebarVisible,
            isRightVisible: true,
            leftWidth: lastLiveLeftSidebarWidth,
            rightRatio: rightRatio,
            lockedRightWidth: lockedExpandedRightWidth
        )
        lastLiveCenterWidth = postMetrics.centerWidth
        if postMetrics.effectiveRightWidth > 0 {
            lastLiveRightPaneWidth = postMetrics.effectiveRightWidth
        }

        let finalDisposition: InspectorWindowGeometryDisposition = frameAppliedCleanly
            ? plannedDisposition
            : .inPlaceConstrainedFullScreenOrTiled
        let reason: InspectorWindowSystemConstraintReason? = frameAppliedCleanly
            ? nil
            : .frameRejectedByWindowManager

        let outcome = InspectorWindowGeometryTransitionOutcome(
            disposition: finalDisposition,
            systemConstraintReason: reason,
            previousFrame: previousFrame,
            appliedFrame: window.frame,
            preTransitionCenterWidth: preMetrics.centerWidth,
            postTransitionCenterWidth: postMetrics.centerWidth,
            rightPaneWidth: postMetrics.effectiveRightWidth,
            dividerGutterWidth: gutterWidth
        )
        lastTransitionOutcome = outcome
        return outcome
    }

    private func resolveExpandedWindowFrame(
        previousFrame: CGRect,
        idealWidth: CGFloat,
        desiredRightWidth: CGFloat,
        minRightWidth: CGFloat,
        gutterWidth: CGFloat,
        window: NSWindow
    ) -> (CGRect, CGFloat, InspectorWindowGeometryDisposition) {
        guard let visibleFrame = screenVisibleFrameOverride ?? window.screen?.visibleFrame else {
            let frame = CGRect(
                x: previousFrame.origin.x,
                y: previousFrame.origin.y,
                width: idealWidth,
                height: previousFrame.height
            )
            return (frame, desiredRightWidth, .resizedKeepingLeftEdge)
        }

        // Case 1: Normal window fits without crossing visibleFrame.maxX
        if previousFrame.minX + idealWidth <= visibleFrame.maxX + 0.5 {
            let frame = CGRect(
                x: previousFrame.origin.x,
                y: previousFrame.origin.y,
                width: idealWidth,
                height: previousFrame.height
            )
            return (frame, desiredRightWidth, .resizedKeepingLeftEdge)
        }

        // Case 2: Target width fits within visibleFrame.width by shifting origin.x leftward
        if idealWidth <= visibleFrame.width + 0.5 {
            let shiftedOriginX = max(visibleFrame.minX, visibleFrame.maxX - idealWidth)
            let frame = CGRect(
                x: shiftedOriginX,
                y: previousFrame.origin.y,
                width: idealWidth,
                height: previousFrame.height
            )
            return (frame, desiredRightWidth, .shiftedLeftToFitScreen)
        }

        // Case 3: Target width exceeds entire screen visibleFrame.width; clamp to visibleFrame and shrink right pane first
        let clampedWidth = visibleFrame.width
        let availableDeltaForRight = max(minRightWidth, clampedWidth - previousFrame.width - gutterWidth)
        let clampedRightWidth = min(desiredRightWidth, availableDeltaForRight)
        let frame = CGRect(
            x: visibleFrame.minX,
            y: previousFrame.origin.y,
            width: clampedWidth,
            height: previousFrame.height
        )
        return (frame, clampedRightWidth, .clampedToScreenWidth)
    }

    // MARK: - Constrained / Unmounted Helpers

    private func handleConstrainedWindowTransition(
        window: NSWindow,
        reason: InspectorWindowSystemConstraintReason,
        targetVisible: Bool,
        viewModel: AppViewState,
        rightRatio: CGFloat
    ) -> InspectorWindowGeometryTransitionOutcome {
        let frame = window.frame
        let size = window.contentLayoutRect.size.width > 0 ? window.contentLayoutRect.size : frame.size
        let preMetrics = MainLayoutMetrics.compute(
            size: size,
            viewModel: viewModel,
            isLeftVisible: viewModel.navigationState.isLeftSidebarVisible,
            isRightVisible: !targetVisible,
            leftWidth: lastLiveLeftSidebarWidth,
            rightRatio: rightRatio,
            lockedRightWidth: lockedExpandedRightWidth
        )
        if !targetVisible && preMetrics.effectiveRightWidth > 0 {
            capturedRightPaneWidth = preMetrics.effectiveRightWidth
        }
        let postMetrics = MainLayoutMetrics.compute(
            size: size,
            viewModel: viewModel,
            isLeftVisible: viewModel.navigationState.isLeftSidebarVisible,
            isRightVisible: targetVisible,
            leftWidth: lastLiveLeftSidebarWidth,
            rightRatio: rightRatio,
            lockedRightWidth: lockedExpandedRightWidth
        )
        let outcome = InspectorWindowGeometryTransitionOutcome(
            disposition: .inPlaceConstrainedFullScreenOrTiled,
            systemConstraintReason: reason,
            previousFrame: frame,
            appliedFrame: frame,
            preTransitionCenterWidth: preMetrics.centerWidth,
            postTransitionCenterWidth: postMetrics.centerWidth,
            rightPaneWidth: targetVisible ? postMetrics.effectiveRightWidth : preMetrics.effectiveRightWidth,
            dividerGutterWidth: ResizableDividerHandle.gutterWidth
        )
        lastTransitionOutcome = outcome
        return outcome
    }

    private func coordinateWithoutMountedWindow(
        targetVisible: Bool,
        viewModel: AppViewState,
        rightRatio: CGFloat
    ) -> InspectorWindowGeometryTransitionOutcome {
        if !targetVisible {
            capturedRightPaneWidth = lastLiveRightPaneWidth
            lockedExpandedRightWidth = lastLiveRightPaneWidth
        } else if let captured = capturedRightPaneWidth {
            lockedExpandedRightWidth = captured
        }
        let outcome = InspectorWindowGeometryTransitionOutcome(
            disposition: .noChange,
            previousFrame: .zero,
            appliedFrame: .zero,
            preTransitionCenterWidth: lastLiveCenterWidth,
            postTransitionCenterWidth: lastLiveCenterWidth,
            rightPaneWidth: capturedRightPaneWidth ?? lastLiveRightPaneWidth,
            dividerGutterWidth: capturedRightGutterWidth
        )
        lastTransitionOutcome = outcome
        return outcome
    }

    public func updateWindowMinimumSize(
        window: NSWindow,
        viewModel: AppViewState,
        isRightVisible: Bool
    ) {
        let minWidth = MainLayoutMetrics.minimumContentWidth(
            viewModel: viewModel,
            isLeftVisible: viewModel.navigationState.isLeftSidebarVisible,
            isRightVisible: isRightVisible,
            leftWidth: lastLiveLeftSidebarWidth
        )
        effectiveMinimumContentWidth = minWidth
        let currentMinHeight = max(MainLayoutMetrics.minimumWindowContentHeight, window.minSize.height)
        if window.styleMask.contains(.titled) {
            window.contentMinSize = NSSize(width: minWidth, height: currentMinHeight)
        }
        window.minSize = NSSize(width: minWidth, height: currentMinHeight)
    }

    /// Applies `targetFrame` to `window` via AppKit `NSWindow.setFrame(_:display:animate:)` without manually
    /// overwriting `window.contentView.frame`. In TTZip's `.fullSizeContentView` main browser window, AppKit's
    /// `NSThemeFrame` owns and resizes `contentView` directly.
    /// Returns `true` if `window.frame.width` matched `targetFrame.width` within `1.0pt`, or `false` if an
    /// external window manager / `NSWindowDelegate` rejected or clamped the frame change.
    @discardableResult
    private func applyWindowFrame(_ targetFrame: CGRect, to window: NSWindow) -> Bool {
        guard !isWindowFrameResizeNeutralizedForTesting else { return true }
        isPerformingProgrammaticFrameChange = true
        defer { isPerformingProgrammaticFrameChange = false }
        window.setFrame(targetFrame, display: true, animate: false)
        if let contentView = window.contentView {
            contentView.needsLayout = true
            contentView.layoutSubtreeIfNeeded()
        }
        window.displayIfNeeded()
        if effectiveMinimumContentWidth > 0 {
            let minHeight = max(MainLayoutMetrics.minimumWindowContentHeight, window.minSize.height)
            if window.styleMask.contains(.titled) {
                window.contentMinSize = NSSize(width: effectiveMinimumContentWidth, height: minHeight)
            }
            window.minSize = NSSize(width: effectiveMinimumContentWidth, height: minHeight)
        }
        lastObservedWindowWidth = window.frame.width
        return abs(window.frame.width - targetFrame.width) <= 1.0
    }

    private func isRightPanelEligibleInCurrentMode(viewModel: AppViewState) -> Bool {
        viewModel.navigationState.activeTab == .home
            && !viewModel.navigationState.isStorageInspectorActive
            && !viewModel.overlayState.showImmersiveMediaBrowser
            && viewModel.navigationState.layoutMode != .mediaFocus
    }

    private func resolveWindow(for viewModel: AppViewState) -> NSWindow? {
        BrowserWindowRegistry.shared.nsWindow(for: viewModel.windowID)
    }

    private func resolveStoredRightRatio() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: "TTZip_UserRightInspectorRatio")
        if stored > 0.05 && stored < 0.85 {
            return CGFloat(stored)
        }
        return MainLayoutMetrics.defaultRightInspectorRatio
    }
}
