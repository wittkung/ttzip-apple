// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

/// License status, Apple Silicon hardware topology, diagnostics log export, and update action pane.
public struct LicenseAndSystemSettingsPane: View {
    @Bindable private var l10n = AppLocalizationState.shared
    private let style: SettingsVisualStyle

    @State private var licenseKeyInput = ""
    @State private var activationStatus = ""
    @State private var isPro = Ed25519LicenseManager.shared.isPro

    public init(style: SettingsVisualStyle) {
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.lg) {
            SettingsCategoryHeader(
                title: l10n.t(L10n.Settings.licenseStatus),
                subtitle: l10n.t(SettingsLocaleKey.licenseSubtitle),
                systemImage: "checkmark.seal",
                style: style
            )

            licenseStatusGroup
            hardwareTopologyGroup
            diagnosticsAndUpdatesGroup
        }
    }

    private var licenseStatusGroup: some View {
        SettingsFormGroup(
            title: l10n.t(L10n.Settings.licenseStatus),
            systemImage: "checkmark.seal.fill",
            trailingHeader: {
                SettingsStatusPill(
                    text: isPro ? l10n.t(L10n.Settings.proLicenseActive) : l10n.t(L10n.Settings.freeEdition),
                    tint: TTZipTheme.bambooGreen
                )
            }
        ) {
            VStack(alignment: .leading, spacing: TTZipTheme.Spacing.xs) {
                licenseBodyContent
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var licenseBodyContent: some View {
        #if MAS_BUILD
        storeEditionRow(
            title: l10n.t(L10n.Settings.macAppStoreLicenseActive),
            subtitle: l10n.t(SettingsLocaleKey.masLicenseSubtitle)
        )
        #elseif STEAM_BUILD
        storeEditionRow(
            title: l10n.t(SettingsLocaleKey.steamEditionTitle),
            subtitle: l10n.t(SettingsLocaleKey.steamEditionSubtitle)
        )
        #else
        directDistributionLicenseContent
        #endif
    }

    private func storeEditionRow(title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(TTZipTheme.Typography.bodyMedium)
                    .foregroundStyle(style.primaryTextColor)
                Text(subtitle)
                    .font(TTZipTheme.Typography.caption)
                    .foregroundStyle(style.secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(TTZipTheme.bambooGreen)
        }
    }

    #if !MAS_BUILD && !STEAM_BUILD
    @ViewBuilder
    private var directDistributionLicenseContent: some View {
        switch Ed25519LicenseManager.shared.currentState {
        case .directPro(let payload):
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.t(L10n.Settings.licenseStatusActive))
                        .font(TTZipTheme.Typography.bodyMedium)
                        .foregroundStyle(style.primaryTextColor)
                    Text(l10n.format(SettingsLocaleKey.directProRegisteredFormat, payload.email, payload.order_id))
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(style.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                SettingsCapsuleButton(
                    title: l10n.t(L10n.Settings.deactivateButton),
                    tone: .neutral,
                    identifier: "settings.license.deactivateButton",
                    action: {
                        Ed25519LicenseManager.shared.deactivate()
                        isPro = false
                        activationStatus = l10n.t(SettingsLocaleKey.licenseDeactivatedNotice)
                    }
                )
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
                    Text(l10n.t(SettingsLocaleKey.communityEditionTitle))
                        .font(TTZipTheme.Typography.bodyMedium)
                        .foregroundStyle(style.primaryTextColor)
                    Text(l10n.t(SettingsLocaleKey.communityEditionSubtitle))
                        .font(TTZipTheme.Typography.caption)
                        .foregroundStyle(style.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(l10n.t(SettingsLocaleKey.communityEditionBadge))
                    .font(TTZipTheme.Typography.caption)
                    .foregroundStyle(style.secondaryTextColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
            }

            Text(l10n.t(SettingsLocaleKey.licenseKeyPrompt))
                .font(TTZipTheme.Typography.caption)
                .foregroundStyle(style.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: TTZipTheme.Spacing.xs) {
                TextField("TTZIP1-<Payload>.<Signature>", text: $licenseKeyInput)
                    .textFieldStyle(.plain)
                    .font(TTZipTheme.Typography.codeCaption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(style.borderColor, lineWidth: style.borderWidth)
                    )
                    .onSubmit(activateLicense)
                    .accessibilityIdentifier("settings.license.keyTextField")

                SettingsCapsuleButton(
                    title: l10n.t(L10n.Settings.activateProButton),
                    tone: .prominent,
                    identifier: "settings.license.activateButton",
                    isEnabled: !licenseKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: activateLicense
                )
            }
        }
    }

    private func activateLicense() {
        let result = Ed25519LicenseManager.shared.activate(licenseKey: licenseKeyInput)
        switch result {
        case .valid(let payload):
            isPro = true
            activationStatus = l10n.format(SettingsLocaleKey.directProRegisteredFormat, payload.email, payload.order_id)
            licenseKeyInput = ""
        case .invalidSignature:
            activationStatus = l10n.t(L10n.Settings.invalidKeyError)
        case .malformedKey(let reason):
            activationStatus = reason
        }
    }
    #endif

    private var hardwareTopologyGroup: some View {
        let tuner = AppleSiliconTuner.shared
        return SettingsFormGroup(
            title: l10n.t(L10n.Settings.hardwareTopology),
            systemImage: "cpu.fill"
        ) {
            SettingsKeyValueRow(
                label: l10n.t(L10n.Settings.chipModel),
                value: tuner.topology.chipName,
                style: style
            )
            SettingsFormDivider()
            SettingsKeyValueRow(
                label: l10n.t(L10n.Settings.cpuCores),
                value: l10n.format(
                    L10n.Benchmark.hardwareCoresFormat,
                    tuner.topology.totalCores,
                    tuner.topology.performanceCores,
                    tuner.topology.efficiencyCores
                ),
                style: style
            )
            SettingsFormDivider()
            SettingsKeyValueRow(
                label: l10n.t(L10n.Settings.unifiedMemory),
                value: l10n.format(L10n.Benchmark.hardwareMemoryFormat, Int(tuner.topology.unifiedMemoryGB.rounded())),
                style: style
            )
        }
    }

    private var diagnosticsAndUpdatesGroup: some View {
        SettingsFormGroup(
            title: l10n.t(SettingsLocaleKey.systemDiagnosticsHeader),
            systemImage: "stethoscope"
        ) {
            SettingsActionRow(
                title: l10n.t(L10n.Menu.revealLogsInFinder),
                style: style
            ) {
                SettingsCapsuleButton(
                    title: l10n.t(L10n.Menu.revealLogsInFinder),
                    systemImage: "folder",
                    tone: .neutral,
                    identifier: "settings.system.revealLogsButton",
                    action: { DiagnosticsSupportService.revealLogsInFinder() }
                )
            }

            SettingsFormDivider()

            SettingsActionRow(
                title: l10n.t(L10n.Menu.exportDiagnosticReport),
                subtitle: l10n.t(SettingsLocaleKey.diagnosticsDesc),
                style: style
            ) {
                SettingsCapsuleButton(
                    title: l10n.t(L10n.Menu.exportDiagnosticReport),
                    systemImage: "doc.zipper",
                    tone: .neutral,
                    identifier: "settings.system.exportDiagnosticsButton",
                    action: { DiagnosticsSupportService.exportDiagnosticReport() }
                )
            }

            if let checkForUpdates = DiagnosticsSupportService.manualUpdateHandler {
                SettingsFormDivider()
                SettingsActionRow(
                    title: l10n.t(L10n.Menu.checkForUpdates),
                    subtitle: l10n.t(SettingsLocaleKey.checkForUpdatesDesc),
                    style: style
                ) {
                    SettingsCapsuleButton(
                        title: l10n.t(L10n.Menu.checkForUpdates),
                        systemImage: "arrow.triangle.2.circlepath",
                        tone: .prominent,
                        identifier: "settings.system.checkForUpdatesButton",
                        action: checkForUpdates
                    )
                }
            }
        }
    }
}
