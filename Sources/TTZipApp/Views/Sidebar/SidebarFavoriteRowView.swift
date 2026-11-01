// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTKitDesign
import TTZipCore
import TTZipUI

/// Dedicated, high-performance sidebar row representing a favorite folder or custom shortcut.
/// Encapsulates local hover, asynchronous icon streaming, spring-loaded folder navigation,
/// inline renaming, inter-row drag reordering coordination, and icon rail geometry.
public struct SidebarFavoriteRowView: View {
    public let title: String
    public let icon: String
    public let path: String
    public let isSelected: Bool
    public let isCustomPinned: Bool
    public var isIconRail: Bool = false
    public var isKeyboardFocused: Bool = false
    public var recordId: UUID? = nil
    public let onSelect: () -> Void
    public let onRemove: (() -> Void)?
    public var onCommitRename: ((String) -> Void)? = nil
    public var onDropURLs: (([URL]) -> Bool)? = nil
    public var onReorderDrop: (([URL], SidebarDropPosition) -> Bool)? = nil
    public var onReorderShortcut: ((SidebarShortcutTransferItem, SidebarDropPosition) -> Bool)? = nil
    public var onQuickLook: (() -> Void)? = nil
    public var onOpenInNewWindow: (() -> Void)? = nil
    public var healthState: SidebarItemHealthState = .accessible
    public var showsHealthyIndicator: Bool = false
    public var onRelink: (() -> Void)? = nil

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ScaledMetric(relativeTo: .body) private var rowMinHeight: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var iconColumnWidth: CGFloat = 18

    @State private var isHovered: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var dropPosition: SidebarDropPosition = .none
    @State private var resolvedIcon: NSImage?
    @State private var tags: [FinderTag] = []
    @State private var springLoadTask: Task<Void, Never>?
    @State private var isInlineRenaming: Bool = false
    @State private var inlineDraftText: String = ""
    @State private var lastClickUptime: TimeInterval = 0
    @FocusState private var isTextFieldFocused: Bool
    private var l10n = AppLocalizationState.shared

    public init(
        title: String,
        icon: String,
        path: String,
        isSelected: Bool,
        isCustomPinned: Bool = false,
        isIconRail: Bool = false,
        isKeyboardFocused: Bool = false,
        recordId: UUID? = nil,
        healthState: SidebarItemHealthState = .accessible,
        showsHealthyIndicator: Bool = false,
        onSelect: @escaping () -> Void,
        onRemove: (() -> Void)? = nil,
        onCommitRename: ((String) -> Void)? = nil,
        onDropURLs: (([URL]) -> Bool)? = nil,
        onReorderDrop: (([URL], SidebarDropPosition) -> Bool)? = nil,
        onReorderShortcut: ((SidebarShortcutTransferItem, SidebarDropPosition) -> Bool)? = nil,
        onQuickLook: (() -> Void)? = nil,
        onOpenInNewWindow: (() -> Void)? = nil,
        onRelink: (() -> Void)? = nil
    ) {
        self.title = title
        self.icon = icon
        self.path = path
        self.isSelected = isSelected
        self.isCustomPinned = isCustomPinned
        self.isIconRail = isIconRail
        self.isKeyboardFocused = isKeyboardFocused
        self.recordId = recordId
        self.healthState = healthState
        self.showsHealthyIndicator = showsHealthyIndicator
        self.onSelect = onSelect
        self.onRemove = onRemove
        self.onCommitRename = onCommitRename
        self.onDropURLs = onDropURLs
        self.onReorderDrop = onReorderDrop
        self.onReorderShortcut = onReorderShortcut
        self.onQuickLook = onQuickLook
        self.onOpenInNewWindow = onOpenInNewWindow
        self.onRelink = onRelink
        self._resolvedIcon = State(initialValue: path.hasSuffix(".app") ? SidebarIconCache.shared.cachedIcon(forPath: path) : nil)
        self._tags = State(initialValue: SidebarMetadataCache.shared.cachedTags(forPath: path) ?? [])
    }

    private var dragSource: SidebarRowDragSource {
        SidebarRowDragSource(
            item: SidebarShortcutTransferItem(
                id: recordId ?? UUID(),
                path: path,
                customName: title
            )
        )
    }

    public var body: some View {
        applyAccessibilityModifiers(
            interactiveRowContent
                .sidebarRowContextMenu(
                    path: path,
                    title: title,
                    isCustomPinned: isCustomPinned,
                    healthState: healthState,
                    onSelect: onSelect,
                    onRemove: onRemove,
                    onStartRename: onCommitRename != nil ? { startInlineRenaming() } : nil,
                    onQuickLook: onQuickLook,
                    onOpenInNewWindow: onOpenInNewWindow,
                    onRelink: onRelink
                )

        )
    }

    @ViewBuilder
    private var baseRowContent: some View {
        Group {
            if isIconRail {
                iconRailContent
            } else {
                standardRowContent
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handlePrimaryTap()
        }
    }

    private func handlePrimaryTap() {
        if healthState.isBroken {
            onRelink?()
            return
        }
        if healthState.isVolumeOffline || healthState.isMounting {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = now - lastClickUptime
        if delta > 0 && delta <= NSEvent.doubleClickInterval, let onOpenInNewWindow {
            lastClickUptime = 0
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            onOpenInNewWindow()
        } else {
            lastClickUptime = now
            onSelect()
        }
    }


    @ViewBuilder
    private var interactiveRowContent: some View {
        baseRowContent
            .draggable(dragSource) {
                dragPreview
            }
            .dropDestination(for: SidebarDropPayload.self) { payloads, location in
                handleDropPayloads(payloads, location: location)
            } isTargeted: { targeted in
                handleDropTargetChanged(targeted)
            }
            .sidebarRowDropIndicator(
                dropPosition: dropPosition,
                isDropTargeted: isDropTargeted,
                cornerRadius: isIconRail ? 7.0 : 6.0
            )
            .onContinuousHover(perform: handleHoverPhase)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                resetInteractiveState()
            }
            .task(id: path) {
                await loadRowMetadata()
            }
            .onDisappear {
                cancelSpringLoad()
            }
    }

    private func applyAccessibilityModifiers<V: View>(_ content: V) -> some View {
        let base = content
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(isSelected ? String(localized: "Selected") : "")
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .accessibilityAction(.default, onSelect)
            .accessibilityCustomContent(
                AccessibilityCustomContentKey(LocalizedStringKey(String(localized: "Physical Path"))),
                Text(path),
                importance: .default
            )

        let diagnosedBase = applyHealthAccessibilityContent(base)

        let revealTitle = Text(String(localized: "Reveal in Finder"))
        let getInfoTitle = Text(String(localized: "Get Info"))
        let terminalTitle = Text(String(localized: "Open in Terminal"))
        let renameTitle = Text(String(localized: "Rename"))
        let removeTitle = Text(String(localized: "Remove from Sidebar"))

        return diagnosedBase
            .accessibilityAction(named: revealTitle) {
                SidebarRowSystemActions.revealInFinder(path: path)
            }
            .accessibilityAction(named: getInfoTitle) {
                SidebarRowSystemActions.showFinderGetInfo(path: path)
            }
            .accessibilityAction(named: terminalTitle) {
                SidebarRowSystemActions.openTerminal(at: path)
            }
            .accessibilityAction(named: renameTitle) {
                startInlineRenaming()
            }
            .accessibilityAction(named: removeTitle) {
                onRemove?()
            }
    }

    private func applyHealthAccessibilityContent<V: View>(_ content: V) -> some View {
        let key = AccessibilityCustomContentKey(LocalizedStringKey(String(localized: "Health Status")))
        switch healthState {
        case .accessible:
            return AnyView(content)
        case .warning(let message):
            return AnyView(
                content.accessibilityCustomContent(
                    key,
                    Text(String(localized: "Warning: \(message)")),
                    importance: .high
                )
            )
        case .mounting(let volume):
            let volName = volume ?? String(localized: "Volume")
            return AnyView(
                content.accessibilityCustomContent(
                    key,
                    Text(String(localized: "Mounting: \(volName)")),
                    importance: .default
                )
            )
        case .missing(let lastKnown):
            return AnyView(
                content.accessibilityCustomContent(
                    key,
                    Text(String(localized: "Broken: \(lastKnown)")),
                    importance: .high
                )
            )
        case .unmountedVolume(let volume, _):
            let volName = volume ?? String(localized: "Unnamed Volume")
            return AnyView(
                content.accessibilityCustomContent(
                    key,
                    Text(String(localized: "Volume Offline: \(volName)")),
                    importance: .high
                )
            )
        case .datalessCloud(let downloading):
            let statusText = downloading
                ? String(localized: "Downloading from cloud")
                : String(localized: "Cloud placeholder")
            return AnyView(
                content.accessibilityCustomContent(key, Text(statusText), importance: downloading ? .high : .default)
            )
        }
    }

    // MARK: - Layouts

    private var standardRowContent: some View {
        HStack(spacing: 8) {
            rowIcon
                .frame(width: max(18, iconColumnWidth), alignment: .center)

            if isInlineRenaming {
                TextField("", text: $inlineDraftText)
                    .focused($isTextFieldFocused)
                    .font(.system(size: 11.5, weight: .medium))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .strokeBorder(TTKitTheme.bambooGreen, lineWidth: 1)
                    )
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .onChange(of: isTextFieldFocused) { _, focused in
                        if !focused && isInlineRenaming {
                            commitRename()
                        }
                    }
            } else {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(foregroundTextColor)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)
            }

            if !isInlineRenaming && !tags.isEmpty {
                tagsIndicatorView
            }

            Spacer(minLength: 0)

            if !isInlineRenaming {
                removeButton
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: max(30, rowMinHeight))
        .opacity(rowContentOpacity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(strokeBorderColor, lineWidth: UniversalTokens.Dimensions.hairlineWidth)
        )
        .contentShape(Rectangle())
    }

    private var iconRailContent: some View {
        ZStack(alignment: .leading) {
            rowIcon
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            if isSelected {
                Capsule()
                    .fill(controlActiveState == .inactive ? Color(nsColor: .secondaryLabelColor) : TTKitTheme.bambooGreen)
                    .frame(width: 2.5, height: 18)
                    .padding(.leading, 2)
            }
        }
        .frame(width: 36)
        .frame(minHeight: max(34, rowMinHeight + 4))
        .opacity(rowContentOpacity)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(strokeBorderColor, lineWidth: UniversalTokens.Dimensions.hairlineWidth)
        )
        .contentShape(Rectangle())
        .help(title)
    }

    private var tagsIndicatorView: some View {
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
    private var removeButton: some View {
        if isCustomPinned, let onRemove {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(isHovered ? 0.08 : 0)))
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
    private var rowIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            primaryIconView

            if healthState != .accessible || showsHealthyIndicator {
                SidebarHealthIndicatorDot(state: healthState)
                    .offset(x: 2.5, y: 2.5)
            }
        }
        .frame(width: max(18, iconColumnWidth), height: max(18, iconColumnWidth), alignment: .center)
    }

    @ViewBuilder
    private var primaryIconView: some View {
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

    private var hierarchicalIconColor: Color {
        if isSelected {
            return TTZipTheme.bambooGreen
        }
        return Color.secondary
    }

    private var dragPreview: some View {
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
            Capsule().strokeBorder(UniversalTokens.Border.specularHairline, lineWidth: UniversalTokens.Dimensions.hairlineWidth)
        )
    }

    private var backgroundColor: Color {
        if isSelected {
            return controlActiveState == .inactive
                ? Color.primary.opacity(0.08)
                : TTZipTheme.bambooGreen.opacity(0.14)
        } else if isHovered {
            return Color.primary.opacity(0.045)
        } else {
            return Color.clear
        }
    }

    private var rowContentOpacity: CGFloat {
        if healthState.isVolumeOffline || healthState.isBroken || healthState.isMounting {
            return 0.45
        }
        return 1.0
    }

    private var foregroundTextColor: Color {
        if isSelected {
            return controlActiveState == .inactive
                ? Color(nsColor: .unemphasizedSelectedTextColor)
                : Color.primary
        }
        if colorSchemeContrast == .increased {
            return Color.primary
        }
        return Color.primary.opacity(0.88)
    }

    private var strokeBorderColor: Color {
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

    private func startInlineRenaming() {
        inlineDraftText = title
        isInlineRenaming = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            isTextFieldFocused = true
        }
    }

    private func commitRename() {
        guard isInlineRenaming else { return }
        isInlineRenaming = false
        isTextFieldFocused = false
        let trimmed = inlineDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != title {
            onCommitRename?(trimmed)
        }
    }

    private func cancelRename() {
        isInlineRenaming = false
        isTextFieldFocused = false
        inlineDraftText = title
    }

    private func handleDropTargetChanged(_ targeted: Bool) {
        guard targeted, healthState.isInteractive else {
            withAnimation(reduceMotion ? nil : .ttMicro) {
                isDropTargeted = false
                dropPosition = .none
            }
            springLoadTask?.cancel()
            springLoadTask = nil
            return
        }

        // Fast-path: Check memory-cached writability
        if let cachedWritable = SidebarWriteGatekeeper.cachedWritability(for: path), !cachedWritable {
            withAnimation(reduceMotion ? nil : .ttMicro) {
                isDropTargeted = false
                dropPosition = .none
            }
            springLoadTask?.cancel()
            springLoadTask = nil
            return
        }

        withAnimation(reduceMotion ? nil : .ttMicro) {
            isDropTargeted = true
        }
        springLoadTask?.cancel()
        springLoadTask = nil

        if SidebarWriteGatekeeper.cachedWritability(for: path) == nil {
            Task { @MainActor in
                let writable = await SidebarWriteGatekeeper.shared.checkWritableAsync(path)
                if !writable && isDropTargeted {
                    withAnimation(reduceMotion ? nil : .ttMicro) {
                        isDropTargeted = false
                        dropPosition = .none
                    }
                    springLoadTask?.cancel()
                    springLoadTask = nil
                }
            }
        }

        // macOS 500ms spring-loaded folder auto-navigation
        if dropPosition == .none {
            springLoadTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, dropPosition == .none else { return }
                onSelect()
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
            }
        }
    }

    private func handleDropPayloads(_ payloads: [SidebarDropPayload], location: CGPoint) -> Bool {
        cancelSpringLoad()
        let activePosition = dropPosition
        dropPosition = .none

        for payload in payloads {
            switch payload {
            case .internalShortcut(let shortcut):
                let resolvedPos: SidebarDropPosition = (activePosition == .none)
                    ? (location.y < 14 ? .above : .below)
                    : activePosition
                if isCustomPinned {
                    if let onReorderShortcut {
                        let res = onReorderShortcut(shortcut, resolvedPos)
                        if res { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default) }
                        return res
                    } else if let onReorderDrop {
                        let res = onReorderDrop([URL(fileURLWithPath: shortcut.path)], resolvedPos)
                        if res { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default) }
                        return res
                    }
                }
            case .externalFiles(let urls):
                if isCustomPinned && activePosition != .none, let onReorderDrop {
                    let res = onReorderDrop(urls, activePosition)
                    if res { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default) }
                    return res
                }
                if let onDropURLs {
                    let res = onDropURLs(urls)
                    if res { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default) }
                    return res
                }
            }
        }
        return false
    }

    private func handleHoverPhase(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            let newPosition: SidebarDropPosition = {
                if isDropTargeted && isCustomPinned {
                    if location.y < 7 { return .above }
                    if location.y > 21 { return .below }
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

    private func resetInteractiveState() {
        withAnimation(reduceMotion ? nil : .ttMicro) {
            isHovered = false
            isDropTargeted = false
            dropPosition = .none
        }
    }

    private func loadRowMetadata() async {
        if path.hasSuffix(".app") && resolvedIcon == nil {
            resolvedIcon = await SidebarIconCache.shared.resolveIcon(forPath: path)
        }
        if tags.isEmpty {
            tags = await SidebarMetadataCache.shared.resolveTags(forPath: path)
        }
    }

    private func cancelSpringLoad() {
        springLoadTask?.cancel()
        springLoadTask = nil
    }

    private func standardizedSidebarIcon(_ icon: String) -> String {
        if icon == "arrow.down.circle.fill" { return "arrow.down.circle" }
        if icon.hasSuffix(".fill") && !icon.contains("badge") {
            let outline = String(icon.dropLast(5))
            return outline.isEmpty ? icon : outline
        }
        return icon
    }
}

// MARK: - Equatable

extension SidebarFavoriteRowView: @preconcurrency Equatable {
    public static func == (lhs: SidebarFavoriteRowView, rhs: SidebarFavoriteRowView) -> Bool {
        lhs.path == rhs.path &&
        lhs.title == rhs.title &&
        lhs.icon == rhs.icon &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isCustomPinned == rhs.isCustomPinned &&
        lhs.isIconRail == rhs.isIconRail &&
        lhs.isKeyboardFocused == rhs.isKeyboardFocused &&
        lhs.recordId == rhs.recordId &&
        lhs.healthState == rhs.healthState &&
        lhs.showsHealthyIndicator == rhs.showsHealthyIndicator
    }
}
