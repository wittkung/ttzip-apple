// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipCore
import TTZipUI

/// Single-layer settings form group container without drop shadows or nested card borders.
public struct SettingsFormGroup<TrailingHeader: View, Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let title: String
    private let systemImage: String
    private let trailingHeader: TrailingHeader
    private let content: Content

    public init(
        title: String,
        systemImage: String,
        @ViewBuilder trailingHeader: () -> TrailingHeader,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailingHeader = trailingHeader()
        self.content = content()
    }

    private var style: SettingsVisualStyle {
        SettingsVisualStyle(
            colorScheme: colorScheme,
            reduceTransparency: reduceTransparency,
            colorSchemeContrast: colorSchemeContrast
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(TTZipTheme.Typography.sectionHeader)
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Spacer(minLength: 8)
                trailingHeader
            }
            .padding(.horizontal, 2)
            .background(
                SettingsFormGroupAccessibilityMarker(
                    identifier: "settings.group.\(systemImage)",
                    title: title
                )
            )

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style.groupBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style.borderColor, lineWidth: style.borderWidth)
            )
        }
    }
}

public extension SettingsFormGroup where TrailingHeader == EmptyView {
    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            trailingHeader: { EmptyView() },
            content: content
        )
    }
}

private struct SettingsFormGroupAccessibilityMarker: NSViewRepresentable {
    let identifier: String
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSView) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(title)
    }
}

/// Hairline row separator inside a `SettingsFormGroup`.
public struct SettingsFormDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init() {}

    public var body: some View {
        let style = SettingsVisualStyle(
            colorScheme: colorScheme,
            reduceTransparency: reduceTransparency,
            colorSchemeContrast: colorSchemeContrast
        )
        Rectangle()
            .fill(style.borderColor)
            .frame(height: style.borderWidth)
            .padding(.horizontal, 14)
    }
}

extension SettingsView {
    // MARK: - 1. General Tab

    @ViewBuilder
    var generalSection: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.lg) {
            appearancePreferenceSection
            smartStoreAndConflictSection
        }
    }

    @ViewBuilder
    var appearancePreferenceSection: some View {
        SettingsFormGroup(
            title: l10n.t(ApplicationAppearanceLocaleKey.sectionHeader),
            systemImage: "circle.lefthalf.filled"
        ) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t(ApplicationAppearanceLocaleKey.modeLabel))
                        .font(TTZipTheme.Typography.bodyMedium)
                        .foregroundStyle(visualStyle.primaryTextColor)
                    Text(l10n.t(ApplicationAppearanceLocaleKey.description))
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(visualStyle.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                ApplicationAppearancePickerControl(
                    selection: appearanceStore.selectionBinding,
                    language: l10n.currentLanguage
                )
                .frame(width: 172, height: 24)
                .help(l10n.t(ApplicationAppearanceLocaleKey.pickerAccessibilityHelp))
                .accessibilityIdentifier("settings.general.appearancePicker")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var smartStoreAndConflictSection: some View {
        SettingsFormGroup(
            title: l10n.t(L10n.Settings.smartStoreBypass),
            systemImage: "bolt.badge.automatic.fill"
        ) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t(L10n.Compress.smartStoreBypassTitle))
                        .font(TTZipTheme.Typography.bodyMedium)
                        .foregroundStyle(visualStyle.primaryTextColor)
                    Text(l10n.t(L10n.Settings.bypassHighEntropyDesc))
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(visualStyle.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $isSmartStoreBypassEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(l10n.t(L10n.Compress.smartStoreBypassTitle))
                    .accessibilityIdentifier("settings.general.smartStoreToggle")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            SettingsFormDivider()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    L10nText(L10n.Settings.conflictHeader)
                        .font(TTZipTheme.Typography.bodyMedium)
                        .foregroundStyle(visualStyle.primaryTextColor)
                    L10nText(L10n.Settings.conflictDesc)
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(visualStyle.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker("", selection: Binding(
                    get: {
                        if collisionDefault == "keepBoth" { return "keep_both" }
                        return collisionDefault
                    },
                    set: { collisionDefault = $0 }
                )) {
                    L10nText(L10n.Settings.conflictAsk).tag("ask")
                    L10nText(L10n.Settings.conflictKeepBoth).tag("keep_both")
                    L10nText(L10n.Settings.conflictReplace).tag("replace")
                    L10nText(L10n.Settings.conflictSkip).tag("skip")
                }
                .labelsHidden()
                .frame(width: 172)
                .accessibilityIdentifier("settings.general.conflictPicker")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - 2. Localization Tab

    @ViewBuilder
    var localizationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsFormGroup(
                title: l10n.t(L10n.Settings.localization),
                systemImage: "globe"
            ) {
                HStack(alignment: .center, spacing: 16) {
                    Text(l10n.t(L10n.Settings.language))
                        .font(TTZipTheme.Typography.bodyMedium)
                        .foregroundStyle(visualStyle.primaryTextColor)
                    Spacer(minLength: 12)
                    Picker("", selection: Binding(
                        get: { l10n.currentLanguage },
                        set: { l10n.setLanguage($0) }
                    )) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .accessibilityIdentifier("settings.localization.languagePicker")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                SettingsFormDivider()

                HStack(alignment: .center, spacing: 16) {
                    Text(l10n.t(L10n.Settings.byteUnits))
                        .font(TTZipTheme.Typography.bodyMedium)
                        .foregroundStyle(visualStyle.primaryTextColor)
                    Spacer(minLength: 12)
                    Picker("", selection: $l10n.byteUnitStandard) {
                        Text(l10n.t(L10n.Settings.unitSI)).tag(ByteSizeStandard.metricSI)
                        Text(l10n.t(L10n.Settings.unitIEC)).tag(ByteSizeStandard.binaryIEC)
                    }
                    .labelsHidden()
                    .frame(width: 245)
                    .accessibilityIdentifier("settings.localization.byteUnitsPicker")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text(l10n.t(L10n.Settings.instantSwitchNote))
                    .font(TTZipTheme.Typography.caption)
                    .foregroundStyle(visualStyle.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - 3. Presets Tab

    @ViewBuilder
    var presetsSection: some View {
        SettingsFormGroup(
            title: l10n.t(L10n.Presets.title),
            systemImage: "slider.horizontal.3"
        ) {
            HStack(alignment: .center, spacing: 16) {
                Text(l10n.t(L10n.Settings.defaultFormat))
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(visualStyle.primaryTextColor)
                Spacer(minLength: 12)
                Picker("", selection: $defaultFormat) {
                    Text("ZIP (PKWARE)").tag(ArchiveCompressionFormat.zip)
                    Text("7Z (LZMA2)").tag(ArchiveCompressionFormat.sevenZip)
                    Text("TAR.ZST (Direct)").tag(ArchiveCompressionFormat.tarZst)
                }
                .labelsHidden()
                .frame(width: 180)
                .accessibilityIdentifier("settings.presets.formatPicker")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            SettingsFormDivider()

            HStack(alignment: .center, spacing: 16) {
                Text(l10n.t(L10n.Compress.level))
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(visualStyle.primaryTextColor)
                Spacer(minLength: 12)
                Picker("", selection: $defaultLevel) {
                    Text(l10n.t(L10n.Compress.levelStore)).tag(ArchiveCompressionLevel.store)
                    Text(l10n.t(L10n.Compress.levelFastest)).tag(ArchiveCompressionLevel.fastest)
                    Text(l10n.t(L10n.Compress.levelNormal)).tag(ArchiveCompressionLevel.normal)
                    Text(l10n.t(L10n.Compress.levelMaximum)).tag(ArchiveCompressionLevel.maximum)
                    Text(l10n.t(L10n.Compress.levelUltra)).tag(ArchiveCompressionLevel.ultra)
                }
                .labelsHidden()
                .frame(width: 180)
                .accessibilityIdentifier("settings.presets.levelPicker")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    // MARK: - 4. Vault Tab

    @ViewBuilder
    var vaultSection: some View {
        SettingsFormGroup(
            title: l10n.t(L10n.Vault.vaultSecurityHeader),
            systemImage: "lock.shield.fill"
        ) {
            vaultSecuritySpecRow(
                icon: "key.horizontal.fill",
                text: l10n.t(L10n.Vault.pbkdf2Desc)
            )
            SettingsFormDivider()
            vaultSecuritySpecRow(
                icon: "memorychip.fill",
                text: l10n.t(L10n.Vault.volatileZeroingDesc)
            )
            SettingsFormDivider()
            vaultSecuritySpecRow(
                icon: "checkmark.shield.fill",
                text: l10n.t(L10n.Vault.aesGcmStorageDesc)
            )
        }
    }

    private func vaultSecuritySpecRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TTZipTheme.bambooGreen)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            Text(text)
                .font(TTZipTheme.Typography.caption)
                .foregroundStyle(visualStyle.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - 5. License & Hardware Topology Tab

    @ViewBuilder
    var licenseAndHardwareSection: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.lg) {
            licenseStatusGroup
            hardwareTopologyGroup
        }
    }

    @ViewBuilder
    private var licenseStatusGroup: some View {
        SettingsFormGroup(
            title: l10n.t(L10n.Settings.licenseStatus),
            systemImage: "checkmark.seal.fill",
            trailingHeader: {
                licenseEditionPill
            },
            content: {
                VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
                    licenseBodyContent
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        )
    }

    private var licenseEditionPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(TTZipTheme.bambooGreen)
                .frame(width: 7, height: 7)
            Text(isPro ? l10n.t(L10n.Settings.proLicenseActive) : l10n.t(L10n.Settings.freeEdition))
                .font(TTZipTheme.Typography.caption)
                .bold()
                .foregroundStyle(TTZipTheme.bambooGreen)
        }
        .padding(.horizontal, TTZipTheme.Spacing.xs)
        .padding(.vertical, 4)
        .background(TTZipTheme.bambooGreen.opacity(0.12))
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var licenseBodyContent: some View {
        #if MAS_BUILD
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.t(L10n.Settings.macAppStoreLicenseActive))
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(visualStyle.primaryTextColor)
                Text(l10n.uiString(zh: "Pro 终身许可证 · Apple 沙盒防护已启用", en: "Pro Lifetime License · Apple Sandbox Protection Active"))
                    .font(TTZipTheme.Typography.caption)
                    .foregroundStyle(visualStyle.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(TTZipTheme.bambooGreen)
        }
        #elseif STEAM_BUILD
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.uiString(zh: "Steam 商店版", en: "Steam Store Edition"))
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(visualStyle.primaryTextColor)
                Text(l10n.uiString(zh: "Pro 终身许可证 · Steam 正版验证", en: "Pro Lifetime License · Steam Verified & DRM-Free"))
                    .font(TTZipTheme.Typography.caption)
                    .foregroundStyle(visualStyle.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(TTZipTheme.bambooGreen)
        }
        #else
        directDistributionLicenseContent
        #endif
    }

    #if !MAS_BUILD && !STEAM_BUILD
    @ViewBuilder
    private var directDistributionLicenseContent: some View {
        let state = Ed25519LicenseManager.shared.currentState
        switch state {
        case .directPro(let payload):
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t(L10n.Settings.licenseStatusActive))
                        .font(TTZipTheme.Typography.bodyMedium)
                        .foregroundStyle(visualStyle.primaryTextColor)
                    Text(l10n.uiString(zh: "注册邮箱 \(payload.email) · 订单号 \(payload.order_id)", en: "Registered to \(payload.email) · Order \(payload.order_id)"))
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(visualStyle.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(l10n.t(L10n.Settings.deactivateButton)) {
                    Ed25519LicenseManager.shared.deactivate()
                    isPro = false
                    activationStatus = l10n.uiString(zh: "已取消激活，已恢复至社区版。", en: "Deactivated. Reverted to Community Edition.")
                }
                .buttonStyle(.plain)
                .font(TTZipTheme.Typography.caption)
                .padding(.horizontal, TTZipTheme.Spacing.sm)
                .padding(.vertical, TTZipTheme.Spacing.xxs)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
            }
        default:
            communityActivationForm
        }
        if !activationStatus.isEmpty {
            Text(activationStatus)
                .font(TTZipTheme.Typography.caption)
                .foregroundStyle(isPro ? TTZipTheme.bambooGreen : TTZipTheme.cinnabarRed)
        }
    }

    private var communityActivationForm: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.uiString(zh: "社区版", en: "Community Edition"))
                        .font(TTZipTheme.Typography.bodyMedium)
                        .foregroundStyle(visualStyle.primaryTextColor)
                    Text(l10n.uiString(zh: "全部核心归档与压缩解压功能均完整开放、无限制使用。", en: "All core archiving and compression capabilities are 100% unrestricted."))
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(visualStyle.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(l10n.uiString(zh: "免费版", en: "Free & Open Source"))
                    .font(TTZipTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
            }

            Text(l10n.uiString(zh: "输入 Ed25519 许可证密钥 (TTZIP1-...) 解锁 Pro 徽章与优先支持：", en: "Enter Ed25519 License Key (TTZIP1-...) to unlock Pro badge & priority support:"))
                .font(TTZipTheme.Typography.caption)
                .foregroundStyle(visualStyle.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: TTZipTheme.Spacing.xs) {
                TextField("TTZIP1-<Payload>.<Signature>", text: $licenseKeyInput)
                    .font(TTZipTheme.Typography.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityIdentifier("settings.license.keyTextField")

                Button(action: activateLicense) {
                    Text(l10n.t(L10n.Settings.activateProButton))
                        .font(TTZipTheme.Typography.callout)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, TTZipTheme.Spacing.sm)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(TTZipTheme.bambooGradient)
                .clipShape(Capsule())
                .accessibilityIdentifier("settings.license.activateButton")
            }
        }
    }
    #endif

    @ViewBuilder
    private var hardwareTopologyGroup: some View {
        let tuner = AppleSiliconTuner.shared
        SettingsFormGroup(
            title: l10n.t(L10n.Settings.hardwareTopology),
            systemImage: "cpu.fill"
        ) {
            hardwareMetricRow(
                label: l10n.t(L10n.Settings.chipModel),
                value: tuner.topology.chipName
            )
            SettingsFormDivider()
            hardwareMetricRow(
                label: l10n.t(L10n.Settings.cpuCores),
                value: l10n.format(
                    L10n.Benchmark.hardwareCoresFormat,
                    tuner.topology.totalCores,
                    tuner.topology.performanceCores,
                    tuner.topology.efficiencyCores
                )
            )
            SettingsFormDivider()
            hardwareMetricRow(
                label: l10n.t(L10n.Settings.unifiedMemory),
                value: l10n.format(L10n.Benchmark.hardwareMemoryFormat, tuner.topology.unifiedMemoryGB)
            )
        }
    }

    private func hardwareMetricRow(label: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .font(TTZipTheme.Typography.subheadline)
                .foregroundStyle(visualStyle.secondaryTextColor)
            Spacer(minLength: 12)
            Text(value)
                .font(TTZipTheme.Typography.bodyMedium)
                .foregroundStyle(visualStyle.primaryTextColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
