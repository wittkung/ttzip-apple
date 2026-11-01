// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

/// Master password setup and unlock controls for the locked vault.
public struct PasswordVaultLockedView: View {
    public var l10n: AppLocalizationState
    @Bindable public var viewModel: PasswordVaultViewModel
    @FocusState.Binding public var isMasterPasswordFocused: Bool

    public init(
        l10n: AppLocalizationState = .shared,
        viewModel: PasswordVaultViewModel,
        isMasterPasswordFocused: FocusState<Bool>.Binding
    ) {
        self.l10n = l10n
        self.viewModel = viewModel
        self._isMasterPasswordFocused = isMasterPasswordFocused
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: viewModel.isMasterPasswordSet ? "lock.shield" : "key.fill")
                        .font(.title2)
                        .foregroundStyle(TTZipTheme.bambooGreen)
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(viewModel.isMasterPasswordSet
                             ? l10n.uiString(zh: "解锁钥匙库", en: "Unlock vault")
                             : l10n.uiString(zh: "设置主密码", en: "Set master password"))
                            .font(.headline)
                        Text(viewModel.isMasterPasswordSet
                             ? l10n.uiString(zh: "输入主密码，或使用此设备上已启用的 Touch ID。", en: "Enter your master password or use Touch ID enabled on this device.")
                             : l10n.uiString(zh: "主密码用于保护已保存的归档密码。", en: "Your master password protects saved archive passwords."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(l10n.uiString(zh: "主密码", en: "Master password"))
                        .font(.subheadline.weight(.medium))

                    TTSecureTextField(l10n.uiString(zh: "输入主密码", en: "Enter master password"), text: $viewModel.masterPasswordInput)
                        .focused($isMasterPasswordFocused)
                        .font(.body)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    if !viewModel.isMasterPasswordSet {
                        TTSecureTextField(l10n.uiString(zh: "再次输入主密码", en: "Confirm master password"), text: $viewModel.confirmMasterPasswordInput)
                            .font(.body)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    if !viewModel.unlockErrorMessage.isEmpty {
                        Label(viewModel.unlockErrorMessage, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(TTZipTheme.cinnabarRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button(viewModel.isMasterPasswordSet
                               ? l10n.t(L10n.Vault.unlockButton)
                               : l10n.uiString(zh: "创建钥匙库", en: "Create vault")) {
                            if viewModel.isMasterPasswordSet {
                                viewModel.unlockVault()
                            } else {
                                viewModel.setupFirstMasterPassword()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TTZipTheme.bambooGreen)
                        .keyboardShortcut(.return, modifiers: [])
                        .disabled(viewModel.isUnlocking || viewModel.masterPasswordInput.isEmpty ||
                                  (!viewModel.isMasterPasswordSet && viewModel.confirmMasterPasswordInput.isEmpty))

                        if viewModel.isMasterPasswordSet && viewModel.isBiometricAvailable && !viewModel.isBiometricKeyMissing {
                            Button {
                                viewModel.authenticateWithBiometrics()
                            } label: {
                                Label("Touch ID", systemImage: "touchid")
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isUnlocking)
                        }

                        if viewModel.isUnlocking {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel(l10n.uiString(zh: "正在解锁", en: "Unlocking"))
                        }
                    }
                    .controlSize(.large)

                    if viewModel.isMasterPasswordSet {
                        Button(l10n.uiString(zh: "无法使用旧主密码？备份并重设钥匙库", en: "Forgot the old master password? Back up and reset vault")) {
                            viewModel.resetErrorMessage = ""
                            viewModel.isResetSheetPresented = true
                        }
                        .buttonStyle(.plain)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }

                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
