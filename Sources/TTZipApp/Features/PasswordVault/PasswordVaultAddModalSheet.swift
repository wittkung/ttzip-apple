// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

public struct PasswordVaultAddModalSheet: View {
    @Binding public var isPresented: Bool
    @State private var newLabel: String = ""
    @State private var newCategory: String = "General"
    @State private var newPassword: String = ""
    @State private var saveError: String = ""
    private var l10n: AppLocalizationState { AppLocalizationState.shared }
    
    public let onSave: (String, String, String) -> VaultEntrySaveResult
    
    public init(isPresented: Binding<Bool>, onSave: @escaping (String, String, String) -> VaultEntrySaveResult) {
        self._isPresented = isPresented
        self.onSave = onSave
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.uiString(zh: "添加密码至安全保险库", en: "Add Password to Secure Vault"))
                .font(.system(size: 14, weight: .bold, design: .serif))
            
            VStack(alignment: .leading, spacing: 10) {
                TextField(l10n.uiString(zh: "密码说明（如：财务数据备份）", en: "Password description (e.g. Financial Data Backup)"), text: $newLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(8)
                    .background(Color.primary.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                
                TextField(l10n.uiString(zh: "分类（如：工作 / 个人 / 通用）", en: "Category (e.g. Work / Personal / General)"), text: $newCategory)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .padding(8)
                    .background(Color.primary.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                
                HStack(spacing: 8) {
                    TextField(l10n.uiString(zh: "密码", en: "Password"), text: $newPassword)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(8)
                        .background(Color.primary.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    
                    Button(l10n.uiString(zh: "生成", en: "Generate")) {
                        newPassword = PasswordVaultManager.shared.generateRandomPassword()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if !saveError.isEmpty {
                Label(saveError, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .font(.system(size: 11))
            }
            
            HStack {
                Spacer()
                Button(l10n.t(L10n.Common.cancel)) { isPresented = false }
                    .buttonStyle(.plain)
                
                Button(l10n.uiString(zh: "保存至加密保险库", en: "Save to Encrypted Vault")) {
                    let pwd = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !pwd.isEmpty else { return }
                    let lbl = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    let labelToUse = lbl.isEmpty ? "Archive Password" : lbl
                    let catToUse = newCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "General" : newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                    let result = onSave(labelToUse, pwd, catToUse)
                    if case .saved = result {
                        saveError = ""
                        isPresented = false
                    } else {
                        saveError = l10n.uiString(
                            zh: "钥匙库未能保存，输入仍保留。请检查文件状态后重试。",
                            en: "The vault could not save. Your input is still here. Check the file and try again."
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(TTZipTheme.bambooGreen)
                .disabled(newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
