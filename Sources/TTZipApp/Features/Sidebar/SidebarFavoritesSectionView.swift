// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipCore
import TTZipUI

/// Dedicated section view managing macOS Finder dynamic favorites and SFL authorization sync.
/// Isolates favorites list filtering and collapse state from neighboring sections.
public struct SidebarFavoritesSectionView: View {
    public let currentDirectory: URL
    public let isLocalLocationActive: Bool
    public let isIconRail: Bool
    @FocusState.Binding var focusedItem: SidebarRowIdentifier?
    public let onSelectDirectory: (URL) -> Void
    public let onQuickLook: (URL) -> Void
    public let onOpenInNewWindow: (URL) -> Void

    @AppStorage("TTZipSidebar_FavoritesCollapsed") private var isFavoritesCollapsed: Bool = false

    private var viewModel = FinderFavoritesViewModel.shared
    private var volumeManager = MountedVolumeManager.shared
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
        let mountedPaths = volumeManager.mountedPathSet
        let currentIdentity = viewModel.currentIdentity

        VStack(alignment: isIconRail ? .center : .leading, spacing: 2) {
            if !isIconRail {
                SidebarSectionHeaderView(
                    title: String(localized: "FAVORITES"),
                    isCollapsed: $isFavoritesCollapsed
                ) {
                    Button(action: authorizeFinderFavorites) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(viewModel.hasResolvedCustomFavorites ? Color.secondary : TTZipTheme.bambooGreen)
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.hasResolvedCustomFavorites
                        ? String(localized: "Finder Favorites Synced (Click to re-sync)")
                        : String(localized: "Sync macOS Finder Favorites..."))
                    .accessibilityLabel(String(localized: "Sync Finder Favorites"))
                }
            }

            if !isFavoritesCollapsed || isIconRail {
                ForEach(viewModel.dynamicFinderFavorites.filter { !mountedPaths.contains($0.path) }) { item in
                    let rowIdentifier = SidebarRowIdentifier(section: .favorites, id: item.path)
                    let isRovingTabTarget = (focusedItem?.id ?? currentDirectory.path) == item.path && (focusedItem?.section == .favorites || focusedItem == nil)
                    renderFavoriteRow(item: item, currentIdentity: currentIdentity, mountedPaths: mountedPaths, rowIdentifier: rowIdentifier)
                        .equatable()
                        .focused($focusedItem, equals: rowIdentifier)
                        .focusable(isRovingTabTarget)
                        .focusEffectDisabled()
                        .id(rowIdentifier)
                        .accessibilityIdentifier(item.path)
                }
            }
        }
        .animation(.ttMicro, value: isFavoritesCollapsed)
        .accessibilityRotor(String(localized: "Favorites")) {
            ForEach(viewModel.dynamicFinderFavorites.filter { !mountedPaths.contains($0.path) }) { item in
                AccessibilityRotorEntry(item.name, id: item.id)
            }
        }
        .task(id: currentDirectory) {
            viewModel.updateCurrentIdentity(for: currentDirectory)
        }
    }

    private func renderFavoriteRow(
        item: FinderFavoriteItem,
        currentIdentity: FileIdentity?,
        mountedPaths: Set<String>,
        rowIdentifier: SidebarRowIdentifier
    ) -> SidebarFavoriteRowView {
        let isSelected: Bool
        if let currentIdentity {
            isSelected = viewModel.isRowSelected(
                identity: item.identity,
                section: .favorites,
                currentIdentity: currentIdentity,
                mountedPaths: mountedPaths
            )
        } else {
            isSelected = item.path == currentDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        }
        let itemURL = URL(fileURLWithPath: item.path)

        return SidebarFavoriteRowView(
            title: item.name,
            icon: item.systemImage,
            path: item.path,
            isSelected: isLocalLocationActive && isSelected,
            isCustomPinned: false,
            isIconRail: isIconRail,
            isKeyboardFocused: focusedItem == rowIdentifier,
            onSelect: {
                if let bookmark = item.bookmarkData {
                    RootFolderAccessManager.shared.registerSecurityScopedBookmark(bookmark, for: item.path)
                }
                viewModel.activeSection = .favorites
                onSelectDirectory(itemURL)
            },
            onDropURLs: { urls in
                handleDropFilesIntoFolder(urls: urls, targetPath: item.path)
            },
            onQuickLook: {
                onQuickLook(itemURL)
            },
            onOpenInNewWindow: {
                onOpenInNewWindow(itemURL)
            }
        )
    }

    private func authorizeFinderFavorites() {
        viewModel.promptAuthorizeFinderFavorites {}
    }

    private func handleDropFilesIntoFolder(urls: [URL], targetPath: String) -> Bool {
        SidebarFileIngestionService.ingestFiles(urls: urls, targetPath: targetPath)
    }
}
