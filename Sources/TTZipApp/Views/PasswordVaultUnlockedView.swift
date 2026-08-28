// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Subview displaying saved passwords grid, auto-unlock settings, and action toolbars when vault is unlocked.
public struct PasswordVaultUnlockedView: View {
    @ObservedObject public var l10n: AppLocalizationState
    @ObservedObject public var viewModel: PasswordVaultViewModel
    public var onSelectPassword: ((String) -> Void)?
    
    public init(
        l10n: AppLocalizationState = .shared,
        viewModel: PasswordVaultViewModel,
        onSelectPassword: ((String) -> Void)? = nil
    ) {
        self.l10n = l10n
        self.viewModel = viewModel
        self.onSelectPassword = onSelectPassword
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            
            if viewModel.entries.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "key.radiowaves.forward")
                        .font(.system(size: 42, weight: .ultraLight))
                        .foregroundStyle(TTZipTheme.bambooGreen.opacity(0.4))
                    
                    VStack(spacing: 4) {
                        Text(l10n.t(L10n.Vault.emptyVault))
                            .font(.system(size: 13, weight: .bold))
                        Text(l10n.t(L10n.Vault.noPasswordsSavedPrompt))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 14)], spacing: 14) {
                        ForEach(viewModel.entries) { entry in
                            PasswordVaultEntryRowView(
                                entry: entry,
                                isVisible: viewModel.visiblePasswordIDs.contains(entry.id),
                                isCopied: viewModel.copiedID == entry.id,
                                onToggleVisibility: {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        if viewModel.visiblePasswordIDs.contains(entry.id) {
                                            viewModel.visiblePasswordIDs.remove(entry.id)
                                        } else {
                                            viewModel.visiblePasswordIDs.insert(entry.id)
                                        }
                                    }
                                },
                                onCopy: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.password, forType: .string)
                                    PasswordVaultManager.shared.recordUsage(id: entry.id)
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        viewModel.copiedID = entry.id
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        withAnimation(.easeOut(duration: 0.15)) {
                                            if viewModel.copiedID == entry.id { viewModel.copiedID = nil }
                                        }
                                    }
                                },
                                onDelete: {
                                    withAnimation {
                                        viewModel.deleteEntry(id: entry.id)
                                    }
                                },
                                onSelect: {
                                    PasswordVaultManager.shared.recordUsage(id: entry.id)
                                    onSelectPassword?(entry.password)
                                }
                            )
                            .padding(14)
                            .background(Color.primary.opacity(0.025))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
