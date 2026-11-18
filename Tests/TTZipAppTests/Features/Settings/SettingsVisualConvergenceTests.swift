// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Security
import SwiftUI
import XCTest
@testable import TTZipApp
@testable import TTZipCore
@testable import TTZipPreviewKit
@testable import TTZipUI

@MainActor
final class SettingsVisualConvergenceTests: XCTestCase {
    private static let autoUnlockKey = "TTZipAutoUnlockArchivesWithVault"

    private var suiteName: String!
    private var isolatedDefaults: UserDefaults!
    private var originalLanguage: AppLanguage!
    private var originalByteStandard: ByteSizeStandard!
    private var originalAutoUnlockObject: Any?
    private var originalManualUpdateHandler: (@MainActor () -> Void)?

    override func setUp() async throws {
        try await super.setUp()
        let enhancedUISelector = NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:")
        if NSApplication.shared.responds(to: enhancedUISelector) {
            _ = NSApplication.shared.perform(enhancedUISelector, with: NSNumber(value: true))
        }
        suiteName = "com.metastudyline.ttzip.tests.settings.visual.\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: suiteName)
        isolatedDefaults.removePersistentDomain(forName: suiteName)
        originalLanguage = AppLocalizationState.shared.currentLanguage
        originalByteStandard = AppLocalizationState.shared.byteUnitStandard
        originalAutoUnlockObject = UserDefaults.standard.object(forKey: Self.autoUnlockKey)
        originalManualUpdateHandler = DiagnosticsSupportService.manualUpdateHandler
    }

    override func tearDown() async throws {
        DiagnosticsSupportService.registerManualUpdateHandler(originalManualUpdateHandler)
        if let originalAutoUnlockObject {
            UserDefaults.standard.set(originalAutoUnlockObject, forKey: Self.autoUnlockKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.autoUnlockKey)
        }
        if let originalByteStandard {
            AppLocalizationState.shared.byteUnitStandard = originalByteStandard
        }
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

    func testNativeSettingsHostAndSheetHostEliminateDuplicateSettingsHeader() throws {
        XCTAssertFalse(SettingsView.rendersInternalWorkspaceHeader)
        XCTAssertFalse(SettingsView.rendersFullPageEnclosedCard)

        let l10n = AppLocalizationState.shared
        for lang in [AppLanguage.zhHans, .zhHant, .en] {
            l10n.setLanguage(lang)
            let expectedTitle = l10n.t(L10n.Sidebar.settings)

            let nativeHosting = NSHostingView(rootView: SettingsView(initialTab: .general, defaults: isolatedDefaults))
            nativeHosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
            let nativeWindow = makeOffscreenWindow(contentView: nativeHosting, title: expectedTitle)
            defer { nativeWindow.close() }
            pumpLayout(window: nativeWindow, hostingView: nativeHosting)

            XCTAssertEqual(nativeWindow.title, expectedTitle)
            XCTAssertEqual(findPopUpButtons(in: nativeHosting).count, 2)

            var didDismissSheet = false
            let sheetView = SecondaryToolSheetContainer(tab: .settings, onDismiss: { didDismissSheet = true })
            XCTAssertEqual(sheetView.headerTitle, expectedTitle)
            XCTAssertEqual(sheetView.idealSheetSize, CGSize(width: 720, height: 540))

            let sheetHosting = NSHostingView(rootView: sheetView)
            sheetHosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
            let sheetWindow = makeOffscreenWindow(contentView: sheetHosting, title: "")
            defer { sheetWindow.close() }
            pumpLayout(window: sheetWindow, hostingView: sheetHosting)

            XCTAssertEqual(findPopUpButtons(in: sheetHosting).count, 2)

            let closeButton = try XCTUnwrap(findButton(in: sheetHosting, identifier: "secondaryToolSheet.closeButton"))
            XCTAssertFalse(closeButton.isHidden)
            XCTAssertTrue(closeButton.isEnabled)
            XCTAssertEqual(closeButton.keyEquivalent, "\u{1b}")
            closeButton.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertTrue(didDismissSheet)
        }
    }

    func testAdaptiveNavigationBreakpointAndKeyboardTabCycling() throws {
        XCTAssertTrue(SettingsView.usesSidebarNavigation(forWidth: 720))
        XCTAssertTrue(SettingsView.usesSidebarNavigation(forWidth: 540))
        XCTAssertFalse(SettingsView.usesSidebarNavigation(forWidth: 500))
        XCTAssertFalse(SettingsView.usesSidebarNavigation(forWidth: 460))
        XCTAssertTrue(SettingsView.usesSidebarNavigation(forWidth: 0))

        let allTabs = SettingsView.SettingsTab.allCases
        XCTAssertEqual(allTabs, [.general, .localization, .presets, .vault, .localModels, .license])
        XCTAssertEqual(SettingsView.adjacentTab(from: .general, offset: -1), .general)
        XCTAssertEqual(SettingsView.adjacentTab(from: .general, offset: 1), .localization)
        XCTAssertEqual(SettingsView.adjacentTab(from: .license, offset: 1), .license)
        XCTAssertEqual(SettingsView.adjacentTab(from: .license, offset: -1), .localModels)

        let l10n = AppLocalizationState.shared
        for lang in AppLanguage.allCases {
            l10n.setLanguage(lang)
            for tab in allTabs {
                XCTAssertFalse(tab.localizedTitle(using: l10n).isEmpty)
            }
        }
        l10n.setLanguage(.zhHans)

        try assertWideNavigationCycling(l10n: l10n)
        try assertNarrowCompactNavigation()
    }

    private func assertWideNavigationCycling(l10n: AppLocalizationState) throws {
        let wideHosting = NSHostingView(rootView: makeIsolatedSettingsView(initialTab: .general))
        wideHosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        let wideWindow = makeOffscreenWindow(contentView: wideHosting, title: "SettingsWide")
        defer { wideWindow.close() }
        pumpLayout(window: wideWindow, hostingView: wideHosting)

        let generalBtn = try XCTUnwrap(findButton(in: wideHosting, identifier: "settings.nav.tab.general"))
        let localizationBtn = try XCTUnwrap(findButton(in: wideHosting, identifier: "settings.nav.tab.localization"))
        let licenseBtn = try XCTUnwrap(findButton(in: wideHosting, identifier: "settings.nav.tab.license"))
        XCTAssertTrue(generalBtn.isAccessibilitySelected())
        XCTAssertEqual(findPopUpButtons(in: wideHosting).count, 2)
        XCTAssertEqual(findSwitches(in: wideHosting).count, 1)
        XCTAssertNil(findSwitch(in: wideHosting, identifier: "settings.general.smartStoreToggle"))

        XCTAssertTrue(wideWindow.makeFirstResponder(generalBtn))
        try sendKeyCode(125, to: generalBtn, in: wideWindow)
        pumpLayout(window: wideWindow, hostingView: wideHosting)
        XCTAssertTrue(localizationBtn.isAccessibilitySelected())
        XCTAssertEqual(findPopUpButtons(in: wideHosting).count, 2)

        licenseBtn.performClick(nil)
        pumpLayout(window: wideWindow, hostingView: wideHosting)
        XCTAssertTrue(licenseBtn.isAccessibilitySelected())
        XCTAssertEqual(
            findAccessibilityGroupView(in: wideHosting, identifier: "settings.group.checkmark.seal.fill")?.accessibilityLabel(),
            l10n.t(L10n.Settings.licenseStatus)
        )
        XCTAssertNotNil(findAccessibilityGroupView(in: wideHosting, identifier: "settings.group.cpu.fill"))
        XCTAssertNotNil(findAccessibilityGroupView(in: wideHosting, identifier: "settings.group.stethoscope"))
    }

    private func assertNarrowCompactNavigation() throws {
        let narrowHosting = NSHostingView(rootView: makeIsolatedSettingsView(initialTab: .general))
        narrowHosting.frame = NSRect(x: 0, y: 0, width: 480, height: 420)
        let narrowWindow = makeOffscreenWindow(contentView: narrowHosting, title: "SettingsNarrow")
        defer { narrowWindow.close() }
        pumpLayout(window: narrowWindow, hostingView: narrowHosting)

        let narrowPopUps = findPopUpButtons(in: narrowHosting)
        XCTAssertEqual(narrowPopUps.count, 2)
        for popUp in narrowPopUps {
            XCTAssertFalse(popUp.isHidden)
            XCTAssertGreaterThanOrEqual(popUp.bounds.width, 100)
        }
        let generalBtn = try XCTUnwrap(findButton(in: narrowHosting, identifier: "settings.nav.tab.general"))
        let locBtn = try XCTUnwrap(findButton(in: narrowHosting, identifier: "settings.nav.tab.localization"))
        XCTAssertTrue(narrowWindow.makeFirstResponder(generalBtn))
        try sendKeyCode(124, to: generalBtn, in: narrowWindow)
        pumpLayout(window: narrowWindow, hostingView: narrowHosting)
        XCTAssertTrue(locBtn.isAccessibilitySelected())
    }

    func testAllSixCategoriesMountCleanlyAndVisualStyleAdaptsToAccessibilitySettings() throws {
        let l10n = AppLocalizationState.shared
        l10n.setLanguage(.zhHans)

        try verifyGeneralTabControls()
        try verifyLocalizationTabControls(l10n: l10n)
        try verifyPresetsTabControls()
        try verifyVaultAndLocalModelsTabControls(l10n: l10n)
        try verifyLicenseAndSystemTabControls()
        verifyAccessibilityVisualStyleTokens()
    }

    private func verifyGeneralTabControls() throws {
        let appearanceStore = ApplicationAppearanceStore(
            defaults: isolatedDefaults,
            applier: AppKitApplicationAppearanceApplier(targetProvider: { nil }),
            applyImmediately: false
        )
        let textStore = TTTextReadingPreferenceStore(defaults: isolatedDefaults)
        let hosting = NSHostingView(
            rootView: makeIsolatedSettingsView(
                initialTab: .general,
                appearanceStore: appearanceStore,
                textReadingStore: textStore
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        let window = makeOffscreenWindow(contentView: hosting, title: "GeneralTab")
        defer { window.close() }
        pumpLayout(window: window, hostingView: hosting)

        let appearancePopUp = try XCTUnwrap(findPopUpButton(in: hosting, identifier: "settings.general.appearancePicker"))
        appearancePopUp.selectItem(at: 2)
        _ = appearancePopUp.sendAction(appearancePopUp.action, to: appearancePopUp.target)
        XCTAssertEqual(appearanceStore.mode, .dark)

        let conflictPopUp = try XCTUnwrap(findPopUpButton(in: hosting, identifier: "settings.general.conflictPicker"))
        XCTAssertEqual(conflictPopUp.numberOfItems, 4)
        conflictPopUp.selectItem(at: 2)
        _ = conflictPopUp.sendAction(conflictPopUp.action, to: conflictPopUp.target)
        XCTAssertEqual(isolatedDefaults.string(forKey: "ttzip_collision_default"), "replace")

        let goldSwatch = try XCTUnwrap(findButton(in: hosting, identifier: "settings.general.accent.gold"))
        goldSwatch.performClick(nil)
        XCTAssertEqual(AccentMineralTheme.load(from: isolatedDefaults), .gold)

        let softWrapToggle = try XCTUnwrap(findSwitch(in: hosting, identifier: "settings.general.softWrapToggle"))
        let initialWrap = textStore.isSoftWrapEnabled
        softWrapToggle.performClick(nil)
        XCTAssertEqual(textStore.isSoftWrapEnabled, !initialWrap)
        softWrapToggle.performClick(nil)
        XCTAssertEqual(textStore.isSoftWrapEnabled, initialWrap)
    }

    private func verifyLocalizationTabControls(l10n: AppLocalizationState) throws {
        let hosting = NSHostingView(rootView: makeIsolatedSettingsView(initialTab: .localization))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        let window = makeOffscreenWindow(contentView: hosting, title: "LocalizationTab")
        defer { window.close() }
        pumpLayout(window: window, hostingView: hosting)

        let languagePopUp = try XCTUnwrap(findPopUpButton(in: hosting, identifier: "settings.localization.languagePicker"))
        XCTAssertEqual(languagePopUp.numberOfItems, AppLanguage.allCases.count)

        let unitsPopUp = try XCTUnwrap(findPopUpButton(in: hosting, identifier: "settings.localization.byteUnitsPicker"))
        XCTAssertEqual(unitsPopUp.numberOfItems, 2)

        unitsPopUp.selectItem(at: 0)
        _ = unitsPopUp.sendAction(unitsPopUp.action, to: unitsPopUp.target)
        pumpLayout(window: window, hostingView: hosting)
        let siSample = l10n.formatBytes(1_000_000_000, standard: .metricSI)
        let iecSample = l10n.formatBytes(1_000_000_000, standard: .binaryIEC)
        XCTAssertNotEqual(siSample, iecSample)
        XCTAssertTrue(collectVisibleStrings(in: hosting).contains(where: { $0.contains(siSample) }))

        unitsPopUp.selectItem(at: 1)
        _ = unitsPopUp.sendAction(unitsPopUp.action, to: unitsPopUp.target)
        pumpLayout(window: window, hostingView: hosting)
        XCTAssertTrue(collectVisibleStrings(in: hosting).contains(where: { $0.contains(iecSample) }))
    }

    private func verifyPresetsTabControls() throws {
        var openedTool: WorkspaceTab?
        let hosting = NSHostingView(
            rootView: makeIsolatedSettingsView(
                initialTab: .presets,
                onOpenWorkspaceTool: { openedTool = $0 }
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        let window = makeOffscreenWindow(contentView: hosting, title: "PresetsTab")
        defer { window.close() }
        pumpLayout(window: window, hostingView: hosting)

        XCTAssertEqual(findPopUpButtons(in: hosting).count, 2)
        XCTAssertEqual(findSwitches(in: hosting).count, 2)

        let openStudioBtn = try XCTUnwrap(findButton(in: hosting, identifier: "settings.presets.openStudioButton"))
        openStudioBtn.performClick(nil)
        XCTAssertEqual(openedTool, .presets)

        let noActionHosting = NSHostingView(rootView: makeIsolatedSettingsView(initialTab: .presets, onOpenWorkspaceTool: nil))
        noActionHosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        let noActionWindow = makeOffscreenWindow(contentView: noActionHosting, title: "PresetsNoAction")
        defer { noActionWindow.close() }
        pumpLayout(window: noActionWindow, hostingView: noActionHosting)
        XCTAssertNil(findButton(in: noActionHosting, identifier: "settings.presets.openStudioButton"))
    }

    private func verifyVaultAndLocalModelsTabControls(l10n: AppLocalizationState) throws {
        let vaultHosting = NSHostingView(rootView: makeIsolatedSettingsView(initialTab: .vault))
        vaultHosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        let vaultWindow = makeOffscreenWindow(contentView: vaultHosting, title: "VaultTab")
        defer { vaultWindow.close() }
        pumpLayout(window: vaultWindow, hostingView: vaultHosting)

        XCTAssertNotNil(findAccessibilityGroupView(in: vaultHosting, identifier: "settings.group.key.fill"))
        XCTAssertNotNil(findAccessibilityGroupView(in: vaultHosting, identifier: "settings.group.lock.shield.fill"))
        XCTAssertNotNil(findSwitch(in: vaultHosting, identifier: "settings.vault.autoUnlockToggle"))

        for lang in [AppLanguage.ja, .de] {
            l10n.setLanguage(lang)
            let localHosting = NSHostingView(rootView: makeIsolatedSettingsView(initialTab: .localModels))
            localHosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
            let localWindow = makeOffscreenWindow(contentView: localHosting, title: "LocalModels-\(lang.rawValue)")
            defer { localWindow.close() }
            pumpLayout(window: localWindow, hostingView: localHosting)

            XCTAssertNotNil(findSwitch(in: localHosting, identifier: "settings.localModels.enableToggle"))
            let expectedToggleTitle = SettingsLocaleKey.localModelEnableToggleTitle.translation(for: lang)
            XCTAssertTrue(
                collectVisibleStrings(in: localHosting).contains(where: { $0.contains(expectedToggleTitle) }),
                "LocalModels toggle must be localized in \(lang.rawValue)"
            )
        }
        l10n.setLanguage(.zhHans)
    }

    private func verifyLicenseAndSystemTabControls() throws {
        var didTriggerUpdate = false
        DiagnosticsSupportService.registerManualUpdateHandler { didTriggerUpdate = true }

        let hosting = NSHostingView(rootView: makeIsolatedSettingsView(initialTab: .license))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        let window = makeOffscreenWindow(contentView: hosting, title: "LicenseTab")
        defer { window.close() }
        pumpLayout(window: window, hostingView: hosting)

        XCTAssertNotNil(findAccessibilityGroupView(in: hosting, identifier: "settings.group.checkmark.seal.fill"))
        XCTAssertNotNil(findAccessibilityGroupView(in: hosting, identifier: "settings.group.cpu.fill"))
        XCTAssertNotNil(findAccessibilityGroupView(in: hosting, identifier: "settings.group.stethoscope"))
        XCTAssertNotNil(findButton(in: hosting, identifier: "settings.system.revealLogsButton"))
        XCTAssertNotNil(findButton(in: hosting, identifier: "settings.system.exportDiagnosticsButton"))

        let checkUpdatesBtn = try XCTUnwrap(findButton(in: hosting, identifier: "settings.system.checkForUpdatesButton"))
        checkUpdatesBtn.performClick(nil)
        XCTAssertTrue(didTriggerUpdate)
    }

    private func verifyAccessibilityVisualStyleTokens() {
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

    func testCompressionDefaultsWireIntoCompressFormSession() throws {
        let hosting = NSHostingView(rootView: makeIsolatedSettingsView(initialTab: .presets))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        let window = makeOffscreenWindow(contentView: hosting, title: "PresetsWiring")
        defer { window.close() }
        pumpLayout(window: window, hostingView: hosting)

        let formatPopUp = try XCTUnwrap(findPopUpButton(in: hosting, identifier: "settings.presets.formatPicker"))
        XCTAssertEqual(formatPopUp.numberOfItems, CompressionDefaultsSnapshot.supportedDefaultFormats.count)
        let tarZstIndex = try XCTUnwrap(CompressionDefaultsSnapshot.supportedDefaultFormats.firstIndex(of: .tarZst))
        formatPopUp.selectItem(at: tarZstIndex)
        _ = formatPopUp.sendAction(formatPopUp.action, to: formatPopUp.target)

        let levelPopUp = try XCTUnwrap(findPopUpButton(in: hosting, identifier: "settings.presets.levelPicker"))
        let ultraIndex = try XCTUnwrap(DefaultCompressionTier.allCases.firstIndex(of: .ultra))
        levelPopUp.selectItem(at: ultraIndex)
        _ = levelPopUp.sendAction(levelPopUp.action, to: levelPopUp.target)

        let skipToggle = try XCTUnwrap(findSwitch(in: hosting, identifier: "settings.presets.skipMacJunkToggle"))
        if skipToggle.state == .on {
            skipToggle.performClick(nil)
        }

        let openFinderToggle = try XCTUnwrap(findSwitch(in: hosting, identifier: "settings.presets.openFinderToggle"))
        if openFinderToggle.state == .off {
            openFinderToggle.performClick(nil)
        }

        let session = CompressFormSession(defaults: isolatedDefaults)
        XCTAssertEqual(session.selectedFormat, .tarZst)
        XCTAssertEqual(
            session.compressionLevel,
            CompressionDefaultsSnapshot.clampedLevel(.level9, for: .tarZst)
        )
        XCTAssertFalse(session.skipMacJunk)
        XCTAssertTrue(session.openFinderAfterCompress)
        XCTAssertFalse(session.hasUserOverriddenRecommendation)
    }

    func testVaultSettingsShowsUnlockedEntryCountAndLocksVault() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTZipSettingsVaultTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vault = PasswordVaultManager(
            vaultURL: tempDir.appendingPathComponent("vault.enc"),
            configURL: tempDir.appendingPathComponent("config.json"),
            backupURL: tempDir.appendingPathComponent("backup.enc")
        )
        vault.customKeychainOperations = .init(
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess },
            copyMatching: { _, _ in errSecItemNotFound },
            delete: { _ in errSecSuccess }
        )
        vault.setMasterPassword("TestMasterPass123!")
        vault.addEntry(label: "Fixture", password: "ArchiveSecret")
        XCTAssertTrue(vault.isUnlocked)
        XCTAssertEqual(vault.getEntries().count, 1)

        AppLocalizationState.shared.setLanguage(.en)
        let hosting = NSHostingView(
            rootView: makeIsolatedSettingsView(
                initialTab: .vault,
                vaultManager: vault,
                onOpenWorkspaceTool: { _ in }
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        let window = makeOffscreenWindow(contentView: hosting, title: "VaultLockTest")
        defer { window.close() }
        pumpLayout(window: window, hostingView: hosting)

        let expectedCountText = AppLocalizationState.shared.format(SettingsLocaleKey.savedCredentialsCountFormat, 1)
        XCTAssertTrue(collectVisibleStrings(in: hosting).contains(where: { $0.contains(expectedCountText) }))

        let lockButton = try XCTUnwrap(findButton(in: hosting, identifier: "settings.vault.lockButton"))
        lockButton.performClick(nil)
        pumpLayout(window: window, hostingView: hosting)

        XCTAssertFalse(vault.isUnlocked)
        XCTAssertNil(findButton(in: hosting, identifier: "settings.vault.lockButton"))
        let lockedBadge = SettingsLocaleKey.vaultStateLocked.translation(for: .en)
        XCTAssertTrue(collectVisibleStrings(in: hosting).contains(where: { $0.contains(lockedBadge) }))
    }

    func testGenerateOffscreenConvergenceSnapshotsForBothHosts() throws {
        AppLocalizationState.shared.setLanguage(.zhHans)
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        let sheetHosting = NSHostingView(
            rootView: SecondaryToolSheetContainer(tab: .settings, onSwitchTool: { _ in }, onDismiss: {})
        )
        sheetHosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
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
        XCTAssertGreaterThan(sheetLightLuma - sheetDarkLuma, 0.25)

        try exportCategorySnapshots(lightAppearance: lightAppearance, darkAppearance: darkAppearance)
    }

    private func exportCategorySnapshots(
        lightAppearance: NSAppearance,
        darkAppearance: NSAppearance
    ) throws {
        DiagnosticsSupportService.registerManualUpdateHandler { }
        for tab in SettingsView.SettingsTab.allCases {
            AppLocalizationState.shared.setLanguage(tab == .localization ? .en : .zhHans)
            let hosting = NSHostingView(
                rootView: makeIsolatedSettingsView(initialTab: tab, onOpenWorkspaceTool: { _ in })
            )
            hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 540)
            let window = makeOffscreenWindow(contentView: hosting, title: "Settings-\(tab.rawValue)")
            defer { window.close() }
            pumpLayout(window: window, hostingView: hosting)

            let lightLuma = try exportOffscreenSnapshot(
                window: window,
                view: hosting,
                appearance: lightAppearance,
                filename: "after-host-native-wide-\(tab.rawValue)-light.png"
            )
            let darkLuma = try exportOffscreenSnapshot(
                window: window,
                view: hosting,
                appearance: darkAppearance,
                filename: "after-host-native-wide-\(tab.rawValue)-dark.png"
            )
            XCTAssertGreaterThan(lightLuma - darkLuma, 0.25, "Contrast check failed for \(tab.rawValue)")
        }

        AppLocalizationState.shared.setLanguage(.zhHans)
        let narrowHosting = NSHostingView(rootView: makeIsolatedSettingsView(initialTab: .general))
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

    private func makeIsolatedSettingsView(
        initialTab: SettingsView.SettingsTab,
        appearanceStore: ApplicationAppearanceStore? = nil,
        textReadingStore: TTTextReadingPreferenceStore? = nil,
        vaultManager: PasswordVaultManager = .shared,
        onOpenWorkspaceTool: ((WorkspaceTab) -> Void)? = nil
    ) -> SettingsView {
        let resolvedAppearance = appearanceStore ?? ApplicationAppearanceStore(
            defaults: isolatedDefaults,
            applier: AppKitApplicationAppearanceApplier(targetProvider: { nil }),
            applyImmediately: false
        )
        let resolvedTextStore = textReadingStore ?? TTTextReadingPreferenceStore(defaults: isolatedDefaults)
        return SettingsView(
            initialTab: initialTab,
            appearanceStore: resolvedAppearance,
            defaults: isolatedDefaults,
            compressionDefaultsStore: CompressionDefaultsStore(defaults: isolatedDefaults),
            textReadingStore: resolvedTextStore,
            vaultManager: vaultManager,
            onOpenWorkspaceTool: onOpenWorkspaceTool
        )
    }

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

    private func findPopUpButton(in root: NSView, identifier: String) -> NSPopUpButton? {
        findPopUpButtons(in: root).first { $0.accessibilityIdentifier() == identifier }
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

    private func findSwitch(in root: NSView, identifier: String) -> NSSwitch? {
        findSwitches(in: root).first { $0.accessibilityIdentifier() == identifier }
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

    private func collectVisibleStrings(in root: NSView) -> [String] {
        var results: [String] = []
        var visited = Set<ObjectIdentifier>()

        func visit(_ node: Any) {
            let obj = node as AnyObject
            guard visited.insert(ObjectIdentifier(obj)).inserted else { return }

            if let tf = obj as? NSTextField, !tf.isHidden, tf.alphaValue > 0.01, !tf.stringValue.isEmpty {
                results.append(tf.stringValue)
            }
            if let popUp = obj as? NSPopUpButton {
                results.append(contentsOf: popUp.itemTitles)
            }
            if let button = obj as? NSButton, !button.title.isEmpty {
                results.append(button.title)
            }
            for selectorName in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                if let text = safeAccessibilityString(obj, selectorName: selectorName), !text.isEmpty {
                    results.append(text)
                }
            }
            for child in obj.accessibilityChildren?() ?? [] {
                visit(child)
            }
            if let view = obj as? NSView {
                for subview in view.subviews {
                    visit(subview)
                }
            }
        }

        visit(root)
        return results
    }

    private func safeAccessibilityString(_ obj: AnyObject, selectorName: String) -> String? {
        let sel = NSSelectorFromString(selectorName)
        guard obj.responds(to: sel),
              let unmanaged = obj.perform(sel) else {
            return nil
        }
        let raw = unmanaged.takeUnretainedValue()
        if let attr = raw as? NSAttributedString {
            return attr.string
        }
        if let str = raw as? NSString {
            return str as String
        }
        return nil
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

        let meanLuma = computeMeanLuminance(of: viewRep)
        let pngData = try renderCompositePNG(rep: viewRep, canvasColor: canvasColor, size: bounds.size)
        XCTAssertGreaterThan(pngData.count, 1024, "Snapshot \(filename) must be non-empty PNG")

        if let outDir = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"] {
            let dirURL = URL(fileURLWithPath: outDir, isDirectory: true)
            try? pngData.write(to: dirURL.appendingPathComponent(filename), options: .atomic)
        }
        if let evidenceDir = ProcessInfo.processInfo.environment["TTZIP_SETTINGS_EVIDENCE_DIR"] {
            let dirURL = URL(fileURLWithPath: evidenceDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try? pngData.write(to: dirURL.appendingPathComponent(filename), options: .atomic)
        }
        return meanLuma
    }

    private func computeMeanLuminance(of rep: NSBitmapImageRep) -> Double {
        var lumaSum = 0.0
        var sampleCount = 0
        let stepX = max(1, rep.pixelsWide / 32)
        let stepY = max(1, rep.pixelsHigh / 32)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                if let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    lumaSum += 0.2126 * Double(pixel.redComponent)
                        + 0.7152 * Double(pixel.greenComponent)
                        + 0.0722 * Double(pixel.blueComponent)
                    sampleCount += 1
                }
            }
        }
        return sampleCount > 0 ? lumaSum / Double(sampleCount) : 0.0
    }

    private func renderCompositePNG(
        rep: NSBitmapImageRep,
        canvasColor: NSColor,
        size: NSSize
    ) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        canvasColor.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        rep.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()

        let tiffData = try XCTUnwrap(image.tiffRepresentation)
        let outRep = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        return try XCTUnwrap(outRep.representation(using: .png, properties: [:]))
    }
}
