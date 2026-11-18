// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

/// Password Vault Settings pane exposing auto-unlock preference, live lock state, quick lock action, and security specs.
public struct VaultSettingsPane: View {
    @Bindable private var l10n = AppLocalizationState.shared
    private let vaultManager: PasswordVaultManager
    private let style: SettingsVisualStyle
    private let onOpenVault: (() -> Void)?

    @State private var isUnlocked: Bool
    @State private var isInitialized: Bool
    @State private var entryCount: Int
    @State private var autoUnlockEnabled: Bool

    public init(
        vaultManager: PasswordVaultManager = .shared,
        style: SettingsVisualStyle,
        onOpenVault: (() -> Void)? = nil
    ) {
        self.vaultManager = vaultManager
        self.style = style
        self.onOpenVault = onOpenVault
        self._isUnlocked = State(initialValue: vaultManager.isUnlocked)
        self._isInitialized = State(initialValue: vaultManager.isMasterPasswordSet)
        self._entryCount = State(initialValue: vaultManager.getEntries().count)
        self._autoUnlockEnabled = State(initialValue: vaultManager.autoUnlockArchives)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TTZipTheme.Spacing.lg) {
            SettingsCategoryHeader(
                title: l10n.t(L10n.Vault.title),
                subtitle: l10n.t(SettingsLocaleKey.vaultSubtitle),
                systemImage: "lock.shield",
                style: style
            )

            statusAndPreferencesGroup
            cryptographicSpecsGroup
        }
        .onAppear {
            refreshSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: PasswordVaultManager.vaultDidChangeNotification)) { _ in
            refreshSnapshot()
        }
    }

    private var statusAndPreferencesGroup: some View {
        SettingsFormGroup(
            title: l10n.t(SettingsLocaleKey.vaultStatusHeader),
            systemImage: "key.fill",
            trailingHeader: {
                SettingsStatusPill(
                    text: statusPillTitle,
                    tint: statusPillTint,
                    identifier: "settings.vault.statusPill"
                )
            }
        ) {
            SettingsToggleRow(
                title: l10n.t(SettingsLocaleKey.autoUnlockTitle),
                subtitle: l10n.t(SettingsLocaleKey.autoUnlockDesc),
                style: style,
                isOn: Binding(
                    get: { autoUnlockEnabled },
                    set: { enabled in
                        autoUnlockEnabled = enabled
                        vaultManager.autoUnlockArchives = enabled
                    }
                ),
                accessibilityIdentifier: "settings.vault.autoUnlockToggle"
            )

            SettingsFormDivider()

            statusActionRow
        }
    }

    private var statusActionRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(statusSummaryText)
                .font(TTZipTheme.Typography.callout)
                .foregroundStyle(style.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.vault.summaryText")

            Spacer(minLength: 12)

            if isUnlocked {
                SettingsCapsuleButton(
                    title: l10n.t(L10n.Vault.lockVault),
                    systemImage: "lock.fill",
                    tone: .destructive,
                    identifier: "settings.vault.lockButton",
                    action: {
                        vaultManager.lockVault()
                        refreshSnapshot()
                    }
                )
            }

            if let onOpenVault {
                SettingsCapsuleButton(
                    title: l10n.t(SettingsLocaleKey.openVaultWorkspaceAction),
                    systemImage: "arrow.up.forward.app",
                    tone: .neutral,
                    identifier: "settings.vault.openWorkspaceButton",
                    action: onOpenVault
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var cryptographicSpecsGroup: some View {
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
                .foregroundStyle(style.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var statusPillTitle: String {
        if isUnlocked {
            return l10n.t(SettingsLocaleKey.vaultStateUnlocked)
        }
        if isInitialized {
            return l10n.t(SettingsLocaleKey.vaultStateLocked)
        }
        return l10n.t(SettingsLocaleKey.vaultStateUninitialized)
    }

    private var statusPillTint: Color {
        if isUnlocked {
            return TTZipTheme.bambooGreen
        }
        if isInitialized {
            return TTZipTheme.archiveAmber
        }
        return .secondary
    }

    private var statusSummaryText: String {
        if isUnlocked {
            return l10n.format(SettingsLocaleKey.savedCredentialsCountFormat, entryCount)
        }
        return l10n.t(L10n.Vault.unlockPrompt)
    }

    private func refreshSnapshot() {
        isUnlocked = vaultManager.isUnlocked
        isInitialized = vaultManager.isMasterPasswordSet
        entryCount = vaultManager.getEntries().count
        autoUnlockEnabled = vaultManager.autoUnlockArchives
    }
}
