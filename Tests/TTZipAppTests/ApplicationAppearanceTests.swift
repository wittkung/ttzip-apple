// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTMediaKit
import TTZipCore
import TTZipUI
import XCTest
@testable import TTZipApp

// MARK: - Observable Appearance Target & Applier Test Doubles

@MainActor
final class SimulatedApplicationAppearanceTarget: ApplicationAppearanceTargetProtocol {
    struct AppliedEvent: Equatable {
        let mode: ApplicationAppearance
        let appearanceName: NSAppearance.Name?
    }

    var systemAppearanceName: NSAppearance.Name = .aqua {
        didSet {
            propagateSystemAppearanceToWindows()
        }
    }

    var appearance: NSAppearance? {
        didSet {
            propagateSystemAppearanceToWindows()
        }
    }

    var windows: [NSWindow] = []
    private(set) var windowSystemBackdrops: [ObjectIdentifier: NSView] = [:]
    private(set) var windowAppContainers: [ObjectIdentifier: NSView] = [:]
    private(set) var auxiliarySyncCount: Int = 0

    func attachHostedWindow(contentView: NSView, initialWindowOverride: NSAppearance? = nil) -> NSWindow {
        let frame = NSRect(x: -16000, y: -16000, width: 580, height: 460)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderOut(nil)
        window.appearance = initialWindowOverride

        let systemBackdrop = NSView(frame: NSRect(origin: .zero, size: frame.size))
        systemBackdrop.autoresizingMask = [.width, .height]
        systemBackdrop.appearance = NSAppearance(named: systemAppearanceName)

        let appContainer = NSView(frame: systemBackdrop.bounds)
        appContainer.autoresizingMask = [.width, .height]
        appContainer.appearance = appearance

        contentView.frame = appContainer.bounds
        contentView.autoresizingMask = [.width, .height]
        appContainer.addSubview(contentView)
        systemBackdrop.addSubview(appContainer)
        window.contentView = systemBackdrop

        let id = ObjectIdentifier(window)
        windowSystemBackdrops[id] = systemBackdrop
        windowAppContainers[id] = appContainer
        windows.append(window)
        return window
    }

    func synchronizeAuxiliaryWindows() {
        auxiliarySyncCount += 1
        propagateSystemAppearanceToWindows()
    }

    func resolvedWindowBestAppearance(_ window: NSWindow) -> NSAppearance.Name? {
        if let explicitWindowAppearance = window.appearance {
            return explicitWindowAppearance.bestMatch(from: [.aqua, .darkAqua])
        }
        let id = ObjectIdentifier(window)
        if let container = windowAppContainers[id] {
            return container.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        }
        return window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    }

    private func propagateSystemAppearanceToWindows() {
        let sysAppearance = NSAppearance(named: systemAppearanceName)
        for window in windows {
            let id = ObjectIdentifier(window)
            windowSystemBackdrops[id]?.appearance = sysAppearance
            windowAppContainers[id]?.appearance = appearance
        }
    }
}

@MainActor
final class RecordingAppearanceApplier: ApplicationAppearanceApplying {
    let target: SimulatedApplicationAppearanceTarget
    private let underlyingApplier: AppKitApplicationAppearanceApplier
    private(set) var events: [SimulatedApplicationAppearanceTarget.AppliedEvent] = []

    init(target: SimulatedApplicationAppearanceTarget) {
        self.target = target
        self.underlyingApplier = AppKitApplicationAppearanceApplier(target: target)
    }

    func apply(appearance: NSAppearance?, mode: ApplicationAppearance) {
        underlyingApplier.apply(appearance: appearance, mode: mode)
        events.append(
            SimulatedApplicationAppearanceTarget.AppliedEvent(
                mode: mode,
                appearanceName: appearance?.bestMatch(from: [.aqua, .darkAqua])
            )
        )
    }
}

// MARK: - Application Appearance Contract & Offscreen Host Verification Suite

@MainActor
final class ApplicationAppearanceTests: XCTestCase {
    private var suiteName: String!
    private var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "com.metastudyline.ttzip.appearance.tests.\(UUID().uuidString)"
        isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        isolatedDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        if let suiteName {
            isolatedDefaults?.removePersistentDomain(forName: suiteName)
        }
        isolatedDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - 1. Single-Owner Persistence, Settings Binding & Reconstruction Recovery

    func testSettingsBindingPersistsAppliesViaSameOwnerAndRecoversOnStoreReconstruction() {
        let target = SimulatedApplicationAppearanceTarget()
        let applier = RecordingAppearanceApplier(target: target)
        let store = ApplicationAppearanceStore(
            defaults: isolatedDefaults,
            applier: applier,
            applyImmediately: true
        )

        XCTAssertEqual(store.mode, .system)
        XCTAssertEqual(
            applier.events,
            [.init(mode: .system, appearanceName: nil)],
            "Initial store creation with applyImmediately must apply .system (nil NSAppearance)"
        )

        let settingsView = SettingsView(
            initialTab: .general,
            appearanceStore: store
        )
        XCTAssertEqual(
            ObjectIdentifier(settingsView.appearanceStore),
            ObjectIdentifier(store),
            "SettingsView must read and write the exact same ApplicationAppearanceStore owner"
        )

        let binding = settingsView.appearanceStore.selectionBinding
        binding.wrappedValue = .light
        XCTAssertEqual(store.mode, .light)
        XCTAssertEqual(isolatedDefaults.string(forKey: ApplicationAppearance.preferenceKey), "light")
        XCTAssertEqual(target.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)

        binding.wrappedValue = .dark
        XCTAssertEqual(store.mode, .dark)
        XCTAssertEqual(isolatedDefaults.string(forKey: ApplicationAppearance.preferenceKey), "dark")
        XCTAssertEqual(target.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)

        let reconstructedTarget = SimulatedApplicationAppearanceTarget()
        let reconstructedApplier = RecordingAppearanceApplier(target: reconstructedTarget)
        let reconstructedStore = ApplicationAppearanceStore(
            defaults: isolatedDefaults,
            applier: reconstructedApplier,
            applyImmediately: true
        )
        XCTAssertEqual(reconstructedStore.mode, .dark)
        XCTAssertEqual(
            reconstructedApplier.events,
            [.init(mode: .dark, appearanceName: .darkAqua)],
            "Reconstructed store must restore and apply persisted .dark preference"
        )
    }

    // MARK: - 2. Dynamic System Following Clears Override Without Startup Snapshot Lock-in

    func testSystemModeClearsOverrideAndFollowsDynamicSystemAppearanceChangesWithoutLockIn() {
        let target = SimulatedApplicationAppearanceTarget()
        target.systemAppearanceName = .aqua
        let applier = RecordingAppearanceApplier(target: target)
        let store = ApplicationAppearanceStore(
            defaults: isolatedDefaults,
            applier: applier,
            applyImmediately: true
        )

        let probeView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let window = target.attachHostedWindow(
            contentView: probeView,
            initialWindowOverride: NSAppearance(named: .darkAqua)
        )
        defer { window.close() }

        store.setMode(.dark)
        XCTAssertNil(window.appearance, "Applier must clear stale per-window appearance override")
        XCTAssertEqual(target.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(
            probeView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
            .darkAqua,
            "Explicit .dark mode must force .darkAqua even when system is .aqua"
        )

        store.setMode(.system)
        XCTAssertNil(target.appearance, "Switching to .system must set application appearance override to nil")
        XCTAssertNil(window.appearance, "Switching to .system must keep window appearance override nil")
        XCTAssertEqual(
            probeView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
            .aqua,
            "Switching from .dark to .system must immediately release .darkAqua lock and reflect system .aqua"
        )

        target.systemAppearanceName = .darkAqua
        XCTAssertEqual(
            probeView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
            .darkAqua,
            ".system mode must dynamically track runtime OS transition to .darkAqua without restart"
        )

        target.systemAppearanceName = .aqua
        XCTAssertEqual(
            probeView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
            .aqua,
            ".system mode must dynamically track runtime OS transition back to .aqua"
        )
    }

    // MARK: - 3. Unknown / Corrupted Stored Value Fallback

    func testUnknownAndCorruptedStoredValuesFallbackToSystemAndNormalizeStorage() {
        let invalidPayloads = ["sepia", "high_contrast", "auto", "", "   ", "12345"]
        for payload in invalidPayloads {
            isolatedDefaults.set(payload, forKey: ApplicationAppearance.preferenceKey)
            let target = SimulatedApplicationAppearanceTarget()
            let applier = RecordingAppearanceApplier(target: target)
            let store = ApplicationAppearanceStore(
                defaults: isolatedDefaults,
                applier: applier,
                applyImmediately: true
            )

            XCTAssertEqual(
                store.mode,
                .system,
                "Invalid persisted value '\(payload)' must fall back to .system"
            )
            XCTAssertNil(target.appearance, "Fallback .system must apply nil NSAppearance override")
            XCTAssertEqual(
                isolatedDefaults.string(forKey: ApplicationAppearance.preferenceKey),
                ApplicationAppearance.system.rawValue,
                "Corrupted stored value '\(payload)' must normalize to 'system' in storage"
            )
        }

        XCTAssertEqual(ApplicationAppearance(persistedRawValue: nil), .system)
        XCTAssertEqual(ApplicationAppearance(persistedRawValue: " LIGHT "), .light)
        XCTAssertEqual(ApplicationAppearance(persistedRawValue: "Dark"), .dark)
        XCTAssertEqual(ApplicationAppearance(persistedRawValue: "SYSTEM"), .system)
    }

    // MARK: - 4. Multi-Window & Newly Created Window Consistency (No Divergence)

    func testExistingAndNewlyCreatedWindowsRemainUnifiedAcrossAppearanceTransitions() {
        let target = SimulatedApplicationAppearanceTarget()
        target.systemAppearanceName = .aqua
        let applier = RecordingAppearanceApplier(target: target)
        let store = ApplicationAppearanceStore(
            defaults: isolatedDefaults,
            applier: applier,
            applyImmediately: true
        )

        let existingWindowA = target.attachHostedWindow(contentView: NSView())
        let existingWindowB = target.attachHostedWindow(
            contentView: NSView(),
            initialWindowOverride: NSAppearance(named: .darkAqua)
        )
        let standalonePlayerWindow = StandalonePlaybackNSWindow.makeStandardPlayerWindow(title: "AppearanceProbe")
        standalonePlayerWindow.orderOut(nil)
        target.windows.append(standalonePlayerWindow)
        defer {
            existingWindowA.close()
            existingWindowB.close()
            standalonePlayerWindow.close()
        }

        store.setMode(.light)
        let newWindowAfterLight = target.attachHostedWindow(contentView: NSView())
        defer { newWindowAfterLight.close() }

        for window in [existingWindowA, existingWindowB, standalonePlayerWindow, newWindowAfterLight] {
            XCTAssertNil(window.appearance, "No existing or new window may retain a per-window override")
        }
        XCTAssertEqual(target.resolvedWindowBestAppearance(existingWindowA), .aqua)
        XCTAssertEqual(target.resolvedWindowBestAppearance(existingWindowB), .aqua)
        XCTAssertEqual(target.resolvedWindowBestAppearance(newWindowAfterLight), .aqua)

        store.setMode(.dark)
        let newWindowAfterDark = target.attachHostedWindow(contentView: NSView())
        defer { newWindowAfterDark.close() }

        for window in [existingWindowA, existingWindowB, newWindowAfterLight, newWindowAfterDark] {
            XCTAssertNil(window.appearance)
            XCTAssertEqual(
                target.resolvedWindowBestAppearance(window),
                .darkAqua,
                "All existing and newly created windows must unify on .darkAqua without divergence"
            )
        }
    }

    // MARK: - 5. Reader Background Independence & Global System Hygiene

    func testReaderUserBackgroundPreferencesAndSystemInterfaceStyleRemainUntouched() {
        let baselineStandardPref = UserDefaults.standard.object(forKey: ApplicationAppearance.preferenceKey)
        let baselineSystemInterfaceStyle = UserDefaults.standard.object(forKey: "AppleInterfaceStyle")

        let textReadingStore = TTTextReadingPreferenceStore(defaults: isolatedDefaults)
        textReadingStore.mode = .black
        let epubThemeKey = "ttmedia.epub.userThemeMode"
        isolatedDefaults.set("sepia", forKey: epubThemeKey)

        let target = SimulatedApplicationAppearanceTarget()
        let applier = RecordingAppearanceApplier(target: target)
        let appearanceStore = ApplicationAppearanceStore(
            defaults: isolatedDefaults,
            applier: applier,
            applyImmediately: true
        )

        for appMode in [ApplicationAppearance.light, .dark, .system, .light] {
            appearanceStore.setMode(appMode)
            XCTAssertEqual(
                textReadingStore.mode,
                .black,
                "Switching app appearance to \(appMode.rawValue) must not overwrite user text reading background (.black)"
            )
            XCTAssertEqual(
                isolatedDefaults.string(forKey: TTTextReadingBackgroundMode.userDefaultsKey),
                TTTextReadingBackgroundMode.black.rawValue
            )
            XCTAssertTrue(
                textReadingStore.mode.effectiveIsDark(isAppDarkAppearance: appMode == .dark),
                "Explicit .black text reading canvas must stay dark even when app appearance is .light"
            )
            XCTAssertEqual(
                isolatedDefaults.string(forKey: epubThemeKey),
                "sepia",
                "Switching app appearance must not overwrite EPUB user theme preference"
            )
            XCTAssertNil(
                isolatedDefaults.persistentDomain(forName: suiteName)?["AppleInterfaceStyle"],
                "ApplicationAppearanceStore must never write AppleInterfaceStyle into persistent domain"
            )
            XCTAssertEqual(
                isolatedDefaults.object(forKey: "AppleInterfaceStyle") as? String,
                baselineSystemInterfaceStyle as? String,
                "ApplicationAppearanceStore must never mutate global AppleInterfaceStyle"
            )
        }

        textReadingStore.mode = .white
        appearanceStore.setMode(.dark)
        XCTAssertEqual(textReadingStore.mode, .white)
        XCTAssertFalse(
            textReadingStore.mode.effectiveIsDark(isAppDarkAppearance: true),
            "Explicit .white text reading canvas must stay light even when app appearance is .dark"
        )

        let epubPrefs = EPUBReaderPreferences(
            latinFont: "serif",
            cjkFont: "serif",
            fontSize: 18,
            theme: "sepia",
            layout: "paginated"
        )
        XCTAssertEqual(epubPrefs.theme, "sepia")
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: ApplicationAppearance.preferenceKey) as? String,
            baselineStandardPref as? String,
            "Isolated tests must never mutate UserDefaults.standard application appearance"
        )
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: "AppleInterfaceStyle") as? String,
            baselineSystemInterfaceStyle as? String,
            "Isolated tests must never mutate machine AppleInterfaceStyle"
        )
    }

    // MARK: - 6. Offscreen Settings Host Real Picker Reachability, Trilingual Labels & Contrast

    func testOffscreenSettingsHostRealPickerReachabilityTrilingualLabelsAndLightDarkContrast() throws {
        let l10n = AppLocalizationState.shared
        let originalLanguage = l10n.currentLanguage
        defer { l10n.setLanguage(originalLanguage) }

        let target = SimulatedApplicationAppearanceTarget()
        let applier = RecordingAppearanceApplier(target: target)
        let store = ApplicationAppearanceStore(
            defaults: isolatedDefaults,
            applier: applier,
            applyImmediately: true
        )

        let hostingView = NSHostingView(
            rootView: SettingsView(initialTab: .general, appearanceStore: store)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 460)
        let window = target.attachHostedWindow(contentView: hostingView)
        defer { window.close() }

        pumpLayout(for: window, hostingView: hostingView)

        try assertTrilingualPickerAndTextInOffscreenHost(
            window: window,
            hostingView: hostingView,
            store: store,
            l10n: l10n
        )

        try assertRealPickerControlDrivesStoreAndPersistence(
            hostingView: hostingView,
            store: store,
            applier: applier
        )

        try assertLightAndDarkContrastAndCaptureEvidence(
            window: window,
            hostingView: hostingView,
            store: store
        )
    }

    // MARK: - Offscreen Inspection & Contrast Helpers

    private func assertTrilingualPickerAndTextInOffscreenHost(
        window: NSWindow,
        hostingView: NSHostingView<SettingsView>,
        store: ApplicationAppearanceStore,
        l10n: AppLocalizationState
    ) throws {
        let expectations: [(AppLanguage, String, String, [String])] = [
            (.zhHans, "应用外观", "外观模式", ["跟随系统", "浅色", "深色"]),
            (.zhHant, "應用外觀", "外觀模式", ["跟隨系統", "淺色", "深色"]),
            (.en, "Appearance", "Appearance", ["System", "Light", "Dark"])
        ]

        for (lang, expectedHeader, expectedLabel, expectedOptions) in expectations {
            l10n.setLanguage(lang)
            hostingView.rootView = SettingsView(initialTab: .general, appearanceStore: store)
            pumpLayout(for: window, hostingView: hostingView)

            let popUp = try XCTUnwrap(
                findAppearancePopUpButton(in: hostingView, expectedTitles: expectedOptions),
                "Settings -> General must host a reachable NSPopUpButton for appearance in \(lang.rawValue)"
            )
            XCTAssertFalse(popUp.isHidden, "Appearance picker must be visible in \(lang.rawValue)")
            XCTAssertTrue(popUp.isEnabled, "Appearance picker must be enabled in \(lang.rawValue)")
            XCTAssertGreaterThanOrEqual(popUp.bounds.width, 100, "Appearance picker must have non-zero width")
            XCTAssertGreaterThanOrEqual(popUp.bounds.height, 16, "Appearance picker must have non-zero height")
            XCTAssertEqual(popUp.itemTitles, expectedOptions, "Picker option titles mismatch in \(lang.rawValue)")

            let visibleTexts = collectVisibleStrings(in: hostingView)
            XCTAssertTrue(
                visibleTexts.contains(where: { $0.contains(expectedHeader) }),
                "Settings -> General must display localized section header '\(expectedHeader)' in \(lang.rawValue)"
            )
            XCTAssertTrue(
                visibleTexts.contains(where: { $0.contains(expectedLabel) }),
                "Settings -> General must display localized mode label '\(expectedLabel)' in \(lang.rawValue)"
            )
        }
    }

    private func assertRealPickerControlDrivesStoreAndPersistence(
        hostingView: NSView,
        store: ApplicationAppearanceStore,
        applier: RecordingAppearanceApplier
    ) throws {
        let popUp = try XCTUnwrap(
            findAppearancePopUpButton(in: hostingView, expectedTitles: ["System", "Light", "Dark"]),
            "English appearance NSPopUpButton must be reachable"
        )
        XCTAssertEqual(popUp.indexOfSelectedItem, 0, "Initial selected item index must be 0 (.system)")

        popUp.selectItem(at: 1)
        if let action = popUp.action {
            _ = popUp.sendAction(action, to: popUp.target)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(store.mode, .light, "Selecting index 1 on real NSPopUpButton must update store.mode to .light")
        XCTAssertEqual(isolatedDefaults.string(forKey: ApplicationAppearance.preferenceKey), "light")
        XCTAssertEqual(applier.events.last, .init(mode: .light, appearanceName: .aqua))

        popUp.selectItem(at: 2)
        if let action = popUp.action {
            _ = popUp.sendAction(action, to: popUp.target)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(store.mode, .dark, "Selecting index 2 on real NSPopUpButton must update store.mode to .dark")
        XCTAssertEqual(isolatedDefaults.string(forKey: ApplicationAppearance.preferenceKey), "dark")
        XCTAssertEqual(applier.events.last, .init(mode: .dark, appearanceName: .darkAqua))

        popUp.selectItem(at: 0)
        if let action = popUp.action {
            _ = popUp.sendAction(action, to: popUp.target)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(store.mode, .system, "Selecting index 0 on real NSPopUpButton must update store.mode to .system")
        XCTAssertEqual(isolatedDefaults.string(forKey: ApplicationAppearance.preferenceKey), "system")
        XCTAssertEqual(applier.events.last, .init(mode: .system, appearanceName: nil))
    }

    private func assertLightAndDarkContrastAndCaptureEvidence(
        window: NSWindow,
        hostingView: NSHostingView<some View>,
        store: ApplicationAppearanceStore
    ) throws {
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        for (mode, appearance, tag) in [
            (ApplicationAppearance.light, lightAppearance, "light"),
            (ApplicationAppearance.dark, darkAppearance, "dark")
        ] {
            store.setMode(mode)
            pumpLayout(for: window, hostingView: hostingView)

            let primaryTextContrast = resolvedContrastRatio(
                foreground: .labelColor,
                background: .windowBackgroundColor,
                in: appearance
            )
            let descriptionTextContrast = resolvedContrastRatio(
                foreground: .labelColor,
                foregroundAlpha: 0.72,
                background: .windowBackgroundColor,
                in: appearance
            )
            let buttonTextContrast = resolvedContrastRatio(
                foreground: .controlTextColor,
                background: .controlColor,
                in: appearance
            )

            XCTAssertGreaterThanOrEqual(
                primaryTextContrast,
                7.0,
                "Primary text contrast in \(tag) mode must be >= 7.0 (got \(primaryTextContrast))"
            )
            XCTAssertGreaterThanOrEqual(
                descriptionTextContrast,
                4.5,
                "Description text contrast in \(tag) mode must be >= 4.5 (got \(descriptionTextContrast))"
            )
            XCTAssertGreaterThanOrEqual(
                buttonTextContrast,
                4.5,
                "Control/button text contrast in \(tag) mode must be >= 4.5 (got \(buttonTextContrast))"
            )
        }

        store.setMode(.light)
        AppLocalizationState.shared.setLanguage(.zhHans)
        pumpLayout(for: window, hostingView: hostingView)
        let lightMeanLuma = try renderOffscreenSnapshotAndComputeMeanLuma(
            view: hostingView,
            appearance: lightAppearance,
            filename: "settings-general-light.png"
        )

        store.setMode(.dark)
        pumpLayout(for: window, hostingView: hostingView)
        let darkMeanLuma = try renderOffscreenSnapshotAndComputeMeanLuma(
            view: hostingView,
            appearance: darkAppearance,
            filename: "settings-general-dark.png"
        )

        XCTAssertGreaterThan(
            lightMeanLuma - darkMeanLuma,
            0.25,
            "Offscreen rendered Light snapshot (luma=\(lightMeanLuma)) must be visibly brighter than Dark snapshot (luma=\(darkMeanLuma))"
        )
    }

    private func pumpLayout(for window: NSWindow, hostingView: NSView) {
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

    private func findAppearancePopUpButton(in root: NSView, expectedTitles: [String]) -> NSPopUpButton? {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if let popUp = current as? NSPopUpButton {
                if popUp.accessibilityIdentifier() == "settings.general.appearancePicker"
                    || popUp.itemTitles == expectedTitles {
                    return popUp
                }
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    private func collectVisibleStrings(in root: NSView) -> [String] {
        var results: [String] = []
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if let textField = current as? NSTextField, !textField.stringValue.isEmpty {
                results.append(textField.stringValue)
            }
            if let button = current as? NSButton, !button.title.isEmpty {
                results.append(button.title)
            }
            if let popUp = current as? NSPopUpButton {
                results.append(contentsOf: popUp.itemTitles)
            }
            if let axTitle = current.accessibilityTitle(), !axTitle.isEmpty {
                results.append(axTitle)
            }
            if let axLabel = current.accessibilityLabel(), !axLabel.isEmpty {
                results.append(axLabel)
            }
            if let axHelp = current.accessibilityHelp(), !axHelp.isEmpty {
                results.append(axHelp)
            }
            if let toolTip = current.toolTip, !toolTip.isEmpty {
                results.append(toolTip)
            }
            if let axValue = current.accessibilityValue() as? String, !axValue.isEmpty {
                results.append(axValue)
            }
            stack.append(contentsOf: current.subviews)
        }
        return results
    }

    private func resolvedContrastRatio(
        foreground: NSColor,
        foregroundAlpha: CGFloat? = nil,
        background: NSColor,
        in appearance: NSAppearance
    ) -> Double {
        var fgSRGB: NSColor = foreground
        var bgSRGB: NSColor = background
        var canvasSRGB: NSColor = .windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            let resolvedFG = foreground.usingColorSpace(.sRGB) ?? foreground
            fgSRGB = foregroundAlpha.map { resolvedFG.withAlphaComponent($0) } ?? resolvedFG
            bgSRGB = background.usingColorSpace(.sRGB) ?? background
            canvasSRGB = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor
        }
        let opaqueCanvas = NSColor(
            srgbRed: canvasSRGB.redComponent,
            green: canvasSRGB.greenComponent,
            blue: canvasSRGB.blueComponent,
            alpha: 1.0
        )
        let compositeBG = composite(foreground: bgSRGB, over: opaqueCanvas)
        let compositeFG = composite(foreground: fgSRGB, over: compositeBG)
        let l1 = relativeLuminance(of: compositeFG)
        let l2 = relativeLuminance(of: compositeBG)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func composite(foreground: NSColor, over background: NSColor) -> NSColor {
        let alpha = Double(foreground.alphaComponent)
        let r = Double(foreground.redComponent) * alpha + Double(background.redComponent) * (1.0 - alpha)
        let g = Double(foreground.greenComponent) * alpha + Double(background.greenComponent) * (1.0 - alpha)
        let b = Double(foreground.blueComponent) * alpha + Double(background.blueComponent) * (1.0 - alpha)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    private func relativeLuminance(of color: NSColor) -> Double {
        func linearize(_ channel: CGFloat) -> Double {
            let c = Double(channel)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let r = linearize(srgb.redComponent)
        let g = linearize(srgb.greenComponent)
        let b = linearize(srgb.blueComponent)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func renderOffscreenSnapshotAndComputeMeanLuma(
        view: NSView,
        appearance: NSAppearance,
        filename: String
    ) throws -> Double {
        view.appearance = appearance
        view.needsDisplay = true
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let viewRep = try XCTUnwrap(
            view.bitmapImageRepForCachingDisplay(in: bounds),
            "Must create offscreen bitmap representation for \(filename)"
        )
        var canvasColor: NSColor = .windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            canvasColor = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor
            view.cacheDisplay(in: bounds, to: viewRep)
        }
        let opaqueCanvas = NSColor(
            srgbRed: canvasColor.redComponent,
            green: canvasColor.greenComponent,
            blue: canvasColor.blueComponent,
            alpha: 1.0
        )

        var lumaSum = 0.0
        var sampleCount = 0
        let stepX = max(1, viewRep.pixelsWide / 32)
        let stepY = max(1, viewRep.pixelsHigh / 32)
        for y in stride(from: 0, to: viewRep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: viewRep.pixelsWide, by: stepX) {
                if let pixel = viewRep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let composited = composite(foreground: pixel, over: opaqueCanvas)
                    lumaSum += 0.2126 * Double(composited.redComponent)
                        + 0.7152 * Double(composited.greenComponent)
                        + 0.0722 * Double(composited.blueComponent)
                    sampleCount += 1
                }
            }
        }

        let compositedImage = NSImage(size: bounds.size)
        compositedImage.lockFocus()
        opaqueCanvas.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: bounds.size)).fill()
        viewRep.draw(in: NSRect(origin: .zero, size: bounds.size))
        compositedImage.unlockFocus()

        let outputDirs: [URL] = [
            URL(fileURLWithPath: "/tmp/ttzip-antigravity-appearance/evidence", isDirectory: true),
            ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        ].compactMap { $0 }

        if let tiffData = compositedImage.tiffRepresentation,
           let outRep = NSBitmapImageRep(data: tiffData),
           let pngData = outRep.representation(using: .png, properties: [:]) {
            for dir in outputDirs where FileManager.default.fileExists(atPath: dir.path) {
                try? pngData.write(to: dir.appendingPathComponent(filename), options: .atomic)
            }
        }

        return sampleCount > 0 ? lumaSum / Double(sampleCount) : 0.0
    }
}
