// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTKitDesign
import TTZipCore
import TTZipUI

extension SidebarFavoriteRowView {
    // MARK: - Subviews & Styling

    var tagsIndicatorView: some View {
        let visibleTags = Array(tags.prefix(3))
        return HStack(spacing: -2.2) {
            ForEach(Array(visibleTags.enumerated()), id: \.element.id) { index, tag in
                FinderTagDotView(
                    tagColor: FinderTagColor(rawValue: tag.colorIndex) ?? .gray,
                    diameter: 7.0
                )
                .zIndex(Double(visibleTags.count - index))
            }
        }
    }

    @ViewBuilder
    var removeButton: some View {
        if isCustomPinned, let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1.0 : 0.0)
            .allowsHitTesting(isHovered)
            .animation(reduceMotion ? nil : .ttMicro, value: isHovered)
            .help(String(localized: "Unpin shortcut"))
            .accessibilityLabel(String(localized: "Unpin shortcut"))
        }
    }

    @ViewBuilder
    var rowIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            primaryIconView

            if healthState != .accessible || showsHealthyIndicator {
                SidebarHealthIndicatorDot(state: healthState)
                    .offset(x: 2.5, y: 2.5)
            }
        }
        .frame(
            width: max(18, iconColumnWidth),
            height: max(18, iconColumnWidth),
            alignment: .center
        )
    }

    @ViewBuilder
    var primaryIconView: some View {
        if let resolvedIcon {
            Image(nsImage: resolvedIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .opacity(controlActiveState == .inactive ? 0.7 : 1.0)
        } else {
            Image(systemName: standardizedSidebarIcon(icon))
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(hierarchicalIconColor)
                .frame(width: 16, height: 16)
        }
    }

    var hierarchicalIconColor: Color {
        isSelected ? TTZipTheme.bambooGreen : Color.secondary
    }

    var dragPreview: some View {
        HStack(spacing: 6) {
            if let resolvedIcon {
                Image(nsImage: resolvedIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2.5)
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    UniversalTokens.Border.specularHairline,
                    lineWidth: UniversalTokens.Dimensions.hairlineWidth
                )
        )
    }

    var backgroundColor: Color {
        if isSelected {
            return controlActiveState == .inactive
                ? Color.primary.opacity(0.08)
                : TTZipTheme.bambooGreen.opacity(0.14)
        }
        return isHovered ? Color.primary.opacity(0.045) : Color.clear
    }

    var rowContentOpacity: CGFloat {
        (healthState.isVolumeOffline || healthState.isBroken || healthState.isMounting) ? 0.45 : 1.0
    }

    var foregroundTextColor: Color {
        if isSelected {
            return controlActiveState == .inactive
                ? Color(nsColor: .unemphasizedSelectedTextColor)
                : Color.primary
        }
        return colorSchemeContrast == .increased ? Color.primary : Color.primary.opacity(0.88)
    }

    var strokeBorderColor: Color {
        guard controlActiveState != .inactive else {
            return Color.clear
        }
        if isKeyboardFocused {
            return TTKitTheme.kintsugiGoldEditorial.opacity(0.7)
        }
        if colorSchemeContrast == .increased && isSelected {
            return Color(nsColor: .selectedControlColor)
        }
        return Color.clear
    }

    // MARK: - Actions & State Transitions

    func startInlineRenaming() {
        inlineDraftText = title
        isInlineRenaming = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            setInlineTextFieldFocused(true)
        }
    }

    func commitRename() {
        guard isInlineRenaming else { return }
        isInlineRenaming = false
        setInlineTextFieldFocused(false)
        let trimmed = inlineDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != title {
            onCommitRename?(trimmed)
        }
    }

    func cancelRename() {
        isInlineRenaming = false
        setInlineTextFieldFocused(false)
        inlineDraftText = title
    }

    func handleDropTargetChanged(_ targeted: Bool) {
        guard targeted,
              healthState.isInteractive,
              SidebarWriteGatekeeper.cachedWritability(for: path) != false else {
            clearDropTargetState()
            return
        }

        withAnimation(reduceMotion ? nil : .ttMicro) {
            isDropTargeted = true
        }
        cancelSpringLoad()
        verifyDropWritabilityIfNeeded()
        scheduleSpringLoadIfNeeded()
    }

    func clearDropTargetState() {
        withAnimation(reduceMotion ? nil : .ttMicro) {
            isDropTargeted = false
            dropPosition = .none
        }
        cancelSpringLoad()
    }

    func verifyDropWritabilityIfNeeded() {
        guard SidebarWriteGatekeeper.cachedWritability(for: path) == nil else { return }
        Task { @MainActor in
            let writable = await SidebarWriteGatekeeper.shared.checkWritableAsync(path)
            if !writable && isDropTargeted {
                clearDropTargetState()
            }
        }
    }

    func scheduleSpringLoadIfNeeded() {
        guard dropPosition == .none else { return }
        springLoadTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, dropPosition == .none else { return }
            onSelect()
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        }
    }

    func handleDropPayloads(_ payloads: [SidebarDropPayload], location: CGPoint) -> Bool {
        cancelSpringLoad()
        let activePosition = dropPosition
        dropPosition = .none

        for payload in payloads {
            switch payload {
            case .internalShortcut(let shortcut):
                guard isCustomPinned else { continue }
                let resolvedPos: SidebarDropPosition = (activePosition == .none)
                    ? (location.y < 14 ? .above : .below)
                    : activePosition
                if let onReorderShortcut {
                    return performDropWithHaptic(onReorderShortcut(shortcut, resolvedPos))
                } else if let onReorderDrop {
                    return performDropWithHaptic(
                        onReorderDrop([URL(fileURLWithPath: shortcut.path)], resolvedPos)
                    )
                }
            case .externalFiles(let urls):
                if isCustomPinned && activePosition != .none, let onReorderDrop {
                    return performDropWithHaptic(onReorderDrop(urls, activePosition))
                }
                if let onDropURLs {
                    return performDropWithHaptic(onDropURLs(urls))
                }
            }
        }
        return false
    }

    func performDropWithHaptic(_ succeeded: Bool) -> Bool {
        if succeeded {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        }
        return succeeded
    }

    func handleHoverPhase(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            let newPosition: SidebarDropPosition = {
                if isDropTargeted && isCustomPinned {
                    if location.y < 7 {
                        return .above
                    }
                    if location.y > 21 {
                        return .below
                    }
                }
                return .none
            }()
            if newPosition != dropPosition {
                dropPosition = newPosition
                if newPosition != .none {
                    cancelSpringLoad()
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                }
            }
            guard !isHovered else { return }
            withAnimation(reduceMotion ? nil : .ttMicro) {
                isHovered = true
            }
        case .ended:
            guard isHovered || dropPosition != .none else { return }
            withAnimation(reduceMotion ? nil : .ttMicro) {
                isHovered = false
                dropPosition = .none
            }
        }
    }

    func resetInteractiveState() {
        withAnimation(reduceMotion ? nil : .ttMicro) {
            isHovered = false
            isDropTargeted = false
            dropPosition = .none
        }
    }

    func loadRowMetadata() async {
        if path.hasSuffix(".app") && resolvedIcon == nil {
            resolvedIcon = await SidebarIconCache.shared.resolveIcon(forPath: path)
        }
        if tags.isEmpty {
            tags = await SidebarMetadataCache.shared.resolveTags(forPath: path)
        }
    }

    func cancelSpringLoad() {
        springLoadTask?.cancel()
        springLoadTask = nil
    }

    func standardizedSidebarIcon(_ icon: String) -> String {
        if icon == "arrow.down.circle.fill" {
            return "arrow.down.circle"
        }
        if icon.hasSuffix(".fill") && !icon.contains("badge") {
            let outline = String(icon.dropLast(5))
            return outline.isEmpty ? icon : outline
        }
        return icon
    }
}
