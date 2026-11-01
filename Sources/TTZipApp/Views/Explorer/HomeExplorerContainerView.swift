// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTMediaKit
import TTZipCore
import TTZipUI

/// Home explorer container holding toolbar header and directory browser.
public struct HomeExplorerContainerView: View {
    public var viewModel: AppViewState
    private var l10n = AppLocalizationState.shared
    public let isRightSidebarVisible: Bool
    public let isLeftSidebarVisible: Bool
    public var onToggleLeftSidebar: (() -> Void)? = nil
    public var onToggleRightSidebar: (() -> Void)? = nil
    public var onOpenArchive: (() -> Void)? = nil
    public var onNewArchive: (() -> Void)? = nil
    public let isActive: Bool
    
    @Environment(\.colorScheme) private var colorScheme
    @State private var accessRefreshTrigger: Int = 0
    @State private var storageInspectorViewModel = StorageInspectorViewModel()
    @State private var hoveredActionID: String? = nil
    
    public init(
        viewModel: AppViewState,
        isRightSidebarVisible: Bool = true,
        isLeftSidebarVisible: Bool = true,
        onToggleLeftSidebar: (() -> Void)? = nil,
        onToggleRightSidebar: (() -> Void)? = nil,
        onOpenArchive: (() -> Void)? = nil,
        onNewArchive: (() -> Void)? = nil,
        isActive: Bool = true
    ) {
        self.viewModel = viewModel
        self.isRightSidebarVisible = isRightSidebarVisible
        self.isLeftSidebarVisible = isLeftSidebarVisible
        self.onToggleLeftSidebar = onToggleLeftSidebar
        self.onToggleRightSidebar = onToggleRightSidebar
        self.onOpenArchive = onOpenArchive
        self.onNewArchive = onNewArchive
        self.isActive = isActive
    }
    
    private var hasCurrentDirectoryAccess: Bool {
        _ = accessRefreshTrigger
        return RootFolderAccessManager.shared.hasActiveAccess(for: viewModel.navigationState.currentDirectory)
    }
    
    private var activeArchivePath: String? {
        let navigation = viewModel.navigationState
        guard AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(navigation.currentDirectory) else { return nil }
        return viewModel.explorerState.acceptedArchiveProjection(
            for: navigation.activeSessionID, archivePath: navigation.currentDirectory.path
        )?.archivePath
    }

    public var body: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 640
            // Idle search renders as a 28x28pt button so the address bar gets maximum width;
            // clicking the button or pressing ⌘F expands the search capsule and compresses the address bar.
            let isSearchIconOnly = true
            
            TTZipWorkspaceScaffold(
                isEdgeToEdge: true,
                headerLeading: {
                    HStack(spacing: isCompact ? 6 : 8) {
                        if !isLeftSidebarVisible, let onToggle = onToggleLeftSidebar {
                            sidebarToggleButton(action: onToggle)
                        }
                        
                        TopOmnibarView(
                            viewModel: viewModel,
                            searchQuery: Binding(
                                get: { viewModel.explorerState.searchQuery },
                                set: { viewModel.explorerState.searchQuery = $0 }
                            ),
                            isCompact: isCompact,
                            isSearchIconOnly: isSearchIconOnly
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1.0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1.0)
                },
                headerTrailing: {
                    HStack(spacing: isCompact ? 5 : 6) {
                        if onOpenArchive != nil || onNewArchive != nil {
                            workspaceArchiveActionsGroup
                        }
                        
                        if let archivePath = activeArchivePath {
                            activeArchiveContextGroup(archivePath: archivePath, isCompact: isCompact)
                        }

                        if !hasCurrentDirectoryAccess {
                            compactRootAccessButton {
                                let targetURL = RootFolderAccessManager.shared.canonicalDirectoryURL(for: viewModel.navigationState.currentDirectory)
                                RootFolderAccessManager.shared.requestRootAccess(for: targetURL) { granted in
                                    if granted {
                                        accessRefreshTrigger &+= 1
                                    }
                                }
                            }
                        }

                        let isCompress = viewModel.navigationState.isCompressWorkspaceActive
                        if let onToggleRight = onToggleRightSidebar {
                            toggleRightSidebarButton(isCompress: isCompress, action: onToggleRight)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(10.0)
                },
                content: {
                    VStack(alignment: .leading, spacing: 0) {
                        if viewModel.navigationState.tabSessions.count > 1 || viewModel.navigationState.tabSessions.contains(where: { $0.kind.isCompressWorkspace || $0.kind.isStorageInspector }) {
                            MultiDirectoryTabBarView(viewModel: viewModel)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity.combined(with: .move(edge: .top))))
                        }

                        if viewModel.overlayState.activeSmartFolderID != nil {
                            ActiveSmartFolderResultsBannerView(viewModel: viewModel)
                        }
                        
                        if let androidDevice = AndroidDeviceViewModel.shared.activeDevice(forWindow: viewModel.windowID) {
                            VStack(spacing: 0) {
                                AndroidHeaderView(viewModel: AndroidDeviceViewModel.shared, windowID: viewModel.windowID)
                                AndroidDeviceBrowserView(viewModel: AndroidDeviceViewModel.shared, device: androidDevice, windowID: viewModel.windowID)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else if viewModel.navigationState.isStorageInspectorActive {
                            StorageInspectorView(isPresented: .constant(true), viewModel: storageInspectorViewModel)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else if viewModel.navigationState.isCompressWorkspaceActive {
                            CompressWorkspaceView(viewModel: viewModel)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            DiskDirectoryBrowserView(
                                viewModel: viewModel,
                                rootDirectory: viewModel.navigationState.currentDirectory,
                                isActive: isActive
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    .background(Color.clear)
                }
            )
            .onChange(of: viewModel.navigationState.currentDirectory) { _, _ in
                AndroidDeviceViewModel.shared.bindWindow(viewModel.windowID, toDevice: nil)
            }
            .onChange(of: viewModel.navigationState.isStorageInspectorActive) { _, isStorageActive in
                if !isStorageActive {
                    storageInspectorViewModel.cancelScan()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TTZipArchiveUnlockedRefresh"))) { notification in
                guard notification.userInfo?["archiveContentsChanged"] as? Bool == true,
                      let path = notification.object as? String else { return }
                Task { await viewModel.archiveContentsDidChange(at: path) }
            }
            .onDisappear {
                storageInspectorViewModel.cancelScan()
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
    
    // MARK: - Header Supporting Components
    
    @ViewBuilder
    private func sidebarToggleButton(action: @escaping () -> Void) -> some View {
        let isHovered = hoveredActionID == "toggle_left"
        Button(action: action) {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isHovered ? 0.14 : 0.07), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { updateHover(id: "toggle_left", hovering: $0) }
        .ttButtonHelp(l10n.t(L10n.Sidebar.showFavoritesSidebar) + " (⌃⌘S)")
        .accessibilityLabel(l10n.t(L10n.Sidebar.showFavoritesSidebar))
        .accessibilityIdentifier("CenterTopBarLeftSidebarToggleButton")
    }

    @ViewBuilder
    private var workspaceArchiveActionsGroup: some View {
        HStack(spacing: 0) {
            if let onOpen = onOpenArchive {
                let isHovered = hoveredActionID == "open_archive"
                Button(action: onOpen) {
                    Image(systemName: "doc.zipper")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                                .padding(1.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { updateHover(id: "open_archive", hovering: $0) }
                .ttButtonHelp(l10n.t(L10n.Menu.openArchive) + " (⌘O)")
                .accessibilityLabel(l10n.t(L10n.Menu.openArchive))
                .accessibilityIdentifier("TopBarOpenArchiveButton")
            }

            if onOpenArchive != nil && onNewArchive != nil {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 0.5, height: 14)
            }

            if let onNew = onNewArchive {
                let isHovered = hoveredActionID == "new_archive"
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(TTZipTheme.bambooGreen.opacity(isHovered ? 0.15 : 0.0))
                                .padding(1.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { updateHover(id: "new_archive", hovering: $0) }
                .ttButtonHelp(l10n.t(L10n.Sidebar.newArchive) + " (⇧⌘N)")
                .accessibilityLabel(l10n.t(L10n.Sidebar.newArchive))
                .accessibilityIdentifier("TopBarNewArchiveButton")
            }
        }
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("TopBarArchiveActionsGroup")
    }
    
    @ViewBuilder
    private func toggleRightSidebarButton(isCompress: Bool, action: @escaping () -> Void) -> some View {
        let isHovered = hoveredActionID == "toggle_right"
        Button(action: action) {
            Image(systemName: "sidebar.trailing")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isRightSidebarVisible ? Color.primary.opacity(0.88) : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.09 : (isRightSidebarVisible ? 0.055 : 0.025)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(isHovered ? 0.16 : (isRightSidebarVisible ? 0.10 : 0.06)),
                            lineWidth: 0.5
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { updateHover(id: "toggle_right", hovering: $0) }
        .ttButtonHelp(sidebarToggleTooltip(isCompress: isCompress))
        .accessibilityLabel(sidebarToggleTooltip(isCompress: isCompress))
        .accessibilityIdentifier("TopBarRightInspectorToggleButton")
    }
    
    private func sidebarToggleTooltip(isCompress: Bool) -> String {
        if isCompress {
            return isRightSidebarVisible
                ? l10n.t(L10n.Compress.hideFeeder)
                : l10n.t(L10n.Compress.showFeeder)
        } else {
            return l10n.t(L10n.Inspector.toggleInspectorPanel) + " (⌘I)"
        }
    }
    
    @ViewBuilder
    private func compactRootAccessButton(action: @escaping () -> Void) -> some View {
        let isHovered = hoveredActionID == "root_access"
        Button(action: action) {
            Image(systemName: "lock.open")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.08 : 0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isHovered ? 0.14 : 0.08), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { updateHover(id: "root_access", hovering: $0) }
        .ttButtonHelp(l10n.t(L10n.Explorer.rootAccessHelp))
        .accessibilityLabel(l10n.t(L10n.Explorer.rootAccess))
        .accessibilityIdentifier("TopBarRootAccessButton")
    }

    // MARK: - Contextual Archive Actions

    @ViewBuilder
    private func activeArchiveContextGroup(archivePath: String, isCompact: Bool) -> some View {
        HStack(spacing: 0) {
            extractOptionsSegmentButton(isCompact: isCompact)
            groupHairlineSeparator
            quickExtractAllSegmentButton(archivePath: archivePath, isCompact: isCompact)
            groupHairlineSeparator
            closeArchiveSegmentButton
        }
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var groupHairlineSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 0.5, height: 14)
    }

    private func extractOptionsSegmentButton(isCompact: Bool) -> some View {
        Button {
            viewModel.overlayState.showExtractModal = true
        } label: {
            if isCompact {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10.5, weight: .medium))
                    Text(l10n.t(L10n.Extract.title))
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(TTZipTheme.bambooGreen)
        .keyboardShortcut("e", modifiers: [.command])
        .ttButtonHelp(l10n.t(L10n.Extract.extractOptionsPrompt) + " (⌘E)")
        .accessibilityLabel(l10n.t(L10n.Extract.title))
    }

    private func quickExtractAllSegmentButton(archivePath: String, isCompact: Bool) -> some View {
        Button {
            Task { @MainActor in
                await viewModel.quickExtractArchive(path: archivePath, destination: nil)
            }
        } label: {
            if isCompact {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 10.5, weight: .medium))
                    Text(l10n.t(L10n.Extract.extractAll))
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary.opacity(0.85))
        .keyboardShortcut("e", modifiers: [.option, .command])
        .ttButtonHelp(l10n.t(L10n.Extract.extractAllPrompt) + " (⌥⌘E)")
        .accessibilityLabel(l10n.t(L10n.Extract.extractAll))
    }

    private var closeArchiveSegmentButton: some View {
        Button {
            viewModel.closeCurrentArchive(discardAcceptedResources: true)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ttButtonHelp(l10n.t(L10n.Explorer.closeArchive))
        .accessibilityLabel(l10n.t(L10n.Explorer.closeArchive))
    }

    private func updateHover(id: String, hovering: Bool) {
        if hovering {
            hoveredActionID = id
        } else if hoveredActionID == id {
            hoveredActionID = nil
        }
    }
}

extension RootFolderAccessManager {
    /// Determines whether active read access is already granted for the target directory.
    public func hasActiveAccess(for url: URL) -> Bool {
        ensureAccess(for: url, promptIfMissing: false)
    }
}

extension ArchiveExplorerTableView {
    /// Convenience initializer supporting currentArchivePath, password, and single entry extraction.
    public init(
        filteredEntries: ArchiveFilteredEntriesView,
        currentArchivePath: String,
        activePassword: String? = nil,
        selectedEntryID: Binding<String?>,
        onSelectEntry: @escaping (String?) -> Void,
        onExtractEntry: @escaping (ArchiveEntry) -> Void
    ) {
        self.init(
            filteredEntries: filteredEntries,
            selectedEntryID: selectedEntryID,
            currentArchivePath: currentArchivePath,
            activePassword: activePassword,
            onSelectEntry: onSelectEntry,
            onReplaceEntry: nil,
            onDeleteEntry: nil,
            onExtractEntry: onExtractEntry
        )
    }

    /// Convenience initializer supporting currentArchivePath, password, and single entry extraction for legacy arrays.
    public init(
        filteredEntries: [ArchiveEntry],
        currentArchivePath: String,
        activePassword: String? = nil,
        selectedEntryID: Binding<String?>,
        onSelectEntry: @escaping (String?) -> Void,
        onExtractEntry: @escaping (ArchiveEntry) -> Void
    ) {
        self.init(
            filteredEntries: ArchiveFilteredEntriesView(source: filteredEntries),
            selectedEntryID: selectedEntryID,
            currentArchivePath: currentArchivePath,
            activePassword: activePassword,
            onSelectEntry: onSelectEntry,
            onReplaceEntry: nil,
            onDeleteEntry: nil,
            onExtractEntry: onExtractEntry
        )
    }
}



