// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTZipCore
import TTZipUI

/// Remote-only inspector: no file URL conversion or local filesystem action callbacks.
struct AndroidLocationInspectorView: View {
    let location: AndroidLocationDescriptor?
    private var l10n: AppLocalizationState { AppLocalizationState.shared }

    static func loadedEntryCount(for state: AndroidDirectoryState) -> Int? {
        switch state {
        case .loaded(let entries): return entries.count
        case .empty: return 0
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(location?.deviceName ?? text("安卓设备", "Android device"), systemImage: "smartphone")
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(height: TTZipTheme.Layout.headerBarHeight)
            TTKintsugiDivider(.horizontal, falloff: false)
                .frame(height: TTZipTheme.Layout.kintsugiGoldLineHeight)
            remoteDetails
        }
        .accessibilityIdentifier("AndroidLocationInspector")
    }

    private var remoteDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let location {
                    row(text("存储分区", "Storage"), location.partitionDisplayName)
                    row(text("远端路径", "Remote path"), location.selectedNode?.path ?? location.currentPath)
                    row(text("连接方式", "Connection"), location.connectionType.rawValue)
                    directoryStatus(location.directoryState)
                    if let count = Self.loadedEntryCount(for: location.directoryState) {
                        row(text("当前目录项目数", "Items in current directory"), String(count))
                    }
                    row(text("分区容量", "Storage capacity"), capacity(location.totalBytes))
                    row(text("分区可用空间", "Available storage"), capacity(location.availableBytes))
                    if let node = location.selectedNode {
                        row(text("名称", "Name"), node.name)
                        if !node.isDirectory {
                            row(text("文件大小", "File size"), capacity(node.sizeBytes, allowsZero: true))
                        }
                        if node.modifiedTimestamp > 0 {
                            row(text("修改时间", "Modified"), node.modifiedDate.formatted())
                        }
                    }
                } else {
                    Label(text("设备已断开连接", "Device disconnected"), systemImage: "cable.connector.slash")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func directoryStatus(_ state: AndroidDirectoryState) -> some View {
        switch state {
        case .idle:
            Text(text("等待读取设备目录", "Waiting to read device directory"))
        case .loading:
            HStack { ProgressView().controlSize(.small); Text(text("正在读取设备目录", "Reading device directory")) }
        case .loaded, .empty:
            Text(text("目录读取完成", "Directory loaded"))
        case .permissionRestricted(let reason):
            Label(text("无法访问设备目录", "Device directory access denied"), systemImage: "lock")
            Text(reason).font(.caption).textSelection(.enabled)
        case .failed(let error):
            Label(text("设备目录读取失败", "Failed to read device directory"), systemImage: "exclamationmark.triangle")
            Text(error).font(.caption).textSelection(.enabled)
        case .disconnected:
            Label(text("设备已断开连接", "Device disconnected"), systemImage: "cable.connector.slash")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func capacity(_ bytes: UInt64, allowsZero: Bool = false) -> String {
        guard bytes > 0 || allowsZero else { return text("未知", "Unknown") }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func text(_ zh: String, _ en: String) -> String {
        l10n.uiString(zh: zh, en: en)
    }
}
