// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import SwiftUI
import TTZipUI

/// Dedicated sidebar row representing a mounted storage volume or cloud storage location.
public struct SidebarVolumeRowView: View {
    public let volume: MountedVolumeItem
    public let isSelected: Bool
    public var isIconRail: Bool = false
    public let onSelect: (URL) -> Void

    @State private var isHovered: Bool = false
    private var l10n = AppLocalizationState.shared

    public init(
        volume: MountedVolumeItem,
        isSelected: Bool,
        isIconRail: Bool = false,
        onSelect: @escaping (URL) -> Void
    ) {
        self.volume = volume
        self.isSelected = isSelected
        self.isIconRail = isIconRail
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: { onSelect(volume.url) }) {
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = false
            }
        }
        .contextMenu {
            Button(l10n.currentLanguage == .zhHans ? "在访达中显示" : "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([volume.url])
            }

            if volume.isEjectable {
                Divider()
                Button(l10n.currentLanguage == .zhHans ? "推出 “\(volume.name)”" : "Eject \"\(volume.name)\"") {
                    ejectVolume()
                }
            }
        }
    }

    private var iconRailContent: some View {
        ZStack(alignment: .leading) {
            Image(systemName: displayIcon)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
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
        .help(volume.name)
        .contentShape(Rectangle())
    }

    private var standardRowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: displayIcon)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? TTZipTheme.bambooGreen : Color.secondary)
                .frame(width: 18, alignment: .center)

            Text(volume.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if volume.isEjectable {
                Button(action: ejectVolume) {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(isHovered ? 0.9 : 0.4))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(l10n.currentLanguage == .zhHans ? "推出 “\(volume.name)”" : "Eject \"\(volume.name)\"")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? TTZipTheme.bambooGreen.opacity(0.16) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? TTZipTheme.bambooGreen.opacity(0.28) : Color.clear, lineWidth: 0.6)
        )
        .contentShape(Rectangle())
    }

    private var displayIcon: String {
        if volume.systemImage.hasSuffix(".fill") && !volume.systemImage.contains("badge") {
            let outline = String(volume.systemImage.dropLast(5))
            return outline.isEmpty ? volume.systemImage : outline
        }
        return volume.systemImage
    }

    private func ejectVolume() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        withAnimation(.easeInOut(duration: 0.2)) {
            try? MountedVolumeManager.shared.ejectVolume(volume)
        }
    }
}
