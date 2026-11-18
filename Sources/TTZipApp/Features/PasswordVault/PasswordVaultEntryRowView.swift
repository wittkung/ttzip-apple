// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

public struct PasswordVaultEntryRowView: View {
    public let entry: PasswordVaultEntry
    public let isVisible: Bool
    public let isCopied: Bool
    
    public let onToggleVisibility: () -> Void
    public let onCopy: () -> Void
    public let onDelete: () -> Void
    public let onSelect: () -> Void
    private var l10n: AppLocalizationState { AppLocalizationState.shared }
    
    public init(
        entry: PasswordVaultEntry,
        isVisible: Bool,
        isCopied: Bool,
        onToggleVisibility: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSelect: @escaping () -> Void
    ) {
        self.entry = entry
        self.isVisible = isVisible
        self.isCopied = isCopied
        self.onToggleVisibility = onToggleVisibility
        self.onCopy = onCopy
        self.onDelete = onDelete
        self.onSelect = onSelect
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.label)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary)
                        
                        Text(entry.category)
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(TTZipTheme.bambooGreen.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    
                    if let lastUsed = entry.lastUsedAt {
                        Text(l10n.uiString(zh: "上次使用：\(DateFormatterCache.shared.string(fromShortDateTime: lastUsed))", en: "Last used: \(DateFormatterCache.shared.string(fromShortDateTime: lastUsed))"))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                
                Spacer()
                
                Button(action: onSelect) {
                    HStack(spacing: 4) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 10))
                        Text(l10n.uiString(zh: "使用密码", en: "Use Password"))
                            .font(.system(size: 10.5, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(TTZipTheme.kintsugiGold.opacity(0.14))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            
            Divider()
            
            HStack {
                if isVisible {
                    Text(entry.password)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                } else {
                    Text("••••••••••••")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                HStack(spacing: 6) {
                    Button(action: onToggleVisibility) {
                        Image(systemName: isVisible ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isVisible ? "Hide Password" : "Show Password")
                    .help(isVisible ? "Hide Password" : "Show Password")
                    
                    Button(action: onCopy) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(isCopied ? TTZipTheme.bambooGreen : Color.secondary)
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCopied ? "Password Copied" : "Copy Password")
                    .help("Copy Password")
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(TTZipTheme.cinnabarRed)
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete Password")
                    .help("Delete Password")
                }
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}
