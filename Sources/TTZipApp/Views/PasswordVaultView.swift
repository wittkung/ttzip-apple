// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import LocalAuthentication
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Keychain and password safe vault view.
public struct PasswordVaultView: View {
    @ObservedObject private var l10n = AppLocalizationState.shared
    @StateObject private var viewModel: PasswordVaultViewModel
    @FocusState private var isMasterPasswordFocused: Bool
    
    var onSelectPassword: ((String) -> Void)? = nil
    
    public init(viewModel: PasswordVaultViewModel = PasswordVaultViewModel(), onSelectPassword: ((String) -> Void)? = nil) {
        self._viewModel = StateObject(wrappedValue: viewModel)
        self.onSelectPassword = onSelectPassword
    }
    
    public var body: some View {
        TTZipWorkspaceScaffold(
            title: l10n.t(L10n.Vault.title),
            isCardEnclosed: true
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
                PasswordVaultManager.shared.addEntry(label: labelToUse, password: pwd, category: catToUse)
                viewModel.refreshState()
            }
        }
        .sheet(isPresented: $viewModel.isResetSheetPresented) {
            PasswordVaultResetSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isRecoverSheetPresented) {
            PasswordVaultRecoverSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isRecoverySheetPresented) {
            PasswordVaultRecoveryModalSheet(viewModel: viewModel)
        }
        .onAppear {
            if !viewModel.isUnlocked {
                isMasterPasswordFocused = true
            }
            viewModel.refreshState()
        }
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
                        Text("Auto-Unlock")
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
                        Text("Recovery")
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
