// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

/// Compression Defaults pane configuring initial container format, tier, cleanup filters, and saved presets access.
public struct CompressionDefaultsSettingsPane: View {
    @Bindable private var l10n = AppLocalizationState.shared
    @Bindable private var store: CompressionDefaultsStore
    private let presetManager: PresetManager
    private let style: SettingsVisualStyle
    private let onOpenPresets: (() -> Void)?

    public init(
        store: CompressionDefaultsStore,
        presetManager: PresetManager = .shared,
        style: SettingsVisualStyle,
        onOpenPresets: (() -> Void)? = nil
    ) {
        self.store = store
        self.presetManager = presetManager
        self.style = style
        self.onOpenPresets = onOpenPresets
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.lg) {
            SettingsCategoryHeader(
                title: l10n.t(L10n.Presets.title),
                subtitle: l10n.t(SettingsLocaleKey.presetsSubtitle),
                systemImage: "slider.horizontal.3",
                style: style
            )

            defaultsGroup
            savedPresetsGroup
        }
    }

    private var defaultsGroup: some View {
        SettingsFormGroup(
            title: l10n.t(L10n.Presets.title),
            systemImage: "slider.horizontal.3"
        ) {
            SettingsPickerRow(
                title: l10n.t(L10n.Settings.defaultFormat),
                subtitle: l10n.t(SettingsLocaleKey.defaultFormatDesc),
                style: style,
                selection: $store.defaultFormat,
                options: CompressionDefaultsSnapshot.supportedDefaultFormats.map {
                    SettingsPopUpButtonOption(value: $0, title: $0.displayName)
                },
                controlWidth: 195,
                accessibilityIdentifier: "settings.presets.formatPicker"
            )

            SettingsFormDivider()

            SettingsPickerRow(
                title: l10n.t(SettingsLocaleKey.defaultLevelTitle),
                subtitle: l10n.t(SettingsLocaleKey.defaultLevelDesc),
                style: style,
                selection: $store.defaultTier,
                options: DefaultCompressionTier.allCases.map {
                    SettingsPopUpButtonOption(value: $0, title: localizedTitle(for: $0))
                },
                controlWidth: 195,
                accessibilityIdentifier: "settings.presets.levelPicker"
            )

            SettingsFormDivider()

            SettingsToggleRow(
                title: l10n.t(L10n.Compress.filterMacJunk),
                subtitle: l10n.t(SettingsLocaleKey.skipMacJunkDesc),
                style: style,
                isOn: $store.skipMacJunk,
                accessibilityIdentifier: "settings.presets.skipMacJunkToggle"
            )

            SettingsFormDivider()

            SettingsToggleRow(
                title: l10n.t(L10n.Compress.openFinder),
                subtitle: l10n.t(SettingsLocaleKey.openFinderDesc),
                style: style,
                isOn: $store.openFinderAfterCompress,
                accessibilityIdentifier: "settings.presets.openFinderToggle"
            )
        }
    }

    private var savedPresetsGroup: some View {
        SettingsFormGroup(
            title: l10n.t(SettingsLocaleKey.savedPresetsHeader),
            systemImage: "tray.full"
        ) {
            HStack(alignment: .center, spacing: 16) {
                Text(l10n.format(SettingsLocaleKey.savedPresetsSummaryFormat, presetManager.presets.count))
                    .font(TTZipTheme.Typography.callout)
                    .foregroundStyle(style.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.presets.savedCountLabel")

                Spacer(minLength: 12)

                if let onOpenPresets {
                    SettingsCapsuleButton(
                        title: l10n.t(SettingsLocaleKey.openPresetStudioAction),
                        systemImage: "slider.horizontal.3",
                        tone: .neutral,
                        identifier: "settings.presets.openStudioButton",
                        action: onOpenPresets
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func localizedTitle(for tier: DefaultCompressionTier) -> String {
        switch tier {
        case .store: return l10n.t(L10n.Compress.levelStore)
        case .fastest: return l10n.t(L10n.Compress.levelFastest)
        case .normal: return l10n.t(L10n.Compress.levelNormal)
        case .maximum: return l10n.t(L10n.Compress.levelMaximum)
        case .ultra: return l10n.t(L10n.Compress.levelUltra)
        }
    }
}
