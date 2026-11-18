// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Global mineral accent theme persisted in `ttzip_accent_theme` and rendered by the window fluid canvas.
public enum AccentMineralTheme: String, CaseIterable, Identifiable, Sendable {
    case bamboo = "bamboo"
    case gold = "gold"
    case amber = "amber"
    case cinnabar = "cinnabar"
    case purple = "purple"

    public static let preferenceKey = "ttzip_accent_theme"
    public static let defaultTheme: Self = .bamboo

    public var id: String { rawValue }

    /// Parses persisted or legacy alias strings into a canonical mineral theme, defaulting to `.bamboo`.
    public init(persistedRawValue: String?) {
        let normalized = persistedRawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch normalized {
        case "gold", "kintsugigold":
            self = .gold
        case "amber", "archiveamber":
            self = .amber
        case "cinnabar", "cinnabarred":
            self = .cinnabar
        case "purple", "celestial", "celestialpurple":
            self = .purple
        default:
            self = .bamboo
        }
    }

    public static func load(from defaults: UserDefaults = .standard) -> AccentMineralTheme {
        AccentMineralTheme(persistedRawValue: defaults.string(forKey: preferenceKey))
    }

    public func persist(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}
