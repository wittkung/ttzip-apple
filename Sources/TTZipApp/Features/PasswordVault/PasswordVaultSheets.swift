// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI

/// Reset master password sheet.
public struct PasswordVaultResetSheet: View {
    @Bindable public var viewModel: PasswordVaultViewModel
    private var l10n: AppLocalizationState { AppLocalizationState.shared }
    
    public init(viewModel: PasswordVaultViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(l10n.uiString(zh: "备份并重设钥匙库", en: "Back Up and Reset Vault"))
                    .font(.system(size: 16, weight: .bold))
                Text(l10n.uiString(zh: "先备份当前钥匙库的加密文件和配置，再建立空白钥匙库。旧条目不会自动转入新库；以后仍需旧主密码才能读取备份。", en: "The encrypted vault and its configuration will be backed up before creating an empty vault. Old entries will not transfer; the old master password is still required to read the backup."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            TTSecureTextField(l10n.uiString(zh: "新主密码", en: "New Master Password"), text: $viewModel.newMasterPasswordInput)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .frame(width: 280)

            TTSecureTextField(l10n.uiString(zh: "再次输入新主密码", en: "Confirm New Master Password"), text: $viewModel.confirmNewMasterPasswordInput)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(width: 280)

            if !viewModel.resetErrorMessage.isEmpty {
                Text(viewModel.resetErrorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(TTZipTheme.cinnabarRed)
            }
            
            HStack(spacing: 12) {
                Button(l10n.t(L10n.Common.cancel)) {
                    viewModel.isResetSheetPresented = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
                
                Button(l10n.uiString(zh: "备份并重设", en: "Back Up and Reset")) {
                    viewModel.resetVault()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(TTZipTheme.cinnabarRed)
                .clipShape(Capsule())
                .disabled(viewModel.newMasterPasswordInput.isEmpty || viewModel.confirmNewMasterPasswordInput.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

/// Recover vault backup sheet.
public struct PasswordVaultRecoverSheet: View {
    @Bindable public var viewModel: PasswordVaultViewModel
    private var l10n: AppLocalizationState { AppLocalizationState.shared }
    
    public init(viewModel: PasswordVaultViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text(l10n.uiString(zh: "恢复保险库备份", en: "Restore Vault Backup"))
                    .font(.system(size: 16, weight: .bold))
                Text(l10n.uiString(zh: "请输入创建此备份时使用的历史主密码。", en: "Enter the historical master password used when this backup was created."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            TTSecureTextField(l10n.uiString(zh: "历史主密码", en: "Historical Master Password"), text: $viewModel.oldMasterPasswordInput)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .frame(width: 280)
            
            if !viewModel.recoverErrorMessage.isEmpty {
                Text(viewModel.recoverErrorMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TTZipTheme.cinnabarRed)
            }
            
            HStack(spacing: 12) {
                Button(l10n.t(L10n.Common.cancel)) {
                    viewModel.isRecoverSheetPresented = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
                
                Button(l10n.uiString(zh: "验证并恢复", en: "Verify & Restore")) {
                    viewModel.recoverVault()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(TTZipTheme.bambooGreen)
                .clipShape(Capsule())
                .disabled(viewModel.oldMasterPasswordInput.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

/// Multi-core parallel archive password recovery sheet.
public struct PasswordVaultRecoveryModalSheet: View {
    @Bindable public var viewModel: PasswordVaultViewModel
    @State private var customDictionaryText: String = ""
    private var l10n: AppLocalizationState { AppLocalizationState.shared }
    
    public init(viewModel: PasswordVaultViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            targetArchiveSection
            candidateWordsSection
            if !viewModel.recoveryStatusMessage.isEmpty {
                statusMessageSection
            }
            if !viewModel.entryErrorMessage.isEmpty {
                Text(viewModel.entryErrorMessage)
                    .font(.subheadline)
                    .foregroundStyle(TTZipTheme.cinnabarRed)
            }
            footerActionsSection
        }
        .padding(20)
        .frame(width: 480)
    }
    
    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.badge.clock.fill")
                .font(.system(size: 18))
                .foregroundStyle(TTZipTheme.bambooGreen)
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.uiString(zh: "多核并行密码找回", en: "Parallel Multi-Core Password Recovery"))
                    .font(.system(size: 14, weight: .bold, design: .serif))
                Text(l10n.uiString(zh: "基于原生 Rust Rayon 与 SIMD 多线程字典高速碰撞", en: "Powered by native Rust Rayon & SIMD multi-threaded dictionary exploration"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private var targetArchiveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.uiString(zh: "目标加密归档", en: "Target Encrypted Archive"))
                .font(.system(size: 11, weight: .semibold))
            
            HStack(spacing: 8) {
                TextField(l10n.uiString(zh: "选择归档文件（.zip、.7z 等）", en: "Select archive (.zip, .7z, etc.)"), text: $viewModel.recoveryArchivePath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
                    .background(Color.primary.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                
                Button(l10n.uiString(zh: "浏览...", en: "Browse...")) {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.recoveryArchivePath = url.path
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
    
    @ViewBuilder
    private var candidateWordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.uiString(zh: "附加候选词（逗号或换行分隔）", en: "Additional Candidate Words (comma or newline separated)"))
                .font(.system(size: 11, weight: .semibold))
            
            TextEditor(text: $customDictionaryText)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 60)
                .padding(4)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
    
    @ViewBuilder
    private var statusMessageSection: some View {
        HStack(spacing: 8) {
            if viewModel.isRecoveringPassword {
                ProgressView().scaleEffect(0.8)
            }
            Text(viewModel.recoveryStatusMessage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(viewModel.recoveryResult?.foundPassword != nil ? TTZipTheme.bambooGreen : .primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    @ViewBuilder
    private var footerActionsSection: some View {
        HStack {
            if let found = viewModel.recoveryResult?.foundPassword {
                Button(l10n.uiString(zh: "保存至保险库", en: "Save to Vault")) {
                    let stem = (viewModel.recoveryArchivePath as NSString).lastPathComponent
                    viewModel.saveRecoveredPasswordToVault(label: "Recovered: \(stem)", password: found)
                }
                .buttonStyle(.borderedProminent)
                .tint(TTZipTheme.kintsugiGold)
                .controlSize(.small)
            }
            
            Spacer()
            
            Button(l10n.t(L10n.Common.close)) {
                viewModel.isRecoverySheetPresented = false
            }
            .buttonStyle(.plain)
            
            Button(viewModel.isRecoveringPassword ? l10n.uiString(zh: "正在探索...", en: "Exploring...") : l10n.uiString(zh: "开始找回", en: "Start Recovery")) {
                let words = customDictionaryText
                    .components(separatedBy: CharacterSet(charactersIn: ",\n\r\t "))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                Task {
                    await viewModel.runParallelPasswordRecovery(archivePath: viewModel.recoveryArchivePath, customCandidates: words)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(TTZipTheme.bambooGreen)
            .disabled(viewModel.recoveryArchivePath.isEmpty || viewModel.isRecoveringPassword)
        }
    }
}
