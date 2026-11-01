// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import Observation
import TTZipCore
import enum TTI18nCore.AppLanguage
import protocol TTI18nCore.FallbackLocaleKeyProtocol
import class TTI18nUI.LocalizationState

/// Reactive state manager bridging TTZipCore's zero-I/O localization catalogs with SwiftUI views.
@Observable
@MainActor
public final class AppLocalizationState {
    
    public static let shared = AppLocalizationState()
    
    /// Optional callback hook for host application menu / UI synchronizers.
    public static var onLanguageChanged: (@MainActor (TTZipCore.AppLanguage) -> Void)?
    
    public private(set) var currentLanguage: TTZipCore.AppLanguage {
        didSet {
            TTZipLocalizationManager.shared.currentLanguage = currentLanguage
            TTZipPreferencesStore.saveLanguage(currentLanguage)
            syncSharedLanguage()
            Self.onLanguageChanged?(currentLanguage)
            NotificationCenter.default.post(name: Notification.Name("TTZipLanguageChanged"), object: currentLanguage)
        }
    }
    
    public var byteUnitStandard: ByteSizeStandard {
        didSet {
            TTZipPreferencesStore.saveByteStandard(byteUnitStandard)
        }
    }
    
    private init() {
        if let stored = TTZipPreferencesStore.getSavedLanguage() {
            self.currentLanguage = stored
        } else {
            self.currentLanguage = TTZipLocalizationManager.shared.currentLanguage
        }
        
        self.byteUnitStandard = TTZipPreferencesStore.getSavedByteStandard()
        TTZipLocalizationManager.shared.currentLanguage = self.currentLanguage
        syncSharedLanguage()
    }
    
    private func syncSharedLanguage() {
        if let language = TTI18nCore.AppLanguage.from(identifier: currentLanguage.bcp47) {
            TTI18nUI.LocalizationState.shared.setLanguage(language)
        }
    }

    /// Switches the application's active language dynamically in real time (< 10ms).
    public func setLanguage(_ language: TTZipCore.AppLanguage) {
        guard language != currentLanguage else { return }
        self.currentLanguage = language
    }
    
    /// Resolves a localized string for the specified key in the current language.
    public func t(_ key: any LocaleKeyProtocol) -> String {
        let res = TTZipLocalizationManager.shared.string(for: key, language: currentLanguage)
        if !res.isEmpty && res != key.rawKey {
            return res
        }
        if let fallback = key as? any FallbackLocaleKeyProtocol,
           let lang = TTI18nCore.AppLanguage.from(identifier: currentLanguage.bcp47) {
            return fallback.fallbackTranslation(for: lang)
        }
        return res
    }
    
    /// Resolves a formatted localized string with positional arguments.
    public func format(_ key: any LocaleKeyProtocol, _ args: CVarArg...) -> String {
        var formatStr = TTZipLocalizationManager.shared.string(for: key, language: currentLanguage)
        if (formatStr.isEmpty || formatStr == key.rawKey),
           let fallback = key as? any FallbackLocaleKeyProtocol,
           let lang = TTI18nCore.AppLanguage.from(identifier: currentLanguage.bcp47) {
            formatStr = fallback.fallbackTranslation(for: lang)
        }
        return String(format: formatStr, locale: Locale(identifier: currentLanguage.bcp47), arguments: args)
    }
    
    /// Formats a byte count into localized string using the active ByteSizeStandard.
    public func formatBytes(_ bytes: Int64, standard: ByteSizeStandard? = nil) -> String {
        let targetStandard = standard ?? self.byteUnitStandard
        return ByteSizeFormatter.format(bytes: bytes, style: targetStandard, language: currentLanguage)
    }
    
    /// Formats throughput rate into localized string (e.g. "1250.5 MB/s").
    public func formatThroughput(_ mbPerSec: Double) -> String {
        return ThroughputFormatter.format(mbPerSec: mbPerSec, language: currentLanguage)
    }
    
    /// Formats a fraction (e.g. 0.425) into localized percentage string (e.g. "42.5%").
    public func formatPercent(_ fraction: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.locale = Locale(identifier: currentLanguage.bcp47)
        return formatter.string(from: NSNumber(value: fraction)) ?? String(format: "%.1f%%", fraction * 100.0)
    }
    
    /// Formats a date into a localized long date string.
    public func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: currentLanguage.bcp47)
        return formatter.string(from: date)
    }
    
    /// Evaluates plural category and returns formatted string.
    public func plural(key: any LocaleKeyProtocol, count: Int) -> String {
        let template = t(key)
        return String(format: template, locale: Locale(identifier: currentLanguage.bcp47), count)
    }
    
    /// Formats file and directory counts with grammatical pluralization across supported languages.
    public func formatFilesAndDirectories(files: Int, directories: Int) -> String {
        if currentLanguage == .en {
            let fileWord = files == 1 ? "File" : "Files"
            let dirWord = directories == 1 ? "Directory" : "Directories"
            return "\(files) \(fileWord) · \(directories) \(dirWord)"
        }
        return format(L10n.Units.filesAndDirectories, files, directories)
    }
    
    /// Resolves localized string across all supported languages using native language fallback.
    public func uiString(
        zh: String,
        en: String,
        zhHant: String? = nil,
        ja: String? = nil,
        ko: String? = nil,
        de: String? = nil,
        fr: String? = nil,
        es: String? = nil
    ) -> String {
        switch currentLanguage {
        case .zhHans: return zh
        case .zhHant: return zhHant ?? zh
        case .ja: return ja ?? en
        case .de: return de ?? en
        case .fr: return fr ?? en
        case .es: return es ?? en
        default: return en
        }
    }
}
