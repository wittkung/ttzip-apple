// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore

public struct PasswordPromptSheetView: View {
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    let archivePath: String
    let onSubmitPassword: (String) async -> Bool
    let onCancel: () -> Void
    
    @State private var passwordInput: String = ""
    @State private var showPasswordMask: Bool = false
    @State private var isVerifying: Bool = false
    @State private var errorMessage: String? = nil
    @FocusState private var isPasswordFieldFocused: Bool
    
    @State private var showVaultPopover: Bool = false
    @State private var vaultMasterPasswordInput: String = ""
    @State private var masterPasswordError: Bool = false
    @State private var vaultUpdateTrigger: Int = 0
    
    public init(
        archivePath: String,
        onSubmitPassword: @escaping (String) async -> Bool,
        onCancel: @escaping () -> Void
    ) {
        self.archivePath = archivePath
        self.onSubmitPassword = onSubmitPassword
        self.onCancel = onCancel
    }
    
    private var isVaultUnlocked: Bool {
        _ = vaultUpdateTrigger
        return PasswordVaultManager.shared.isUnlocked
    }
    
    private var isMasterPasswordSet: Bool {
        _ = vaultUpdateTrigger
        return PasswordVaultManager.shared.isMasterPasswordSet
    }
    
    private var vaultEntries: [PasswordVaultEntry] {
        _ = vaultUpdateTrigger
        return PasswordVaultManager.shared.getEntries()
    }
    
    private var archiveFileName: String {
        (archivePath as NSString).lastPathComponent
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            
            Rectangle()
                .fill(TTZipTheme.kintsugiGold)
                .frame(height: 1.5)
            
            contentSection
            
            footerBar
        }
        .frame(width: 540)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow, state: .active)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [TTZipTheme.kintsugiGold.opacity(0.4), Color.primary.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
        .onReceive(NotificationCenter.default.publisher(for: PasswordVaultManager.vaultDidChangeNotification)) { _ in
            vaultUpdateTrigger += 1
        }
        .task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            isPasswordFieldFocused = true
        }
    }
    
    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                Text(l10n.t(L10n.Extract.passwordPrompt))
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
            }
            
            Spacer()
            
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                Text(archiveFileName)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(TTZipTheme.bambooGreen.opacity(0.12))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(TTZipTheme.bambooGreen.opacity(0.3), lineWidth: 0.8)
            )
            
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(l10n.t(L10n.Common.cancel))
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
    }
    
    @ViewBuilder
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(l10n.t(L10n.Sidebar.vault))
                        .font(.system(size: 10, weight: .bold, design: .serif))
                        .tracking(1.5)
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                    Spacer()
                    Text(l10n.t(L10n.Vault.passwordPlaceholder))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                        
                        TextField(l10n.t(L10n.Vault.passwordPlaceholder), text: $passwordInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .focused($isPasswordFieldFocused)
                            .onSubmit { submit() }
                        
                        Button {
                            showPasswordMask.toggle()
                        } label: {
                            Image(systemName: showPasswordMask ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isPasswordFieldFocused ? TTZipTheme.bambooGreen : Color.primary.opacity(0.08), lineWidth: isPasswordFieldFocused ? 1.2 : 0.8)
                    )
                    
                    Button {
                        showVaultPopover.toggle()
                    } label: {
                        vaultButtonLabel
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showVaultPopover, arrowEdge: .bottom) {
                        vaultPopoverContent
                    }
                }
                
                if isVaultUnlocked && !vaultEntries.isEmpty {
                    savedCredentialsList
                }
            }
            .padding(18)
            .background(Color.primary.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.8)
            )
            
            if let err = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                    Text(err)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(TTZipTheme.cinnabarRed)
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(22)
    }
    
    @ViewBuilder
    private var savedCredentialsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l10n.t(L10n.Vault.title))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vaultEntries.prefix(5)) { entry in
                        Button(action: {
                            passwordInput = entry.password
                            submit()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "key.fill")
                                    .font(.system(size: 8.5))
                                Text(entry.label)
                                    .font(.system(size: 10.5, weight: .bold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                            .background(TTZipTheme.bambooGreen.opacity(0.12))
                            .foregroundStyle(TTZipTheme.bambooGreen)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().strokeBorder(TTZipTheme.bambooGreen.opacity(0.25), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 2)
    }
    
    @ViewBuilder
    private var footerBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
            
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "shield.checkmark.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                    Text("AES-256 / ZipCrypto Hardware Acceleration")
                        .font(.system(size: 10, weight: .semibold, design: .serif))
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(l10n.t(L10n.Common.cancel)) {
                        onCancel()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7.5)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
                    .disabled(isVerifying)
                    .keyboardShortcut(.escape, modifiers: [])
                    
                    Button {
                        submit()
                    } label: {
                        HStack(spacing: 6) {
                            if isVerifying {
                                ProgressView()
                                    .controlSize(.small)
                                Text(l10n.t(L10n.Common.processing))
                                    .font(.system(size: 12, weight: .bold))
                            } else {
                                Text(l10n.t(L10n.Vault.unlockButton))
                                    .font(.system(size: 12, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 7.5)
                        .background(
                            passwordInput.isEmpty || isVerifying ?
                            TTZipTheme.bambooGreen.opacity(0.35) : TTZipTheme.bambooGreen
                        )
                        .foregroundStyle(
                            passwordInput.isEmpty || isVerifying ?
                            Color.white.opacity(0.6) : Color.white
                        )
                        .clipShape(Capsule())
                        .shadow(color: passwordInput.isEmpty || isVerifying ? Color.clear : TTZipTheme.bambooGreen.opacity(0.35), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(passwordInput.isEmpty || isVerifying)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.015))
        }
    }
    
    @ViewBuilder
    private var vaultButtonLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "rectangle.stack.badge.person.crop.fill")
                .font(.system(size: 11))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(l10n.t(L10n.Sidebar.vault))
                .font(.system(size: 11, weight: .bold))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(TTZipTheme.bambooGreen.opacity(0.12))
        .foregroundStyle(TTZipTheme.bambooGreen)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TTZipTheme.bambooGreen.opacity(0.3), lineWidth: 0.8)
        )
    }
    
    private func submit() {
        guard !passwordInput.isEmpty, !isVerifying else { return }
        isVerifying = true
        errorMessage = nil
        
        Task { @MainActor in
            let success = await onSubmitPassword(passwordInput)
            isVerifying = false
            if !success {
                errorMessage = l10n.t(L10n.Errors.incorrectPassword)
            }
        }
    }
    
    @ViewBuilder
    private var vaultPopoverContent: some View {
        PasswordVaultView { selectedPwd in
            passwordInput = selectedPwd
            showVaultPopover = false
        }
        .frame(width: 400, height: 460)
    }
}
