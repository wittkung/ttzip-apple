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

/// Right contextual Inspector side panel supporting Home and Compress modes.
public struct RightInspectorSidePanel: View {
    public var viewModel: AppViewState
    @Binding public var rightVerticalTopHeight: CGFloat
    
    public init(viewModel: AppViewState, rightVerticalTopHeight: Binding<CGFloat> = .constant(300)) {
        self.viewModel = viewModel
        self._rightVerticalTopHeight = rightVerticalTopHeight
    }
    
    private var headerSectionTitle: String {
        if let item = viewModel.selectedDiskItem {
            return item.isDirectory ? "DIRECTORY CANVAS" : "INSPECTOR"
        }
        return "CURRENT DIRECTORY"
    }
    
    private var headerItemName: String {
        if let item = viewModel.selectedDiskItem {
            return item.name
        }
        let folderName = viewModel.currentDirectory.lastPathComponent
        return folderName.isEmpty ? "Macintosh HD" : folderName
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 52pt Header strictly honoring Y=90pt Golden Line rule
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(headerSectionTitle)
                        .font(.system(size: 8.5, weight: .bold, design: .serif))
                        .tracking(1.8)
                        .foregroundStyle(TTZipTheme.kintsugiGold)
                    
                    Text(headerItemName)
                        .font(.system(size: 13.5, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if let item = viewModel.selectedDiskItem, item.isArchive {
                    Button(action: {
                        viewModel.overlayState.inspectingArchivePath = item.path
                        viewModel.overlayState.showArchiveInspectorModal = true
                    }) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.system(size: 13))
                            .foregroundStyle(TTZipTheme.archiveAmber)
                    }
                    .buttonStyle(.plain)
                    .help("View archive standards and compliance diagnostics...")
                }
                
                if viewModel.selectedDiskItem != nil {
                    Button(action: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            viewModel.selectedDiskItem = nil
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Clear selection and view current directory canvas")
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            
            // 1.5pt Kintsugi Gold Line (Y=90pt Alignment)
            Rectangle()
                .fill(TTZipTheme.kintsugiGold)
                .frame(height: 1.5)
            
            // Contextual Content Area: Directory Canvas, File Preview, or Current Directory Canvas
            VStack(alignment: .leading, spacing: 0) {
                if let item = viewModel.selectedDiskItem {
                    if item.isDirectory {
                        FolderMediaArtboardView(
                            item: item,
                            onCompressPath: { folderPath in
                                viewModel.openCompressWorkspace(paths: [folderPath])
                            }
                        )
                        .id(item.path)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        InspectorColumnView(
                            item: item,
                            onSelectArchive: { archivePath in
                                Task { await viewModel.loadArchive(path: archivePath) }
                            },
                            onCompressPath: { folderPath in
                                viewModel.openCompressWorkspace(paths: [folderPath])
                            },
                            onPreviewFile: { _ in }
                        )
                        .id(item.path)
                        .frame(maxHeight: .infinity)
                    }
                } else {
                    let currentFolderItem = DiskItemInfo(url: viewModel.currentDirectory)
                    if currentFolderItem.isDirectory {
                        FolderMediaArtboardView(
                            item: currentFolderItem,
                            onCompressPath: { folderPath in
                                viewModel.openCompressWorkspace(paths: [folderPath])
                            }
                        )
                        .id(viewModel.currentDirectory.path)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        zenPlaceholderView
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
    
    private var zenPlaceholderView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "circle.dotted")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(TTZipTheme.kintsugiGold.opacity(0.6))
            Text("Zen Workspace")
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(.primary.opacity(0.8))
            Text("Select an item in the explorer to inspect")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
