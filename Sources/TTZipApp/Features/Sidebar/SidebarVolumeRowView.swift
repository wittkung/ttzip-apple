// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipUI

/// Package-internal descriptor for an item in `SidebarVolumeRowView`'s context menu.
package enum SidebarVolumeContextMenuActionKind: Equatable {
    case openInNewWindow
    case revealInFinder
    case copyFullPath
    case eject
}

package struct SidebarVolumeContextMenuAction {
    package let kind: SidebarVolumeContextMenuActionKind
    package let title: String
    package let precedesDivider: Bool
    package let followsDivider: Bool
    package let perform: @MainActor () -> Void
}

/// Dedicated sidebar row representing a mounted storage volume or cloud storage location.
public struct SidebarVolumeRowView: View {
    public let volume: MountedVolumeItem
    public let isSelected: Bool
    public var isIconRail: Bool = false
    public var isKeyboardFocused: Bool = false
    public let onSelect: (URL) -> Void
    public var onOpenInNewWindow: ((URL) -> Void)? = nil
    package var pasteboard: NSPasteboard = .general

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var dropPulseScale: CGFloat = 1.0
    @State private var springLoadTask: Task<Void, Never>?
    @State private var lastClickUptime: TimeInterval = 0
    private var l10n = AppLocalizationState.shared

    public init(
        volume: MountedVolumeItem,
        isSelected: Bool,
        isIconRail: Bool = false,
        isKeyboardFocused: Bool = false,
        onSelect: @escaping (URL) -> Void,
        onOpenInNewWindow: ((URL) -> Void)? = nil
    ) {
        self.volume = volume
        self.isSelected = isSelected
        self.isIconRail = isIconRail
        self.isKeyboardFocused = isKeyboardFocused
        self.onSelect = onSelect
        self.onOpenInNewWindow = onOpenInNewWindow
    }

    public var body: some View {
        Button(action: handleVolumeClick) {
            if isIconRail {
                iconRailContent
            } else {
                standardRowContent
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(dropPulseScale)
        .onRightClickSelect {
            onSelect(volume.url)
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .ttMicro) {
                isHovered = hovering
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            withAnimation(reduceMotion ? nil : .ttMicro) {
                isHovered = false
            }
        }
        .contextMenu {
            ForEach(Array(contextMenuActions.enumerated()), id: \.offset) { _, item in
                if item.followsDivider {
                    Divider()
                }
                Button(item.title) {
                    item.perform()
                }
                if item.precedesDivider {
                    Divider()
                }
            }
        }
        .dropDestination(for: SidebarDropPayload.self) { payloads, _ in
            handleVolumeDrop(payloads)
        } isTargeted: { targeted in
            handleVolumeDropTarget(targeted)
        }
        .sidebarRowDropIndicator(
            dropPosition: .none,
            isDropTargeted: isDropTargeted,
            cornerRadius: isIconRail ? 7.0 : 6.0
        )
        .overlay(
            RoundedRectangle(cornerRadius: isIconRail ? 7.0 : 6.0, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? TTZipTheme.bambooGreen.opacity(0.80) : Color.clear,
                    lineWidth: TTZipUniversalTokens.Border.width
                )
                .overlay(
                    RoundedRectangle(cornerRadius: isIconRail ? 7.0 : 6.0, style: .continuous)
                        .strokeBorder(
                            isDropTargeted ? TTZipUniversalTokens.Border.specularHairline : Color.clear,
                            lineWidth: TTZipUniversalTokens.Border.width
                        )
                )
                .shadow(
                    color: isDropTargeted ? TTZipTheme.bambooGreen.opacity(0.40) : Color.clear,
                    radius: 4.5,
                    x: 0,
                    y: 0
                )
                .allowsHitTesting(false)
        )
        .animation(reduceMotion ? nil : .ttMicro, value: isDropTargeted)
        .onDisappear {
            springLoadTask?.cancel()
            springLoadTask = nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(volume.name), \(volume.isEjectable ? String(localized: "External Drive") : String(localized: "Volume"))")
        .accessibilityValue(isSelected ? String(localized: "Selected") : "")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }


    private var iconRailContent: some View {
        ZStack(alignment: .leading) {
            Image(systemName: displayIcon)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            if isSelected {
                Capsule()
                    .fill(controlActiveState == .inactive ? Color(nsColor: .secondaryLabelColor) : TTZipTheme.bambooGreen)
                    .frame(width: 2.5, height: 18)
                    .overlay(
                        Capsule()
                            .strokeBorder(TTZipUniversalTokens.Border.specularHairline, lineWidth: TTZipUniversalTokens.Border.width)
                    )
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
        .help(rowHelpText)
        .contentShape(Rectangle())
    }

    package var rowHelpText: String {
        "\(volume.name)\n\(volume.path)"
    }

    private var standardRowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: displayIcon)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18, alignment: .center)


            Text(volume.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? (controlActiveState == .inactive ? Color.secondary : Color.primary) : Color.primary.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            if volume.isCloudStorage {
                volumeStatusBadge(title: String(localized: "Cloud"))
            }

            if volume.isEjectable {
                Button(action: ejectVolume) {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(isHovered ? 0.9 : 0.4))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Eject \"\(volume.name)\""))
                .accessibilityLabel(String(localized: "Eject \"\(volume.name)\""))
            }
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
        .help(rowHelpText)
        .contentShape(Rectangle())
    }

    private func volumeStatusBadge(title: String) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(TTZipUniversalTokens.Border.specularHairline, lineWidth: TTZipUniversalTokens.Border.width)
            )
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

    private var displayIcon: String {
        if volume.systemImage.hasSuffix(".fill") && !volume.systemImage.contains("badge") {
            let outline = String(volume.systemImage.dropLast(5))
            return outline.isEmpty ? volume.systemImage : outline
        }
        return volume.systemImage
    }

    private func handleVolumeDrop(_ payloads: [SidebarDropPayload]) -> Bool {
        var droppedURLs: [URL] = []
        for payload in payloads {
            switch payload {
            case .externalFiles(let urls):
                droppedURLs.append(contentsOf: urls)
            case .internalShortcut:
                break
            }
        }
        guard !droppedURLs.isEmpty else { return false }

        guard SidebarWriteGatekeeper.cachedWritability(for: volume.path) ?? true else {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            return false
        }

        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        triggerDropPulseAnimation()
        Task { @MainActor in
            SidebarFileIngestionService.ingestFiles(urls: droppedURLs, targetPath: volume.path)
        }
        return true
    }

    private func triggerDropPulseAnimation() {
        guard !reduceMotion else { return }
        withAnimation(.ttMicro) {
            dropPulseScale = 1.02
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.ttSnap) {
                dropPulseScale = 1.0
            }
        }
    }

    private func handleVolumeDropTarget(_ targeted: Bool) {
        springLoadTask?.cancel()
        if targeted {
            guard SidebarWriteGatekeeper.cachedWritability(for: volume.path) ?? true else {
                isDropTargeted = false
                return
            }
            withAnimation(reduceMotion ? nil : .ttMicro) {
                isDropTargeted = true
            }
            springLoadTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, isDropTargeted else { return }
                onSelect(volume.url)
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            }
        } else {
            withAnimation(reduceMotion ? nil : .ttMicro) {
                isDropTargeted = false
            }
        }
    }

    private func handleVolumeClick() {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = now - lastClickUptime
        if delta > 0 && delta <= NSEvent.doubleClickInterval, let onOpenInNewWindow {
            lastClickUptime = 0
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            onOpenInNewWindow(volume.url)
        } else {
            lastClickUptime = now
            onSelect(volume.url)
        }
    }

    @MainActor
    package var contextMenuActions: [SidebarVolumeContextMenuAction] {
        var actions: [SidebarVolumeContextMenuAction] = []
        if let onOpenInNewWindow {
            let volumeURL = volume.url
            actions.append(
                SidebarVolumeContextMenuAction(
                    kind: .openInNewWindow,
                    title: l10n.t(MultiWindowLocaleKey.openInNewWindow),
                    precedesDivider: true,
                    followsDivider: false,
                    perform: { onOpenInNewWindow(volumeURL) }
                )
            )
        }

        let volumeURL = volume.url
        actions.append(
            SidebarVolumeContextMenuAction(
                kind: .revealInFinder,
                title: String(localized: "Reveal in Finder"),
                precedesDivider: false,
                followsDivider: false,
                perform: { NSWorkspace.shared.activateFileViewerSelecting([volumeURL]) }
            )
        )

        actions.append(
            SidebarVolumeContextMenuAction(
                kind: .copyFullPath,
                title: String(localized: "Copy Full Path"),
                precedesDivider: false,
                followsDivider: false,
                perform: { copyFullPath() }
            )
        )

        if volume.isEjectable {
            actions.append(
                SidebarVolumeContextMenuAction(
                    kind: .eject,
                    title: String(localized: "Eject \"\(volume.name)\""),
                    precedesDivider: false,
                    followsDivider: true,
                    perform: { ejectVolume() }
                )
            )
        }
        return actions
    }

    @MainActor
    package func copyFullPath() {
        SidebarRowSystemActions.copyFullPath(path: volume.path, pasteboard: pasteboard)
    }

    private func ejectVolume() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        Task { @MainActor in
            try? await MountedVolumeManager.shared.ejectVolumeAsync(volume)
        }
    }
}


extension SidebarVolumeRowView: @preconcurrency Equatable {
    public static func == (lhs: SidebarVolumeRowView, rhs: SidebarVolumeRowView) -> Bool {
        lhs.volume.id == rhs.volume.id &&
        lhs.volume.name == rhs.volume.name &&
        lhs.volume.path == rhs.volume.path &&
        lhs.volume.systemImage == rhs.volume.systemImage &&
        lhs.volume.isCloudStorage == rhs.volume.isCloudStorage &&
        lhs.volume.isEjectable == rhs.volume.isEjectable &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isIconRail == rhs.isIconRail &&
        lhs.isKeyboardFocused == rhs.isKeyboardFocused
    }
}
