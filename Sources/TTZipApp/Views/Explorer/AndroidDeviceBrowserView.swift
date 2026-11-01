// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import AppKit
import TTZipCore
import TTZipUI
import TTKitDesign

/// Dedicated browsing viewport and file transfer view for connected Android devices.
public struct AndroidDeviceBrowserView: View {
    @Bindable public var viewModel: AndroidDeviceViewModel
    public let device: AndroidDevice
    public let windowID: UUID?

    @State private var hoveredNodeId: String? = nil
    private var l10n: AppLocalizationState { AppLocalizationState.shared }

    public init(
        viewModel: AndroidDeviceViewModel = .shared,
        device: AndroidDevice,
        windowID: UUID? = nil
    ) {
        self.viewModel = viewModel
        self.device = device
        self.windowID = windowID
    }

    private var currentDirectoryPath: String {
        viewModel.currentDirectoryPath(forWindow: windowID)
    }

    private var currentDirectoryState: AndroidDirectoryState {
        viewModel.directoryState(forPath: currentDirectoryPath, windowID: windowID)
    }

    private var currentNodes: [AndroidStorageNode] {
        currentDirectoryState.entries
    }

    public var body: some View {
        VStack(spacing: 0) {
            contentArea

            // Transfer Status and Progress HUD Strip
            if let activeJob = activeTransferJob {
                transferHudStrip(for: activeJob)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var contentArea: some View {
        switch currentDirectoryState {
        case .loading, .idle:
            loadingPlaceholder
        case .empty:
            emptyPlaceholder
        case .permissionRestricted(let reason):
            permissionRestrictedPlaceholder(reason: reason)
        case .failed(let error):
            enumerationFailedPlaceholder(error: error)
        case .disconnected:
            disconnectedPlaceholder
        case .loaded(let nodes):
            fileListTable(nodes: nodes)
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.9)
            Text(l10n.uiString(zh: "正在读取设备目录...", en: "Reading device directory..."))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(l10n.uiString(zh: "真实空目录", en: "Empty Directory"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text(l10n.uiString(zh: "此目录下暂无文件或文件夹", en: "No files or folders in this directory"))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
            Button(action: {
                presentUploadPanel(to: currentDirectoryPath)
            }) {
                Label(
                    l10n.uiString(zh: "上传文件到此目录", en: "Upload File to Directory"),
                    systemImage: "arrow.up.doc"
                )
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(TTZipTheme.bambooGreen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func permissionRestrictedPlaceholder(reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(TTZipTheme.archiveAmber)

            Text(l10n.uiString(zh: "存储访问受限", en: "Storage Access Restricted"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            let isPtp = reason.contains("ptpcamerad") || reason.contains("Access denied") || reason.contains("Busy")
            Text(isPtp
                ? l10n.uiString(
                    zh: "macOS ptpcamerad（图像捕捉/照片）或外部程序正在独占 USB 接口。\n请退出冲突程序，或在手机端开启 USB 调试以使用 ADB 高速模式。",
                    en: "macOS ptpcamerad (Image Capture/Photos) or another process is holding the USB interface.\nPlease close conflicting apps or enable USB debugging on the phone to use ADB mode."
                )
                : reason
            )
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .frame(maxWidth: 380)

            HStack(spacing: 12) {
                Button(action: {
                    Task {
                        await viewModel.loadDirectoryContents(path: currentDirectoryPath, forceReload: true, windowID: windowID)
                    }
                }) {
                    Label(l10n.uiString(zh: "重试读取", en: "Retry"), systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)

                if device.connectionType == .usbMtp {
                    Button(action: {
                        viewModel.showAdbGuideSheet = true
                    }) {
                        Label(l10n.uiString(zh: "查看 ADB 指南", en: "View ADB Guide"), systemImage: "arrow.up.forward.app")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TTZipTheme.bambooGreen)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func enumerationFailedPlaceholder(error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(TTZipTheme.cinnabarRed)

            Text(l10n.uiString(zh: "目录枚举失败", en: "Directory Enumeration Failed"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text(error)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 400)

            Button(action: {
                Task {
                    await viewModel.loadDirectoryContents(path: currentDirectoryPath, forceReload: true, windowID: windowID)
                }
            }) {
                Label(l10n.uiString(zh: "重试读取", en: "Retry"), systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var disconnectedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "cable.connector.slash")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)

            Text(l10n.uiString(zh: "设备未连接或已断开", en: "Device Disconnected"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text(l10n.uiString(zh: "请检查 USB 数据线或无线调试连接", en: "Please check USB cable or wireless debugging connection"))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)

            Button(action: {
                Task {
                    await viewModel.refreshHardwareDevices()
                }
            }) {
                Label(l10n.uiString(zh: "刷新设备列表", en: "Refresh Devices"), systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func fileListTable(nodes: [AndroidStorageNode]) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(nodes) { node in
                    nodeRowView(for: node)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func nodeRowView(for node: AndroidStorageNode) -> some View {
        let isSelected = viewModel.selectedNode(forWindow: windowID)?.id == node.id
        let isHovered = hoveredNodeId == node.id

        return HStack(spacing: 10) {
            // Node Icon
            Image(systemName: nodeIcon(for: node))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(nodeIconColor(for: node))
                .frame(width: 20)

            // File / Folder Name
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if node.isRestricted {
                    Text(l10n.uiString(zh: "Scoped Storage 受限", en: "Scoped Storage Restricted"))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(TTZipTheme.archiveAmber)
                }
            }

            Spacer(minLength: 8)

            // File Size
            if !node.isDirectory {
                Text(formatBytes(node.sizeBytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Chevron for Folders
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? TTZipTheme.bambooGreen.opacity(0.12) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredNodeId = hovering ? node.id : nil
        }
        .onTapGesture {
            let depth = max(0, viewModel.columnPaths(forWindow: windowID).count - 1)
            viewModel.selectNode(node, atColumn: depth, windowID: windowID)
        }
        .contextMenu {
            if !node.isDirectory {
                Button(action: {
                    presentDownloadPanel(for: node)
                }) {
                    Label(l10n.uiString(zh: "下载到 Mac...", en: "Download to Mac..."), systemImage: "arrow.down.doc")
                }
            } else {
                Button(action: {
                    presentUploadPanel(to: node.path)
                }) {
                    Label(l10n.uiString(zh: "上传文件到此目录...", en: "Upload File to Here..."), systemImage: "arrow.up.doc")
                }
            }

            Divider()

            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }) {
                Label(l10n.uiString(zh: "拷贝路径", en: "Copy Path"), systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Transfer Progress Strip

    private var activeTransferJob: AndroidTransferJobInfo? {
        viewModel.activeTransferJobsByDevice[device.deviceId]?.values.first(where: { !$0.status.isTerminal })
            ?? viewModel.activeTransfer
    }

    private func transferHudStrip(for job: AndroidTransferJobInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: job.direction == .androidToMac ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(TTZipTheme.bambooGreen)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(job.fileName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)

                    statusBadge(for: job)
                }

                HStack(spacing: 8) {
                    ProgressView(value: job.progress)
                        .frame(width: 120)
                        .scaleEffect(x: 1.0, y: 0.8)

                    Text("\(formatBytes(job.transferredBytes)) / \(formatBytes(job.totalBytes))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)

                    if job.status == .transferring && job.currentSpeedBps > 0 {
                        Text(String(format: "%.1f MB/s", job.speedMBs))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            if job.status == .transferring {
                Button(action: {
                    viewModel.cancelTransfer(jobId: job.id)
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(l10n.uiString(zh: "取消传输", en: "Cancel Transfer"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private func statusBadge(for job: AndroidTransferJobInfo) -> some View {
        let (title, color): (String, Color) = {
            if job.isSkipped {
                return (l10n.uiString(zh: "已跳过", en: "Skipped"), TTZipTheme.archiveAmber)
            }
            switch job.status {
            case .transferring:
                return (l10n.uiString(zh: "传输中", en: "Transferring"), TTZipTheme.bambooGreen)
            case .completed:
                return (l10n.uiString(zh: "传输完成", en: "Completed"), TTZipTheme.bambooGreen)
            case .cancelling:
                return (l10n.uiString(zh: "正在取消...", en: "Cancelling..."), .secondary)
            case .failed:
                let isCancel = job.errorMessage?.contains("Cancelled") == true
                return (isCancel ? l10n.uiString(zh: "已取消", en: "Cancelled") : l10n.uiString(zh: "传输失败", en: "Failed"), isCancel ? .secondary : TTZipTheme.cinnabarRed)
            case .queued:
                return (l10n.uiString(zh: "等待中", en: "Queued"), .secondary)
            case .paused:
                return (l10n.uiString(zh: "已暂停", en: "Paused"), .secondary)
            }
        }()

        return Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Actions

    public func presentUploadPanel(to remoteDir: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = l10n.uiString(zh: "选择要上传到 Android 设备的文件", en: "Select a file to upload to Android device")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                viewModel.uploadLocalFile(url, to: remoteDir)
            }
        }
    }

    public func presentDownloadPanel(for node: AndroidStorageNode) {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = node.name
        savePanel.message = l10n.uiString(zh: "选择下载到 Mac 的保存位置", en: "Choose save location on Mac")
        savePanel.begin { response in
            if response == .OK, let targetURL = savePanel.url {
                viewModel.downloadNode(node, to: targetURL)
            }
        }
    }

    // MARK: - Helpers

    private func nodeIcon(for node: AndroidStorageNode) -> String {
        if node.isDirectory {
            return node.isRestricted ? "folder.badge.gearshape" : "folder.fill"
        }
        let ext = (node.name as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "7z", "rar", "tar", "gz":
            return "doc.zipper"
        case "jpg", "jpeg", "png", "heic", "webp":
            return "photo"
        case "mp4", "mkv", "mov":
            return "film"
        case "mp3", "m4a", "flac":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }

    private func nodeIconColor(for node: AndroidStorageNode) -> Color {
        if node.isDirectory {
            return node.isRestricted ? TTZipTheme.archiveAmber : TTZipTheme.bambooGreen
        }
        return .secondary
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
