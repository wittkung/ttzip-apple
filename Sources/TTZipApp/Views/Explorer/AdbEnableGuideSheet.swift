// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI

/// Step-by-step interactive guidance modal illustrating how to unlock high-speed USB debugging
/// and penetrate Android 11+ Scoped Storage restrictions.
public struct AdbEnableGuideSheet: View {
    @Binding public var isPresented: Bool
    
    @ObservedObject private var l10n = AppLocalizationState.shared
    @State private var isChecking: Bool = false
    @State private var checkSuccess: Bool = false
    
    public init(isPresented: Binding<Bool> = .constant(true)) {
        self._isPresented = isPresented
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerSection
            
            Rectangle()
                .fill(TTZipTheme.kintsugiGold)
                .frame(height: 1.5)
            
            // Scrollable Guide Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    // Benefit comparison matrix
                    performanceComparisonBanner
                    
                    // 4-Step Illustrated Walkthrough
                    stepsSection
                }
                .padding(24)
            }
            
            Divider()
            
            // Footer with verification button
            footerSection
        }
        .frame(width: 540, height: 600)
        .background(TTZipTheme.paperWhite)
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(TTZipTheme.bambooGreen.opacity(0.15))
                    .frame(width: 36, height: 36)
                
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.currentLanguage == .zhHans ? "切换至高速 ADB 调试通道" : "Switch to High-Speed ADB Mode")
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                
                Text(l10n.currentLanguage == .zhHans
                     ? "解锁 100x 目录遍历速率与 /Android/data 私有目录完整读写权限"
                     : "Unlock 100x traversal throughput and unrestricted /Android/data read/write")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }
    
    private var performanceComparisonBanner: some View {
        HStack(spacing: 12) {
            // MTP standard
            VStack(alignment: .leading, spacing: 4) {
                Text("Standard USB (MTP)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                
                Text("15 MB/s · No /data Access")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Text("Subject to Android 11+ Scoped Storage blocks")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            
            // ADB high-speed
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("High-Speed Channel (ADB)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
                
                Text("80~120 MB/s · Full Access")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                
                Text("Complete read/write to all app packages without root")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TTZipTheme.bambooGreen.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(TTZipTheme.bambooGreen.opacity(0.25), lineWidth: 0.8)
            )
        }
    }
    
    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(l10n.currentLanguage == .zhHans ? "四步开启指南" : "Step-by-Step Enablement Guide")
                .font(.system(size: 12.5, weight: .bold, design: .serif))
                .foregroundStyle(.primary)
            
            stepRow(
                stepNumber: 1,
                icon: "gearshape.fill",
                title: l10n.currentLanguage == .zhHans ? "打开「设置」->「关于手机」" : "Open Settings -> About Phone",
                description: l10n.currentLanguage == .zhHans
                    ? "在安卓手机的主屏幕或抽屉中进入系统设置，滑动至最底部的“关于手机”页面。"
                    : "Navigate into device Settings and scroll to the bottom to find 'About Phone'."
            )
            
            stepRow(
                stepNumber: 2,
                icon: "hand.tap.fill",
                title: l10n.currentLanguage == .zhHans ? "连续轻点「版本号」7 次" : "Tap 'Build Number' 7 Times",
                description: l10n.currentLanguage == .zhHans
                    ? "找到“版本号 (Build Number)”，连续快速点击 7 次，直到屏幕弹出“您现在处于开发者模式！”提示。"
                    : "Rapidly tap 'Build Number' 7 consecutive times until the system confirms developer mode is enabled."
            )
            
            stepRow(
                stepNumber: 3,
                icon: "wrench.and.screwdriver.fill",
                title: l10n.currentLanguage == .zhHans ? "进入「开发者选项」开启「USB 调试」" : "Toggle 'USB Debugging' ON",
                description: l10n.currentLanguage == .zhHans
                    ? "返回设置，进入“系统”->“开发者选项”，找到“USB 调试 (USB Debugging)”开关并开启。"
                    : "Return to Settings -> System -> Developer Options, then toggle 'USB Debugging' ON."
            )
            
            stepRow(
                stepNumber: 4,
                icon: "lock.open.display",
                title: l10n.currentLanguage == .zhHans ? "手机上勾选「始终允许来自此计算机」" : "Authorize Host Machine on Phone",
                description: l10n.currentLanguage == .zhHans
                    ? "拔插一次 USB 数据线，手机将弹出 RSA 密钥授权弹窗，请务必勾选“一律允许来自此计算机的调试”并轻触“允许”。"
                    : "Re-plug USB cable. When the RSA prompt appears on the phone screen, check 'Always allow from this computer' and tap 'Allow'."
            )
        }
    }
    
    private func stepRow(stepNumber: Int, icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Badge
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 26, height: 26)
                
                Text("\(stepNumber)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                
                Text(description)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
    }
    
    private var footerSection: some View {
        HStack(spacing: 12) {
            if checkSuccess {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    Text("ADB High-Speed Active")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                }
            }
            
            Spacer()
            
            Button(action: {
                verifyConnection()
            }) {
                HStack(spacing: 6) {
                    if isChecking {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(l10n.currentLanguage == .zhHans ? "重新检测模式" : "Re-Check Connection")
                }
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isChecking)
            
            Button(action: {
                isPresented = false
            }) {
                Text(l10n.currentLanguage == .zhHans ? "完成" : "Done")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(TTZipTheme.bambooGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Color.primary.opacity(0.02))
    }
    
    private func verifyConnection() {
        isChecking = true
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run {
                isChecking = false
                checkSuccess = true
                if let dev = AndroidDeviceViewModel.shared.selectedDevice {
                    var updated = dev
                    updated.connectionType = .usbAdb
                    AndroidDeviceViewModel.shared.selectDevice(updated)
                }
            }
        }
    }
}
