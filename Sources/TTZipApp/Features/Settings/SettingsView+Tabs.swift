// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipPreviewKit
import TTZipUI

/// General Settings category covering window appearance, ambient mineral tint, extraction conflict defaults, and preview wrap.
public struct GeneralSettingsPane: View {
    private static let collisionDefaultsKey = "ttzip_collision_default"

    @Bindable private var l10n = AppLocalizationState.shared
    private let appearanceStore: ApplicationAppearanceStore
    @Bindable private var textReadingStore: TTTextReadingPreferenceStore
    private let defaults: UserDefaults
    private let style: SettingsVisualStyle

    @State private var selectedAccent: AccentMineralTheme
    @State private var collisionPolicy: String

    public init(
        appearanceStore: ApplicationAppearanceStore,
        textReadingStore: TTTextReadingPreferenceStore,
        defaults: UserDefaults = .standard,
        style: SettingsVisualStyle
    ) {
        self.appearanceStore = appearanceStore
        self.textReadingStore = textReadingStore
        self.defaults = defaults
        self.style = style
        self._selectedAccent = State(initialValue: AccentMineralTheme.load(from: defaults))
        self._collisionPolicy = State(
            initialValue: Self.normalizedCollisionPolicy(defaults.string(forKey: Self.collisionDefaultsKey))
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.lg) {
            SettingsCategoryHeader(
                title: l10n.t(L10n.Settings.general),
                subtitle: l10n.t(SettingsLocaleKey.generalSubtitle),
                systemImage: "gearshape",
                style: style
            )

            appearanceGroup
            fileAndPreviewGroup
        }
    }

    private var appearanceGroup: some View {
        SettingsFormGroup(
            title: l10n.t(ApplicationAppearanceLocaleKey.sectionHeader),
            systemImage: "circle.lefthalf.filled"
        ) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.t(ApplicationAppearanceLocaleKey.modeLabel))
                        .font(TTZipTheme.Typography.bodyMedium)
                        .foregroundStyle(style.primaryTextColor)
                    Text(l10n.t(ApplicationAppearanceLocaleKey.description))
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(style.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                ApplicationAppearancePickerControl(
                    selection: appearanceStore.selectionBinding,
                    language: l10n.currentLanguage
                )
                .frame(width: 180, height: 24)
                .help(l10n.t(ApplicationAppearanceLocaleKey.pickerAccessibilityHelp))
                .accessibilityIdentifier("settings.general.appearancePicker")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            SettingsFormDivider()

            accentThemeRow
        }
    }

    private var accentThemeRow: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t(SettingsLocaleKey.accentThemeTitle))
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(style.primaryTextColor)
                Text(l10n.t(SettingsLocaleKey.accentThemeDesc))
                    .font(TTZipTheme.Typography.caption)
                    .foregroundStyle(style.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                ForEach(AccentMineralTheme.allCases) { theme in
                    accentSwatchView(for: theme)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func accentSwatchView(for theme: AccentMineralTheme) -> some View {
        let isSelected = (selectedAccent == theme)
        let title = l10n.t(theme.labelKey)
        return ZStack {
            Circle()
                .strokeBorder(
                    isSelected ? theme.swatchColor : Color.clear,
                    lineWidth: style.borderWidth * 3.0
                )
                .frame(width: 28, height: 28)

            Circle()
                .fill(theme.swatchColor)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .strokeBorder(style.borderColor, lineWidth: style.borderWidth)
                )

            if isSelected {
                Circle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 28, height: 28)
        .overlay(
            SettingsNativeButtonBridge(
                identifier: "settings.general.accent.\(theme.rawValue)",
                title: title,
                isSelected: isSelected,
                onPress: {
                    withAnimation(TTZipTheme.Motion.micro) {
                        selectedAccent = theme
                    }
                    theme.persist(to: defaults)
                }
            )
        )
        .contentShape(Circle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.general.accent.\(theme.rawValue)")
    }

    private var fileAndPreviewGroup: some View {
        SettingsFormGroup(
            title: l10n.t(SettingsLocaleKey.fileAndPreviewHeader),
            systemImage: "doc.text.magnifyingglass"
        ) {
            SettingsPickerRow(
                title: l10n.t(L10n.Settings.conflictHeader),
                subtitle: l10n.t(L10n.Settings.conflictDesc),
                style: style,
                selection: Binding(
                    get: { collisionPolicy },
                    set: { nextPolicy in
                        let normalized = Self.normalizedCollisionPolicy(nextPolicy)
                        collisionPolicy = normalized
                        defaults.set(normalized, forKey: Self.collisionDefaultsKey)
                    }
                ),
                options: [
                    SettingsPopUpButtonOption(value: "ask", title: l10n.t(L10n.Settings.conflictAsk)),
                    SettingsPopUpButtonOption(value: "keep_both", title: l10n.t(L10n.Settings.conflictKeepBoth)),
                    SettingsPopUpButtonOption(value: "replace", title: l10n.t(L10n.Settings.conflictReplace)),
                    SettingsPopUpButtonOption(value: "skip", title: l10n.t(L10n.Settings.conflictSkip)),
                ],
                controlWidth: 180,
                accessibilityIdentifier: "settings.general.conflictPicker"
            )

            SettingsFormDivider()

            SettingsToggleRow(
                title: l10n.t(SettingsLocaleKey.softWrapTitle),
                subtitle: l10n.t(SettingsLocaleKey.softWrapDesc),
                style: style,
                isOn: $textReadingStore.isSoftWrapEnabled,
                accessibilityIdentifier: "settings.general.softWrapToggle"
            )
        }
    }

    private static func normalizedCollisionPolicy(_ rawValue: String?) -> String {
        switch rawValue {
        case "keepBoth", "keep_both":
            return "keep_both"
        case "replace":
            return "replace"
        case "skip":
            return "skip"
        default:
            return "ask"
        }
    }
}

/// Language & Byte Units Settings category using native AppKit pickers and live formatting preview.
public struct LocalizationSettingsPane: View {
    private static let sampleByteCount: Int64 = 1_000_000_000

    @Bindable private var l10n = AppLocalizationState.shared
    private let style: SettingsVisualStyle

    public init(style: SettingsVisualStyle) {
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.lg) {
            SettingsCategoryHeader(
                title: l10n.t(L10n.Settings.localization),
                subtitle: l10n.t(SettingsLocaleKey.localizationSubtitle),
                systemImage: "globe",
                style: style
            )

            VStack(alignment: .leading, spacing: 10) {
                SettingsFormGroup(
                    title: l10n.t(L10n.Settings.localization),
                    systemImage: "globe"
                ) {
                    SettingsPickerRow(
                        title: l10n.t(L10n.Settings.language),
                        style: style,
                        selection: Binding(
                            get: { l10n.currentLanguage },
                            set: { l10n.setLanguage($0) }
                        ),
                        options: AppLanguage.allCases.map {
                            SettingsPopUpButtonOption(value: $0, title: $0.displayName)
                        },
                        controlWidth: 190,
                        accessibilityIdentifier: "settings.localization.languagePicker"
                    )

                    SettingsFormDivider()

                    SettingsPickerRow(
                        title: l10n.t(L10n.Settings.byteUnits),
                        subtitle: l10n.t(SettingsLocaleKey.byteUnitsDesc),
                        style: style,
                        selection: $l10n.byteUnitStandard,
                        options: [
                            SettingsPopUpButtonOption(
                                value: .metricSI,
                                title: l10n.t(L10n.Settings.unitSI)
                            ),
                            SettingsPopUpButtonOption(
                                value: .binaryIEC,
                                title: l10n.t(L10n.Settings.unitIEC)
                            ),
                        ],
                        controlWidth: 244,
                        accessibilityIdentifier: "settings.localization.byteUnitsPicker"
                    )

                    SettingsFormDivider()

                    SettingsKeyValueRow(
                        label: l10n.t(SettingsLocaleKey.byteUnitsPreviewLabel),
                        value: "1,000,000,000 B → \(l10n.formatBytes(Self.sampleByteCount, standard: l10n.byteUnitStandard))",
                        style: style,
                        monospacedValue: true,
                        valueAccessibilityIdentifier: "settings.localization.bytePreviewValue"
                    )
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    Text(l10n.t(L10n.Settings.instantSwitchNote))
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(style.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
            }
        }
    }
}
