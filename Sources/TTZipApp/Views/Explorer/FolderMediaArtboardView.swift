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
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                quickActionButtonsRow
                
                overviewSection
                
                contentBreakdownSection
            }
            .padding(14)
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
                    shortcut: nil,
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
                    shortcut: nil,
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
                    shortcut: nil,
                    action: {
                        showCreateFileAlert = true
                    }
                )
                
                QuickActionSegmentButton(
                    icon: "archivebox",
                    shortTitle: isZh ? "压缩" : "Zip",
                    fullTitle: isZh ? "压缩目录" : "Compress Folder",
                    width: w,
                    help: isZh ? "压缩此目录 (⌘N)" : "Compress Folder (⌘N)",
                    shortcut: "⌘N",
                    action: {
                        onCompressPath(item.path)
                    }
                )
                
                QuickActionSegmentButton(
                    icon: "doc.on.doc",
                    shortTitle: isZh ? "复制" : "Copy",
                    fullTitle: isZh ? "拷贝路径" : "Copy Path",
                    width: w,
                    help: isZh ? "拷贝路径" : "Copy Path",
                    shortcut: nil,
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
}

// MARK: - Inset Segmented Quick Action Button

private struct QuickActionSegmentButton: View {
    let icon: String
    let shortTitle: String
    let fullTitle: String
    let width: CGFloat
    let help: String
    let shortcut: String?
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(isHovered ? TTZipTheme.bambooGreen : Color.secondary)
                
                if width >= 320 {
                    Text(shortTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isHovered ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
        .overlay(alignment: .top) {
            if isHovered {
                HStack(spacing: 4) {
                    Text(fullTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.primary)
                    
                    if let sc = shortcut {
                        Text(sc)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(TTZipTheme.kintsugiGold)
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 3)
                .fixedSize()
                .offset(y: -28)
                .zIndex(999)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)),
                    removal: .opacity
                ))
                .allowsHitTesting(false)
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
