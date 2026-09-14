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
            
            // 1.5pt Kintsugi Gold Line (Y=90pt Full-width Seamless Alignment)
            Rectangle()
                .fill(TTZipTheme.kintsugiGold)
                .frame(height: TTZipTheme.Layout.kintsugiGoldLineHeight)
            
            // Contextual Content Area: Directory Canvas, File Preview, or Current Directory Canvas
            VStack(alignment: .leading, spacing: 0) {
                if let fileItem = viewModel.activeInspectedFile ?? (viewModel.selectedDiskItem?.isDirectory == false ? viewModel.selectedDiskItem : nil) {
                    InspectorColumnView(
                        item: fileItem,
                        onSelectArchive: { archivePath in
                            Task { await viewModel.loadArchive(path: archivePath) }
                        },
                        onCompressPath: { folderPath in
                            viewModel.openCompressWorkspace(paths: [folderPath])
                        },
                        onPreviewFile: { _ in
                            viewModel.openImmersiveMedia(for: fileItem)
                        }
                    )
                    .id(fileItem.path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let item = viewModel.selectedDiskItem, item.isDirectory {
                    FolderMediaArtboardView(
                        item: item,
                        onCompressPath: { folderPath in
                            viewModel.openCompressWorkspace(paths: [folderPath])
                        }
                    )
                    .id(item.path)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    
    // MARK: - Zen Empty State
    
    @ViewBuilder
    private var zenPlaceholderView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "circle.dashed")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(TTZipTheme.bambooGreen.opacity(0.4))
            Text(l10n.currentLanguage == .zhHans ? "轻触选中文件以查看详情" : "Select an item to inspect")
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(.secondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Header Components
    
    private var activeHeaderItem: DiskItemInfo? {
        viewModel.activeInspectedFile ?? (viewModel.selectedDiskItem?.isDirectory == false ? viewModel.selectedDiskItem : nil) ?? viewModel.selectedDiskItem
    }
    
    @ViewBuilder
    private var headerView: some View {
        if let item = activeHeaderItem {
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
                    .foregroundStyle(Color.primary.opacity(0.85))
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
                    
                    let ext = URL(fileURLWithPath: item.path).pathExtension.uppercased()
                    Text(ext.isEmpty ? item.kindText : ext)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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
                        viewModel.clearInspectedFile()
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
                .menuIndicator(.hidden)
                .help(l10n.currentLanguage == .zhHans ? "更多操作" : "More Actions")
                .accessibilityLabel(l10n.currentLanguage == .zhHans ? "更多操作" : "More Actions")
                
                // Deselect Button (Return to Directory Overview)
                Button(action: {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        viewModel.clearInspectedFile()
                    }
                }) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n.currentLanguage == .zhHans ? "取消文件选中并返回目录概览" : "Deselect file and return to folder overview")
                .accessibilityLabel(l10n.currentLanguage == .zhHans ? "取消文件选中并返回目录概览" : "Deselect file and return to folder overview")
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
                    .foregroundStyle(TTZipTheme.kintsugiGoldEditorial)
                
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
            return LinearGradient(
                colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"].contains(ext) {
            return LinearGradient(
                colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        return LinearGradient(
            colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
