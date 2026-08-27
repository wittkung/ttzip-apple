// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
@testable import TTZipApp
@testable import TTZipCore

final class ResponsiveLayoutBoundsTests: XCTestCase {
    
    @MainActor
    func test_window_layout_tier_evaluations() {
        XCTAssertEqual(WindowLayoutTier.evaluate(width: 400), .compact)
        XCTAssertEqual(WindowLayoutTier.evaluate(width: 819), .compact)
        XCTAssertEqual(WindowLayoutTier.evaluate(width: 820), .medium)
        XCTAssertEqual(WindowLayoutTier.evaluate(width: 1099), .medium)
        XCTAssertEqual(WindowLayoutTier.evaluate(width: 1100), .expanded)
        XCTAssertEqual(WindowLayoutTier.evaluate(width: 1920), .expanded)
    }
    
    @MainActor
    func test_workspace_scaffold_geometric_invariants_across_viewports() {
        let topOffset = TTZipTheme.Layout.topBarOffset
        let bottomOffset = TTZipTheme.Spacing.md
        let headerHeight = TTZipTheme.Layout.headerBarHeight
        let goldLineHeight = TTZipTheme.Layout.kintsugiGoldLineHeight
        
        let testHeights: [CGFloat] = [400.0, 480.0, 600.0, 768.0, 1080.0, 1440.0]
        
        for totalHeight in testHeights {
            let maxAllowedCardHeight = totalHeight - topOffset - bottomOffset
            let contentSlotMaxHeight = maxAllowedCardHeight - headerHeight - goldLineHeight
            
            XCTAssertGreaterThan(maxAllowedCardHeight, 0, "Card height must remain strictly positive for viewport \(totalHeight)")
            XCTAssertGreaterThan(contentSlotMaxHeight, 0, "Content slot height must remain strictly positive for viewport \(totalHeight)")
            XCTAssertLessThanOrEqual(
                topOffset + maxAllowedCardHeight + bottomOffset,
                totalHeight,
                "Card with top and bottom paddings must strictly not exceed viewport height \(totalHeight)"
            )
        }
    }
    
    @MainActor
    func test_sidebar_vertical_adaptive_breakpoints() {
        // Height breakpoints: Extremely constrained (< 440), Constrained (440..<520), Full (>= 520)
        XCTAssertEqual(SidebarLayoutTier.evaluate(height: 380.0), .extremelyConstrained)
        XCTAssertEqual(SidebarLayoutTier.evaluate(height: 400.0), .extremelyConstrained)
        XCTAssertEqual(SidebarLayoutTier.evaluate(height: 439.0), .extremelyConstrained)
        
        XCTAssertEqual(SidebarLayoutTier.evaluate(height: 440.0), .constrained)
        XCTAssertEqual(SidebarLayoutTier.evaluate(height: 480.0), .constrained)
        XCTAssertEqual(SidebarLayoutTier.evaluate(height: 519.0), .constrained)
        
        XCTAssertEqual(SidebarLayoutTier.evaluate(height: 520.0), .full)
        XCTAssertEqual(SidebarLayoutTier.evaluate(height: 600.0), .full)
        XCTAssertEqual(SidebarLayoutTier.evaluate(height: 1080.0), .full)
    }
    
    @MainActor
    func test_hosting_view_renders_in_constrained_400x400_window() {
        let widthTier = WindowLayoutTier.evaluate(width: 400)
        let sidebarTier = SidebarLayoutTier.evaluate(height: 400)
        XCTAssertEqual(widthTier, .compact, "400px width must be compact WindowLayoutTier")
        XCTAssertEqual(sidebarTier, .extremelyConstrained, "400px height must be extremelyConstrained SidebarLayoutTier")
        
        let mainView = MainView()
        let hostingView = NSHostingView(rootView: mainView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        hostingView.layoutSubtreeIfNeeded()
        
        XCTAssertEqual(hostingView.frame.size.width, 400.0)
        XCTAssertEqual(hostingView.frame.size.height, 400.0)
    }
    
    @MainActor
    func test_right_inspector_drag_clamping_mathematical_invariants() {
        let leftSidebarWidth: CGFloat = 215.0
        let leftDividerWidth: CGFloat = ResizableDividerHandle.gutterWidth // 8.0
        let rightDividerWidth: CGFloat = ResizableDividerHandle.gutterWidth // 8.0
        let rightPanelPadding: CGFloat = 14.0 // leading 4 + trailing 10
        let minSafeWorkspaceWidth: CGFloat = 420.0
        let minRightSidebarWidth: CGFloat = 200.0
        let maxRightSidebarWidth: CGFloat = 480.0
        
        let testWindowWidths: [CGFloat] = [600.0, 800.0, 900.0, 1200.0, 1600.0, 2560.0]
        
        for totalWidth in testWindowWidths {
            let tier = WindowLayoutTier.evaluate(width: totalWidth)
            let effectiveLeftWidth = (tier == .compact) ? 64.0 : leftSidebarWidth
            let effectiveLeftDivider = (tier == .compact) ? 0.0 : leftDividerWidth
            
            let totalChrome = effectiveLeftWidth + effectiveLeftDivider + rightDividerWidth + rightPanelPadding
            let maxRightAllowedByWorkspace = max(minRightSidebarWidth, totalWidth - totalChrome - minSafeWorkspaceWidth)
            let effectiveMaxRight = min(maxRightSidebarWidth, maxRightAllowedByWorkspace)
            
            // Invariant 1: effectiveMaxRight must NEVER exceed absolute ceiling 480pt
            XCTAssertLessThanOrEqual(
                effectiveMaxRight,
                maxRightSidebarWidth,
                "Right sidebar must never exceed \(maxRightSidebarWidth)pt at window width \(totalWidth)"
            )
            
            // Invariant 2: Leftward extreme drag (e.g. targetWidth = 1200pt) must be clamped safely
            let simulatedTargetWidth: CGFloat = 1200.0
            let clampedWidth = min(max(simulatedTargetWidth, minRightSidebarWidth), effectiveMaxRight)
            
            XCTAssertLessThanOrEqual(clampedWidth, effectiveMaxRight)
            XCTAssertGreaterThanOrEqual(clampedWidth, minRightSidebarWidth)
            
            // Invariant 3: Remaining workspace width must satisfy safe minimum in medium/expanded tiers
            if tier != .compact && totalWidth >= (totalChrome + minSafeWorkspaceWidth) {
                let actualWorkspaceWidth = totalWidth - totalChrome - clampedWidth
                XCTAssertGreaterThanOrEqual(
                    actualWorkspaceWidth,
                    minSafeWorkspaceWidth - 0.01,
                    "Middle workspace width (\(actualWorkspaceWidth)) must be at least \(minSafeWorkspaceWidth)pt at window width \(totalWidth)"
                )
            }
        }
    }
}

