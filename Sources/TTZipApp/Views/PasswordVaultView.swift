// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import LocalAuthentication
import TTZipUI

/// Keychain and password safe vault view.
public struct PasswordVaultView: View {
    private var l10n = AppLocalizationState.shared
    @State private var viewModel: PasswordVaultViewModel
    @FocusState private var isMasterPasswordFocused: Bool
    
    var onSelectPassword: ((String) -> Void)? = nil
    
    @MainActor
    public init(viewModel: PasswordVaultViewModel? = nil, onSelectPassword: ((String) -> Void)? = nil) {
        self._viewModel = State(initialValue: viewModel ?? PasswordVaultViewModel())
        self.onSelectPassword = onSelectPassword
    }
    
    public var body: some View {
        TTZipWorkspaceScaffold(
            title: l10n.t(L10n.Vault.title),
            isCardEnclosed: viewModel.isUnlocked
        ) {
            headerTrailingControls
        } content: {
            Group {
                if !viewModel.isUnlocked {
                    PasswordVaultLockedView(
                        l10n: l10n,
                        viewModel: viewModel,
                        isMasterPasswordFocused: $isMasterPasswordFocused
                    )
                } else {
                    PasswordVaultUnlockedView(
                        l10n: l10n,
                        viewModel: viewModel,
                        onSelectPassword: onSelectPassword
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $viewModel.isAddModalPresented) {
            PasswordVaultAddModalSheet(isPresented: $viewModel.isAddModalPresented) { labelToUse, pwd, catToUse in
                let result = viewModel.manager.addEntryVerified(label: labelToUse, password: pwd, category: catToUse)
                if case .saved = result { viewModel.refreshState() }
                return result
            }
        }
        .sheet(isPresented: $viewModel.isResetSheetPresented) {
            PasswordVaultResetSheet(viewModel: viewModel)
        }
        .alert(l10n.uiString(zh: "新钥匙库已建立", en: "New vault created"), isPresented: $viewModel.isResetBackupNoticePresented) {
            Button(l10n.uiString(zh: "显示加密备份", en: "Show encrypted backup")) {
                if let location = viewModel.resetBackupLocation {
                    NSWorkspace.shared.activateFileViewerSelecting([location])
                }
            }
            Button(l10n.t(L10n.Common.close), role: .cancel) {}
        } message: {
            Text(l10n.uiString(zh: "旧加密库与配置已保留在备份目录。旧条目需要旧主密码才能读取。", en: "The old encrypted vault and configuration are preserved in the backup folder. The old master password is needed to read those entries."))
        }
        .sheet(isPresented: $viewModel.isRecoverSheetPresented) {
            PasswordVaultRecoverSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isRecoverySheetPresented) {
            PasswordVaultRecoveryModalSheet(viewModel: viewModel)
        }
        .onAppear {
            viewModel.refreshState()
            viewModel.refreshBiometricAvailability()
        }
        .onDisappear { viewModel.cancelPendingUnlock() }
        .onReceive(NotificationCenter.default.publisher(for: PasswordVaultManager.vaultDidChangeNotification)) { _ in
            viewModel.refreshState()
        }
    }
    
    @ViewBuilder
    private var headerTrailingControls: some View {
        if viewModel.isUnlocked {
            HStack(spacing: 8) {
                Toggle(isOn: $viewModel.autoUnlockArchives) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.shield.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                        Text(l10n.uiString(zh: "自动解锁", en: "Auto-Unlock"))
                            .font(.system(size: 10.5, weight: .bold))
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(TTZipTheme.bambooGreen)
                
                Button(action: { viewModel.isRecoverySheetPresented = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.badge.clock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                        Text(l10n.uiString(zh: "密码找回", en: "Recovery"))
                            .font(.system(size: 10.5, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                
                Button(action: { viewModel.lockVault() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                        Text(l10n.t(L10n.Vault.lockVault))
                            .font(.system(size: 10.5, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                
                Button(action: { viewModel.isAddModalPresented = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(l10n.t(L10n.Vault.addPassword))
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(TTZipTheme.bambooGreen)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                Text(l10n.t(L10n.Vault.lockVault))
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(TTZipTheme.kintsugiGold.opacity(0.12))
            .clipShape(Capsule())
        }
    }
}
