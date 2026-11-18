// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit

extension InspectorWindowGeometryCoordinator {
    // MARK: - Constrained / Unmounted Helpers

    func handleConstrainedWindowTransition(
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

    func coordinateWithoutMountedWindow(
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
    func applyWindowFrame(_ targetFrame: CGRect, to window: NSWindow) -> Bool {
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

    func isRightPanelEligibleInCurrentMode(viewModel: AppViewState) -> Bool {
        viewModel.navigationState.activeTab == .home
            && !viewModel.navigationState.isStorageInspectorActive
            && !viewModel.overlayState.showImmersiveMediaBrowser
            && viewModel.navigationState.layoutMode != .mediaFocus
    }

    func resolveWindow(for viewModel: AppViewState) -> NSWindow? {
        BrowserWindowRegistry.shared.nsWindow(for: viewModel.windowID)
    }

    func resolveStoredRightRatio() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: "TTZip_UserRightInspectorRatio")
        if stored > 0.05 && stored < 0.85 {
            return CGFloat(stored)
        }
        return MainLayoutMetrics.defaultRightInspectorRatio
    }
}
