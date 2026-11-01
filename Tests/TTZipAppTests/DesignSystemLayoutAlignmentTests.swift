// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

@MainActor
final class DesignSystemLayoutAlignmentTests: XCTestCase {
    
    func test_sidebar_workspace_inspector_golden_rule_aligned_at_y52() {
        // Design system baseline invariants
        let topInset: CGFloat = TTZipTheme.Layout.topBarOffset
        let headerHeight: CGFloat = TTZipTheme.Layout.headerBarHeight
        let goldenLineY: CGFloat = topInset + headerHeight
        
        XCTAssertEqual(topInset, 0.0, "Top safety offset must be 0.0pt for unified titlebar")
        XCTAssertEqual(headerHeight, 52.0, "Header bar height must be exactly 52.0pt")
        XCTAssertEqual(goldenLineY, 52.0, "Golden Rule Line across 3 columns must align precisely at Y = 52pt")
    }
    
    func test_zen_gutter_and_scaffold_spacing_tokens() {
        XCTAssertEqual(ResizableDividerHandle.gutterWidth, 8.0, "Zen Gutter width must be strictly 8.0pt")
        XCTAssertEqual(TTZipTheme.Spacing.xs, 8.0, "Inset card leading spacing must be 8.0pt")
        XCTAssertEqual(TTZipTheme.Layout.kintsugiGoldLineHeight, 0.5, "Kintsugi gold line height must be strictly 0.5pt")
        XCTAssertEqual(TTZipTheme.Layout.kintsugiGoldLineHeight, TTZipUniversalTokens.Dimensions.hairlineWidth)
        XCTAssertEqual(TTZipTheme.Layout.kintsugiGoldLineHeight, TTZipUniversalTokens.Layout.goldenRuleLineThickness)
    }
    
    func test_52pt_header_bar_typography_tokens() {
        guard let aquaAppearance = NSAppearance(named: .aqua),
              let darkAquaAppearance = NSAppearance(named: .darkAqua) else {
            XCTFail("Failed to load standard system appearances")
            return
        }
        
        // 1. Kintsugi Gold Token (UniversalTokens.Mineral.gold: #BF9936 = 191, 153, 54 in Aqua; #DEB84B = 222, 184, 75 in DarkAqua)
        XCTAssertEqual(TTZipTheme.kintsugiGold, TTZipUniversalTokens.Mineral.gold, "TTZipTheme.kintsugiGold must strictly match TTZipUniversalTokens.Mineral.gold")
        
        let goldNSColor = NSColor(TTZipTheme.kintsugiGold)
        var goldAqua = goldNSColor
        var goldDark = goldNSColor
        aquaAppearance.performAsCurrentDrawingAppearance {
            goldAqua = goldNSColor.usingColorSpace(.sRGB) ?? goldNSColor
        }
        darkAquaAppearance.performAsCurrentDrawingAppearance {
            goldDark = goldNSColor.usingColorSpace(.sRGB) ?? goldNSColor
        }
        
        XCTAssertEqual(goldAqua.redComponent, 191.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Aqua Red channel must be #BF (191/255)")
        XCTAssertEqual(goldAqua.greenComponent, 153.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Aqua Green channel must be #99 (153/255)")
        XCTAssertEqual(goldAqua.blueComponent, 54.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Aqua Blue channel must be #36 (54/255)")
        
        XCTAssertEqual(goldDark.redComponent, 222.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Dark Red channel must be 222/255")
        XCTAssertEqual(goldDark.greenComponent, 184.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Dark Green channel must be 184/255")
        XCTAssertEqual(goldDark.blueComponent, 75.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Dark Blue channel must be 75/255")
        
        // 2. Bamboo Green Token (UniversalTokens.Fluid.organicCore: #789262 = 120, 146, 98 in Aqua; #8FA876 = 143, 168, 118 in DarkAqua)
        XCTAssertEqual(TTZipTheme.bambooGreen, TTZipUniversalTokens.Fluid.organicCore, "TTZipTheme.bambooGreen must strictly match TTZipUniversalTokens.Fluid.organicCore")
        XCTAssertEqual(TTZipTheme.mineralBamboo, TTZipUniversalTokens.Mineral.bamboo, "TTZipTheme.mineralBamboo must strictly match TTZipUniversalTokens.Mineral.bamboo")
        let bambooNSColor = NSColor(TTZipTheme.bambooGreen)
        var bambooAqua = bambooNSColor
        var bambooDark = bambooNSColor
        aquaAppearance.performAsCurrentDrawingAppearance {
            bambooAqua = bambooNSColor.usingColorSpace(.sRGB) ?? bambooNSColor
        }
        darkAquaAppearance.performAsCurrentDrawingAppearance {
            bambooDark = bambooNSColor.usingColorSpace(.sRGB) ?? bambooNSColor
        }
        
        XCTAssertEqual(bambooAqua.redComponent, 120.0 / 255.0, accuracy: 0.01, "Bamboo Green Aqua Red channel must be 120/255")
        XCTAssertEqual(bambooAqua.greenComponent, 146.0 / 255.0, accuracy: 0.01, "Bamboo Green Aqua Green channel must be 146/255")
        XCTAssertEqual(bambooAqua.blueComponent, 98.0 / 255.0, accuracy: 0.01, "Bamboo Green Aqua Blue channel must be 98/255")
        
        XCTAssertEqual(bambooDark.redComponent, 143.0 / 255.0, accuracy: 0.01, "Bamboo Green Dark Red channel must be 143/255")
        XCTAssertEqual(bambooDark.greenComponent, 168.0 / 255.0, accuracy: 0.01, "Bamboo Green Dark Green channel must be 168/255")
        XCTAssertEqual(bambooDark.blueComponent, 118.0 / 255.0, accuracy: 0.01, "Bamboo Green Dark Blue channel must be 118/255")
        
        // 3. Cinnabar Red (#D15947: 0.82, 0.35, 0.28)
        let redNSColor = NSColor(TTZipTheme.cinnabarRed)
        var redAqua = redNSColor
        var redDark = redNSColor
        aquaAppearance.performAsCurrentDrawingAppearance {
            redAqua = redNSColor.usingColorSpace(.sRGB) ?? redNSColor
        }
        darkAquaAppearance.performAsCurrentDrawingAppearance {
            redDark = redNSColor.usingColorSpace(.sRGB) ?? redNSColor
        }
        XCTAssertEqual(redAqua.redComponent, 0.82, accuracy: 0.01, "Cinnabar Red Aqua Red channel")
        XCTAssertEqual(redAqua.greenComponent, 0.35, accuracy: 0.01, "Cinnabar Red Aqua Green channel")
        XCTAssertEqual(redAqua.blueComponent, 0.28, accuracy: 0.01, "Cinnabar Red Aqua Blue channel")
        XCTAssertEqual(redDark.redComponent, 0.82, accuracy: 0.01, "Cinnabar Red Dark Red channel")
        XCTAssertEqual(redDark.greenComponent, 0.35, accuracy: 0.01, "Cinnabar Red Dark Green channel")
        XCTAssertEqual(redDark.blueComponent, 0.28, accuracy: 0.01, "Cinnabar Red Dark Blue channel")
    }
    
    func test_52pt_toolbar_typography_and_kinetics_invariants() {
        // 1. 52.0pt Golden Baseline & Geometry Invariants
        XCTAssertEqual(MainToolbarLayoutMetrics.toolbarHeight, 52.0, "Toolbar height must strictly lock at 52.0pt")
        XCTAssertEqual(MainToolbarLayoutMetrics.toolbarHeight, TTZipUniversalTokens.Layout.headerBarHeight)
        XCTAssertEqual(MainToolbarLayoutMetrics.windowControlDragOffset, 38.0, "Window control buttons & safety area offset must be 38.0pt")
        XCTAssertEqual(MainToolbarLayoutMetrics.goldenBaselineY, 90.0, "Global baseline must align at Y = 90.0pt (38 + 52)")
        XCTAssertEqual(
            MainToolbarLayoutMetrics.goldenBaselineY,
            MainToolbarLayoutMetrics.windowControlDragOffset + MainToolbarLayoutMetrics.toolbarHeight,
            "Golden baseline must be exactly sum of top clearance and toolbar height"
        )
        
        // 2. Control Click Hit Target Invariants (>= 28pt)
        XCTAssertGreaterThanOrEqual(MainToolbarLayoutMetrics.minHitTarget, 28.0, "Control click hit target must be >= 28pt")
        
        // 3. Kinetics & Motion Springs Invariants (Apple binary spring damping)
        XCTAssertEqual(TTZipUniversalTokens.Motion.microResponse, 0.28, accuracy: 1e-5)
        XCTAssertEqual(TTZipUniversalTokens.Motion.microDampingFraction, 0.82, accuracy: 1e-5)
        
        // 4. View instantiation and layout hierarchy
        let button = NewArchiveToolbarButton(title: "New Archive") {}
        XCTAssertNotNil(button)
        
        let iconButton = ToolbarIconButton(systemImage: "sidebar.leading") {}
        XCTAssertNotNil(iconButton)
        
        let slider = ToolbarModeSwitchSlider(
            options: ["list", "grid"],
            selection: .constant("list"),
            title: { $0.capitalized }
        )
        XCTAssertNotNil(slider)
        
        let topbar = MainTop52ptToolbarView(
            leading: { Text("Leading") },
            center: { Text("Center") },
            trailing: { Text("Trailing") }
        )
        XCTAssertNotNil(topbar)
    }

    // MARK: - Right Inspector Collapse/Expand Window Geometry Coordination Tests

    private final class LockedFrameWindowDelegate: NSObject, NSWindowDelegate {
        let lockedSize: NSSize

        init(lockedSize: NSSize) {
            self.lockedSize = lockedSize
        }

        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            lockedSize
        }
    }

    private final class WindowManagerLockedNSWindow: NSWindow {
        var isFrameLockedByWindowManager: Bool = false
        var lockedFrameWidth: CGFloat?
        var simulatedFullScreenStyleMask: Bool = false

        override var styleMask: NSWindow.StyleMask {
            get {
                var mask = super.styleMask
                if simulatedFullScreenStyleMask {
                    mask.insert(.fullScreen)
                }
                return mask
            }
            set {
                super.styleMask = newValue
            }
        }

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            if isFrameLockedByWindowManager, let lockedWidth = lockedFrameWidth {
                var clamped = frameRect
                clamped.size.width = lockedWidth
                super.setFrame(clamped, display: flag)
                return
            }
            super.setFrame(frameRect, display: flag)
        }

        override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
            if isFrameLockedByWindowManager, let lockedWidth = lockedFrameWidth {
                var clamped = frameRect
                clamped.size.width = lockedWidth
                super.setFrame(clamped, display: displayFlag, animate: animateFlag)
                return
            }
            super.setFrame(frameRect, display: displayFlag, animate: animateFlag)
        }
    }

    private struct MountedWindowHarness {
        let viewModel: AppViewState
        let coordinator: InspectorWindowGeometryCoordinator
        let window: WindowManagerLockedNSWindow
        let hostingView: NSHostingView<AnyView>

        @MainActor
        func pumpLayout(iterations: Int = 6) {
            for _ in 0..<iterations {
                window.contentView?.needsLayout = true
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            coordinator.updateWindowMinimumSize(
                window: window,
                viewModel: viewModel,
                isRightVisible: viewModel.navigationState.isInspectorVisible
            )
        }

        @MainActor
        func cleanup() {
            BrowserWindowRegistry.shared.unregister(id: viewModel.windowID)
            InspectorWindowGeometryCoordinator.unregister(windowID: viewModel.windowID)
            window.delegate = nil
            window.contentView = nil
            window.close()
        }
    }

    @MainActor
    private func makeMountedWindowHarness(
        frame: NSRect = NSRect(x: 160, y: 180, width: 1080, height: 720),
        styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        initialDirectory: URL? = nil,
        screenVisibleFrameOverride: CGRect? = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    ) -> MountedWindowHarness {
        _ = NSApplication.shared
        UserDefaults.standard.set(Double(MainLayoutMetrics.defaultRightInspectorRatio), forKey: "TTZip_UserRightInspectorRatio")
        let viewModel = AppViewState()
        if let initialDirectory {
            viewModel.navigationState.currentDirectory = initialDirectory
        }
        let window = WindowManagerLockedNSWindow(
            contentRect: frame,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        let rootView = AnyView(
            MainWindowSceneRootView(viewModel: viewModel)
        )
        let hostingView = NSHostingView(rootView: rootView)
        window.contentView = hostingView
        window.setFrame(frame, display: true)

        BrowserWindowRegistry.shared.register(viewModel, nsWindow: window)
        BrowserWindowRegistry.shared.bindNSWindow(window, for: viewModel.windowID)

        let coordinator = InspectorWindowGeometryCoordinator.coordinator(
            for: viewModel.windowID,
            initialVisibility: viewModel.navigationState.isInspectorVisible
        )
        coordinator.attachWindowLifecycleObservers(to: window)
        coordinator.screenVisibleFrameOverride = screenVisibleFrameOverride
        coordinator.updateWindowMinimumSize(
            window: window,
            viewModel: viewModel,
            isRightVisible: viewModel.navigationState.isInspectorVisible
        )

        let harness = MountedWindowHarness(
            viewModel: viewModel,
            coordinator: coordinator,
            window: window,
            hostingView: hostingView
        )
        harness.pumpLayout(iterations: 8)
        return harness
    }

    @MainActor
    func testInspectorCollapseAndExpandPreservesCenterWidthAndLeftEdgeInRealOffscreenNSWindow() {
        let savedRatio = UserDefaults.standard.object(forKey: "TTZip_UserRightInspectorRatio")
        UserDefaults.standard.set(Double(MainLayoutMetrics.defaultRightInspectorRatio), forKey: "TTZip_UserRightInspectorRatio")
        defer {
            if let savedRatio {
                UserDefaults.standard.set(savedRatio, forKey: "TTZip_UserRightInspectorRatio")
            } else {
                UserDefaults.standard.removeObject(forKey: "TTZip_UserRightInspectorRatio")
            }
        }

        let harness = makeMountedWindowHarness(frame: NSRect(x: 160, y: 180, width: 1080, height: 720))
        defer { harness.cleanup() }

        let initialWindowFrame = harness.window.frame
        let initialCenterWidth = harness.coordinator.lastLiveCenterWidth
        let initialRightWidth = harness.coordinator.lastLiveRightPaneWidth
        let expectedDelta = initialRightWidth + ResizableDividerHandle.gutterWidth

        XCTAssertTrue(harness.hostingView.sizingOptions.contains(.minSize), "Production NSHostingView minSize option must remain active")
        XCTAssertTrue(harness.viewModel.navigationState.isInspectorVisible)
        XCTAssertEqual(initialWindowFrame.width, 1080.0, accuracy: 0.5)
        XCTAssertEqual(harness.hostingView.bounds.width, 1080.0, accuracy: 0.5)
        XCTAssertEqual(harness.hostingView.fittingSize.width, 720.0, accuracy: 0.5)
        XCTAssertEqual(initialRightWidth, 288.0, accuracy: 0.5)
        XCTAssertEqual(initialCenterWidth, 576.0, accuracy: 0.5)
        XCTAssertEqual(measuredCenterWorkspaceFrame(in: harness.hostingView)?.width ?? -1, initialCenterWidth, accuracy: 1.0)
        XCTAssertEqual(ResizableDividerHandle.gutterWidth, 8.0, accuracy: 0.01)

        // Collapse via production entrypoint: window shrinks leftward on the right edge by (288 + 8 = 296pt)
        let collapseOutcome = harness.viewModel.toggleInspector(animated: false)
        harness.pumpLayout()

        XCTAssertFalse(harness.viewModel.navigationState.isInspectorVisible)
        XCTAssertEqual(collapseOutcome.disposition, .resizedKeepingLeftEdge)
        XCTAssertEqual(harness.window.frame.minX, initialWindowFrame.minX, accuracy: 0.01, "Window left edge must stay stationary on collapse")
        XCTAssertEqual(initialWindowFrame.width - harness.window.frame.width, expectedDelta, accuracy: 0.5, "Window width delta must equal rightPane + dividerGutter")
        XCTAssertEqual(harness.coordinator.lastLiveCenterWidth, initialCenterWidth, accuracy: 0.5, "Center workspace width must remain invariant on collapse")
        XCTAssertEqual(measuredCenterWorkspaceFrame(in: harness.hostingView)?.width ?? -1, initialCenterWidth, accuracy: 1.0, "Real mounted center NSScrollView width must remain invariant on collapse")
        XCTAssertEqual(harness.hostingView.bounds.width, harness.window.frame.width, accuracy: 0.5, "AppKit-managed fullSizeContentView NSHostingView bounds must track shrunk window width (< 860pt)")
        XCTAssertEqual(harness.hostingView.fittingSize.width, 488.0, accuracy: 0.5, "Collapsed root fittingSize.width must drop to 2-column minimum (488pt)")
        XCTAssertEqual(harness.window.contentLayoutRect.width, harness.window.frame.width, accuracy: 0.5, "Window contentLayoutRect must match shrunk window frame width")

        // Expand again: window expands rightward on the right edge to restore exact captured right width
        let expandOutcome = harness.viewModel.toggleInspector(animated: false)
        harness.pumpLayout()

        XCTAssertTrue(harness.viewModel.navigationState.isInspectorVisible)
        XCTAssertEqual(expandOutcome.disposition, .resizedKeepingLeftEdge)
        XCTAssertEqual(harness.window.frame.minX, initialWindowFrame.minX, accuracy: 0.01, "Window left edge must stay stationary on expand")
        XCTAssertEqual(harness.window.frame.width, initialWindowFrame.width, accuracy: 0.5, "Window width must restore to pre-collapse width")
        XCTAssertEqual(harness.hostingView.bounds.width, initialWindowFrame.width, accuracy: 0.5, "AppKit-managed NSHostingView bounds must restore to expanded window width")
        XCTAssertEqual(harness.hostingView.fittingSize.width, 720.0, accuracy: 0.5, "Expanded root fittingSize.width must restore to 3-column minimum (720pt)")
        XCTAssertEqual(harness.coordinator.lastLiveCenterWidth, initialCenterWidth, accuracy: 0.5, "Center workspace width must remain invariant on expand")
        XCTAssertEqual(measuredCenterWorkspaceFrame(in: harness.hostingView)?.width ?? -1, initialCenterWidth, accuracy: 1.0, "Real mounted center NSScrollView width must remain invariant on expand")
        XCTAssertEqual(harness.coordinator.lastLiveRightPaneWidth, initialRightWidth, accuracy: 0.5, "Right pane width must restore exactly")
    }

    @MainActor
    func testRepeatedCollapseExpandCyclesAndCustomInspectorWidthZeroCumulativeDrift() {
        let harness = makeMountedWindowHarness(frame: NSRect(x: 180, y: 180, width: 1180, height: 740))
        defer { harness.cleanup() }

        // User drags right inspector divider to custom 364pt width
        let customRightWidth: CGFloat = 364.0
        harness.coordinator.recordUserDividerCommit(clampedRightWidth: customRightWidth)
        harness.pumpLayout()

        let baselineFrame = harness.window.frame
        let baselineCenterWidth = harness.coordinator.lastLiveCenterWidth
        let expectedCollapsedWidth = baselineFrame.width - (customRightWidth + ResizableDividerHandle.gutterWidth)

        for cycle in 1...12 {
            harness.viewModel.setInspectorVisible(false, animated: false)
            harness.pumpLayout(iterations: 3)

            XCTAssertEqual(harness.window.frame.minX, baselineFrame.minX, accuracy: 0.01, "Cycle \(cycle) collapse drifted left edge")
            XCTAssertEqual(harness.window.frame.width, expectedCollapsedWidth, accuracy: 0.05, "Cycle \(cycle) collapse drifted window width")
            XCTAssertEqual(harness.hostingView.bounds.width, expectedCollapsedWidth, accuracy: 0.5, "Cycle \(cycle) collapse drifted host bounds")
            XCTAssertEqual(harness.coordinator.lastLiveCenterWidth, baselineCenterWidth, accuracy: 0.05, "Cycle \(cycle) collapse drifted center width")
            XCTAssertEqual(measuredCenterWorkspaceFrame(in: harness.hostingView)?.width ?? -1, baselineCenterWidth, accuracy: 1.0)

            harness.viewModel.setInspectorVisible(true, animated: false)
            harness.pumpLayout(iterations: 3)

            XCTAssertEqual(harness.window.frame.minX, baselineFrame.minX, accuracy: 0.01, "Cycle \(cycle) expand drifted left edge")
            XCTAssertEqual(harness.window.frame.width, baselineFrame.width, accuracy: 0.05, "Cycle \(cycle) expand accumulated window width drift")
            XCTAssertEqual(harness.hostingView.bounds.width, baselineFrame.width, accuracy: 0.5, "Cycle \(cycle) expand drifted host bounds")
            XCTAssertEqual(harness.coordinator.lastLiveCenterWidth, baselineCenterWidth, accuracy: 0.05, "Cycle \(cycle) expand accumulated center width drift")
            XCTAssertEqual(measuredCenterWorkspaceFrame(in: harness.hostingView)?.width ?? -1, baselineCenterWidth, accuracy: 1.0)
            XCTAssertEqual(harness.coordinator.lastLiveRightPaneWidth, customRightWidth, accuracy: 0.05, "Cycle \(cycle) expand drifted custom right inspector width")
        }
    }

    @MainActor
    func testManualWindowResizeWhileHiddenPreservesResizedCenterWidthOnExpand() {
        let savedRatio = UserDefaults.standard.double(forKey: "TTZip_UserRightInspectorRatio")
        UserDefaults.standard.set(Double(MainLayoutMetrics.defaultRightInspectorRatio), forKey: "TTZip_UserRightInspectorRatio")
        defer { UserDefaults.standard.set(savedRatio, forKey: "TTZip_UserRightInspectorRatio") }

        let harness = makeMountedWindowHarness(frame: NSRect(x: 150, y: 180, width: 1080, height: 720))
        defer { harness.cleanup() }

        let capturedRight = harness.coordinator.lastLiveRightPaneWidth // 288pt
        let gutter = ResizableDividerHandle.gutterWidth // 8pt

        // 1. Collapse inspector -> window width becomes 1080 - 296 = 784pt (centerWidth = 576pt)
        harness.viewModel.setInspectorVisible(false, animated: false)
        harness.pumpLayout()
        XCTAssertEqual(harness.window.frame.width, 784.0, accuracy: 0.5)
        XCTAssertEqual(harness.hostingView.bounds.width, 784.0, accuracy: 0.5)
        XCTAssertEqual(harness.coordinator.lastLiveCenterWidth, 576.0, accuracy: 0.5)
        XCTAssertEqual(measuredCenterWorkspaceFrame(in: harness.hostingView)?.width ?? -1, 576.0, accuracy: 1.0)

        // 2. While hidden, user manually resizes window wider from 784pt to 920pt (+136pt to center)
        let manuallyResizedHiddenFrame = NSRect(x: 150, y: 180, width: 920, height: 720)
        harness.window.setFrame(manuallyResizedHiddenFrame, display: true)
        harness.pumpLayout()

        let resizedCenterWhileHidden = harness.coordinator.lastLiveCenterWidth
        XCTAssertEqual(harness.hostingView.bounds.width, 920.0, accuracy: 0.5)
        XCTAssertEqual(resizedCenterWhileHidden, 920.0 - 208.0, accuracy: 0.5, "Hidden manual resize must directly widen center workspace to 712pt")
        XCTAssertEqual(measuredCenterWorkspaceFrame(in: harness.hostingView)?.width ?? -1, resizedCenterWhileHidden, accuracy: 1.0)

        // 3. Expand inspector -> must use the 712pt hidden center width as baseline and add captured 288 + 8 = 296pt
        let expandOutcome = harness.viewModel.setInspectorVisible(true, animated: false)
        harness.pumpLayout()

        XCTAssertEqual(expandOutcome.disposition, .resizedKeepingLeftEdge)
        XCTAssertEqual(harness.window.frame.minX, 150.0, accuracy: 0.01)
        XCTAssertEqual(harness.window.frame.width, 920.0 + capturedRight + gutter, accuracy: 0.5)
        XCTAssertEqual(harness.hostingView.bounds.width, 920.0 + capturedRight + gutter, accuracy: 0.5)
        XCTAssertEqual(
            harness.coordinator.lastLiveCenterWidth,
            resizedCenterWhileHidden,
            accuracy: 0.5,
            "Expanding after manual resize while hidden must preserve the resized center width instead of recalculating from old ratio"
        )
        XCTAssertEqual(measuredCenterWorkspaceFrame(in: harness.hostingView)?.width ?? -1, resizedCenterWhileHidden, accuracy: 1.0)
        XCTAssertEqual(
            harness.coordinator.lastLiveRightPaneWidth,
            capturedRight,
            accuracy: 0.5,
            "Expanding after manual resize while hidden must restore captured right pane width"
        )
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: "TTZip_UserRightInspectorRatio"),
            Double(MainLayoutMetrics.defaultRightInspectorRatio),
            accuracy: 0.0001,
            "Collapse/expand must not mutate global UserDefaults preference"
        )
    }

    @MainActor
    func testMultiWindowIsolationAndAllWriteEntrypointsConsistency() {
        let harnessA = makeMountedWindowHarness(frame: NSRect(x: 100, y: 160, width: 1080, height: 700))
        let harnessB = makeMountedWindowHarness(frame: NSRect(x: 320, y: 200, width: 1260, height: 760))
        defer {
            harnessA.cleanup()
            harnessB.cleanup()
        }

        let initialFrameB = harnessB.window.frame
        let initialCenterB = harnessB.coordinator.lastLiveCenterWidth
        let initialCenterA = harnessA.coordinator.lastLiveCenterWidth

        // 1. Toggle Window A via toolbar/menu entrypoint -> Window B must remain untouched
        harnessA.viewModel.toggleInspector(animated: false)
        harnessA.pumpLayout()
        harnessB.pumpLayout()

        XCTAssertFalse(harnessA.viewModel.navigationState.isInspectorVisible)
        XCTAssertTrue(harnessB.viewModel.navigationState.isInspectorVisible)
        XCTAssertEqual(harnessB.window.frame, initialFrameB, "Toggling Window A must not alter Window B's frame")
        XCTAssertEqual(harnessB.coordinator.lastLiveCenterWidth, initialCenterB, accuracy: 0.1)
        XCTAssertEqual(harnessA.coordinator.lastLiveCenterWidth, initialCenterA, accuracy: 0.5)

        // 2. Programmatic auto-show via restoreStandaloneOriginPreview on Window A only
        let dummyURL = URL(fileURLWithPath: "/tmp/test-origin.txt")
        let session = StandalonePlaybackSessionState(
            item: ImmersiveMediaItem(url: dummyURL, name: "test-origin.txt"),
            canonicalIdentityKey: dummyURL.path,
            originBrowserWindowID: harnessA.viewModel.windowID,
            originSelectedItem: DiskItemInfo(url: dummyURL),
            originDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
        harnessA.viewModel.restoreStandaloneOriginPreview(session)
        harnessA.pumpLayout()

        XCTAssertTrue(harnessA.viewModel.navigationState.isInspectorVisible)
        XCTAssertEqual(harnessA.window.frame.width, 1080.0, accuracy: 0.5)
        XCTAssertEqual(harnessA.coordinator.lastLiveCenterWidth, initialCenterA, accuracy: 0.5)
        XCTAssertEqual(harnessB.window.frame, initialFrameB, "Programmatic origin restore on Window A must not alter Window B")

        // 3. Direct property write fallback (`navigationState.isInspectorVisible = false`) on Window B
        let rightWidthB = harnessB.coordinator.lastLiveRightPaneWidth
        harnessB.viewModel.navigationState.isInspectorVisible = false
        harnessB.coordinator.synchronizeGeometryForCurrentVisibility(of: harnessB.viewModel)
        harnessB.pumpLayout()

        XCTAssertEqual(
            harnessB.window.frame.width,
            initialFrameB.width - (rightWidthB + ResizableDividerHandle.gutterWidth),
            accuracy: 0.5,
            "Direct property mutation must be caught by window-local coordinator and shrink window by exact right footprint"
        )
        XCTAssertEqual(harnessB.coordinator.lastLiveCenterWidth, initialCenterB, accuracy: 0.5)
    }

    @MainActor
    func testPhysicalConstraintsScreenRightEdgeMinimumWidthAndFullScreenTileBranches() {
        // Branch A: Minimum window width consistency when collapsing a minimum-sized 3-column window (860pt),
        // resizing while hidden below 860pt (down to 540pt >= 488pt), and expanding back to 768pt (< 860pt).
        let compactHarness = makeMountedWindowHarness(frame: NSRect(x: 120, y: 160, width: 860, height: 640))
        defer { compactHarness.cleanup() }

        let preCollapseCenter = compactHarness.coordinator.lastLiveCenterWidth
        let preCollapseRight = compactHarness.coordinator.lastLiveRightPaneWidth
        XCTAssertEqual(compactHarness.window.minSize.width, 720.0, accuracy: 0.5)
        XCTAssertEqual(compactHarness.hostingView.fittingSize.width, 720.0, accuracy: 0.5)
        XCTAssertEqual(compactHarness.hostingView.bounds.width, 860.0, accuracy: 0.5)

        let compactCollapse = compactHarness.viewModel.setInspectorVisible(false, animated: false)
        compactHarness.pumpLayout()

        // At 860pt, right is 220pt + 8pt = 228pt -> collapsed width 632pt (< 860pt!).
        XCTAssertEqual(compactCollapse.disposition, .resizedKeepingLeftEdge)
        XCTAssertEqual(compactHarness.window.minSize.width, 488.0, accuracy: 0.5)
        XCTAssertEqual(compactHarness.window.frame.width, 860.0 - (preCollapseRight + 8.0), accuracy: 0.5)
        XCTAssertEqual(compactHarness.hostingView.bounds.width, 632.0, accuracy: 0.5)
        XCTAssertEqual(compactHarness.hostingView.fittingSize.width, 488.0, accuracy: 0.5)
        XCTAssertEqual(compactHarness.coordinator.lastLiveCenterWidth, preCollapseCenter, accuracy: 0.5)
        XCTAssertEqual(measuredCenterWorkspaceFrame(in: compactHarness.hostingView)?.width ?? -1, preCollapseCenter, accuracy: 1.0)

        // Resize while hidden narrower to 580pt (< 860pt, >= 488pt), then expand back to 580 + 228 = 808pt (< 860pt)
        compactHarness.window.setFrame(NSRect(x: 120, y: 160, width: 580, height: 640), display: true)
        compactHarness.pumpLayout()
        XCTAssertEqual(compactHarness.hostingView.bounds.width, 580.0, accuracy: 0.5)
        XCTAssertEqual(compactHarness.coordinator.lastLiveCenterWidth, 372.0, accuracy: 0.5)
        XCTAssertEqual(measuredCenterWorkspaceFrame(in: compactHarness.hostingView)?.width ?? -1, 372.0, accuracy: 1.0)

        let compactReexpand = compactHarness.viewModel.setInspectorVisible(true, animated: false)
        compactHarness.pumpLayout()
        XCTAssertEqual(compactReexpand.disposition, .resizedKeepingLeftEdge)
        XCTAssertEqual(compactHarness.window.frame.width, 580.0 + preCollapseRight + 8.0, accuracy: 0.5)
        XCTAssertEqual(compactHarness.hostingView.bounds.width, 808.0, accuracy: 0.5)
        XCTAssertEqual(compactHarness.hostingView.fittingSize.width, 720.0, accuracy: 0.5)
        XCTAssertEqual(compactHarness.coordinator.lastLiveCenterWidth, 372.0, accuracy: 0.5)
        XCTAssertEqual(measuredCenterWorkspaceFrame(in: compactHarness.hostingView)?.width ?? -1, 372.0, accuracy: 1.0)

        // Branch B: Screen right-edge overflow shifts window leftward to preserve full width & centerWidth
        let edgeHarness = makeMountedWindowHarness(
            frame: NSRect(x: 600, y: 160, width: 1080, height: 700),
            screenVisibleFrameOverride: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        defer { edgeHarness.cleanup() }

        edgeHarness.viewModel.setInspectorVisible(false, animated: false)
        edgeHarness.pumpLayout()
        // Move collapsed window (width 784) near the right edge of the 1440pt screen (minX = 620, maxX = 1404)
        edgeHarness.window.setFrame(NSRect(x: 620, y: 160, width: 784, height: 700), display: true)
        edgeHarness.pumpLayout()

        let shiftOutcome = edgeHarness.viewModel.setInspectorVisible(true, animated: false)
        edgeHarness.pumpLayout()

        XCTAssertEqual(shiftOutcome.disposition, .shiftedLeftToFitScreen, "Must explicitly report .shiftedLeftToFitScreen when shifting origin.x")
        XCTAssertEqual(edgeHarness.window.frame.width, 1080.0, accuracy: 0.5, "Full expanded width must be preserved")
        XCTAssertEqual(edgeHarness.window.frame.maxX, 1440.0, accuracy: 0.5, "Right edge must align with visibleFrame.maxX")
        XCTAssertEqual(edgeHarness.window.frame.minX, 1440.0 - 1080.0, accuracy: 0.5, "Left edge must shift leftward to fit screen")
        XCTAssertEqual(edgeHarness.coordinator.lastLiveCenterWidth, 576.0, accuracy: 0.5, "Center width must remain preserved")

        // Branch C: Real AppKit FullScreen / Split-View Tile lifecycle & styleMask does not force frame resize
        let fullScreenHarness = makeMountedWindowHarness(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        defer { fullScreenHarness.cleanup() }

        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: fullScreenHarness.window)
        fullScreenHarness.pumpLayout(iterations: 2)
        XCTAssertTrue(fullScreenHarness.coordinator.isInFullScreenTransition)
        XCTAssertEqual(fullScreenHarness.coordinator.activeSystemConstraintReason(for: fullScreenHarness.window), .fullScreenTransition)

        let transitionCollapse = fullScreenHarness.viewModel.setInspectorVisible(false, animated: false)
        fullScreenHarness.pumpLayout(iterations: 2)
        XCTAssertEqual(transitionCollapse.disposition, .inPlaceConstrainedFullScreenOrTiled)
        XCTAssertEqual(transitionCollapse.systemConstraintReason, .fullScreenTransition)
        XCTAssertEqual(fullScreenHarness.window.frame.width, 1440.0, accuracy: 0.5, "Window in fullScreen transition must not be resized via setFrame")
        XCTAssertFalse(fullScreenHarness.viewModel.navigationState.isInspectorVisible)

        fullScreenHarness.window.simulatedFullScreenStyleMask = true
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: fullScreenHarness.window)
        fullScreenHarness.pumpLayout(iterations: 2)
        XCTAssertFalse(fullScreenHarness.coordinator.isInFullScreenTransition)
        XCTAssertTrue(fullScreenHarness.coordinator.isSystemFullScreenActive)
        XCTAssertEqual(fullScreenHarness.coordinator.activeSystemConstraintReason(for: fullScreenHarness.window), .fullScreenStyleMask)

        let fullScreenExpand = fullScreenHarness.viewModel.setInspectorVisible(true, animated: false)
        fullScreenHarness.pumpLayout(iterations: 2)
        XCTAssertEqual(fullScreenExpand.disposition, .inPlaceConstrainedFullScreenOrTiled)
        XCTAssertEqual(fullScreenExpand.systemConstraintReason, .fullScreenStyleMask)
        XCTAssertEqual(fullScreenHarness.window.frame.width, 1440.0, accuracy: 0.5, "Active fullScreen / Split View tile window frame must not be mutated")
        XCTAssertTrue(fullScreenHarness.viewModel.navigationState.isInspectorVisible)

        // Exit fullScreen -> normal desktop window resizing resumes
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: fullScreenHarness.window)
        fullScreenHarness.window.simulatedFullScreenStyleMask = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: fullScreenHarness.window)
        fullScreenHarness.window.setFrame(NSRect(x: 120, y: 140, width: 1080, height: 720), display: true)
        fullScreenHarness.pumpLayout(iterations: 4)
        XCTAssertNil(fullScreenHarness.coordinator.activeSystemConstraintReason(for: fullScreenHarness.window))

        let postExitCollapse = fullScreenHarness.viewModel.setInspectorVisible(false, animated: false)
        fullScreenHarness.pumpLayout(iterations: 3)
        XCTAssertEqual(postExitCollapse.disposition, .resizedKeepingLeftEdge, "Exiting fullScreen must restore normal right-edge retract behavior")
    }

    @MainActor
    func testRealAppKitLiveResizeMiniaturizedNonResizableAndWindowManagerFrameRejectionConstraints() {
        // 1. Live Resize lifecycle (`willStartLiveResizeNotification` / `didEndLiveResizeNotification`)
        let liveResizeHarness = makeMountedWindowHarness(frame: NSRect(x: 140, y: 160, width: 1080, height: 720))
        defer { liveResizeHarness.cleanup() }

        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: liveResizeHarness.window)
        liveResizeHarness.pumpLayout(iterations: 2)
        XCTAssertEqual(liveResizeHarness.coordinator.activeSystemConstraintReason(for: liveResizeHarness.window), .liveResizeInProgress)

        let liveResizeCollapse = liveResizeHarness.viewModel.setInspectorVisible(false, animated: false)
        liveResizeHarness.pumpLayout(iterations: 2)
        XCTAssertEqual(liveResizeCollapse.disposition, .inPlaceConstrainedFullScreenOrTiled)
        XCTAssertEqual(liveResizeCollapse.systemConstraintReason, .liveResizeInProgress)
        XCTAssertEqual(liveResizeHarness.window.frame.width, 1080.0, accuracy: 0.5, "Must not call setFrame while user is actively live-resizing")

        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: liveResizeHarness.window)
        liveResizeHarness.pumpLayout(iterations: 2)
        XCTAssertNil(liveResizeHarness.coordinator.activeSystemConstraintReason(for: liveResizeHarness.window))

        // 2. Miniaturized & Non-resizable styleMask constraints
        NotificationCenter.default.post(name: NSWindow.willMiniaturizeNotification, object: liveResizeHarness.window)
        liveResizeHarness.pumpLayout(iterations: 2)
        let miniExpand = liveResizeHarness.viewModel.setInspectorVisible(true, animated: false)
        XCTAssertEqual(miniExpand.disposition, .inPlaceConstrainedFullScreenOrTiled)
        XCTAssertEqual(miniExpand.systemConstraintReason, .miniaturized)

        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: liveResizeHarness.window)
        liveResizeHarness.pumpLayout(iterations: 2)
        XCTAssertNil(liveResizeHarness.coordinator.activeSystemConstraintReason(for: liveResizeHarness.window))

        let nonResizableHarness = makeMountedWindowHarness(
            frame: NSRect(x: 140, y: 160, width: 1080, height: 720),
            styleMask: [.titled, .closable, .fullSizeContentView]
        )
        defer { nonResizableHarness.cleanup() }
        let nonResizableCollapse = nonResizableHarness.viewModel.setInspectorVisible(false, animated: false)
        XCTAssertEqual(nonResizableCollapse.disposition, .inPlaceConstrainedFullScreenOrTiled)
        XCTAssertEqual(nonResizableCollapse.systemConstraintReason, .nonResizableStyleMask)

        // 3. External WindowManager / desktop tile frame rejection fallback (`frameRejectedByWindowManager`):
        // When a window has `.resizable` styleMask on the desktop space (no public AppKit pre-flight property exists for desktop tiling)
        // and the window manager clamps/rejects `setFrame`, coordinator detects post-setFrame discrepancy and degrades safely.
        let tiledHarness = makeMountedWindowHarness(frame: NSRect(x: 0, y: 0, width: 960, height: 720))
        defer { tiledHarness.cleanup() }
        tiledHarness.window.isFrameLockedByWindowManager = true
        tiledHarness.window.lockedFrameWidth = 960.0

        let rejectedCollapse = tiledHarness.viewModel.setInspectorVisible(false, animated: false)
        tiledHarness.pumpLayout(iterations: 3)
        XCTAssertEqual(rejectedCollapse.disposition, .inPlaceConstrainedFullScreenOrTiled)
        XCTAssertEqual(rejectedCollapse.systemConstraintReason, .frameRejectedByWindowManager)
        XCTAssertEqual(tiledHarness.window.frame.width, 960.0, accuracy: 0.5)

        let rejectedExpand = tiledHarness.viewModel.setInspectorVisible(true, animated: false)
        tiledHarness.pumpLayout(iterations: 3)
        XCTAssertEqual(rejectedExpand.disposition, .inPlaceConstrainedFullScreenOrTiled)
        XCTAssertEqual(rejectedExpand.systemConstraintReason, .frameRejectedByWindowManager)
        XCTAssertNil(tiledHarness.coordinator.lockedExpandedRightWidth, "Frame rejection on expand must release lockedExpandedRightWidth so layout fits inside the locked tile width")
        XCTAssertEqual(
            tiledHarness.coordinator.lastLiveLeftSidebarWidth
                + ResizableDividerHandle.gutterWidth
                + tiledHarness.coordinator.lastLiveCenterWidth
                + ResizableDividerHandle.gutterWidth
                + tiledHarness.coordinator.lastLiveRightPaneWidth,
            960.0,
            accuracy: 1.0,
            "Three columns must fit cleanly within the 960pt locked desktop tile width without overflow"
        )
    }

    @MainActor
    func testSelectionColumnWidthsAndScrollAnchorPreservedAndMutationSensitivity() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip-inspector-geom-\(UUID().uuidString)", isDirectory: true)
        let childDir = tempRoot.appendingPathComponent("AlphaFolder", isDirectory: true)
        let targetFile = childDir.appendingPathComponent("readme.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: childDir, withIntermediateDirectories: true)
        try Data("hello inspector geometry".utf8).write(to: targetFile)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let harness = makeMountedWindowHarness(
            frame: NSRect(x: 140, y: 160, width: 1080, height: 720),
            initialDirectory: tempRoot
        )
        defer { harness.cleanup() }

        let selectedDiskItem = DiskItemInfo(url: targetFile)
        harness.viewModel.selectionState.select(selectedDiskItem)
        harness.pumpLayout(iterations: 8)

        let preCollapseCenter = harness.coordinator.lastLiveCenterWidth
        XCTAssertEqual(harness.viewModel.selectedDiskItem?.path, targetFile.path)

        // Locate real NSScrollViews inside the center Miller Columns workspace and record their scroll origins & frames
        let initialScrollRects = findScrollViewsWithOrigins(in: harness.hostingView)
        XCTAssertFalse(initialScrollRects.isEmpty, "Real offscreen MainView must mount NSScrollViews for Miller columns")

        // Collapse and expand: selection, directory state, and scroll anchors must remain intact
        harness.viewModel.toggleInspector(animated: false)
        harness.pumpLayout()
        XCTAssertEqual(harness.viewModel.selectedDiskItem?.path, targetFile.path)
        XCTAssertEqual(harness.viewModel.navigationState.currentDirectory, tempRoot)
        XCTAssertEqual(harness.coordinator.lastLiveCenterWidth, preCollapseCenter, accuracy: 0.5)

        let collapsedScrollRects = findScrollViewsWithOrigins(in: harness.hostingView)
        XCTAssertFalse(collapsedScrollRects.isEmpty)
        XCTAssertEqual(
            collapsedScrollRects.first?.documentVisibleOrigin.x ?? -1,
            initialScrollRects.first?.documentVisibleOrigin.x ?? -2,
            accuracy: 0.5,
            "Horizontal Miller scroll origin must remain anchored across collapse"
        )
        XCTAssertEqual(
            collapsedScrollRects.first?.documentVisibleOrigin.y ?? -1,
            initialScrollRects.first?.documentVisibleOrigin.y ?? -2,
            accuracy: 0.5,
            "Vertical Miller scroll origin must remain anchored across collapse"
        )

        harness.viewModel.toggleInspector(animated: false)
        harness.pumpLayout()
        XCTAssertEqual(harness.viewModel.selectedDiskItem?.path, targetFile.path)
        XCTAssertEqual(harness.coordinator.lastLiveCenterWidth, preCollapseCenter, accuracy: 0.5)

        // Mutation sensitivity proof: if window resize is neutralized, collapsing causes centerWidth to widen by ~296pt
        harness.coordinator.isWindowFrameResizeNeutralizedForTesting = true
        harness.viewModel.setInspectorVisible(false, animated: false)
        harness.pumpLayout()

        let driftedCenterWidth = harness.coordinator.lastLiveCenterWidth
        XCTAssertGreaterThan(
             abs(driftedCenterWidth - preCollapseCenter),
            200.0,
            "Neutralizing NSWindow.setFrame MUST cause centerWidth invariance assertion to fail (mutation sensitivity guard)"
        )
    }

    private struct ScrollViewSnapshot {
        let frameInWindow: NSRect
        let documentVisibleOrigin: NSPoint
    }

    private func measuredCenterWorkspaceFrame(in hostingView: NSView) -> NSRect? {
        findScrollViewsWithOrigins(in: hostingView)
            .map(\.frameInWindow)
            .filter { $0.minX >= 190.0 && $0.width >= 260.0 }
            .max(by: { $0.width < $1.width })
    }

    private func findScrollViewsWithOrigins(in root: NSView) -> [ScrollViewSnapshot] {
        var results: [ScrollViewSnapshot] = []
        if let scrollView = root as? NSScrollView {
            let rect = scrollView.convert(scrollView.bounds, to: nil)
            results.append(
                ScrollViewSnapshot(
                    frameInWindow: rect,
                    documentVisibleOrigin: scrollView.contentView.bounds.origin
                )
            )
        }
        for child in root.subviews {
            results.append(contentsOf: findScrollViewsWithOrigins(in: child))
        }
        return results
    }
}
