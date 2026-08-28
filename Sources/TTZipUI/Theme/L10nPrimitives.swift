// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore

/// Reactive SwiftUI Text primitive that automatically updates upon `AppLocalizationState` language changes.
public struct L10nText: View {
    @ObservedObject private var l10n = AppLocalizationState.shared
    private let key: any LocaleKeyProtocol
    private let args: [any CVarArg]
    
    public init(_ key: any LocaleKeyProtocol, _ args: any CVarArg...) {
        self.key = key
        self.args = args
    }
    
    public var body: some View {
        if args.isEmpty {
            Text(l10n.t(key))
        } else {
            let template = TTZipLocalizationManager.shared.string(for: key)
            let formatted = String(format: template, locale: Locale(identifier: l10n.currentLanguage.bcp47), arguments: args)
            Text(formatted)
        }
    }
}

/// Reactive SwiftUI Label primitive that automatically updates upon `AppLocalizationState` language changes.
public struct L10nLabel: View {
    @ObservedObject private var l10n = AppLocalizationState.shared
    private let key: any LocaleKeyProtocol
    private let systemImage: String
    private let args: [any CVarArg]
    
    public init(_ key: any LocaleKeyProtocol, systemImage: String, _ args: any CVarArg...) {
        self.key = key
        self.systemImage = systemImage
        self.args = args
    }
    
    public var body: some View {
        if args.isEmpty {
            Label(l10n.t(key), systemImage: systemImage)
        } else {
            let template = TTZipLocalizationManager.shared.string(for: key)
            let formatted = String(format: template, locale: Locale(identifier: l10n.currentLanguage.bcp47), arguments: args)
            Label(formatted, systemImage: systemImage)
        }
    }
}

public extension View {
    /// Applies a reactive localized tooltip to the view.
    @ViewBuilder
    func l10nHelp(_ key: any LocaleKeyProtocol) -> some View {
        self.help(AppLocalizationState.shared.t(key))
    }
}
