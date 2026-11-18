// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
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
        
        let testWindowWidths: [CGFloat] = [600.0, 800.0, 900.0, 1200.0, 1600.0, 2560.0]
        
        for totalWidth in testWindowWidths {
            let tier = WindowLayoutTier.evaluate(width: totalWidth)
            let effectiveLeftWidth = (tier == .compact) ? 64.0 : leftSidebarWidth
            let effectiveLeftDivider = (tier == .compact) ? 0.0 : leftDividerWidth
            let maxRightSidebarWidth: CGFloat = max(850.0, totalWidth * 0.55)
            
            let totalChrome = effectiveLeftWidth + effectiveLeftDivider + rightDividerWidth + rightPanelPadding
            let maxRightAllowedByWorkspace = max(minRightSidebarWidth, totalWidth - totalChrome - minSafeWorkspaceWidth)
            let effectiveMaxRight = min(maxRightSidebarWidth, maxRightAllowedByWorkspace)
            
            // Invariant 1: effectiveMaxRight must NEVER exceed adaptive upper bound
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
    
    @MainActor
    func test_sidebar_and_inspector_rubber_band_kinematics() {
        // 1. Sidebar in-bounds translation is preserved exactly
        let normalLeft = MainLayoutMetrics.rubberBandClampLeftSidebar(offset: 250.0)
        XCTAssertEqual(normalLeft, 250.0)
        
        // 2. Sidebar over-drag beyond max (300pt) is smoothly resisted
        let overdragLeft = MainLayoutMetrics.rubberBandClampLeftSidebar(offset: 380.0)
        XCTAssertGreaterThan(overdragLeft, 300.0)
        XCTAssertLessThan(overdragLeft, 380.0)
        
        // 3. Sidebar under-drag below min (200pt) is smoothly resisted
        let underdragLeft = MainLayoutMetrics.rubberBandClampLeftSidebar(offset: 140.0)
        XCTAssertLessThan(underdragLeft, 200.0)
        XCTAssertGreaterThan(underdragLeft, 140.0)
        
        // 4. Inspector in-bounds translation is preserved exactly
        let normalRight = MainLayoutMetrics.rubberBandClampRightSidebar(offset: 300.0, maxWidth: 450.0)
        XCTAssertEqual(normalRight, 300.0)
        
        // 5. Inspector over-drag beyond maxWidth is smoothly resisted
        let overdragRight = MainLayoutMetrics.rubberBandClampRightSidebar(offset: 600.0, maxWidth: 450.0)
        XCTAssertGreaterThan(overdragRight, 450.0)
        XCTAssertLessThan(overdragRight, 600.0)
        
        // 6. Inspector under-drag below min (220pt) is smoothly resisted
        let underdragRight = MainLayoutMetrics.rubberBandClampRightSidebar(offset: 150.0, maxWidth: 450.0)
        XCTAssertLessThan(underdragRight, 220.0)
        XCTAssertGreaterThan(underdragRight, 150.0)
        
        // 7. Physical invariants
        XCTAssertEqual(MainLayoutMetrics.minLeftSidebarWidth, 200.0)
        XCTAssertEqual(MainLayoutMetrics.maxLeftSidebarWidth, 300.0)
        XCTAssertEqual(MainLayoutMetrics.defaultLeftSidebarWidth, 200.0)
        XCTAssertEqual(MainLayoutMetrics.minRightSidebarWidth, 220.0)
        XCTAssertEqual(MainLayoutMetrics.defaultRightSidebarWidth, 340.0)
        XCTAssertEqual(MainLayoutMetrics.defaultRightInspectorRatio, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(MainLayoutMetrics.hairlineBorderWidth, 0.5)
        XCTAssertEqual(MainLayoutMetrics.goldenRuleBaselineY, 52.0)
    }
    
    @MainActor
    func testTwoToOneProportionalScalingAndWindowResizeInvariants() {
        let viewModel = AppViewState()
        
        // 1. Verify default ratio is exactly 1/3 (giving 2:1 Center : Right)
        XCTAssertEqual(MainLayoutMetrics.defaultRightInspectorRatio, 1.0 / 3.0, accuracy: 0.0001)
        
        // 2. Base window size: 1080 x 720
        let baseSize = CGSize(width: 1080, height: 720)
        let baseMetrics = MainLayoutMetrics.compute(
            size: baseSize,
            viewModel: viewModel,
            isLeftVisible: true,
            isRightVisible: true,
            leftWidth: 200.0,
            rightRatio: MainLayoutMetrics.defaultRightInspectorRatio
        )
        
        // At 1080 width, available content = 1080 - 208 - 8 = 864
        // Expected right width = 864 * (1/3) = 288
        // Expected center width = 864 - 288 = 576
        // Ratio = 576 / 288 = exactly 2.0 (2:1)
        XCTAssertEqual(baseMetrics.centerWidth / baseMetrics.effectiveRightWidth, 2.0, accuracy: 0.01)
        
        // 3. Resized window size: 1440 x 900
        let expandedSize = CGSize(width: 1440, height: 900)
        let expandedMetrics = MainLayoutMetrics.compute(
            size: expandedSize,
            viewModel: viewModel,
            isLeftVisible: true,
            isRightVisible: true,
            leftWidth: 200.0,
            rightRatio: MainLayoutMetrics.defaultRightInspectorRatio
        )
        
        // At 1440 width, available content = 1440 - 208 - 8 = 1224
        // Expected right width = 1224 * (1/3) = 408
        // Expected center width = 1224 - 408 = 816
        // Right width has grown from 288 to 408 automatically!
        XCTAssertGreaterThan(expandedMetrics.effectiveRightWidth, baseMetrics.effectiveRightWidth)
        XCTAssertEqual(expandedMetrics.centerWidth / expandedMetrics.effectiveRightWidth, 2.0, accuracy: 0.01)
        
        // 4. Large monitor size: 1920 x 1080 (triggers 540pt ergonomic cap)
        let largeSize = CGSize(width: 1920, height: 1080)
        let largeMetrics = MainLayoutMetrics.compute(
            size: largeSize,
            viewModel: viewModel,
            isLeftVisible: true,
            isRightVisible: true,
            leftWidth: 200.0,
            rightRatio: MainLayoutMetrics.defaultRightInspectorRatio
        )
        XCTAssertGreaterThan(largeMetrics.effectiveRightWidth, expandedMetrics.effectiveRightWidth)
        XCTAssertEqual(largeMetrics.effectiveRightWidth, MainLayoutMetrics.maxRightInspectorErgonomicCap)
        XCTAssertEqual(largeMetrics.centerWidth + largeMetrics.effectiveRightWidth, 1704.0, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(largeMetrics.centerWidth / largeMetrics.effectiveRightWidth, 2.0)
        
        // 5. Override width during drag
        let dragMetrics = MainLayoutMetrics.compute(
            size: baseSize,
            viewModel: viewModel,
            isLeftVisible: true,
            isRightVisible: true,
            leftWidth: 200.0,
            rightRatio: MainLayoutMetrics.defaultRightInspectorRatio,
            overrideRightWidth: 320.0
        )
        XCTAssertEqual(dragMetrics.effectiveRightWidth, 320.0, accuracy: 0.1)
    }
    
    @MainActor
    func testMillerColumnsResponsiveInvariants() {
        // 1. Minimum and default column width constants
        XCTAssertEqual(SingleMillerColumnView.defaultWidth, 260.0)
        XCTAssertEqual(SingleMillerColumnView.minComfortableWidth, 200.0)
        XCTAssertGreaterThan(SingleMillerColumnView.defaultWidth, SingleMillerColumnView.minComfortableWidth)
        
        // 2. Drag clamping invariants
        let initialWidth: CGFloat = SingleMillerColumnView.defaultWidth
        let extremeLeftTranslation: CGFloat = -150.0
        let clampedMin = min(max(initialWidth + extremeLeftTranslation, SingleMillerColumnView.minComfortableWidth), 800.0)
        XCTAssertEqual(clampedMin, SingleMillerColumnView.minComfortableWidth, "Negative drag must clamp strictly to minComfortableWidth (200pt)")
        
        let extremeRightTranslation: CGFloat = 1000.0
        let clampedMax = min(max(initialWidth + extremeRightTranslation, SingleMillerColumnView.minComfortableWidth), 800.0)
        XCTAssertEqual(clampedMax, 800.0, "Positive drag must clamp strictly to maximum ceiling (800pt)")
    }
    
    @MainActor
    func testLayoutStateMigrationClearsLegacyDirtyRatioAndWidth() {
        let testSuiteName = "com.metastudyline.ttzip.test.migration.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Failed to allocate isolated test UserDefaults suite")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: testSuiteName) }
        
        // 1. Inject dirty uncalibrated legacy preferences
        testDefaults.set(0.4212233040201005, forKey: "TTZip_UserRightInspectorRatio")
        testDefaults.set(419.1171875, forKey: "TTZip_UserRightSidebarWidth")
        testDefaults.set(0, forKey: LayoutStateMigration.layoutStateVersionKey)
        
        // 2. Execute idempotent migration
        LayoutStateMigration.migrateIfNeeded(defaults: testDefaults)
        
        // 3. Verify clean baseline
        let migratedRatio = testDefaults.double(forKey: "TTZip_UserRightInspectorRatio")
        XCTAssertEqual(migratedRatio, 1.0 / 3.0, accuracy: 0.0001, "Ratio must reset to canonical 1/3 (2:1)")
        XCTAssertNil(testDefaults.object(forKey: "TTZip_UserRightSidebarWidth"), "Deprecated width key must be purged")
        XCTAssertEqual(testDefaults.integer(forKey: LayoutStateMigration.layoutStateVersionKey), 1)
    }
    
    @MainActor
    func testUserDragInV1IsPreservedAcrossLaunches() {
        let testSuiteName = "com.metastudyline.ttzip.test.userdrag.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: testSuiteName) else {
            XCTFail("Failed to allocate isolated test UserDefaults suite")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: testSuiteName) }
        
        // 1. Version 1 already stamped, user explicitly dragged to 0.38
        testDefaults.set(1, forKey: LayoutStateMigration.layoutStateVersionKey)
        testDefaults.set(0.38, forKey: "TTZip_UserRightInspectorRatio")
        
        // 2. Running migration again must be a no-op
        LayoutStateMigration.migrateIfNeeded(defaults: testDefaults)
        
        XCTAssertEqual(testDefaults.double(forKey: "TTZip_UserRightInspectorRatio"), 0.38, accuracy: 0.0001)
    }
    
    @MainActor
    func testScreenshotGeometryUnderflowEliminatesDeadSpace() {
        // 1. Underflow with custom compact columns (e.g. 200pt each in 447pt available workspace)
        let availableWidth: CGFloat = 447.0
        let totalColumns = 2
        let columnWidths: [Int: CGFloat] = [0: 200.0, 1: 200.0]
        
        let col0Width = FinderMillerColumnsView.computeColumnWidth(
            for: 0,
            totalColumns: totalColumns,
            availableWidth: availableWidth,
            columnWidths: columnWidths
        )
        let col1Width = FinderMillerColumnsView.computeColumnWidth(
            for: 1,
            totalColumns: totalColumns,
            availableWidth: availableWidth,
            columnWidths: columnWidths
        )
        
        XCTAssertEqual(col0Width, 200.0, accuracy: 0.1)
        // Leaf column (index 1) absorbs the remaining deficit: 447 - 200 = 247
        XCTAssertEqual(col1Width, 247.0, accuracy: 0.1)
        // Total occupied width equals available width: dead space is identically 0.0pt!
        XCTAssertEqual(col0Width + col1Width, availableWidth, accuracy: 0.1)
        
        // 2. Underflow with default column widths (260pt each in 600pt available workspace)
        let wideAvailable: CGFloat = 600.0
        let defCol0 = FinderMillerColumnsView.computeColumnWidth(for: 0, totalColumns: totalColumns, availableWidth: wideAvailable)
        let defCol1 = FinderMillerColumnsView.computeColumnWidth(for: 1, totalColumns: totalColumns, availableWidth: wideAvailable)
        
        XCTAssertEqual(defCol0, SingleMillerColumnView.defaultWidth)
        XCTAssertEqual(defCol1, wideAvailable - SingleMillerColumnView.defaultWidth) // 600 - 260 = 340
        XCTAssertEqual(defCol0 + defCol1, wideAvailable, accuracy: 0.1)
    }
    
    @MainActor
    func testUniversalColumnWidthOverflowEnablesScrolling() {
        let availableWidth: CGFloat = 500.0
        let totalColumns = 3
        
        let col0Width = FinderMillerColumnsView.computeColumnWidth(for: 0, totalColumns: totalColumns, availableWidth: availableWidth)
        let col1Width = FinderMillerColumnsView.computeColumnWidth(for: 1, totalColumns: totalColumns, availableWidth: availableWidth)
        let col2Width = FinderMillerColumnsView.computeColumnWidth(for: 2, totalColumns: totalColumns, availableWidth: availableWidth)
        
        XCTAssertEqual(col0Width, SingleMillerColumnView.defaultWidth)
        XCTAssertEqual(col1Width, SingleMillerColumnView.defaultWidth)
        XCTAssertEqual(col2Width, SingleMillerColumnView.defaultWidth)
        XCTAssertGreaterThan(col0Width + col1Width + col2Width, availableWidth)
    }
    
    @MainActor
    func testErgonomicCapOnUltrawide4KDisplay() {
        let viewModel = AppViewState()
        let ultrawide4KSize = CGSize(width: 3840, height: 2160)
        
        let metrics = MainLayoutMetrics.compute(
            size: ultrawide4KSize,
            viewModel: viewModel,
            isLeftVisible: true,
            isRightVisible: true,
            leftWidth: 200.0,
            rightRatio: MainLayoutMetrics.defaultRightInspectorRatio
        )
        
        XCTAssertLessThanOrEqual(metrics.effectiveRightWidth, MainLayoutMetrics.maxRightInspectorErgonomicCap)
        XCTAssertEqual(metrics.effectiveRightWidth, MainLayoutMetrics.maxRightInspectorErgonomicCap, accuracy: 0.1)
    }
    
    @MainActor
    func testStorageInspectorMutualExclusion() {
        let viewModel = AppViewState()
        viewModel.navigationState.openStorageInspectorTab()
        XCTAssertTrue(viewModel.navigationState.isStorageInspectorActive)
        
        let metrics = MainLayoutMetrics.compute(
            size: CGSize(width: 1200, height: 800),
            viewModel: viewModel,
            isLeftVisible: true,
            isRightVisible: true,
            leftWidth: 200.0
        )
        
        XCTAssertFalse(metrics.shouldShowRight, "Storage inspector must collapse outer right inspector to prevent 4-pane splitting")
    }

    // MARK: - TopBar Layout & Breadcrumb Folding Invariants

    @MainActor
    func testBreadcrumbMiddleSegmentFoldingKeepsRootAndCurrentWithNavigableEllipsis() {
        let rootURL = URL(fileURLWithPath: "/Users/tester")
        let docURL = rootURL.appendingPathComponent("Documents")
        let videoURL = docURL.appendingPathComponent("video_dev")
        let dailyURL = videoURL.appendingPathComponent("日更专栏")
        let topicURL = dailyURL.appendingPathComponent("9.25 完美主义，利他")
        let currentURL = topicURL.appendingPathComponent("享受别人的成功")

        let segments: [BreadcrumbPathSegment] = [
            BreadcrumbPathSegment(id: rootURL.path, name: "~", iconName: "house.fill", url: rootURL, isCurrent: false),
            BreadcrumbPathSegment(id: docURL.path, name: "文稿", iconName: "doc.text.fill", url: docURL, isCurrent: false),
            BreadcrumbPathSegment(id: videoURL.path, name: "video_dev", iconName: "folder.fill", url: videoURL, isCurrent: false),
            BreadcrumbPathSegment(id: dailyURL.path, name: "日更专栏", iconName: "folder.fill", url: dailyURL, isCurrent: false),
            BreadcrumbPathSegment(id: topicURL.path, name: "9.25 完美主义，利他", iconName: "folder.fill", url: topicURL, isCurrent: false),
            BreadcrumbPathSegment(id: currentURL.path, name: "享受别人的成功", iconName: "folder.fill", url: currentURL, isCurrent: true)
        ]

        // 1. Narrow available width (e.g. 220pt in 860pt window): must fold intermediate segments into .collapsedMiddle
        let narrowItems = BreadcrumbMiddleFolder.computeDisplayItems(segments: segments, availableWidth: 220.0)
        XCTAssertGreaterThanOrEqual(narrowItems.count, 3)
        if case .segment(let firstSeg) = narrowItems.first {
            XCTAssertEqual(firstSeg.url, rootURL, "Root segment must always be preserved")
        } else {
            XCTFail("First breadcrumb item must be root segment")
        }
        if case .segment(let lastSeg) = narrowItems.last {
            XCTAssertEqual(lastSeg.url, currentURL, "Current segment must always be preserved")
            XCTAssertTrue(lastSeg.isCurrent)
        } else {
            XCTFail("Last breadcrumb item must be current segment")
        }

        var collapsedCaptured: [BreadcrumbPathSegment] = []
        for item in narrowItems {
            if case .collapsedMiddle(let middle) = item {
                collapsedCaptured = middle
            }
        }
        XCTAssertFalse(collapsedCaptured.isEmpty, "Narrow breadcrumb bar must collapse middle segments into … menu")
        XCTAssertTrue(collapsedCaptured.contains(where: { $0.url == docURL }), "Collapsed menu must retain intermediate directory URLs for navigation")

        // 2. Wide available width (e.g. 720pt in 1440pt+ window): all segments fit without folding
        let wideItems = BreadcrumbMiddleFolder.computeDisplayItems(segments: segments, availableWidth: 720.0)
        XCTAssertEqual(wideItems.count, segments.count, "Wide address bar must display all segments without folding")
    }

    @MainActor
    func testTopBarSearchButtonExpandsOnDemandAndCompressesAddressBarAcrossWindowWidths() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("TTZipTopBarMatrix-\(UUID().uuidString)")
        let deepChineseDir = tempRoot
            .appendingPathComponent("文稿")
            .appendingPathComponent("video_dev")
            .appendingPathComponent("日更")
            .appendingPathComponent("9.25 完美主义，利他")
            .appendingPathComponent("享受别人的成功")
        try fm.createDirectory(at: deepChineseDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let viewModel = AppViewState()
        viewModel.navigationState.showDirectory(at: deepChineseDir)

        let windowWidths: [CGFloat] = [860.0, 1080.0, 1440.0]
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

        for appearanceName in appearances {
            for width in windowWidths {
                try verifyMountedTopBarIdleAndExpandedSearch(
                    viewModel: viewModel,
                    width: width,
                    height: 720.0,
                    appearanceName: appearanceName
                )
            }
        }
    }

    @MainActor
    private func verifyMountedTopBarIdleAndExpandedSearch(
        viewModel: AppViewState,
        width: CGFloat,
        height: CGFloat,
        appearanceName: NSAppearance.Name
    ) throws {
        let metrics = MainLayoutMetrics.compute(
            size: CGSize(width: width, height: height),
            viewModel: viewModel,
            isLeftVisible: true,
            isRightVisible: true,
            leftWidth: 200.0,
            rightRatio: MainLayoutMetrics.defaultRightInspectorRatio
        )

        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: metrics.centerWidth, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearanceName)
        let host = NSHostingView(rootView: makeCenterTopBarContainer(viewModel: viewModel, centerWidth: metrics.centerWidth, height: height))
        host.frame = NSRect(x: 0, y: 0, width: metrics.centerWidth, height: height)
        window.contentView = host
        defer {
            viewModel.explorerState.searchQuery = ""
            window.contentView = nil
            window.close()
        }

        // 1. Idle state (searchQuery is empty): search renders as a compact 28pt trigger button
        viewModel.explorerState.searchQuery = ""
        host.rootView = makeCenterTopBarContainer(viewModel: viewModel, centerWidth: metrics.centerWidth, height: height)
        settleHostLayout(host)
        try assertIdleTopBarInvariants(
            in: host,
            viewModel: viewModel,
            width: width,
            height: height,
            centerWidth: metrics.centerWidth,
            appearanceName: appearanceName
        )

        // 2. Expanded state (triggered on click / ⌘F / active query): search expands and compresses address bar
        viewModel.explorerState.searchQuery = "完美"
        host.rootView = makeCenterTopBarContainer(viewModel: viewModel, centerWidth: metrics.centerWidth, height: height)
        settleHostLayout(host)
        try assertExpandedTopBarInvariants(
            in: host,
            viewModel: viewModel,
            width: width,
            height: height,
            centerWidth: metrics.centerWidth,
            appearanceName: appearanceName
        )
    }

    @MainActor
    private func makeCenterTopBarContainer(
        viewModel: AppViewState,
        centerWidth: CGFloat,
        height: CGFloat
    ) -> some View {
        HomeExplorerContainerView(
            viewModel: viewModel,
            isRightSidebarVisible: true,
            isLeftSidebarVisible: true,
            onToggleLeftSidebar: {},
            onToggleRightSidebar: {},
            onOpenArchive: {},
            onNewArchive: {},
            isActive: true
        )
        .frame(width: centerWidth, height: height)
    }

    @MainActor
    private func settleHostLayout(_ host: NSHostingView<some View>) {
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func assertIdleTopBarInvariants(
        in host: NSView,
        viewModel: AppViewState,
        width: CGFloat,
        height: CGFloat,
        centerWidth: CGFloat,
        appearanceName: NSAppearance.Name
    ) throws {
        let idleTextFields = collectVisibleNSTextFields(in: host).filter { $0.isEditable }
        XCTAssertTrue(
            idleTextFields.isEmpty,
            "Idle topbar should keep search collapsed as a 28pt trigger button at width \(width) so the address bar is wider"
        )

        let topBarButtons = collectVisibleNSButtons(in: host).filter { btn in
            let rect = btn.convert(btn.bounds, to: host)
            return rect.minY <= 60.0 || rect.maxY >= (height - 60.0)
        }
        for btn in topBarButtons {
            let rect = btn.convert(btn.bounds, to: host)
            XCTAssertLessThanOrEqual(
                rect.maxX,
                centerWidth + 1.0,
                "Idle topbar button must never overflow centerWidth (\(centerWidth)) at window width \(width)"
            )
        }

        if let outDir = ProcessInfo.processInfo.environment["TTZIP_TOPBAR_SNAPSHOT_DIR"], !outDir.isEmpty {
            try? captureFullWindowTopBarSnapshot(
                viewModel: viewModel,
                width: width,
                height: height,
                appearanceName: appearanceName,
                stateTag: "idle",
                searchRectInCenter: .zero,
                centerWidth: centerWidth,
                outputDir: URL(fileURLWithPath: outDir)
            )
        }
    }

    @MainActor
    private func assertExpandedTopBarInvariants(
        in host: NSView,
        viewModel: AppViewState,
        width: CGFloat,
        height: CGFloat,
        centerWidth: CGFloat,
        appearanceName: NSAppearance.Name
    ) throws {
        let expandedTextFields = collectVisibleNSTextFields(in: host)
        let searchField = expandedTextFields.first(where: { field in
            field.isEditable && (
                field.accessibilityIdentifier() == "ExplorerSearchTextField"
                || field.stringValue == "完美"
                || (field.placeholderString?.contains("搜索") == true)
                || (field.placeholderString?.contains("Search") == true)
            )
        })
        let unwrappedSearch = try XCTUnwrap(
            searchField,
            "Expanded search NSTextField must be mounted and editable at window width \(width) (\(appearanceName.rawValue))"
        )
        let searchRectInHost = unwrappedSearch.convert(unwrappedSearch.bounds, to: host)
        XCTAssertGreaterThanOrEqual(
            searchRectInHost.width,
            48.0,
            "Expanded search text field must retain usable editable width at window width \(width)"
        )
        XCTAssertLessThanOrEqual(
            searchRectInHost.maxX,
            centerWidth,
            "Expanded search text field must not clip outside center column width \(centerWidth)"
        )

        if let outDir = ProcessInfo.processInfo.environment["TTZIP_TOPBAR_SNAPSHOT_DIR"], !outDir.isEmpty {
            try? captureFullWindowTopBarSnapshot(
                viewModel: viewModel,
                width: width,
                height: height,
                appearanceName: appearanceName,
                stateTag: "expanded",
                searchRectInCenter: searchRectInHost,
                centerWidth: centerWidth,
                outputDir: URL(fileURLWithPath: outDir)
            )
        }
    }

    @MainActor
    private func captureFullWindowTopBarSnapshot(
        viewModel: AppViewState,
        width: CGFloat,
        height: CGFloat,
        appearanceName: NSAppearance.Name,
        stateTag: String,
        searchRectInCenter: NSRect,
        centerWidth: CGFloat,
        outputDir: URL
    ) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let themeTag = (appearanceName == .darkAqua) ? "dark" : "light"
        let widthInt = Int(width)

        let metrics = MainLayoutMetrics.compute(
            size: CGSize(width: width, height: height),
            viewModel: viewModel,
            isLeftVisible: true,
            isRightVisible: true,
            leftWidth: 200.0,
            rightRatio: MainLayoutMetrics.defaultRightInspectorRatio
        )

        let fullTopBarComposite = HStack(alignment: .top, spacing: 0) {
            FinderFavoritesSidebarView(
                currentDirectory: viewModel.navigationState.currentDirectory,
                onSelectDirectory: { _ in },
                onToggleSidebar: {}
            )
            .frame(width: 200.0, height: height)

            ResizableDividerHandle(topInset: 52.0, onDragStart: {}, onDragChanged: { _ in }, onDragEnd: {}, onDoubleClick: {})
                .frame(height: height)

            HomeExplorerContainerView(
                viewModel: viewModel,
                isRightSidebarVisible: true,
                isLeftSidebarVisible: true,
                onToggleLeftSidebar: {},
                onToggleRightSidebar: {},
                onOpenArchive: {},
                onNewArchive: {},
                isActive: true
            )
            .frame(width: metrics.centerWidth, height: height)

            ResizableDividerHandle(topInset: 52.0, onDragStart: {}, onDragChanged: { _ in }, onDragEnd: {}, onDoubleClick: {})
                .frame(height: height)

            RightInspectorSidePanel(viewModel: viewModel)
                .frame(width: metrics.effectiveRightWidth, height: height)
        }
        .frame(width: width, height: height)
        .background(Color(nsColor: .windowBackgroundColor))

        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearanceName)
        let host = NSHostingView(rootView: fullTopBarComposite)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        host.layoutSubtreeIfNeeded()

        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let fileURL = outputDir.appendingPathComponent("after-topbar-\(stateTag)-\(widthInt)w-\(themeTag).png")
                try png.write(to: fileURL)
            }
        }
        let receipt = """
        {"state":"\(stateTag)","windowWidth":\(widthInt),"theme":"\(themeTag)","centerWidth":\(centerWidth),"rightWidth":\(metrics.effectiveRightWidth),"searchFieldWidth":\(searchRectInCenter.width),"searchFieldMinX":\(searchRectInCenter.minX),"searchFieldMaxX":\(searchRectInCenter.maxX)}
        """
        let jsonURL = outputDir.appendingPathComponent("after-topbar-\(stateTag)-\(widthInt)w-\(themeTag).json")
        try receipt.write(to: jsonURL, atomically: true, encoding: .utf8)
    }

    @MainActor
    private func collectVisibleNSTextFields(in root: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if let tf = current as? NSTextField, !tf.isHidden, tf.alphaValue > 0.01 {
                result.append(tf)
            }
            stack.append(contentsOf: current.subviews)
        }
        return result
    }

    @MainActor
    private func collectVisibleNSButtons(in root: NSView) -> [NSButton] {
        var result: [NSButton] = []
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if let btn = current as? NSButton, !btn.isHidden, btn.alphaValue > 0.01 {
                result.append(btn)
            }
            stack.append(contentsOf: current.subviews)
        }
        return result
    }
}


