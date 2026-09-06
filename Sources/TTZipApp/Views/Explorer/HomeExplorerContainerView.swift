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
    @ObservedObject private var l10n = AppLocalizationState.shared
    public let isRightSidebarVisible: Bool
    public let isActive: Bool
    
    @State private var accessRefreshTrigger: Int = 0
    
    public init(viewModel: AppViewState, isRightSidebarVisible: Bool, isActive: Bool = true) {
        self.viewModel = viewModel
        self.isRightSidebarVisible = isRightSidebarVisible
        self.isActive = isActive
    }
    
    private var hasCurrentDirectoryAccess: Bool {
        _ = accessRefreshTrigger
        return RootFolderAccessManager.shared.hasActiveAccess(for: viewModel.currentDirectory)
    }
    
    public var body: some View {
        TTZipWorkspaceScaffold(
            title: l10n.t(L10n.Explorer.fileExplorer),
            isCardEnclosed: true
        ) {
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
                .help("Grant root access to parent directory to browse without sandbox prompts")
            }
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
                    viewModel.previewMediaFile(path: path)
                },
                onSelectItem: { item in
                    viewModel.selectedDiskItem = item
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

extension RootFolderAccessManager {
    /// Determines whether active read access is already granted for the target directory.
    public func hasActiveAccess(for url: URL) -> Bool {
        ensureAccess(for: url, promptIfMissing: false)
    }
}
