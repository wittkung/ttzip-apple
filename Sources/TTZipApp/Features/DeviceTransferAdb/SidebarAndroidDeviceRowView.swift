// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipCore
import TTZipUI

/// Dedicated sidebar row representing a connected Android device over USB or Wi-Fi.
public struct SidebarAndroidDeviceRowView: View {
    public let device: AndroidDevice
    public let isSelected: Bool
    public var isIconRail: Bool = false
    public var isKeyboardFocused: Bool = false
    public let onSelect: (AndroidDevice) -> Void
    public let onEject: (AndroidDevice) -> Void

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false
    @State private var androidViewModel = AndroidDeviceViewModel.shared
    private var l10n = AppLocalizationState.shared

    public init(
        device: AndroidDevice,
        isSelected: Bool,
        isIconRail: Bool = false,
        isKeyboardFocused: Bool = false,
        onSelect: @escaping (AndroidDevice) -> Void,
        onEject: @escaping (AndroidDevice) -> Void
    ) {
        self.device = device
        self.isSelected = isSelected
        self.isIconRail = isIconRail
        self.isKeyboardFocused = isKeyboardFocused
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
        .onRightClickSelect {
            onSelect(device)
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button(String(localized: "Eject Device")) {
                onEject(device)
            }

            if device.connectionType == .usbMtp {
                Button(String(localized: "Switch to High-Speed ADB Mode...")) {
                    androidViewModel.showAdbGuideSheet = true
                }
            }

            Divider()

            Text("ID: \(device.deviceId)")
                .font(.caption)
            Text(String(localized: "Status: \(device.status.description)"))
                .font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.displayName), \(device.connectionType.description)")
        .accessibilityValue(isSelected ? String(localized: "Selected") : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var iconRailContent: some View {
        ZStack(alignment: .leading) {
            Image(systemName: deviceIcon)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            if isSelected {
                Capsule()
                    .fill(controlActiveState == .inactive ? Color(nsColor: .secondaryLabelColor) : TTZipTheme.bambooGreen)
                    .frame(width: 2.5, height: 18)
                    .padding(.leading, 2)
            }
        }
        .frame(width: 36)
        .frame(minHeight: 34)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(strokeBorderColor, lineWidth: borderLineWidth)
        )
        .help("\(device.displayName) (\(device.connectionType.description))")
        .contentShape(Rectangle())
    }

    private var standardRowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: deviceIcon)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18, alignment: .center)


            Text(device.displayName)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? (controlActiveState == .inactive ? Color.secondary : Color.primary) : Color.primary.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            connectionModeBadge(type: device.connectionType)

            Button(action: {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    onEject(device)
                }
            }) {
                Image(systemName: "eject.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(isHovered ? 0.9 : 0.4))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Eject Android Device"))
            .accessibilityLabel(String(localized: "Eject Android Device"))
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(strokeBorderColor, lineWidth: borderLineWidth)
        )
        .contentShape(Rectangle())
    }

    private var backgroundColor: Color {
        if isSelected {
            if controlActiveState == .inactive {
                return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
            }
            return TTZipTheme.bambooGreen.opacity(0.14)
        }
        return isHovered ? Color.primary.opacity(0.045) : Color.clear
    }

    private var strokeBorderColor: Color {
        if controlActiveState == .inactive {
            return Color.clear
        }
        if isKeyboardFocused {
            return TTZipTheme.kintsugiGoldEditorial
        }
        if isSelected {
            if colorSchemeContrast == .increased {
                return Color(nsColor: .selectedControlColor)
            }
            return TTZipTheme.bambooGreen.opacity(0.28)
        }
        return Color.clear
    }

    private var borderLineWidth: CGFloat {
        if isKeyboardFocused || colorSchemeContrast == .increased {
            return 1.0
        }
        return TTZipUniversalTokens.Border.width
    }

    private var iconColor: Color {
        if isSelected {
            if controlActiveState == .inactive {
                return Color(nsColor: .secondaryLabelColor)
            }
            return TTZipTheme.bambooGreen
        }
        return Color.secondary
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

extension SidebarAndroidDeviceRowView: @preconcurrency Equatable {
    public static func == (lhs: SidebarAndroidDeviceRowView, rhs: SidebarAndroidDeviceRowView) -> Bool {
        lhs.device.deviceId == rhs.device.deviceId &&
        lhs.device.displayName == rhs.device.displayName &&
        lhs.device.connectionType == rhs.device.connectionType &&
        lhs.device.status == rhs.device.status &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isIconRail == rhs.isIconRail &&
        lhs.isKeyboardFocused == rhs.isKeyboardFocused
    }
}
