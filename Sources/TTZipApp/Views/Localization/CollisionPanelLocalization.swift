// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import TTZipCore
import TTZipUI
import TTKitUI

// MARK: - AppLocalizationState Typed Extensions

public extension AppLocalizationState {
    /// Resolves a localized collision string for the current active language.
    func t(_ key: CollisionLocaleKey) -> String {
        TTZipLocalizationManager.shared.string(for: key, language: currentLanguage)
    }

    /// Formats a localized collision string template using the current active language `Locale`.
    func format(_ key: CollisionLocaleKey, _ args: CVarArg...) -> String {
        let formatStr = TTZipLocalizationManager.shared.string(for: key, language: currentLanguage)
        return String(format: formatStr, locale: Locale(identifier: currentLanguage.bcp47), arguments: args)
    }
}

// MARK: - TTZip Adapter for ForensicCollisionPanel

/// Adapter bridging TTZip's `AppLocalizationState` (`TTI18n`) and `CollisionLocaleKey`
/// into TTKit's product-agnostic `ForensicCollisionLocalization` model.
@MainActor
public enum CollisionPanelLocalization {
    /// Registers the shared `AppLocalizationState` as the default fallback provider for `ForensicCollisionPanel`.
    public static func registerFallbackProvider(state: AppLocalizationState = .shared) {
        ForensicCollisionLocalization.fallbackProvider = {
            makeLocalization(from: state)
        }
    }

    /// Builds a reactive `ForensicCollisionLocalization` from `AppLocalizationState`.
    /// Accessing `state.currentLanguage` and `state.byteUnitStandard` inside a SwiftUI view body
    /// automatically subscribes the view to real-time language and byte-unit changes.
    public static func makeLocalization(
        from state: AppLocalizationState = .shared
    ) -> ForensicCollisionLocalization {
        if ForensicCollisionLocalization.fallbackProvider == nil {
            registerFallbackProvider(state: state)
        }
        return makeLocalization(
            language: state.currentLanguage,
            byteUnitStandard: state.byteUnitStandard,
            manager: .shared
        )
    }

    /// Builds a `ForensicCollisionLocalization` for an explicit `AppLanguage` and `ByteSizeStandard`.
    nonisolated public static func makeLocalization(
        language: AppLanguage,
        byteUnitStandard: ByteSizeStandard = .metricSi,
        manager: TTZipLocalizationManager = .shared
    ) -> ForensicCollisionLocalization {
        let byteStyle: ForensicCollisionByteCountStyle = (byteUnitStandard == .binaryIec) ? .binary : .file
        func resolve(_ key: CollisionLocaleKey) -> String {
            manager.string(for: key, language: language)
        }

        return ForensicCollisionLocalization(
            localeIdentifier: language.bcp47,
            byteCountStyle: byteStyle,
            panelTitle: resolve(.panelTitle),
            conflictProgressFormat: resolve(.conflictProgressFormat),
            sameTypeTitle: resolve(.sameTypeTitle),
            typeMismatchBadge: resolve(.typeMismatchBadge),
            typeMismatchHelp: resolve(.typeMismatchHelp),
            incomingCardTitle: resolve(.incomingCardTitle),
            existingCardTitle: resolve(.existingCardTitle),
            newerBadge: resolve(.newerBadge),
            largerBadge: resolve(.largerBadge),
            mismatchBadge: resolve(.mismatchBadge),
            directoryBadge: resolve(.directoryBadge),
            fileBadge: resolve(.fileBadge),
            pathLabel: resolve(.pathLabel),
            sizeLabel: resolve(.sizeLabel),
            modifiedLabel: resolve(.modifiedLabel),
            typeLabel: resolve(.typeLabel),
            directoryTypeValue: resolve(.directoryTypeValue),
            fileTypeValue: resolve(.fileTypeValue),
            unavailableValue: resolve(.unavailableValue),
            bytesExactFormat: resolve(.bytesExactFormat),
            bytesOnlyFormat: resolve(.bytesOnlyFormat),
            stopAction: ForensicCollisionActionCopy(
                title: resolve(.actionStopTitle),
                subtitle: resolve(.actionStopSubtitle),
                accessibilityHint: resolve(.actionStopAccessibilityHint)
            ),
            skipAction: ForensicCollisionActionCopy(
                title: resolve(.actionSkipTitle),
                subtitle: resolve(.actionSkipSubtitle),
                accessibilityHint: resolve(.actionSkipAccessibilityHint)
            ),
            replaceAction: ForensicCollisionActionCopy(
                title: resolve(.actionReplaceTitle),
                subtitle: resolve(.actionReplaceSubtitle),
                accessibilityHint: resolve(.actionReplaceAccessibilityHint)
            ),
            keepBothAction: ForensicCollisionActionCopy(
                title: resolve(.actionKeepBothTitle),
                subtitle: resolve(.actionKeepBothSubtitle),
                accessibilityHint: resolve(.actionKeepBothAccessibilityHint)
            ),
            applyToAllTitle: resolve(.applyToAllRemaining),
            applyToAllAccessibilityHint: resolve(.applyToAllAccessibilityHint),
            dialogAccessibilityLabel: resolve(.dialogAccessibilityLabel),
            headerSummaryVoiceOverFormat: resolve(.headerSummaryVoiceOverFormat),
            headerTypeMismatchClause: resolve(.headerTypeMismatchClause),
            typeMismatchAccessibilityLabel: resolve(.typeMismatchAccessibilityLabel),
            cardAccessibilityFormat: resolve(.cardAccessibilityFormat)
        )
    }
}

public extension View {
    /// Injects TTZip's reactive `ForensicCollisionLocalization` into the SwiftUI environment.
    @MainActor
    func ttzipCollisionPanelLocalization(_ state: AppLocalizationState = .shared) -> some View {
        self.environment(
            \.forensicCollisionLocalization,
            CollisionPanelLocalization.makeLocalization(from: state)
        )
    }
}
