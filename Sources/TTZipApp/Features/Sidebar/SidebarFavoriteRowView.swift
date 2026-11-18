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

    @Environment(\.controlActiveState) var controlActiveState
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    @ScaledMetric(relativeTo: .body) var rowMinHeight: CGFloat = 30
    @ScaledMetric(relativeTo: .body) var iconColumnWidth: CGFloat = 18

    @State var isHovered: Bool = false
    @State var isDropTargeted: Bool = false
    @State var dropPosition: SidebarDropPosition = .none
    @State var resolvedIcon: NSImage?
    @State var tags: [FinderTag] = []
    @State var springLoadTask: Task<Void, Never>?
    @State var isInlineRenaming: Bool = false
    @State var inlineDraftText: String = ""
    @State var lastClickUptime: TimeInterval = 0
    @FocusState private var isTextFieldFocused: Bool
    var l10n = AppLocalizationState.shared

    func setInlineTextFieldFocused(_ focused: Bool) {
        isTextFieldFocused = focused
    }

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
