// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

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
    
    @State private var accessRefreshTrigger: Int = 0
    
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
        return RootFolderAccessManager.shared.hasActiveAccess(for: viewModel.currentDirectory)
    }
    
    public var body: some View {
        TTZipWorkspaceScaffold(
            isEdgeToEdge: true,
            headerLeading: {
                HStack(spacing: 8) {
                    if !isLeftSidebarVisible, let onToggle = onToggleLeftSidebar {
                        Button(action: onToggle) {
                            Image(systemName: "sidebar.leading")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(TTZipTheme.bambooGreen)
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(l10n.currentLanguage == .zhHans ? "显示常用目录边栏 (⌃⌘S)" : "Show Favorites Sidebar (⌃⌘S)")
                    }
                    
                    SegmentedBreadcrumbCapsuleView(viewModel: viewModel)
                    
                    SpotlightSearchCapsuleView(viewModel: viewModel)
                }
            },
            headerTrailing: {
                HStack(spacing: 8) {
                    if let onOpen = onOpenArchive {
                        Button(action: onOpen) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(l10n.t(L10n.Menu.openArchive) + " (⌘O)")
                    }
                    
                    if let onNew = onNewArchive {
                        NewArchiveToolbarButton(
                            title: l10n.currentLanguage == .zhHans ? "新建压缩" : "New Archive",
                            action: onNew
                        )
                    }
                    
                    if let onToggleRight = onToggleRightSidebar {
                        Button(action: onToggleRight) {
                            Image(systemName: "sidebar.trailing")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(isRightSidebarVisible ? TTZipTheme.bambooGreen : Color.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(l10n.currentLanguage == .zhHans ? "切换检视器面板 (⌥⌘I)" : "Toggle Inspector Panel (⌥⌘I)")
                    }
                    
                    if !hasCurrentDirectoryAccess {
                        Button(action: {
                            let rootURL = RootFolderAccessManager.shared.highestRootURL(for: viewModel.currentDirectory)
                            if RootFolderAccessManager.shared.requestRootAccess(for: rootURL) {
                                accessRefreshTrigger &+= 1
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.open")
                                    .font(.system(size: 9.5, weight: .medium))
                                L10nText(L10n.Explorer.rootAccess)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(Color.primary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                            )
                        }
                        .buttonStyle(.plain)
                        .fixedSize(horizontal: true, vertical: false)
                        .l10nHelp(L10n.Explorer.rootAccessHelp)
                    }
                }
            },
            content: {
                VStack(spacing: 0) {
                    MultiDirectoryTabBarView(viewModel: viewModel)
                    
                    DiskDirectoryBrowserView(
                        rootDirectory: viewModel.currentDirectory,
                        isActive: isActive,
                        onSelectArchive: { archivePath in
                            let u = URL(fileURLWithPath: archivePath)
                            viewModel.openArchiveAsFolder(url: u)
                        },
                        onCompressPath: { folderPath in
                            viewModel.openCompressWorkspace(paths: [folderPath])
                        },
                        onPreviewFile: { path in
                            let item = DiskItemInfo(url: URL(fileURLWithPath: path), isDirectory: false)
                            viewModel.openImmersiveMedia(for: item)
                        },
                        onSelectItem: { item in
                            viewModel.selectedDiskItem = item
                            if !item.isDirectory {
                                viewModel.activeInspectedFile = item
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        )
    }
}

extension RootFolderAccessManager {
    /// Determines whether active read access is already granted for the target directory.
    public func hasActiveAccess(for url: URL) -> Bool {
        ensureAccess(for: url, promptIfMissing: false)
    }
}
