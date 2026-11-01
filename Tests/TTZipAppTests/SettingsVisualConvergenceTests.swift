// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import XCTest
@testable import TTZipApp
@testable import TTZipCore
@testable import TTZipUI

@MainActor
final class SettingsVisualConvergenceTests: XCTestCase {
    private var suiteName: String!
    private var isolatedDefaults: UserDefaults!
    private var originalLanguage: AppLanguage!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.metastudyline.ttzip.tests.settings.visual.\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: suiteName)
        isolatedDefaults.removePersistentDomain(forName: suiteName)
        originalLanguage = AppLocalizationState.shared.currentLanguage
    }

    override func tearDown() async throws {
        if let originalLanguage {
            AppLocalizationState.shared.setLanguage(originalLanguage)
        }
        if let suiteName, let isolatedDefaults {
            isolatedDefaults.removePersistentDomain(forName: suiteName)
        }
        isolatedDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - 1. Single-Container Ownership & Zero Duplicate Title Across Both Real Hosts

    func testNativeSettingsHostAndSheetHostEliminateDuplicateSettingsHeader() throws {
        XCTAssertFalse(
            SettingsView.rendersInternalWorkspaceHeader,
            "SettingsView must not render an internal TTZipWorkspaceScaffold header bar"
        )
        XCTAssertFalse(
            SettingsView.rendersFullPageEnclosedCard,
            "SettingsView must not wrap the entire page inside an inner enclosed card"
        )

        let l10n = AppLocalizationState.shared
        for lang in [AppLanguage.zhHans, .zhHant, .en] {
            l10n.setLanguage(lang)
            let expectedWindowTitle = l10n.t(L10n.Sidebar.settings)

            // Host A: macOS Native Settings scene host (window title owns localized "Settings" label)
            let nativeHosting = NSHostingView(rootView: SettingsView(initialTab: .general))
            nativeHosting.frame = NSRect(x: 0, y: 0, width: 660, height: 470)
            let nativeWindow = makeOffscreenWindow(contentView: nativeHosting, title: expectedWindowTitle)
            defer { nativeWindow.close() }
            pumpLayout(window: nativeWindow, hostingView: nativeHosting)

            XCTAssertEqual(nativeWindow.title, expectedWindowTitle)
            let nativePopUps = findPopUpButtons(in: nativeHosting)
            XCTAssertGreaterThanOrEqual(
                nativePopUps.count,
                1,
                "Native SettingsView(.general) must mount reachable appearance NSPopUpButton in \(lang.rawValue)"
            )

            // Host B: Main Window SecondaryToolSheetContainer(.settings) host
            var didDismissSheet = false
            let sheetView = SecondaryToolSheetContainer(tab: .settings, onDismiss: { didDismissSheet = true })
            XCTAssertEqual(sheetView.headerTitle, expectedWindowTitle)
            XCTAssertEqual(sheetView.idealSheetSize, CGSize(width: 680, height: 490))

            let sheetHosting = NSHostingView(rootView: sheetView)
            sheetHosting.frame = NSRect(x: 0, y: 0, width: 680, height: 490)
            let sheetWindow = makeOffscreenWindow(contentView: sheetHosting, title: "")
            defer { sheetWindow.close() }
            pumpLayout(window: sheetWindow, hostingView: sheetHosting)

            let sheetPopUps = findPopUpButtons(in: sheetHosting)
            XCTAssertGreaterThanOrEqual(
                sheetPopUps.count,
                1,
                "SecondaryToolSheetContainer(.settings) must mount reachable appearance NSPopUpButton in \(lang.rawValue)"
            )

            let closeButton = try XCTUnwrap(
                findButton(in: sheetHosting, identifier: "secondaryToolSheet.closeButton"),
                "SecondaryToolSheetContainer(.settings) must mount a reachable close NSButton in \(lang.rawValue)"
            )
            XCTAssertFalse(closeButton.isHidden)
            XCTAssertTrue(closeButton.isEnabled)
            XCTAssertEqual(closeButton.keyEquivalent, "\u{1b}")
            closeButton.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertTrue(
                didDismissSheet,
                "SecondaryToolSheetContainer close button action must invoke onDismiss in \(lang.rawValue)"
            )
        }
    }

    // MARK: - 2. Adaptive Sidebar vs Compact Navigation, Focus Entrypoint & Keyboard/Click Tab Switching

    func testAdaptiveNavigationBreakpointAndKeyboardTabCycling() throws {
        XCTAssertTrue(SettingsView.usesSidebarNavigation(forWidth: 680))
        XCTAssertTrue(SettingsView.usesSidebarNavigation(forWidth: 540))
        XCTAssertFalse(SettingsView.usesSidebarNavigation(forWidth: 500))
        XCTAssertFalse(SettingsView.usesSidebarNavigation(forWidth: 460))
        XCTAssertTrue(SettingsView.usesSidebarNavigation(forWidth: 0), "Zero pre-layout width must default to sidebar mode")

        let allTabs = SettingsView.SettingsTab.allCases
        XCTAssertEqual(allTabs, [.general, .localization, .presets, .vault, .localModels, .license])
        XCTAssertEqual(SettingsView.adjacentTab(from: .general, offset: -1), .general)
        XCTAssertEqual(SettingsView.adjacentTab(from: .general, offset: 1), .localization)
        XCTAssertEqual(SettingsView.adjacentTab(from: .localization, offset: 1), .presets)
        XCTAssertEqual(SettingsView.adjacentTab(from: .license, offset: 1), .license)
        XCTAssertEqual(SettingsView.adjacentTab(from: .license, offset: -1), .localModels)

        let l10n = AppLocalizationState.shared
        for lang in [AppLanguage.zhHans, .zhHant, .en] {
            l10n.setLanguage(lang)
            for tab in allTabs {
                let localized = tab.localizedTitle(using: l10n)
                XCTAssertFalse(localized.isEmpty, "Tab \(tab.rawValue) title must not be empty in \(lang.rawValue)")
            }
        }
        l10n.setLanguage(.zhHans)

        // Wide layout (680x470): verify focus entrypoint, Down Arrow keyDown, and button click tab transitions
        let wideHosting = NSHostingView(rootView: SettingsView(initialTab: .general))
        wideHosting.frame = NSRect(x: 0, y: 0, width: 680, height: 470)
        let wideWindow = makeOffscreenWindow(contentView: wideHosting, title: "SettingsWide")
        defer { wideWindow.close() }
        pumpLayout(window: wideWindow, hostingView: wideHosting)

        let generalBtn = try XCTUnwrap(findButton(in: wideHosting, identifier: "settings.nav.tab.general"))
        let localizationBtn = try XCTUnwrap(findButton(in: wideHosting, identifier: "settings.nav.tab.localization"))
        let licenseBtn = try XCTUnwrap(findButton(in: wideHosting, identifier: "settings.nav.tab.license"))
        XCTAssertTrue(generalBtn.isAccessibilitySelected())
        XCTAssertFalse(localizationBtn.isAccessibilitySelected())
        XCTAssertEqual(findPopUpButtons(in: wideHosting).count, 1)
        XCTAssertEqual(findSwitches(in: wideHosting).count, 1)

        XCTAssertTrue(wideWindow.makeFirstResponder(generalBtn), "General tab button must accept firstResponder focus")
        XCTAssertTrue(wideWindow.firstResponder === generalBtn)
        try sendKeyCode(125, to: generalBtn, in: wideWindow) // Down Arrow -> .localization
        pumpLayout(window: wideWindow, hostingView: wideHosting)
        XCTAssertTrue(localizationBtn.isAccessibilitySelected(), "Down Arrow on focused General tab must select Localization")
        XCTAssertFalse(generalBtn.isAccessibilitySelected())
        XCTAssertTrue(findPopUpButtons(in: wideHosting).isEmpty, "Switching away from .general must unmount appearance NSPopUpButton")

        licenseBtn.performClick(nil)
        pumpLayout(window: wideWindow, hostingView: wideHosting)
        XCTAssertTrue(licenseBtn.isAccessibilitySelected(), "Clicking License tab button must select .license")
        let licenseGroup = try XCTUnwrap(
            findAccessibilityGroupView(in: wideHosting, identifier: "settings.group.checkmark.seal.fill"),
            "Selecting .license must mount the license status SettingsFormGroup"
        )
        XCTAssertEqual(licenseGroup.accessibilityLabel(), l10n.t(L10n.Settings.licenseStatus))
        XCTAssertNotNil(
            findAccessibilityGroupView(in: wideHosting, identifier: "settings.group.cpu.fill"),
            "Selecting .license must mount the hardware topology SettingsFormGroup"
        )
        XCTAssertNil(findAccessibilityGroupView(in: wideHosting, identifier: "settings.group.globe"))

        generalBtn.performClick(nil)
        pumpLayout(window: wideWindow, hostingView: wideHosting)
        XCTAssertTrue(generalBtn.isAccessibilitySelected(), "Clicking General tab button must return to .general")
        XCTAssertEqual(findPopUpButtons(in: wideHosting).count, 1)
        XCTAssertNil(findAccessibilityGroupView(in: wideHosting, identifier: "settings.group.checkmark.seal.fill"))

        // Narrow layout (480x420): verify compact horizontal bar focus entrypoint and Right Arrow keyDown
        let narrowHosting = NSHostingView(rootView: SettingsView(initialTab: .general))
        narrowHosting.frame = NSRect(x: 0, y: 0, width: 480, height: 420)
        let narrowWindow = makeOffscreenWindow(contentView: narrowHosting, title: "SettingsNarrow")
        defer { narrowWindow.close() }
        pumpLayout(window: narrowWindow, hostingView: narrowHosting)
        let narrowPopUps = findPopUpButtons(in: narrowHosting)
        XCTAssertEqual(narrowPopUps.count, 1)
        for popUp in narrowPopUps {
            XCTAssertFalse(popUp.isHidden)
            XCTAssertGreaterThanOrEqual(popUp.bounds.width, 100)
        }
        let narrowGeneralBtn = try XCTUnwrap(findButton(in: narrowHosting, identifier: "settings.nav.tab.general"))
        let narrowLocBtn = try XCTUnwrap(findButton(in: narrowHosting, identifier: "settings.nav.tab.localization"))
        XCTAssertTrue(narrowWindow.makeFirstResponder(narrowGeneralBtn))
        try sendKeyCode(124, to: narrowGeneralBtn, in: narrowWindow) // Right Arrow -> .localization
        pumpLayout(window: narrowWindow, hostingView: narrowHosting)
        XCTAssertTrue(narrowLocBtn.isAccessibilitySelected(), "Right Arrow in compact bar must select Localization")
    }

    // MARK: - 3. All 6 Categories Selected Content, Real Controls & Visual Style Accessibility Matrix

    func testAllSixCategoriesMountCleanlyAndVisualStyleAdaptsToAccessibilitySettings() throws {
        let l10n = AppLocalizationState.shared
        l10n.setLanguage(.zhHans)
        let isolatedStore = ApplicationAppearanceStore(
            defaults: isolatedDefaults,
            applier: AppKitApplicationAppearanceApplier(targetProvider: { nil }),
            applyImmediately: false
        )

        for tab in SettingsView.SettingsTab.allCases {
            let hosting = NSHostingView(
                rootView: SettingsView(initialTab: tab, appearanceStore: isolatedStore)
            )
            hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 470)
            let window = makeOffscreenWindow(contentView: hosting, title: "Settings-\(tab.rawValue)")
            defer { window.close() }
            pumpLayout(window: window, hostingView: hosting)

            for navTab in SettingsView.SettingsTab.allCases {
                let navButton = try XCTUnwrap(
                    findButton(in: hosting, identifier: "settings.nav.tab.\(navTab.rawValue)"),
                    "Category tab button \(navTab.rawValue) must be mounted when initialTab=\(tab.rawValue)"
                )
                XCTAssertEqual(navButton.isAccessibilitySelected(), navTab == tab)
                XCTAssertEqual(navButton.accessibilityLabel(), navTab.localizedTitle(using: l10n))
            }

            let scrollView = try XCTUnwrap(findScrollViews(in: hosting).first, "Tab \(tab.rawValue) must mount content NSScrollView")
            let docHeight = scrollView.documentView?.bounds.height ?? 0
            XCTAssertGreaterThan(docHeight, 80, "Tab \(tab.rawValue) scroll document must have non-trivial rendered height")

            switch tab {
            case .general:
                let popUp = try XCTUnwrap(findPopUpButtons(in: hosting).first)
                XCTAssertEqual(popUp.accessibilityIdentifier(), "settings.general.appearancePicker")
                XCTAssertEqual(popUp.numberOfItems, 3)
                popUp.selectItem(at: 2)
                _ = popUp.sendAction(popUp.action, to: popUp.target)
                XCTAssertEqual(isolatedStore.mode, .dark)
                let toggle = try XCTUnwrap(findSwitches(in: hosting).first)
                let initialState = toggle.state
                toggle.performClick(nil)
                XCTAssertNotEqual(toggle.state, initialState, "Smart Store NSSwitch must toggle state on click")
                toggle.performClick(nil)
                XCTAssertEqual(toggle.state, initialState, "Smart Store NSSwitch must restore state on second click")
                XCTAssertNotNil(findAccessibilityGroupView(in: hosting, identifier: "settings.group.circle.lefthalf.filled"))
                XCTAssertNotNil(findAccessibilityGroupView(in: hosting, identifier: "settings.group.bolt.badge.automatic.fill"))
            case .localization:
                let group = try XCTUnwrap(findAccessibilityGroupView(in: hosting, identifier: "settings.group.globe"))
                XCTAssertEqual(group.accessibilityLabel(), l10n.t(L10n.Settings.localization))
                XCTAssertTrue(findPopUpButtons(in: hosting).isEmpty)
            case .presets:
                let group = try XCTUnwrap(findAccessibilityGroupView(in: hosting, identifier: "settings.group.slider.horizontal.3"))
                XCTAssertEqual(group.accessibilityLabel(), l10n.t(L10n.Presets.title))
                XCTAssertTrue(findPopUpButtons(in: hosting).isEmpty)
            case .vault:
                let group = try XCTUnwrap(findAccessibilityGroupView(in: hosting, identifier: "settings.group.lock.shield.fill"))
                XCTAssertEqual(group.accessibilityLabel(), l10n.t(L10n.Vault.vaultSecurityHeader))
                XCTAssertTrue(findPopUpButtons(in: hosting).isEmpty)
            case .localModels:
                let overview = try XCTUnwrap(findAccessibilityGroupView(in: hosting, identifier: "settings.group.square.stack.3d.up.fill"))
                XCTAssertEqual(overview.accessibilityLabel(), l10n.t(L10n.LocalModel.sectionTitle))
                let metadata = try XCTUnwrap(findAccessibilityGroupView(in: hosting, identifier: "settings.group.internaldrive"))
                XCTAssertEqual(metadata.accessibilityLabel(), l10n.t(L10n.LocalModel.metadataHeader))
                XCTAssertTrue(findPopUpButtons(in: hosting).isEmpty)
            case .license:
                let license = try XCTUnwrap(findAccessibilityGroupView(in: hosting, identifier: "settings.group.checkmark.seal.fill"))
                XCTAssertEqual(license.accessibilityLabel(), l10n.t(L10n.Settings.licenseStatus))
                let hardware = try XCTUnwrap(findAccessibilityGroupView(in: hosting, identifier: "settings.group.cpu.fill"))
                XCTAssertEqual(hardware.accessibilityLabel(), l10n.t(L10n.Settings.hardwareTopology))
                XCTAssertTrue(findPopUpButtons(in: hosting).isEmpty)
            }
        }

        let standardStyle = SettingsVisualStyle(
            colorScheme: .light,
            reduceTransparency: false,
            colorSchemeContrast: .standard
        )
        let highContrastStyle = SettingsVisualStyle(
            colorScheme: .dark,
            reduceTransparency: true,
            colorSchemeContrast: .increased
        )
        XCTAssertEqual(standardStyle.borderWidth, TTZipTheme.Layout.hairlineBorderWidth)
        XCTAssertEqual(highContrastStyle.borderWidth, TTZipTheme.Layout.hairlineBorderWidth * 2.0)
        XCTAssertTrue(highContrastStyle.reduceTransparency)
        XCTAssertTrue(highContrastStyle.increasedContrast)
        XCTAssertGreaterThan(highContrastStyle.selectedTabFillOpacity, standardStyle.selectedTabFillOpacity)
    }

    // MARK: - 4. Offscreen Visual Evidence Export & Light/Dark Contrast for Both Hosts

    func testGenerateOffscreenConvergenceSnapshotsForBothHosts() throws {
        let l10n = AppLocalizationState.shared
        l10n.setLanguage(.zhHans)
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        // 1. SecondaryToolSheetContainer host (680x490) Light & Dark
        let sheetHosting = NSHostingView(
            rootView: SecondaryToolSheetContainer(tab: .settings, onDismiss: {})
        )
        sheetHosting.frame = NSRect(x: 0, y: 0, width: 680, height: 490)
        let sheetWindow = makeOffscreenWindow(contentView: sheetHosting, title: "")
        defer { sheetWindow.close() }
        pumpLayout(window: sheetWindow, hostingView: sheetHosting)

        let sheetLightLuma = try exportOffscreenSnapshot(
            window: sheetWindow,
            view: sheetHosting,
            appearance: lightAppearance,
            filename: "after-host-sheet-wide-general-light.png"
        )
        let sheetDarkLuma = try exportOffscreenSnapshot(
            window: sheetWindow,
            view: sheetHosting,
            appearance: darkAppearance,
            filename: "after-host-sheet-wide-general-dark.png"
        )
        XCTAssertGreaterThan(
            sheetLightLuma - sheetDarkLuma,
            0.25,
            "SecondaryToolSheetContainer Light snapshot (luma=\(sheetLightLuma)) must be visibly brighter than Dark snapshot (luma=\(sheetDarkLuma))"
        )

        // 2. Native Settings host Wide (660x470) Local Models & License & Narrow (480x420) General
        try exportNativeHostSnapshots(lightAppearance: lightAppearance, darkAppearance: darkAppearance)
    }

    private func exportNativeHostSnapshots(
        lightAppearance: NSAppearance,
        darkAppearance: NSAppearance
    ) throws {
        let localModelsHosting = NSHostingView(rootView: SettingsView(initialTab: .localModels))
        localModelsHosting.frame = NSRect(x: 0, y: 0, width: 660, height: 470)
        let localModelsWindow = makeOffscreenWindow(contentView: localModelsHosting, title: "Settings")
        defer { localModelsWindow.close() }
        pumpLayout(window: localModelsWindow, hostingView: localModelsHosting)

        let nativeLightLuma = try exportOffscreenSnapshot(
            window: localModelsWindow,
            view: localModelsHosting,
            appearance: lightAppearance,
            filename: "after-host-native-wide-localmodels-light.png"
        )
        let nativeDarkLuma = try exportOffscreenSnapshot(
            window: localModelsWindow,
            view: localModelsHosting,
            appearance: darkAppearance,
            filename: "after-host-native-wide-localmodels-dark.png"
        )
        XCTAssertGreaterThan(
            nativeLightLuma - nativeDarkLuma,
            0.25,
            "Native SettingsView(.localModels) Light snapshot (luma=\(nativeLightLuma)) must be visibly brighter than Dark snapshot (luma=\(nativeDarkLuma))"
        )

        let licenseHosting = NSHostingView(rootView: SettingsView(initialTab: .license))
        licenseHosting.frame = NSRect(x: 0, y: 0, width: 660, height: 470)
        let licenseWindow = makeOffscreenWindow(contentView: licenseHosting, title: "SettingsLicense")
        defer { licenseWindow.close() }
        pumpLayout(window: licenseWindow, hostingView: licenseHosting)
        _ = try exportOffscreenSnapshot(
            window: licenseWindow,
            view: licenseHosting,
            appearance: lightAppearance,
            filename: "after-host-native-wide-license-light.png"
        )

        AppLocalizationState.shared.setLanguage(.en)
        let enHosting = NSHostingView(rootView: SettingsView(initialTab: .localization))
        enHosting.frame = NSRect(x: 0, y: 0, width: 660, height: 470)
        let enWindow = makeOffscreenWindow(contentView: enHosting, title: "SettingsEn")
        defer { enWindow.close() }
        pumpLayout(window: enWindow, hostingView: enHosting)
        _ = try exportOffscreenSnapshot(
            window: enWindow,
            view: enHosting,
            appearance: lightAppearance,
            filename: "after-host-native-wide-localization-en-light.png"
        )

        AppLocalizationState.shared.setLanguage(.zhHans)
        let narrowHosting = NSHostingView(rootView: SettingsView(initialTab: .general))
        narrowHosting.frame = NSRect(x: 0, y: 0, width: 480, height: 420)
        let narrowWindow = makeOffscreenWindow(contentView: narrowHosting, title: "SettingsNarrow")
        defer { narrowWindow.close() }
        pumpLayout(window: narrowWindow, hostingView: narrowHosting)
        _ = try exportOffscreenSnapshot(
            window: narrowWindow,
            view: narrowHosting,
            appearance: lightAppearance,
            filename: "after-host-native-narrow-general-light.png"
        )
    }

    // MARK: - Private Offscreen Helpers

    private func makeOffscreenWindow(contentView: NSView, title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentView = contentView
        window.setFrameOrigin(NSPoint(x: -16_000, y: -16_000))
        window.orderOut(nil)
        return window
    }

    private func pumpLayout(window: NSWindow, hostingView: NSView) {
        window.contentView?.needsLayout = true
        window.contentView?.layoutSubtreeIfNeeded()
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        }
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()
        if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        }
    }

    private func findPopUpButtons(in root: NSView) -> [NSPopUpButton] {
        var found: [NSPopUpButton] = []
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if let popUp = current as? NSPopUpButton {
                found.append(popUp)
            }
            stack.append(contentsOf: current.subviews)
        }
        return found
    }

    private func findButton(in root: NSView, identifier: String) -> NSButton? {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if let button = current as? NSButton, button.accessibilityIdentifier() == identifier {
                return button
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    private func findSwitches(in root: NSView) -> [NSSwitch] {
        var found: [NSSwitch] = []
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if let sw = current as? NSSwitch {
                found.append(sw)
            }
            stack.append(contentsOf: current.subviews)
        }
        return found
    }

    private func findAccessibilityGroupView(in root: NSView, identifier: String) -> NSView? {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if current.accessibilityIdentifier() == identifier {
                return current
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    private func findScrollViews(in root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if let scroll = current as? NSScrollView {
                found.append(scroll)
            }
            stack.append(contentsOf: current.subviews)
        }
        return found
    }

    private func sendKeyCode(_ keyCode: UInt16, to responder: NSResponder, in window: NSWindow) throws {
        let keyDownEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )
        )
        responder.keyDown(with: keyDownEvent)
    }

    private func exportOffscreenSnapshot(
        window: NSWindow,
        view: NSView,
        appearance: NSAppearance,
        filename: String
    ) throws -> Double {
        window.appearance = appearance
        view.appearance = appearance
        pumpLayout(window: window, hostingView: view)
        let bounds = view.bounds
        let viewRep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        var canvasColor: NSColor = .windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            canvasColor = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor
            view.cacheDisplay(in: bounds, to: viewRep)
        }

        var lumaSum = 0.0
        var sampleCount = 0
        let stepX = max(1, viewRep.pixelsWide / 32)
        let stepY = max(1, viewRep.pixelsHigh / 32)
        for y in stride(from: 0, to: viewRep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: viewRep.pixelsWide, by: stepX) {
                if let pixel = viewRep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    lumaSum += 0.2126 * Double(pixel.redComponent)
                        + 0.7152 * Double(pixel.greenComponent)
                        + 0.0722 * Double(pixel.blueComponent)
                    sampleCount += 1
                }
            }
        }

        let image = NSImage(size: bounds.size)
        image.lockFocus()
        canvasColor.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: bounds.size)).fill()
        viewRep.draw(in: NSRect(origin: .zero, size: bounds.size))
        image.unlockFocus()

        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let outRep = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let pngData = try XCTUnwrap(outRep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(pngData.count, 1024, "Snapshot \(filename) must be non-empty PNG")

        if let outDir = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] {
            let dirURL = URL(fileURLWithPath: outDir, isDirectory: true)
            try? pngData.write(to: dirURL.appendingPathComponent(filename), options: .atomic)
        }
        return sampleCount > 0 ? lumaSum / Double(sampleCount) : 0.0
    }
}
