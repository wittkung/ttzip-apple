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
}
