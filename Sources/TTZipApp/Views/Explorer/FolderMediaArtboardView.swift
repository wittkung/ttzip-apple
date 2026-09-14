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

public struct FolderMediaArtboardView: View {
    public let item: DiskItemInfo
    public let onCompressPath: (String) -> Void
    var l10n = AppLocalizationState.shared
    
    @State var totalSizeBytes: Int64 = 0
    @State var subfolderCount: Int = 0
    @State var fileCount: Int = 0
    @State var isCalculating: Bool = true
    @State var fileTypeDistribution: [(category: String, count: Int)] = []
    @State var showCreateSubfolderAlert: Bool = false
    @State var newSubfolderName: String = "Untitled Folder"
    @State var showCreateFileAlert: Bool = false
    @State var newSubfileName: String = "Untitled.txt"
    
    public init(item: DiskItemInfo, onCompressPath: @escaping (String) -> Void) {
        self.item = item
        self.onCompressPath = onCompressPath
    }
    
    var formattedFolderSize: String {
        if isCalculating { return l10n.t(L10n.Common.calculating) }
        return ByteCountFormatterFlyweight.shared.string(fromByteCount: totalSizeBytes)
    }
    
    var formattedDate: String {
        guard let d = item.modificationDate else { return l10n.t(L10n.Common.unknown) }
        return DateFormatterCache.shared.string(fromShortDateTime: d)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    quickActionButtonsRow
                    
                    overviewSection
                    
                    contentBreakdownSection
                }
                .padding(14)
            }
            
            bottomPinnedActionBar
        }
        .background(Color.clear)
        .alert(l10n.t(L10n.Explorer.newFolder), isPresented: $showCreateSubfolderAlert) {
            TextField(l10n.t(L10n.Explorer.folderName), text: $newSubfolderName)
            Button(l10n.t(L10n.Common.cancel), role: .cancel) {
                newSubfolderName = "Untitled Folder"
            }
            Button(l10n.t(L10n.Explorer.create), action: createNewFolder)
        } message: {
            Text(l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
                ? "在以下位置创建新文件夹：\n\(item.path)"
                : "Creating new folder in:\n\(item.path)")
        }
        .alert(l10n.t(L10n.Explorer.newFile), isPresented: $showCreateFileAlert) {
            TextField(l10n.t(L10n.Explorer.fileName), text: $newSubfileName)
            Button(l10n.t(L10n.Common.cancel), role: .cancel) {
                newSubfileName = "Untitled.txt"
            }
            Button(l10n.t(L10n.Explorer.create), action: createNewFile)
        } message: {
            Text(l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
                ? "在以下位置创建新文件：\n\(item.path)"
                : "Creating new empty file in:\n\(item.path)")
        }
        .task(id: item.path) {
            await calculateStats()
        }
    }
    
    private var quickActionButtonsRow: some View {
        GeometryReader { btnGeo in
            let w = btnGeo.size.width
            let isZh = l10n.currentLanguage == .zhHans || l10n.currentLanguage == .zhHant
            HStack(spacing: 2) {
                QuickActionSegmentButton(
                    icon: "folder",
                    shortTitle: isZh ? "访达" : "Reveal",
                    fullTitle: l10n.t(L10n.Common.revealInFinder),
                    width: w,
                    help: l10n.t(L10n.Common.revealInFinder),
                    action: {
                        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                    }
                )
                
                QuickActionSegmentButton(
                    icon: "folder.badge.plus",
                    shortTitle: isZh ? "新建" : "Folder",
                    fullTitle: l10n.t(L10n.Explorer.newFolder),
                    width: w,
                    help: l10n.t(L10n.Explorer.newFolder),
                    action: {
                        showCreateSubfolderAlert = true
                    }
                )
                
                QuickActionSegmentButton(
                    icon: "doc.badge.plus",
                    shortTitle: isZh ? "文件" : "File",
                    fullTitle: l10n.t(L10n.Explorer.newFile),
                    width: w,
                    help: l10n.t(L10n.Explorer.newFile),
                    action: {
                        showCreateFileAlert = true
                    }
                )
                
                QuickActionSegmentButton(
                    icon: "doc.on.doc",
                    shortTitle: isZh ? "复制" : "Copy",
                    fullTitle: isZh ? "拷贝路径" : "Copy Path",
                    width: w,
                    help: isZh ? "拷贝路径" : "Copy Path",
                    action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.path, forType: .string)
                    }
                )
            }
            .padding(2)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(TTZipUniversalTokens.Border.subtle, lineWidth: 0.5)
            )
        }
        .frame(height: 28)
        .padding(.bottom, 4)
    }
    
    private var bottomPinnedActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            
            Button(action: { onCompressPath(item.path) }) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text(l10n.t(L10n.Common.newArchiveShortcut))
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)
                    }
                    
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(l10n.t(L10n.Sidebar.newArchive))
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                    }
                    
                    HStack(spacing: 4) {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(l10n.t(L10n.Compress.startAction))
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        TTZipTheme.bambooGreen
                        LinearGradient(
                            colors: [Color.white.opacity(0.06), Color.black.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(TTZipUniversalTokens.Border.specularHairline, lineWidth: TTZipUniversalTokens.Dimensions.hairlineWidth)
                )
                .shadow(color: TTZipTheme.bambooGreen.opacity(0.25), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .padding(14)
            .help(l10n.t(L10n.Common.newArchiveShortcut))
            .accessibilityLabel(l10n.t(L10n.Common.newArchiveShortcut))
        }
        .background(Color.clear)
    }
}

// MARK: - Inset Segmented Quick Action Button

private struct QuickActionSegmentButton: View {
    let icon: String
    let shortTitle: String
    let fullTitle: String
    let width: CGFloat
    let help: String
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                
                if width >= 260 {
                    Text(width > 400 ? fullTitle : shortTitle)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isHovered ? Color.primary : Color.primary.opacity(0.75))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(help)
        .accessibilityLabel(fullTitle)
    }
}

// MARK: - Universal Border Subtle Compatibility

private extension TTZipUniversalTokens.Border {
    static var subtle: Color {
        specularHairline
    }
}
