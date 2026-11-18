// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTKitDesign
import TTZipCore
import TTZipUI

/// Dedicated section view managing user-pinned shortcuts, drop-to-pin, and inter-row reordering.
/// Isolates local drop target highlights and collapse state from the parent sidebar.
public struct SidebarPinnedSectionView: View {
    public let currentDirectory: URL
    public let isLocalLocationActive: Bool
    public let isIconRail: Bool
    @FocusState.Binding var focusedItem: SidebarRowIdentifier?
    public let onSelectDirectory: (URL) -> Void
    public let onQuickLook: (URL) -> Void
    public let onOpenInNewWindow: (URL) -> Void

    @AppStorage("TTZipSidebar_PinnedCollapsed") private var isPinnedCollapsed: Bool = false
    @State private var isPinnedDropTargeted: Bool = false
    @State private var dropPulseScale: CGFloat = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var viewModel = FinderFavoritesViewModel.shared
    private var l10n = AppLocalizationState.shared

    public init(
        currentDirectory: URL,
        isLocalLocationActive: Bool = true,
        isIconRail: Bool,
        focusedItem: FocusState<SidebarRowIdentifier?>.Binding,
        onSelectDirectory: @escaping (URL) -> Void,
        onQuickLook: @escaping (URL) -> Void,
        onOpenInNewWindow: @escaping (URL) -> Void
    ) {
        self.currentDirectory = currentDirectory
        self.isLocalLocationActive = isLocalLocationActive
        self.isIconRail = isIconRail
        self._focusedItem = focusedItem
        self.onSelectDirectory = onSelectDirectory
        self.onQuickLook = onQuickLook
        self.onOpenInNewWindow = onOpenInNewWindow
    }

    public var body: some View {
        let currentIdentity = viewModel.currentIdentity

        VStack(alignment: isIconRail ? .center : .leading, spacing: 2) {
            if !isIconRail {
                headerView
            }

            if !isPinnedCollapsed || isIconRail {
                rowsContent(currentIdentity: currentIdentity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isPinnedDropTargeted && !isIconRail ? TTKitTheme.bambooGreen.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isPinnedDropTargeted && !isIconRail ? TTKitTheme.bambooGreen.opacity(0.45) : Color.clear,
                    lineWidth: 1
                )
        )
        .shadow(
            color: isPinnedDropTargeted ? TTZipTheme.bambooGreen.opacity(0.35) : Color.clear,
            radius: 4.5,
            x: 0,
            y: 0
        )
        .scaleEffect(dropPulseScale)
        .animation(reduceMotion ? nil : .ttMicro, value: isPinnedDropTargeted)
        .animation(reduceMotion ? nil : .ttMicro, value: isPinnedCollapsed)
        .dropDestination(for: SidebarDropPayload.self) { payloads, _ in
            handleDropPayloads(payloads)
        } isTargeted: { targeted in
            isPinnedDropTargeted = targeted
        }
        .accessibilityRotor(String(localized: "Pinned Items")) {
            ForEach(viewModel.pinnedRecords) { record in
                AccessibilityRotorEntry(record.displayName, id: record.path)
            }
        }
        .accessibilityRotor(String(localized: "Diagnostics")) {
            ForEach(viewModel.pinnedRecords.filter { !$0.lastKnownHealthState.isAccessible }) { record in
                AccessibilityRotorEntry(record.displayName, id: record.path)
            }
        }
        .task(id: currentDirectory) {
            viewModel.updateCurrentIdentity(for: currentDirectory)
        }
    }

    @ViewBuilder
    private var headerView: some View {
        SidebarSectionHeaderView(
            title: String(localized: "PINNED"),
            isCollapsed: $isPinnedCollapsed
        ) {
            Button(action: addCustomFolder) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Pin folder to sidebar..."))
            .accessibilityLabel(String(localized: "Pin folder to sidebar"))
        }
    }

    @ViewBuilder
    private func rowsContent(currentIdentity: FileIdentity?) -> some View {
        if viewModel.pinnedRecords.isEmpty && !isIconRail {
            emptyPlaceholder
        } else {
            ForEach(viewModel.pinnedRecords) { record in
                let rowIdentifier = SidebarRowIdentifier(section: .pinned, id: record.path)
                let isRovingTabTarget = (focusedItem?.id ?? currentDirectory.path) == record.path && (focusedItem?.section == .pinned || focusedItem == nil)
                renderPinnedRow(record: record, currentIdentity: currentIdentity, rowIdentifier: rowIdentifier)
                    .equatable()
                    .focused($focusedItem, equals: rowIdentifier)
                    .focusable(isRovingTabTarget)
                    .focusEffectDisabled()
                    .id(rowIdentifier)
                    .accessibilityIdentifier(record.path)
            }
        }
    }

    private var emptyPlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 10))
                .frame(width: 18, height: 18, alignment: .center)
            Text(String(localized: "Drop folders here to pin"))
                .font(.system(size: 10.5))
        }
        .foregroundStyle(Color.secondary.opacity(0.6))
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func renderPinnedRow(record: PinnedFolderRecord, currentIdentity: FileIdentity?, rowIdentifier: SidebarRowIdentifier) -> SidebarFavoriteRowView {
        let displayTitle = record.displayName
        let isSelected: Bool
        if let currentIdentity {
            isSelected = viewModel.isRowSelected(
                identity: record.identity,
                section: .pinned,
                currentIdentity: currentIdentity
            )
        } else {
            isSelected = record.path == currentDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        }

        return SidebarFavoriteRowView(
            title: displayTitle,
            icon: "folder",
            path: record.path,
            isSelected: isLocalLocationActive && isSelected,
            isCustomPinned: true,
            isIconRail: isIconRail,
            isKeyboardFocused: focusedItem == rowIdentifier,
            recordId: record.id,
            healthState: record.lastKnownHealthState,
            onSelect: {
                viewModel.activeSection = .pinned
                onSelectDirectory(URL(fileURLWithPath: record.path))
            },
            onRemove: {
                viewModel.removeCustomPinnedFolder(path: record.path)
            },
            onCommitRename: { newName in
                viewModel.updateCustomName(for: record.path, to: newName)
            },
            onDropURLs: { urls in
                handleDropFilesIntoFolder(urls: urls, targetPath: record.path)
            },
            onReorderDrop: { urls, position in
                handleReorderPinnedDrop(urls: urls, targetRecord: record, position: position)
            },
            onReorderShortcut: { shortcut, position in
                handleReorderPinnedShortcut(shortcut: shortcut, targetRecord: record, position: position)
            },
            onQuickLook: {
                onQuickLook(URL(fileURLWithPath: record.path))
            },
            onOpenInNewWindow: {
                onOpenInNewWindow(URL(fileURLWithPath: record.path))
            },
            onRelink: {
                viewModel.locateMissingRecord(recordId: record.id)
            }
        )
    }

    private func handleDropPayloads(_ payloads: [SidebarDropPayload]) -> Bool {
        var anyAdded = false
        for payload in payloads {
            switch payload {
            case .internalShortcut(let shortcut):
                let destIdx = viewModel.pinnedRecords.count
                viewModel.moveCustomFolder(path: shortcut.path, toIndex: destIdx)
                anyAdded = true
            case .externalFiles(let urls):
                let added = viewModel.addCustomFolder(urls: urls)
                if added > 0 {
                    anyAdded = true
                }
            }
        }
        if anyAdded {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            triggerDropPulse()
        }
        return anyAdded
    }

    private func handleReorderPinnedShortcut(shortcut: SidebarShortcutTransferItem, targetRecord: PinnedFolderRecord, position: SidebarDropPosition) -> Bool {
        guard let targetIdx = viewModel.pinnedRecords.firstIndex(where: { $0.id == targetRecord.id }) else { return false }
        let destIdx = (position == .below) ? targetIdx + 1 : targetIdx
        viewModel.moveCustomFolder(path: shortcut.path, toIndex: destIdx)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        triggerDropPulse()
        return true
    }

    private func handleReorderPinnedDrop(urls: [URL], targetRecord: PinnedFolderRecord, position: SidebarDropPosition) -> Bool {
        guard let targetIdx = viewModel.pinnedRecords.firstIndex(where: { $0.id == targetRecord.id }) else { return false }
        let destIdx = (position == .below) ? targetIdx + 1 : targetIdx

        var movedOrInserted = false
        for url in urls {
            let canonical = url.standardizedFileURL.path
            if viewModel.pinnedRecords.contains(where: { $0.path == canonical }) {
                viewModel.moveCustomFolder(path: canonical, toIndex: destIdx)
                movedOrInserted = true
            } else {
                let inserted = viewModel.insertCustomFolder(urls: [url], at: destIdx)
                if inserted > 0 {
                    movedOrInserted = true
                }
            }
        }

        if movedOrInserted {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
            triggerDropPulse()
        }
        return movedOrInserted
    }

    private func triggerDropPulse() {
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

    private func handleDropFilesIntoFolder(urls: [URL], targetPath: String) -> Bool {
        SidebarFileIngestionService.ingestFiles(urls: urls, targetPath: targetPath)
    }

    private func addCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Pin to Sidebar")

        if panel.runModal() == .OK {
            _ = viewModel.addCustomFolder(urls: panel.urls)
        }
    }
}
