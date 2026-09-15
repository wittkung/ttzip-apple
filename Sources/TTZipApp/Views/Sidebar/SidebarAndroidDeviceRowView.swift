// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import SwiftUI
import TTZipCore
import TTZipUI

/// Dedicated sidebar row representing a connected Android device over USB or Wi-Fi.
public struct SidebarAndroidDeviceRowView: View {
    public let device: AndroidDevice
    public let isSelected: Bool
    public var isIconRail: Bool = false
    public let onSelect: (AndroidDevice) -> Void
    public let onEject: (AndroidDevice) -> Void

    @State private var isHovered: Bool = false
    @State private var androidViewModel = AndroidDeviceViewModel.shared
    private var l10n = AppLocalizationState.shared

    public init(
        device: AndroidDevice,
        isSelected: Bool,
        isIconRail: Bool = false,
        onSelect: @escaping (AndroidDevice) -> Void,
        onEject: @escaping (AndroidDevice) -> Void
    ) {
        self.device = device
        self.isSelected = isSelected
        self.isIconRail = isIconRail
        self.onSelect = onSelect
        self.onEject = onEject
    }

    public var body: some View {
        Button(action: { onSelect(device) }) {
            if isIconRail {
                iconRailContent
            } else {
                standardRowContent
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button(l10n.currentLanguage == .zhHans ? "弹出设备" : "Eject Device") {
                onEject(device)
            }

            if device.connectionType == .usbMtp {
                Button(l10n.currentLanguage == .zhHans ? "切换至高速 ADB 模式..." : "Switch to High-Speed ADB Mode...") {
                    androidViewModel.showAdbGuideSheet = true
                }
            }

            Divider()

            Text("ID: \(device.deviceId)")
                .font(.caption)
            Text(l10n.currentLanguage == .zhHans ? "状态: \(device.status.description)" : "Status: \(device.status.description)")
                .font(.caption)
        }
    }

    private var iconRailContent: some View {
        ZStack(alignment: .leading) {
            Image(systemName: deviceIcon)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : Color.secondary.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            if isSelected {
                Capsule()
                    .fill(TTZipTheme.bambooGreen)
                    .frame(width: 2.5, height: 18)
                    .padding(.leading, 2)
            }
        }
        .frame(width: 36, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? TTZipTheme.bambooGreen.opacity(0.16) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? TTZipTheme.bambooGreen.opacity(0.3) : Color.clear, lineWidth: 0.8)
        )
        .help("\(device.displayName) (\(device.connectionType.description))")
        .contentShape(Rectangle())
    }

    private var standardRowContent: some View {
        HStack(spacing: 7) {
            Image(systemName: deviceIcon)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : Color.white.opacity(0.75))
                .frame(width: 18, alignment: .center)

            Text(device.displayName)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            connectionModeBadge(type: device.connectionType)

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    onEject(device)
                }
            }) {
                Image(systemName: "eject.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(isHovered ? 0.9 : 0.4))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(l10n.currentLanguage == .zhHans ? "弹出此安卓设备" : "Eject Android Device")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.08) : (isHovered ? Color.primary.opacity(0.035) : Color.clear))
        )
        .contentShape(Rectangle())
    }

    private var deviceIcon: String {
        if device.connectionType == .wirelessAdb {
            return "iphone.badge.play"
        }
        let lower = device.displayName.lowercased()
        if lower.contains("pad") || lower.contains("tablet") {
            return "ipad"
        }
        return "iphone"
    }

    private func connectionModeBadge(type: AndroidConnectionType) -> some View {
        let (title, bg, fg): (String, Color, Color) = {
            switch type {
            case .usbMtp:
                return ("MTP", Color.primary.opacity(0.06), Color.secondary)
            case .usbAdb:
                return ("ADB", TTZipTheme.bambooGreen.opacity(0.16), TTZipTheme.bambooGreen)
            case .wirelessAdb:
                return ("Wi-Fi", TTZipTheme.kintsugiGold.opacity(0.18), TTZipTheme.kintsugiGold)
            }
        }()

        return Text(title)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(fg)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(bg)
            .clipShape(Capsule())
    }
}
