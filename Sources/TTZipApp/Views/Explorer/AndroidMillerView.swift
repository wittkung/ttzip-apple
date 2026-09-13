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

/// Multi-column Miller browsing view for connected Android devices with async directory prefetching,
/// file inspection preview, and drag-and-drop / download capabilities.
public struct AndroidMillerView: View {
    @Bindable public var viewModel: AndroidDeviceViewModel
    public var onInspectArchive: ((String) -> Void)? = nil
    public var onPreviewFile: ((String) -> Void)? = nil
    
    @State private var hoveredNodePath: String? = nil
    
    private let columnWidth: CGFloat = 240
    private let previewColumnWidth: CGFloat = 280
    
    public init(
        viewModel: AndroidDeviceViewModel = .shared,
        onInspectArchive: ((String) -> Void)? = nil,
        onPreviewFile: ((String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onInspectArchive = onInspectArchive
        self.onPreviewFile = onPreviewFile
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - 1. Top Navigation & Partition Bar
            AndroidHeaderView(viewModel: viewModel)
            
            // MARK: - 2. Miller Columns Canvas
            ZStack(alignment: .bottomTrailing) {
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: true) {
                        ScrollViewReader { scrollProxy in
                            HStack(alignment: .top, spacing: 0) {
                                // Dynamic Directory Columns
                                ForEach(Array(viewModel.columnPaths.enumerated()), id: \.offset) { index, path in
                                    millerColumn(path: path, depth: index)
                                        .frame(width: columnWidth)
                                        .id("col_\(index)")
                                    
                                    // Vertical column divider
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.06))
                                        .frame(width: 1)
                                }
                                
                                // Leaf File Inspector Column
                                if let selected = viewModel.selectedNode, selected.isFile {
                                    fileInspectorColumn(node: selected)
                                        .frame(width: previewColumnWidth)
                                        .id("inspector_col")
                                }
                            }
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                            .onChange(of: viewModel.columnPaths.count) { _, newCount in
                                withAnimation(.easeOut(duration: 0.22)) {
                                    scrollProxy.scrollTo("col_\(newCount - 1)", anchor: .trailing)
                                }
                            }
                            .onChange(of: viewModel.selectedNode?.id) { _, _ in
                                if viewModel.selectedNode?.isFile == true {
                                    withAnimation(.easeOut(duration: 0.22)) {
                                        scrollProxy.scrollTo("inspector_col", anchor: .trailing)
                                    }
                                }
                            }
                        }
                    }
                }
                
                // MARK: - 3. Floating Transfer Progress HUD
                if let transfer = viewModel.activeTransfer {
                    TransferProgressHUD(
                        job: transfer,
                        onCancel: {
                            viewModel.cancelActiveTransfer()
                        }
                    )
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TTZipTheme.paperWhite)
        .sheet(isPresented: $viewModel.showAdbGuideSheet) {
            AdbEnableGuideSheet(isPresented: $viewModel.showAdbGuideSheet)
        }
        .sheet(isPresented: $viewModel.showPairingSheet) {
            AndroidPairingSheet(isPresented: $viewModel.showPairingSheet, viewModel: viewModel)
        }
    }
    
    // MARK: - Single Miller Column
    
    private func millerColumn(path: String, depth: Int) -> some View {
        let items = viewModel.directoryCache[path]
        let isLoading = viewModel.loadingPaths.contains(path)
        
        return VStack(alignment: .leading, spacing: 0) {
            if isLoading && items == nil {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Reading Android VFS...")
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let items, items.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "folder")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("Empty Directory")
                        .font(.system(size: 11.5, design: .serif))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let items {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 1) {
                        ForEach(items) { node in
                            nodeRow(node: node, depth: depth)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(depth % 2 == 0 ? Color.primary.opacity(0.015) : Color.clear)
    }
    
    // MARK: - Node Row View
    
    private func nodeRow(node: AndroidStorageNode, depth: Int) -> some View {
        let isSelected = viewModel.selectedNodeByColumn[depth]?.id == node.id
        let isHovered = hoveredNodePath == node.path
        
        return HStack(spacing: 7) {
            // Node icon
            Image(systemName: nodeIconName(node: node))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(nodeIconColor(node: node, isSelected: isSelected))
                .frame(width: 16)
            
            // Node name
            Text(node.name)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : Color.primary.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer(minLength: 2)
            
            // Trailing indicator: restricted lock or folder chevron
            if node.isRestricted {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TTZipTheme.archiveAmber)
            } else if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(rowBackgroundColor(isSelected: isSelected, isHovered: isHovered))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isSelected ? TTZipTheme.bambooGreen.opacity(0.35) : Color.clear, lineWidth: 0.8)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredNodePath = hovering ? node.path : nil
        }
        .onTapGesture {
            viewModel.selectNode(node, atColumn: depth)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                handleDoubleTap(node: node, depth: depth)
            }
        )
        .contextMenu {
            Button("Download to Downloads Folder") {
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                let localDest = downloads.appendingPathComponent(node.name)
                viewModel.downloadNode(node, to: localDest)
            }
            
            if isArchive(node.name) {
                Button("Inspect Archive Directly") {
                    onInspectArchive?(node.path)
                }
            }
            
            Divider()
            
            Button("Copy Android Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }
        }
    }
    
    // MARK: - Leaf File Inspector Column
    
    private func fileInspectorColumn(node: AndroidStorageNode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Icon & Name
            VStack(spacing: 8) {
                Image(systemName: nodeIconName(node: node))
                    .font(.system(size: 40))
                    .foregroundStyle(nodeIconColor(node: node, isSelected: true))
                    .padding(.top, 16)
                
                Text(node.name)
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)
            
            Divider()
                .opacity(0.5)
            
            // Metadata Grid
            VStack(alignment: .leading, spacing: 8) {
                metadataRow(label: "File Size", value: formatBytes(node.sizeBytes))
                metadataRow(label: "Modified", value: formatDate(node.modifiedDate))
                metadataRow(label: "Kind", value: fileKindDescription(node.name))
                metadataRow(label: "Protocol", value: viewModel.selectedDevice?.connectionType.description ?? "MTP")
                if let handle = node.objectHandle {
                    metadataRow(label: "Object Handle", value: String(format: "0x%08X", handle))
                }
                metadataRow(label: "Android Path", value: node.path)
            }
            .padding(.horizontal, 12)
            
            Spacer()
            
            // Action Buttons
            VStack(spacing: 8) {
                if isArchive(node.name) {
                    Button(action: {
                        onInspectArchive?(node.path)
                    }) {
                        HStack {
                            Image(systemName: "archivebox.fill")
                            Text("Inspect Remote Archive")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(TTZipTheme.bambooGreen)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: {
                    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                    let localDest = downloads.appendingPathComponent(node.name)
                    viewModel.downloadNode(node, to: localDest)
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text("Download to Mac")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.02))
    }
    
    private func metadataRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold, design: .serif))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    
    // MARK: - Interaction Handlers
    
    private func handleDoubleTap(node: AndroidStorageNode, depth: Int) {
        if node.isDirectory {
            viewModel.selectNode(node, atColumn: depth)
        } else if isArchive(node.name) {
            onInspectArchive?(node.path)
        } else {
            onPreviewFile?(node.path)
        }
    }
    
    // MARK: - Helpers & Styling
    
    private func rowBackgroundColor(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return TTZipTheme.bambooGreen.opacity(0.14)
        } else if isHovered {
            return Color.primary.opacity(0.03)
        } else {
            return Color.clear
        }
    }
    
    private func nodeIconName(node: AndroidStorageNode) -> String {
        if node.isDirectory {
            return "folder.fill"
        }
        let ext = URL(fileURLWithPath: node.name).pathExtension.lowercased()
        switch ext {
        case "zip", "7z", "tar", "gz", "bz2", "xz", "rar":
            return "doc.zipper"
        case "jpg", "jpeg", "png", "webp", "gif", "heic":
            return "photo"
        case "mp4", "mkv", "mov", "webm", "avi":
            return "film"
        case "mp3", "flac", "aac", "wav", "m4a":
            return "music.note"
        case "pdf":
            return "doc.text.fill"
        case "apk":
            return "shippingbox.fill"
        default:
            return "doc"
        }
    }
    
    private func nodeIconColor(node: AndroidStorageNode, isSelected: Bool) -> Color {
        if isSelected {
            return TTZipTheme.bambooGreen
        }
        if node.isDirectory {
            return node.isRestricted ? TTZipTheme.archiveAmber : .secondary
        }
        let ext = URL(fileURLWithPath: node.name).pathExtension.lowercased()
        switch ext {
        case "zip", "7z", "tar", "gz", "bz2", "xz", "rar":
            return TTZipTheme.bambooGreen
        case "apk":
            return TTZipTheme.kintsugiGold
        default:
            return .secondary.opacity(0.8)
        }
    }
    
    private func isArchive(_ name: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ["zip", "7z", "tar", "gz", "tgz", "bz2", "xz", "rar"].contains(ext)
    }
    
    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func fileKindDescription(_ name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.uppercased()
        return ext.isEmpty ? "File" : "\(ext) Document"
    }
}
