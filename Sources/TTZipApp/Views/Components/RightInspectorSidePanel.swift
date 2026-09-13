// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Right contextual Inspector side panel supporting Home and Compress modes.
public struct RightInspectorSidePanel: View {
    public var viewModel: AppViewState
    @Binding public var rightVerticalTopHeight: CGFloat
    private var l10n = AppLocalizationState.shared
    
    public init(viewModel: AppViewState, rightVerticalTopHeight: Binding<CGFloat> = .constant(300)) {
        self.viewModel = viewModel
        self._rightVerticalTopHeight = rightVerticalTopHeight
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 52pt Header strictly honoring Y=90pt Golden Line rule
            headerView
                .padding(.horizontal, 16)
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
                            onPreviewFile: { _ in
                                viewModel.openImmersiveMedia(for: item)
                            }
                        )
                        .id(item.path)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(Color.primary.opacity(0.025))
    }
    
    private var zenPlaceholderView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "circle.dotted")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(TTZipTheme.kintsugiGold.opacity(0.6))
            Text(l10n.t(L10n.Inspector.emptyDirectory))
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(.primary.opacity(0.8))
            Text(l10n.t(L10n.Inspector.emptyDirectoryDesc))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Header Components
    
    @ViewBuilder
    private var headerView: some View {
        if let item = viewModel.selectedDiskItem {
            selectedItemHeader(for: item)
        } else {
            directoryHeader
        }
    }
    
    @ViewBuilder
    private func selectedItemHeader(for item: DiskItemInfo) -> some View {
        HStack(alignment: .center, spacing: 10) {
            // Left: 28×28pt File Icon with Subtle Rounded Gradient Background
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(itemIconGradient(for: item))
                    .frame(width: 28, height: 28)
                Image(systemName: itemIconName(for: item))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            
            // Middle: Vertical 2-line Typography with prioritized expansion
            VStack(alignment: .leading, spacing: 1.5) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                
                HStack(spacing: 4) {
                    if !item.sizeText.isEmpty {
                        Text(item.sizeText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        
                        Text("•")
                            .font(.system(size: 7))
                            .foregroundStyle(.tertiary)
                    }
                    
                    Text(item.kindText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Right: Compact Action Buttons (Context Menu + Dismiss)
            HStack(spacing: 4) {
                // More Actions Menu
                Menu {
                    Button(action: {
                        viewModel.openImmersiveMedia(for: item)
                    }) {
                        Label(l10n.currentLanguage == .zhHans ? "全屏预览 (空格)" : "Quick Look (Space)", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    
                    Button(action: {
                        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                    }) {
                        Label(l10n.t(L10n.Common.revealInFinder), systemImage: "folder")
                    }
                    
                    if item.isArchive {
                        Button(action: {
                            viewModel.overlayState.inspectingArchivePath = item.path
                            viewModel.overlayState.showArchiveInspectorModal = true
                        }) {
                            Label(l10n.t(L10n.Diagnostics.title), systemImage: "doc.badge.gearshape")
                        }
                    }
                    
                    Divider()
                    
                    Button(role: .destructive, action: {
                        try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                        viewModel.selectedDiskItem = nil
                    }) {
                        Label(l10n.currentLanguage == .zhHans ? "移到废纸篓" : "Move to Trash", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help(l10n.currentLanguage == .zhHans ? "更多操作" : "More Actions")
                
                // Deselect / Close Button
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        viewModel.selectedDiskItem = nil
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n.t(L10n.Inspector.currentDirectory))
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
    
    @ViewBuilder
    private var directoryHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(l10n.t(L10n.Inspector.currentDirectory))
                    .font(.system(size: 8.5, weight: .bold, design: .serif))
                    .tracking(1.8)
                    .foregroundStyle(TTZipTheme.kintsugiGold)
                
                Text(FileManager.default.displayName(atPath: viewModel.currentDirectory.path))
                    .font(.system(size: 13.5, weight: .bold, design: .serif))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Visual Helpers
    
    private func itemIconName(for item: DiskItemInfo) -> String {
        if item.isDirectory { return "folder.fill" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if let fmt = ArchiveCompressionFormat.from(extensionOrName: ext) {
            return fmt.iconName
        }
        if item.isArchive { return "archivebox.fill" }
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"].contains(ext) { return "photo.fill" }
        if MediaPreviewFactory.videoExtensions.contains(ext) { return "film.fill" }
        if MediaPreviewFactory.audioExtensions.contains(ext) { return "music.note" }
        if ext == "pdf" { return "doc.richtext.fill" }
        if ["swift", "js", "ts", "py", "json", "html", "css", "cpp", "c", "h", "rs", "go", "sh", "xml"].contains(ext) { return "doc.text.fill" }
        return "doc.fill"
    }
    
    private func itemIconGradient(for item: DiskItemInfo) -> LinearGradient {
        if item.isDirectory {
            return LinearGradient(colors: [TTZipTheme.bambooGreen, TTZipTheme.bambooGreen.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if let fmt = ArchiveCompressionFormat.from(extensionOrName: ext) {
            switch fmt.category {
            case .standard:
                return LinearGradient(colors: [TTZipTheme.bambooGreen, TTZipTheme.bambooGreen.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .unixPackage:
                return LinearGradient(colors: [Color.orange, Color.red.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .diskImage:
                return LinearGradient(colors: [Color.indigo, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            case .modernStream:
                return LinearGradient(colors: [Color.teal, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        if item.isArchive {
            return LinearGradient(colors: [TTZipTheme.bambooGreen, TTZipTheme.bambooGreen.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"].contains(ext) {
            return LinearGradient(colors: [Color.purple, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if MediaPreviewFactory.videoExtensions.contains(ext) {
            return LinearGradient(colors: [Color.pink, Color.orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if MediaPreviewFactory.audioExtensions.contains(ext) {
            return LinearGradient(colors: [Color.teal, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if ext == "pdf" {
            return LinearGradient(colors: [Color.red, Color.orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(colors: [Color.blue, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
