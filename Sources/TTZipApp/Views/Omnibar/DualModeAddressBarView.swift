// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit
import AppKit
import TTZipCore
import TTZipUI

/// Dual-mode address bar providing breadcrumb chips traversal and click-to-edit absolute path input
/// aligning strictly with Windows File Explorer ergonomics.
public struct DualModeAddressBarView: View {
    public var viewModel: AppViewState
    @State private var isEditing: Bool = false
    @State private var inputText: String = ""
    @State private var isHoveringCapsule: Bool = false
    @State private var isShaking: Bool = false
    @State private var isSpinningRefresh: Bool = false
    @State private var measuredWidth: CGFloat = 320.0
    
    private var l10n = AppLocalizationState.shared
    
    public init(viewModel: AppViewState) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        ZStack {
            if let location = androidLocation {
                androidBreadcrumbContent(location)
            } else if isEditing {
                editingModeContent
            } else {
                breadcrumbModeContent
            }
        }
        .frame(minWidth: 96, maxWidth: .infinity)
        .frame(height: 28.0)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { newWidth in
            if newWidth > 0 {
                measuredWidth = newWidth
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(isEditing ? 0.88 : (isHoveringCapsule ? 0.65 : 0.45)))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    isEditing
                        ? TTZipTheme.bambooGreen.opacity(0.85)
                        : (isHoveringCapsule ? Color.primary.opacity(0.18) : Color.primary.opacity(0.10)),
                    lineWidth: 0.5
                )
        )
        .offset(x: isShaking ? -5 : 0)
        .animation(isShaking ? Animation.default.repeatCount(4, autoreverses: true).speed(4) : .default, value: isShaking)
        .onHover { isHoveringCapsule = $0 }
        .contextMenu {
            addressBarContextMenu
        }
        .background(keyboardTriggers)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DualModeAddressBar")
    }
    
    /// Never fall back to another window's globally selected device.
    private var androidLocation: AndroidLocationDescriptor? {
        let devices = AndroidDeviceViewModel.shared
        guard devices.activeDevice(forWindow: viewModel.windowID) != nil else { return nil }
        return devices.currentLocation(forWindow: viewModel.windowID)
    }

    private func androidBreadcrumbContent(_ location: AndroidLocationDescriptor) -> some View {
        let total = location.breadcrumbs.count
        let shouldFoldMiddle = total > 3 && measuredWidth < 360
        return HStack(spacing: 5) {
            Image(systemName: "smartphone")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(TTZipTheme.bambooGreen)
            Text(location.deviceName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if total > 0 {
                androidChevron
                Button(location.partitionDisplayName) {
                    AndroidDeviceViewModel.shared.navigateToBreadcrumbIndex(0, windowID: viewModel.windowID)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: total == 1 ? .semibold : .medium))
                .lineLimit(1)
            }

            if shouldFoldMiddle {
                androidFoldedMiddleTrail(location, total: total)
            } else if total > 1 {
                androidFullTrail(location, total: total)
            }

            Spacer(minLength: 4)

            Button {
                triggerRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .ttButtonHelp(l10n.uiString(zh: "刷新", en: "Refresh"))
        }
        .padding(.horizontal, 8)
        .ttButtonHelp("\(location.deviceName): \(location.currentPath)")
    }

    private var androidChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(.secondary.opacity(0.6))
    }

    @ViewBuilder
    private func androidFoldedMiddleTrail(_ location: AndroidLocationDescriptor, total: Int) -> some View {
        androidChevron
        Menu("…") {
            ForEach(1..<(total - 1), id: \.self) { idx in
                let path = location.breadcrumbs[idx]
                Button((path as NSString).lastPathComponent) {
                    AndroidDeviceViewModel.shared.navigateToBreadcrumbIndex(idx, windowID: viewModel.windowID)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)

        androidChevron
        let lastIdx = total - 1
        Button((location.breadcrumbs[lastIdx] as NSString).lastPathComponent) {
            AndroidDeviceViewModel.shared.navigateToBreadcrumbIndex(lastIdx, windowID: viewModel.windowID)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.middle)
    }

    @ViewBuilder
    private func androidFullTrail(_ location: AndroidLocationDescriptor, total: Int) -> some View {
        ForEach(1..<total, id: \.self) { index in
            let path = location.breadcrumbs[index]
            androidChevron
            Button((path as NSString).lastPathComponent) {
                AndroidDeviceViewModel.shared.navigateToBreadcrumbIndex(index, windowID: viewModel.windowID)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: index == total - 1 ? .semibold : .medium))
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    // MARK: - Mode 1: Breadcrumb Trail Content
    
    private var breadcrumbModeContent: some View {
        let segments = buildSegments()
        let displayItems = BreadcrumbMiddleFolder.computeDisplayItems(
            segments: segments,
            availableWidth: measuredWidth
        )
        let hideRootSegment = segments.count >= 2 && measuredWidth < 190.0
        let hideRootTitle = segments.count >= 2 && measuredWidth < 250.0
        let fullPath = viewModel.effectiveDisplayDirectory.standardizedFileURL.path

        return HStack(spacing: 0) {
            HStack(spacing: 1) {
                ForEach(Array(displayItems.enumerated()), id: \.element.id) { idx, item in
                    switch item {
                    case .segment(let seg):
                        if !(idx == 0 && !seg.isCurrent && hideRootSegment) {
                            BreadcrumbChipItemView(
                                segment: seg,
                                isRootSegment: idx == 0,
                                hideTitle: idx == 0 && !seg.isCurrent && hideRootTitle,
                                onSelect: { url in
                                    viewModel.activeBrowsingDirectory = nil
                                    viewModel.navigationState.navigateTo(url)
                                },
                                onSelectSubdirectory: { subURL in
                                    viewModel.activeBrowsingDirectory = nil
                                    viewModel.navigationState.navigateTo(subURL)
                                }
                            )
                        }
                    case .collapsedMiddle(let collapsed):
                        BreadcrumbCollapsedMenuChipView(
                            collapsedSegments: collapsed,
                            onSelect: { url in
                                viewModel.activeBrowsingDirectory = nil
                                viewModel.navigationState.navigateTo(url)
                            }
                        )
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Integrated Refresh Button (🔄)
            Button {
                triggerRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.secondary)
                    .rotationEffect(.degrees(isSpinningRefresh ? 360 : 0))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, 4)
            .ttButtonHelp(l10n.t(L10n.Common.refresh) + " (⌘R)")
            .accessibilityLabel(l10n.t(L10n.Common.refresh))
            .accessibilityIdentifier("AddressBarRefreshButton")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            enterEditMode()
        }
        .ttButtonHelp(fullPath)
    }

    @ViewBuilder
    private var addressBarContextMenu: some View {
        let fullPath = androidLocation?.currentPath ?? viewModel.effectiveDisplayDirectory.standardizedFileURL.path
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fullPath, forType: .string)
        } label: {
            Label(l10n.t(L10n.Common.copyPath), systemImage: "doc.on.doc")
        }

        if androidLocation == nil {
            Button {
                enterEditMode()
            } label: {
                Label(l10n.uiString(zh: "编辑完整路径 (⌘L)", en: "Edit Full Path (⌘L)"), systemImage: "character.cursor.ibeam")
            }
        }
    }
    
    // MARK: - Mode 2: Plain Text Edit Content
    
    private var editingModeContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TTZipTheme.kintsugiGold)
                .padding(.leading, 8)
            
            OmnibarTextField(
                text: $inputText,
                placeholder: "/path/to/folder",
                isFocused: $isEditing,
                onCommit: {
                    commitPath()
                },
                onCancel: {
                    exitEditMode()
                }
            )
            .frame(height: 22)
            
            if !inputText.isEmpty {
                Button {
                    inputText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .ttButtonHelp(l10n.uiString(zh: "清空路径", en: "Clear Path"))
            }
            
            Button {
                commitPath()
            } label: {
                Image(systemName: "arrow.forward.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TTZipTheme.bambooGreen)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .ttButtonHelp(l10n.uiString(zh: "打开此路径", en: "Open This Path"))
        }
    }
    
    // MARK: - Actions
    
    private func enterEditMode() {
        guard androidLocation == nil else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            inputText = viewModel.effectiveDisplayDirectory.standardizedFileURL.path
            isEditing = true
        }
    }
    
    private func exitEditMode() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            isEditing = false
            inputText = ""
        }
    }
    
    private func commitPath() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            exitEditMode()
            return
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let targetURL = URL(fileURLWithPath: expanded).standardizedFileURL
        
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue {
            viewModel.activeBrowsingDirectory = nil
            viewModel.navigationState.navigateTo(targetURL)
            exitEditMode()
        } else {
            // Invalid directory shake feedback
            isShaking = true
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                isShaking = false
            }
        }
    }
    
    private func triggerRefresh() {
        if let location = androidLocation {
            Task {
                await AndroidDeviceViewModel.shared.loadDirectoryContents(
                    path: location.currentPath, forceReload: true, windowID: viewModel.windowID
                )
            }
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
            isSpinningRefresh = true
        }
        viewModel.navigationState.refresh()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            isSpinningRefresh = false
        }
    }
    
    private func buildSegments() -> [BreadcrumbPathSegment] {
        let segments = TTZipPathPresentationService.shared.breadcrumbSegments(
            for: viewModel.effectiveDisplayDirectory,
            language: l10n.currentLanguage
        )
        return segments.map { seg in
            BreadcrumbPathSegment(
                id: seg.id,
                name: seg.displayName,
                iconName: seg.iconName,
                url: seg.url,
                isCurrent: seg.isCurrent
            )
        }
    }
    
    private var keyboardTriggers: some View {
        Group {
            Button("") { enterEditMode() }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
            Button("") { enterEditMode() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .opacity(0)
            Button("") { triggerRefresh() }
                .keyboardShortcut("r", modifiers: .command)
                .opacity(0)
        }
    }
}
