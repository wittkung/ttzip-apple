// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore

/// Home explorer container holding toolbar header and directory browser.
public struct HomeExplorerContainerView: View {
    public var viewModel: AppViewState
    @ObservedObject private var quickLookCoordinator = QuickLookPreviewCoordinator.shared
    @ObservedObject private var l10n = AppLocalizationState.shared
    public let isRightSidebarVisible: Bool
    public let isActive: Bool
    
    public init(viewModel: AppViewState, isRightSidebarVisible: Bool, isActive: Bool = true) {
        self.viewModel = viewModel
        self.isRightSidebarVisible = isRightSidebarVisible
        self.isActive = isActive
    }
    
    private var hasRightInspector: Bool {
        isRightSidebarVisible && viewModel.selectedDiskItem != nil && viewModel.selectedDiskItem?.isDirectory == false
    }
    
    public var body: some View {
        TTZipWorkspaceScaffold(
            title: l10n.t(L10n.Explorer.fileExplorer),
            isCardEnclosed: true
        ) {
            HStack(alignment: .center, spacing: 8) {
                Button(action: {
                    RootFolderAccessManager.shared.requestRootAccess(for: RootFolderAccessManager.shared.highestRootURL(for: viewModel.currentDirectory))
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 9, weight: .bold))
                        L10nText(L10n.Explorer.rootAccess)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(TTZipTheme.kintsugiGold.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .help("Grant root access to parent directory to browse without sandbox prompts")
                
                Button(action: {
                    viewModel.navigationState.triggerOmnibarFocus()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                        Text(viewModel.currentDirectory.lastPathComponent.isEmpty ? "/" : viewModel.currentDirectory.lastPathComponent)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 160)
                            .foregroundStyle(TTZipTheme.bambooGreen)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(TTZipTheme.bambooGreen.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .help("Current directory (Click or press ⌘L / ⇧⌘G to navigate by path)")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        } content: {
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
                    quickLookCoordinator.previewDiskFile(url: URL(fileURLWithPath: path))
                },
                onSelectItem: { item in
                    viewModel.selectedDiskItem = item
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .quickLookPreview($quickLookCoordinator.activePreviewURL)
    }
}
