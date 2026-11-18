// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation

/// Three-state reading background preference for text and code previews.
/// Operates independently of global application appearance while adapting foreground contrast when in `.fluidTransparent` mode.
public enum TTTextReadingBackgroundMode: String, CaseIterable, Sendable, Equatable, Identifiable {
    case black = "black"
    case white = "white"
    case fluidTransparent = "fluidTransparent"

    public var id: String { rawValue }

    /// Canonical default reading background mode across all text/code preview entry points.
    public static let defaultMode: TTTextReadingBackgroundMode = .fluidTransparent

    /// Persistent `UserDefaults` key shared across all text preview components.
    public static let userDefaultsKey: String = "ttmedia.preview.text.readingBackgroundMode"

    /// SF Symbol icon representing each background state.
    public var iconName: String {
        switch self {
        case .black: return "moon.fill"
        case .white: return "sun.max.fill"
        case .fluidTransparent: return "drop.halffill"
        }
    }

    /// True when the canvas lets the underlying fluid glass material shine through.
    public var isFluidTransparent: Bool {
        self == .fluidTransparent
    }

    /// Dynamic localized label resolved from `LocalizationState.shared`.
    @MainActor
    public var localizedTitle: String {
        switch self {
        case .black:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundBlack)
        case .white:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundWhite)
        case .fluidTransparent:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundFluidTransparent)
        }
    }

    /// Dynamic localized tooltip / accessibility help resolved from `LocalizationState.shared`.
    @MainActor
    public var localizedHelpText: String {
        switch self {
        case .black:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundBlackHelp)
        case .white:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundWhiteHelp)
        case .fluidTransparent:
            return TextAndDocumentPreviewLocalization.text(.readingBackgroundFluidTransparentHelp)
        }
    }
}

/// Shared observable preference store for the 3-state text reading background and soft wrap toggle.
/// Persists across file switches and app launches without mutating global application appearance.
@MainActor
@Observable
public final class TTTextReadingPreferenceStore {
    public static let shared = TTTextReadingPreferenceStore()

    /// Canonical default soft wrap state across all plain text and code previews (`true`).
    nonisolated public static let defaultSoftWrapEnabled: Bool = true

    /// Persistent `UserDefaults` key shared across all plain text and code preview components.
    nonisolated public static let softWrapUserDefaultsKey: String = "ttmedia.preview.text.softWrapEnabled"

    private let defaults: UserDefaults
    public let storageKey: String
    public let softWrapStorageKey: String

    public var mode: TTTextReadingBackgroundMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: storageKey)
        }
    }

    public var isSoftWrapEnabled: Bool {
        didSet {
            guard isSoftWrapEnabled != oldValue else { return }
            defaults.set(isSoftWrapEnabled, forKey: softWrapStorageKey)
        }
    }

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = TTTextReadingBackgroundMode.userDefaultsKey,
        softWrapStorageKey: String = TTTextReadingPreferenceStore.softWrapUserDefaultsKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.softWrapStorageKey = softWrapStorageKey
        if let raw = defaults.string(forKey: storageKey),
           let stored = TTTextReadingBackgroundMode(rawValue: raw) {
            self.mode = stored
        } else {
            self.mode = TTTextReadingBackgroundMode.defaultMode
        }
        if let storedWrap = defaults.object(forKey: softWrapStorageKey) as? Bool {
            self.isSoftWrapEnabled = storedWrap
        } else {
            self.isSoftWrapEnabled = Self.defaultSoftWrapEnabled
        }
    }

    /// Restores and persists the default values for both preferences.
    public func resetToDefault() {
        mode = TTTextReadingBackgroundMode.defaultMode
        defaults.set(mode.rawValue, forKey: storageKey)
        isSoftWrapEnabled = Self.defaultSoftWrapEnabled
        defaults.set(isSoftWrapEnabled, forKey: softWrapStorageKey)
    }
}
