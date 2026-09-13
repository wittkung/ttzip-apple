// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import TTZipCore
import TTZipUI

/// Top navigation and partition switching header bar for Android device browsing.
public struct AndroidHeaderView: View {
    @Bindable public var viewModel: AndroidDeviceViewModel
    
    @State private var hoveredBreadcrumbIndex: Int? = nil
    
    public init(viewModel: AndroidDeviceViewModel = .shared) {
        self.viewModel = viewModel
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
            .frame(height: 44)
            .background(TTZipTheme.paperWhite.opacity(0.92))
            
            // Subtle specular hairline divider
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.6)
        }
    }
    
    // MARK: - Subviews
    
    private var partitionSelectorMenu: some View {
        Menu {
            if let partitions = viewModel.selectedDevice?.storagePartitions, !partitions.isEmpty {
                ForEach(partitions) { partition in
                    Button(action: {
                        viewModel.selectPartition(partition)
                    }) {
                        HStack {
                            Text(partition.displayName)
                            Spacer()
                            Text(formatPartitionCapacity(partition))
                            if viewModel.selectedPartition?.partitionId == partition.partitionId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } else {
                Text("No Partitions Detected")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: partitionIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TTZipTheme.bambooGreen)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.selectedPartition?.displayName ?? "Select Storage")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    if let part = viewModel.selectedPartition {
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
        if let part = viewModel.selectedPartition, part.isRemovable {
            return "sdcard"
        }
        return "internaldrive"
    }
    
    private var breadcrumbPathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Root Device segment
                breadcrumbSegment(
                    title: viewModel.selectedDevice?.displayName ?? "Android Device",
                    systemImage: "iphone",
                    index: -1,
                    isLeaf: viewModel.columnPaths.isEmpty
                )
                
                // Active column path segments
                ForEach(Array(viewModel.columnPaths.enumerated()), id: \.offset) { index, path in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    
                    let title = pathSegmentName(path: path, index: index)
                    let isLeaf = index == viewModel.columnPaths.count - 1
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
            return viewModel.selectedPartition?.displayName ?? "Storage Root"
        }
        let comp = URL(fileURLWithPath: path).lastPathComponent
        return comp.isEmpty ? path : comp
    }
    
    private func breadcrumbSegment(title: String, systemImage: String, index: Int, isLeaf: Bool) -> some View {
        let isHovered = hoveredBreadcrumbIndex == index
        
        return Button(action: {
            if index >= 0 {
                viewModel.navigateToBreadcrumbIndex(index)
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
            if let device = viewModel.selectedDevice {
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
                            .strokeBorder(statusBorderColor(type: device.connectionType), lineWidth: 0.8)
                    )
                }
                .buttonStyle(.plain)
                .help(device.connectionType == .usbMtp ? "Click to view High-Speed ADB guide" : "Connected and operational")
            }
        }
    }
    
    private func statusTitle(type: AndroidConnectionType) -> String {
        switch type {
        case .usbMtp:
            return "MTP Mode"
        case .usbAdb:
            return "ADB High-Speed"
        case .wirelessAdb:
            return "Wi-Fi Debug"
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
            // Reload / Refresh
            Button(action: {
                if let path = viewModel.columnPaths.last {
                    Task {
                        await viewModel.loadDirectoryContents(path: path)
                    }
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
            .help("Refresh Directory")
            
            // Eject device
            if let device = viewModel.selectedDevice {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
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
                .help("Eject Device")
            }
        }
    }
    
    private func formatPartitionCapacity(_ part: AndroidStoragePartition) -> String {
        let availableGB = Double(part.availableBytes) / 1_000_000_000.0
        let totalGB = Double(part.totalBytes) / 1_000_000_000.0
        return String(format: "%.1f GB free / %.0f GB", availableGB, totalGB)
    }
}
