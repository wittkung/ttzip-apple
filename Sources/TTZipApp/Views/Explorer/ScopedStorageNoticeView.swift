// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI

/// Lock badge and inline guidance callout explaining Android 11+ Scoped Storage restrictions.
public struct ScopedStorageNoticeView: View {
    public let restrictedPath: String
    public var onEnableAdbRequested: (() -> Void)? = nil
    public var onDismiss: (() -> Void)? = nil
    
    @ObservedObject private var l10n = AppLocalizationState.shared
    
    public init(
        restrictedPath: String = "/Android/data",
        onEnableAdbRequested: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.restrictedPath = restrictedPath
        self.onEnableAdbRequested = onEnableAdbRequested
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header with lock icon and title
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(TTZipTheme.archiveAmber.opacity(0.15))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(TTZipTheme.archiveAmber)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.currentLanguage == .zhHans ? "Android 系统受限存储保护" : "Android Scoped Storage Restriction")
                        .font(.system(size: 13, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)
                    
                    Text(restrictedPath)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer(minLength: 0)
                
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            
            // Explanatory Body
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n.currentLanguage == .zhHans
                     ? "在标准 USB 文件传输 (MTP) 模式下，Android 11 及更高版本对应用私有数据目录（/Android/data 与 /Android/obb）实施了系统级访问阻断。"
                     : "Under standard USB File Transfer (MTP) mode, Android 11+ enforces system-level access isolation over app private directories (/Android/data and /Android/obb).")
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "bolt.badge.checkmark.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    
                    Text(l10n.currentLanguage == .zhHans
                         ? "开启手机的「USB 调试」后，TTZip 将自动切换至高速 ADB 协议通道，无需 Root 即可 100% 读写私有应用目录并提升传输速度至 100x。"
                         : "Enabling 'USB Debugging' allows TTZip to switch to the high-speed ADB protocol channel, penetrating private app folders with 100% read/write access and 100x folder traversal speed without root.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(TTZipTheme.bambooGreen.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(TTZipTheme.bambooGreen.opacity(0.2), lineWidth: 0.8)
                )
            }
            
            // Action Button
            HStack {
                Spacer()
                
                Button(action: {
                    onEnableAdbRequested?()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text(l10n.currentLanguage == .zhHans ? "查看如何开启高速调试模式" : "Enable High-Speed ADB Mode")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(TTZipTheme.bambooGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: TTZipTheme.bambooGreen.opacity(0.25), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(TTZipTheme.paperWhite)
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(TTZipTheme.kintsugiGold.opacity(0.35), lineWidth: 0.8)
        )
        .frame(maxWidth: 380)
    }
}
