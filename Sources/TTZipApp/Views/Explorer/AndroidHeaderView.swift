// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

/// Top navigation and partition switching header bar for Android device browsing.
public struct AndroidHeaderView: View {
    @Bindable public var viewModel: AndroidDeviceViewModel
    public var windowID: UUID? = nil
    
    @State private var hoveredBreadcrumbIndex: Int? = nil
    private var l10n: AppLocalizationState { AppLocalizationState.shared }
    
    public init(viewModel: AndroidDeviceViewModel = .shared, windowID: UUID? = nil) {
        self.viewModel = viewModel
        self.windowID = windowID
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // MARK: - 1. Partition Volume Selector Menu
                partitionSelectorMenu
                
                Divider()
                    .frame(height: 16)
                    .opacity(0.4)
                
                // MARK: - 2. Breadcrumb Navigation Path Bar
                breadcrumbPathBar
                
                Spacer(minLength: 8)
                
                // MARK: - 3. Connection Status Capsule & Fast Mode Toggle
                connectionStatusPill
                
                // MARK: - 4. Quick Action Controls
                headerActionButtons
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(.ultraThinMaterial)
            
            // Subtle specular hairline divider
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }
    
    // MARK: - Subviews

    private var activeDevice: AndroidDevice? {
        if let winID = windowID {
            return viewModel.activeDevice(forWindow: winID) ?? viewModel.selectedDevice
        }
        return viewModel.selectedDevice
    }

    private var activePartition: AndroidStoragePartition? {
        viewModel.selectedPartition(forWindow: windowID)
    }

    private var activeColumnPaths: [String] {
        viewModel.columnPaths(forWindow: windowID)
    }
    
    private var partitionSelectorMenu: some View {
        Menu {
            if let partitions = activeDevice?.storagePartitions, !partitions.isEmpty {
                ForEach(partitions) { partition in
                    Button(action: {
                        viewModel.selectPartition(partition, windowID: windowID)
                    }) {
                        HStack {
                            Text(partition.displayName)
                            Spacer()
                            Text(formatPartitionCapacity(partition))
                            if activePartition?.partitionId == partition.partitionId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } else {
                Text(l10n.uiString(zh: "未检测到存储分区", en: "No Partitions Detected"))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: partitionIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(activePartition?.displayName ?? l10n.uiString(zh: "选择存储空间", en: "Select Storage"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    if let part = activePartition {
                        Text(formatPartitionCapacity(part))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    private var partitionIcon: String {
        if let part = activePartition, part.isRemovable {
            return "sdcard"
        }
        return "internaldrive"
    }
    
    private var breadcrumbPathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Root Device segment
                breadcrumbSegment(
                    title: activeDevice?.displayName ?? l10n.uiString(zh: "Android 设备", en: "Android Device"),
                    systemImage: "iphone",
                    index: -1,
                    isLeaf: activeColumnPaths.isEmpty
                )
                
                // Active column path segments
                ForEach(Array(activeColumnPaths.enumerated()), id: \.offset) { index, path in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    
                    let title = pathSegmentName(path: path, index: index)
                    let isLeaf = index == activeColumnPaths.count - 1
                    breadcrumbSegment(
                        title: title,
                        systemImage: index == 0 ? "internaldrive" : "folder",
                        index: index,
                        isLeaf: isLeaf
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func pathSegmentName(path: String, index: Int) -> String {
        if index == 0 {
            return activePartition?.displayName ?? l10n.uiString(zh: "存储根目录", en: "Storage Root")
        }
        let comp = URL(fileURLWithPath: path).lastPathComponent
        return comp.isEmpty ? path : comp
    }
    
    private func breadcrumbSegment(title: String, systemImage: String, index: Int, isLeaf: Bool) -> some View {
        let isHovered = hoveredBreadcrumbIndex == index
        
        return Button(action: {
            if index >= 0 {
                viewModel.navigateToBreadcrumbIndex(index, windowID: windowID)
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: isLeaf ? .bold : .medium))
                    .foregroundStyle(isLeaf ? TTZipTheme.bambooGreen : .secondary)
                
                Text(title)
                    .font(.system(size: 11, weight: isLeaf ? .semibold : .regular, design: .serif))
                    .foregroundStyle(isLeaf ? .primary : Color.primary.opacity(0.85))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredBreadcrumbIndex = hovering ? index : nil
        }
    }
    
    private var connectionStatusPill: some View {
        Group {
            if let device = activeDevice {
                Button(action: {
                    if device.connectionType == .usbMtp {
                        viewModel.showAdbGuideSheet = true
                    }
                }) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusIndicatorColor(type: device.connectionType))
                            .frame(width: 6, height: 6)
                        
                        Text(statusTitle(type: device.connectionType))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        
                        if device.connectionType == .usbMtp {
                            Image(systemName: "arrow.up.forward.circle.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(TTZipTheme.archiveAmber)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(statusBackgroundColor(type: device.connectionType))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(statusBorderColor(type: device.connectionType), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help(device.connectionType == .usbMtp
                    ? l10n.uiString(zh: "点击查看 ADB 高速模式指南", en: "Click to view High-Speed ADB guide")
                    : l10n.uiString(zh: "设备已连接并正常运行", en: "Connected and operational")
                )
            }
        }
    }
    
    private func statusTitle(type: AndroidConnectionType) -> String {
        switch type {
        case .usbMtp:
            return l10n.uiString(zh: "MTP 模式", en: "MTP Mode")
        case .usbAdb:
            return l10n.uiString(zh: "ADB 高速模式", en: "ADB High-Speed")
        case .wirelessAdb:
            return l10n.uiString(zh: "无线调试", en: "Wi-Fi Debug")
        }
    }
    
    private func statusIndicatorColor(type: AndroidConnectionType) -> Color {
        switch type {
        case .usbMtp:
            return TTZipTheme.archiveAmber
        case .usbAdb:
            return TTZipTheme.bambooGreen
        case .wirelessAdb:
            return TTZipTheme.kintsugiGold
        }
    }
    
    private func statusBackgroundColor(type: AndroidConnectionType) -> Color {
        switch type {
        case .usbMtp:
            return TTZipTheme.archiveAmber.opacity(0.12)
        case .usbAdb:
            return TTZipTheme.bambooGreen.opacity(0.15)
        case .wirelessAdb:
            return TTZipTheme.kintsugiGold.opacity(0.15)
        }
    }
    
    private func statusBorderColor(type: AndroidConnectionType) -> Color {
        switch type {
        case .usbMtp:
            return TTZipTheme.archiveAmber.opacity(0.35)
        case .usbAdb:
            return TTZipTheme.bambooGreen.opacity(0.4)
        case .wirelessAdb:
            return TTZipTheme.kintsugiGold.opacity(0.4)
        }
    }
    
    private var headerActionButtons: some View {
        HStack(spacing: 6) {
            // Upload local file to current Android directory
            Button(action: {
                presentUploadPanel()
            }) {
                Image(systemName: "arrow.up.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(l10n.uiString(zh: "上传文件到当前目录", en: "Upload File to Directory"))
            .accessibilityLabel(l10n.uiString(zh: "上传文件到当前目录", en: "Upload File to Directory"))

            // Download selected remote file to local Mac
            let selectedNode = viewModel.selectedNode(forWindow: windowID)
            if let node = selectedNode, !node.isDirectory {
                Button(action: {
                    presentDownloadPanel(for: node)
                }) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TTZipTheme.bambooGreen)
                        .frame(width: 26, height: 26)
                        .background(TTZipTheme.bambooGreen.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(l10n.uiString(zh: "下载选中文件到 Mac", en: "Download Selected File to Mac"))
                .accessibilityLabel(l10n.uiString(zh: "下载选中文件到 Mac", en: "Download Selected File to Mac"))
            }

            // Reload / Refresh
            Button(action: {
                let path = viewModel.currentDirectoryPath(forWindow: windowID)
                Task {
                    await viewModel.loadDirectoryContents(path: path, forceReload: true, windowID: windowID)
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(l10n.uiString(zh: "刷新目录", en: "Refresh Directory"))
            .accessibilityLabel(l10n.uiString(zh: "刷新目录", en: "Refresh Directory"))
            
            // Eject device
            if let device = activeDevice {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let winID = windowID {
                            viewModel.bindWindow(winID, toDevice: nil)
                        }
                        viewModel.ejectDevice(device)
                    }
                }) {
                    Image(systemName: "eject.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(l10n.uiString(zh: "推出设备", en: "Eject Device"))
                .accessibilityLabel(l10n.uiString(zh: "推出设备", en: "Eject Device"))
            }
        }
    }
    
    private func presentUploadPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = l10n.uiString(zh: "选择要上传到 Android 设备的文件", en: "Select file to upload")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                let targetDir = viewModel.currentDirectoryPath(forWindow: windowID)
                viewModel.uploadLocalFile(url, to: targetDir)
            }
        }
    }

    private func presentDownloadPanel(for node: AndroidStorageNode) {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = node.name
        savePanel.message = l10n.uiString(zh: "选择下载到 Mac 的保存位置", en: "Choose save location on Mac")
        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                viewModel.downloadNode(node, to: targetURL)
            }
        }
    }

    private func formatPartitionCapacity(_ part: AndroidStoragePartition) -> String {
        let availableGB = Double(part.availableBytes) / 1_000_000_000.0
        let totalGB = Double(part.totalBytes) / 1_000_000_000.0
        return String(format: "%.1f GB free / %.0f GB", availableGB, totalGB)
    }
}
