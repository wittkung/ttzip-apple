// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

public struct CompressFileListView: View {
    @Binding public var itemsList: [CompressFileItem]
    @Binding public var selectedItemIDs: Set<CompressFileItem.ID>
    
    public let totalSizeBytes: Int64
    public let onAddFiles: () -> Void
    public let onAddFolder: () -> Void
    public let onClearAll: () -> Void
    public let onRemoveSelected: () -> Void
    
    public init(
        itemsList: Binding<[CompressFileItem]>,
        selectedItemIDs: Binding<Set<CompressFileItem.ID>>,
        totalSizeBytes: Int64,
        onAddFiles: @escaping () -> Void,
        onAddFolder: @escaping () -> Void,
        onClearAll: @escaping () -> Void,
        onRemoveSelected: @escaping () -> Void
    ) {
        self._itemsList = itemsList
        self._selectedItemIDs = selectedItemIDs
        self.totalSizeBytes = totalSizeBytes
        self.onAddFiles = onAddFiles
        self.onAddFolder = onAddFolder
        self.onClearAll = onClearAll
        self.onRemoveSelected = onRemoveSelected
    }
    
    private var l10n = AppLocalizationState.shared
    
    @State private var isClearHovered = false
    @State private var isRemoveSelectedHovered = false
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                    L10nText(L10n.Compress.sourceFiles)
                        .font(.system(size: 13, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    Text("(\(l10n.plural(key: L10n.Units.itemsCount, count: itemsList.count)) · \(formatBytes(totalSizeBytes)))")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                
                Spacer(minLength: 4)
                
                HStack(spacing: 5) {
                    ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        Button(action: onAddFiles) {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.badge.plus")
                                    .font(.system(size: 10))
                                L10nText(L10n.Compress.addFiles)
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        
                        Button(action: onAddFolder) {
                            HStack(spacing: 3) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 10))
                                L10nText(L10n.Compress.addFolder)
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    Menu {
                        Button(action: onAddFiles) {
                            L10nLabel(L10n.Compress.addFilesEllipsis, systemImage: "doc.badge.plus")
                        }
                        Button(action: onAddFolder) {
                            L10nLabel(L10n.Compress.addFolderEllipsis, systemImage: "folder.badge.plus")
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(TTZipTheme.bambooGreen)
                            L10nText(L10n.Compress.addShort)
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                }    
                    if !selectedItemIDs.isEmpty {
                        Button(action: onRemoveSelected) {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(isRemoveSelectedHovered ? Color.red : Color.red.opacity(0.75))
                                .scaleEffect(isRemoveSelectedHovered ? 1.1 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                isRemoveSelectedHovered = hovering
                            }
                        }
                        .help(l10n.t(L10n.Compress.removeSelected))
                    }
                    
                    if !itemsList.isEmpty {
                        Button(action: onClearAll) {
                            L10nText(L10n.Common.clear)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(isClearHovered ? Color.red.opacity(0.9) : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    isClearHovered ? Color.red.opacity(0.08) : Color.clear
                                )
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isClearHovered = hovering
                            }
                        }
                        .help(l10n.t(L10n.Compress.clearAll))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }
            
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(TTZipTheme.hairlineBorder, lineWidth: TTZipTheme.Layout.hairlineBorderWidth)
                    )
                
                if itemsList.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(TTZipTheme.bambooGreen.opacity(0.6))
                        L10nText(L10n.Compress.dropPrompt)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                } else {
                    fileListContent
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url = url {
                            Task { @MainActor in
                                if !itemsList.contains(where: { $0.path == url.path }) {
                                    let item = CompressFileItem(path: url.path)
                                    itemsList.append(item)
                                    if item.isDirectory && item.isCalculating {
                                        Task.detached(priority: .userInitiated) {
                                            let comp = ArchiveComponentTreeBuilder.buildTree(fromDiskPath: url.path)
                                            let computedSize = comp.sizeBytes
                                            Task { @MainActor in
                                                if let idx = itemsList.firstIndex(where: { $0.id == item.id }) {
                                                    itemsList[idx].size = computedSize
                                                    itemsList[idx].component = comp
                                                    itemsList[idx].isCalculating = false
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                return true
            }
        }
    }
    
    @ViewBuilder
    private var fileListContent: some View {
        if itemsList.count <= 4 {
            VStack(spacing: 0) {
                ForEach(Array(itemsList.enumerated()), id: \.element.id) { index, item in
                    CompressFileRowView(
                        item: item,
                        isSelected: selectedItemIDs.contains(item.id),
                        formattedSize: formatBytes(item.size),
                        onToggleSelect: {
                            if selectedItemIDs.contains(item.id) {
                                selectedItemIDs.remove(item.id)
                            } else {
                                selectedItemIDs.insert(item.id)
                            }
                        },
                        onRemove: {
                            if let idx = itemsList.firstIndex(where: { $0.id == item.id }) {
                                itemsList.remove(at: idx)
                                selectedItemIDs.remove(item.id)
                            }
                        }
                    )
                    if index < itemsList.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(.vertical, 2)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(itemsList.enumerated()), id: \.element.id) { index, item in
                        CompressFileRowView(
                            item: item,
                            isSelected: selectedItemIDs.contains(item.id),
                            formattedSize: formatBytes(item.size),
                            onToggleSelect: {
                                if selectedItemIDs.contains(item.id) {
                                    selectedItemIDs.remove(item.id)
                                } else {
                                    selectedItemIDs.insert(item.id)
                                }
                            },
                            onRemove: {
                                if let idx = itemsList.firstIndex(where: { $0.id == item.id }) {
                                    itemsList.remove(at: idx)
                                    selectedItemIDs.remove(item.id)
                                }
                            }
                        )
                        if index < itemsList.count - 1 {
                            Divider().opacity(0.3)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 180)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [Color.clear, Color.primary.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 24)
                .allowsHitTesting(false)
            }
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatterCache.string(fromByteCount: bytes)
    }
}

/// Interactive row representing a single file or directory item staged for compression.
private struct CompressFileRowView: View {
    let item: CompressFileItem
    let isSelected: Bool
    let formattedSize: String
    let onToggleSelect: () -> Void
    let onRemove: () -> Void
    
    @State private var isRowHovered = false
    @State private var isDeleteHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(item.isDirectory ? TTZipTheme.bambooGreen : Color.blue)
                .font(.system(size: 13))
            
            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            if item.isCalculating {
                L10nText(L10n.Common.calculating)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            } else {
                Text(formattedSize)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(
                        isDeleteHovered
                            ? Color.red.opacity(0.9)
                            : (isRowHovered ? Color.secondary : Color.secondary.opacity(0.4))
                    )
                    .scaleEffect(isDeleteHovered ? 1.15 : 1.0)
            }
            .buttonStyle(.plain)
            .help(AppLocalizationState.shared.t(L10n.Compress.removeItem))
            .onHover { hovering in
                withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                    isDeleteHovered = hovering
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? TTZipTheme.bambooGreen.opacity(0.12)
                : (isRowHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isRowHovered = hovering
            }
        }
        .onTapGesture {
            onToggleSelect()
        }
    }
}

