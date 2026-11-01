// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import Observation
import SwiftUI
import TTZipCore
import TTZipUI

#if canImport(TTI18nCore)
import TTI18nCore
#endif

// MARK: - 1. Application Appearance Preference Model

/// Canonical application-wide appearance preference (`system` / `light` / `dark`).
///
/// Contract:
/// - Stored under `ApplicationAppearance.preferenceKey` (`"TTZip_ApplicationAppearance"`).
/// - `.system` sets `NSApplication.appearance = nil` (and clears per-window overrides) so AppKit
///   dynamically tracks macOS system appearance transitions without freezing a startup snapshot.
/// - Unknown, empty, or missing persisted values deterministically fall back to `.system`.
/// - Independent from text/code (`TTTextReadingPreferenceStore`) and EPUB (`themeMode`) reading
///   canvas background preferences, and never writes global `AppleInterfaceStyle`.
public enum ApplicationAppearance: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public static let preferenceKey = "TTZip_ApplicationAppearance"
    public static let defaultMode: Self = .system

    public var id: String { rawValue }

    /// Resolves a persisted raw string into an `ApplicationAppearance`, falling back to `.system`
    /// for `nil`, whitespace-only, or unrecognized values.
    public init(persistedRawValue: String?) {
        guard let raw = persistedRawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let resolved = Self(rawValue: raw) else {
            self = .system
            return
        }
        self = resolved
    }

    /// The AppKit `NSAppearance.Name` override for this mode, or `nil` when following system.
    public var appearanceName: NSAppearance.Name? {
        switch self {
        case .system:
            return nil
        case .light:
            return .aqua
        case .dark:
            return .darkAqua
        }
    }

    /// Resolves the `NSAppearance` override to install on the application target (`nil` for `.system`).
    public var resolvedNSAppearance: NSAppearance? {
        guard let name = appearanceName else { return nil }
        return NSAppearance(named: name)
    }

    /// Leaf localization key corresponding to this option in Settings -> General.
    public var optionLocaleKey: ApplicationAppearanceLocaleKey {
        switch self {
        case .system:
            return .optionSystem
        case .light:
            return .optionLight
        case .dark:
            return .optionDark
        }
    }
}

// MARK: - 2. Leaf Localization Catalog (`zh-Hans`, `zh-Hant`, `en`)

/// Leaf localization keys for the Application Appearance settings section and picker options.
public enum ApplicationAppearanceLocaleKey: String, TTZipCore.LocaleKeyProtocol, CaseIterable, Sendable {
    case sectionHeader = "settings.appearance.header"
    case modeLabel = "settings.appearance.mode_label"
    case description = "settings.appearance.description"
    case optionSystem = "settings.appearance.option.system"
    case optionLight = "settings.appearance.option.light"
    case optionDark = "settings.appearance.option.dark"
    case pickerAccessibilityHelp = "settings.appearance.picker.help"

    public var rawKey: String { rawValue }

    @MainActor
    public func localized(for language: TTZipCore.AppLanguage? = nil) -> String {
        let resolvedLanguage = language ?? TTZipUI.AppLocalizationState.shared.currentLanguage
        return translation(for: resolvedLanguage)
    }

    public func translation(for language: TTZipCore.AppLanguage) -> String {
        guard let entry = Self.translations[self] else { return rawValue }
        switch language {
        case .zhHans:
            return entry.zhHans
        case .zhHant:
            return entry.zhHant
        default:
            return entry.en
        }
    }

    private static let translations: [Self: (en: String, zhHans: String, zhHant: String)] = [
        .sectionHeader: (
            "Appearance",
            "应用外观",
            "應用外觀"
        ),
        .modeLabel: (
            "Appearance",
            "外观模式",
            "外觀模式"
        ),
        .description: (
            "Applies to application chrome and windows. Text and EPUB reading backgrounds remain independent.",
            "作用于应用界面与所有窗口；文本与电子书阅读底色保持独立设置。",
            "作用於應用介面與所有視窗；文本與電子書閱讀底色保持獨立設定。"
        ),
        .optionSystem: (
            "System",
            "跟随系统",
            "跟隨系統"
        ),
        .optionLight: (
            "Light",
            "浅色",
            "淺色"
        ),
        .optionDark: (
            "Dark",
            "深色",
            "深色"
        ),
        .pickerAccessibilityHelp: (
            "Choose System, Light, or Dark appearance for TTZip",
            "选择 TTZip 的应用外观：跟随系统、浅色或深色",
            "選擇 TTZip 的應用外觀：跟隨系統、淺色或深色"
        )
    ]
}

#if canImport(TTI18nCore)
extension ApplicationAppearanceLocaleKey: FallbackLocaleKeyProtocol {
    public func fallbackTranslation(for language: TTI18nCore.AppLanguage) -> String {
        guard let entry = Self.translations[self] else { return rawValue }
        switch language {
        case .zhHans:
            return entry.zhHans
        case .zhHant:
            return entry.zhHant
        default:
            return entry.en
        }
    }
}
#endif

// MARK: - 3. Application Appearance Target & Applier Boundary

/// Abstract target receiving application-level appearance updates and exposing managed windows
/// whose per-window `appearance` overrides must be cleared so all windows inherit uniformly.
@MainActor
public protocol ApplicationAppearanceTargetProtocol: AnyObject {
    var appearance: NSAppearance? { get set }
    var windows: [NSWindow] { get }
    func synchronizeAuxiliaryWindows()
}

extension NSApplication: ApplicationAppearanceTargetProtocol {
    public func synchronizeAuxiliaryWindows() {
        for windowID in BrowserWindowRegistry.shared.registeredWindowIDs {
            if let window = BrowserWindowRegistry.shared.nsWindow(for: windowID),
               window.appearance != nil {
                window.appearance = nil
            }
        }
        if let playerWindow = StandalonePlaybackWindowManager.shared.playerWindow,
           playerWindow.appearance != nil {
            playerWindow.appearance = nil
        }
    }
}

/// Adapter boundary applying the resolved `ApplicationAppearance` to the host application.
@MainActor
public protocol ApplicationAppearanceApplying: AnyObject {
    func apply(appearance: NSAppearance?, mode: ApplicationAppearance)
}

/// Production AppKit adapter that sets `target.appearance` (`nil` for `.system`, `.aqua` for `.light`,
/// `.darkAqua` for `.dark`) and clears per-window `window.appearance` overrides so existing and newly
/// created windows never diverge from the application-wide preference.
@MainActor
public final class AppKitApplicationAppearanceApplier: ApplicationAppearanceApplying {
    public static let shared = AppKitApplicationAppearanceApplier {
        NSApplication.shared
    }

    private let targetProvider: @MainActor () -> (any ApplicationAppearanceTargetProtocol)?

    public init(targetProvider: @escaping @MainActor () -> (any ApplicationAppearanceTargetProtocol)?) {
        self.targetProvider = targetProvider
    }

    public convenience init(target: any ApplicationAppearanceTargetProtocol) {
        self.init(targetProvider: { target })
    }

    public func apply(appearance: NSAppearance?, mode: ApplicationAppearance) {
        guard let target = targetProvider() else { return }
        target.appearance = appearance
        for window in target.windows where window.appearance != nil {
            window.appearance = nil
        }
        target.synchronizeAuxiliaryWindows()
    }
}

// MARK: - 4. Single-Owner Application Appearance Store

/// Single-owner state store for TTZip's application-wide appearance preference.
///
/// Owned by the App composition root (`ApplicationAppearanceStore.shared`) and injected into
/// `SettingsView` so Settings reads and writes the exact same owner without duplicate per-window
/// state, `@AppStorage` shadow copies, or `NotificationCenter` synchronization buses.
@Observable
@MainActor
public final class ApplicationAppearanceStore {
    public static let shared = ApplicationAppearanceStore()

    public let storageKey: String
    private let defaults: UserDefaults
    private let applier: any ApplicationAppearanceApplying
    public private(set) var mode: ApplicationAppearance

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = ApplicationAppearance.preferenceKey,
        applier: any ApplicationAppearanceApplying = AppKitApplicationAppearanceApplier.shared,
        applyImmediately: Bool = false
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.applier = applier
        let rawStoredValue = defaults.string(forKey: storageKey)
        let resolvedMode = ApplicationAppearance(persistedRawValue: rawStoredValue)
        self.mode = resolvedMode
        if let rawStoredValue, ApplicationAppearance(rawValue: rawStoredValue) == nil {
            defaults.set(resolvedMode.rawValue, forKey: storageKey)
        }
        if applyImmediately {
            applier.apply(appearance: resolvedMode.resolvedNSAppearance, mode: resolvedMode)
        }
    }

    /// Two-way SwiftUI binding for the Settings -> General appearance picker.
    public var selectionBinding: Binding<ApplicationAppearance> {
        Binding(
            get: { self.mode },
            set: { self.setMode($0) }
        )
    }

    /// Persists `newMode` to `defaults` under `storageKey` and immediately applies it via `applier`.
    public func setMode(_ newMode: ApplicationAppearance) {
        defaults.set(newMode.rawValue, forKey: storageKey)
        mode = newMode
        applier.apply(appearance: newMode.resolvedNSAppearance, mode: newMode)
    }

    /// Reloads the stored value from `defaults` (normalizing unknown values to `.system`)
    /// and applies it immediately through the owned `applier`.
    @discardableResult
    public func reloadAndApplyFromStorage() -> ApplicationAppearance {
        let rawStoredValue = defaults.string(forKey: storageKey)
        let resolvedMode = ApplicationAppearance(persistedRawValue: rawStoredValue)
        if let rawStoredValue, ApplicationAppearance(rawValue: rawStoredValue) == nil {
            defaults.set(resolvedMode.rawValue, forKey: storageKey)
        }
        mode = resolvedMode
        applier.apply(appearance: resolvedMode.resolvedNSAppearance, mode: resolvedMode)
        return resolvedMode
    }

    /// Startup composition hook called once from `TTZipApp.init()`.
    public func applyCurrentPreference() {
        _ = reloadAndApplyFromStorage()
    }
}

// MARK: - 5. Native AppKit Pop-Up Control for Settings -> General

/// Native AppKit `NSPopUpButton` control bound to `ApplicationAppearanceStore.selectionBinding`.
/// Provides deterministic macOS pop-up menu behavior, accessibility reachability, and dynamic
/// trilingual title updates in `Settings -> General`.
@MainActor
public struct ApplicationAppearancePickerControl: NSViewRepresentable {
    @Binding public var selection: ApplicationAppearance
    public let language: TTZipCore.AppLanguage

    public init(
        selection: Binding<ApplicationAppearance>,
        language: TTZipCore.AppLanguage
    ) {
        self._selection = selection
        self.language = language
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    public func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24), pullsDown: false)
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionDidChange(_:))
        button.setAccessibilityIdentifier("settings.general.appearancePicker")
        configureMenuItems(on: button)
        return button
    }

    public func updateNSView(_ nsView: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        nsView.setAccessibilityIdentifier("settings.general.appearancePicker")
        configureMenuItems(on: nsView)
    }

    private func configureMenuItems(on button: NSPopUpButton) {
        let options = ApplicationAppearance.allCases
        let titles = options.map { $0.optionLocaleKey.translation(for: language) }
        if button.itemTitles != titles {
            button.removeAllItems()
            for (index, option) in options.enumerated() {
                button.addItem(withTitle: titles[index])
                button.item(at: index)?.representedObject = option.rawValue
            }
        }
        if let selectedIndex = options.firstIndex(of: selection),
           button.indexOfSelectedItem != selectedIndex {
            button.selectItem(at: selectedIndex)
        }
        button.toolTip = ApplicationAppearanceLocaleKey.pickerAccessibilityHelp.translation(for: language)
        button.setAccessibilityTitle(ApplicationAppearanceLocaleKey.sectionHeader.translation(for: language))
        button.setAccessibilityLabel(ApplicationAppearanceLocaleKey.modeLabel.translation(for: language))
        button.setAccessibilityHelp(ApplicationAppearanceLocaleKey.description.translation(for: language))
    }

    @MainActor
    public final class Coordinator: NSObject {
        var selection: Binding<ApplicationAppearance>

        init(selection: Binding<ApplicationAppearance>) {
            self.selection = selection
        }

        @objc
        public func selectionDidChange(_ sender: NSPopUpButton) {
            let options = ApplicationAppearance.allCases
            let index = sender.indexOfSelectedItem
            guard options.indices.contains(index) else { return }
            selection.wrappedValue = options[index]
        }
    }
}
