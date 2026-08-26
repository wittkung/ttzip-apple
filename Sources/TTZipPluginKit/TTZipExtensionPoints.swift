// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI

// MARK: - 1. 侧边栏扩展项 (Sidebar Contribution)
public struct TTZipSidebarContribution: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let icon: String
    public let badgeText: String?
    public let targetTabIdentifier: String
    public let priority: Int
    
    public init(
        id: String,
        title: String,
        icon: String,
        badgeText: String? = nil,
        targetTabIdentifier: String,
        priority: Int = 100
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.badgeText = badgeText
        self.targetTabIdentifier = targetTabIdentifier
        self.priority = priority
    }
}

// MARK: - 4. 预览器扩展协议 (Preview Provider)
@MainActor
public protocol TTZipPreviewProvider: AnyObject {
    var supportedExtensions: [String] { get }
    func canPreview(fileURL: URL) -> Bool
    @ViewBuilder func makePreviewView(fileURL: URL) -> AnyView
}

// MARK: - 5. 虚拟归档数据源扩展协议 (Archive / VFS Source Provider)
@MainActor
public protocol TTZipArchiveSourceProvider: AnyObject {
    var scheme: String { get } // 如 "lark://", "s3://", "notion://"
    func listVirtualEntries(uri: URL) async throws -> [TTZipVirtualEntry]
    func exportVirtualArchive(uri: URL, destination: URL, format: String) async throws -> URL
}

public struct TTZipVirtualEntry: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    public let title: String
    public let isContainer: Bool
    public let sizeBytes: Int64?
    public let modifiedAt: Date?
    
    public init(path: String, title: String, isContainer: Bool, sizeBytes: Int64? = nil, modifiedAt: Date? = nil) {
        self.path = path
        self.title = title
        self.isContainer = isContainer
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

// MARK: - 6. 全局 Omnibar 命令扩展
public struct TTZipCommandAction: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let icon: String
    public let shortcut: String?
    public let action: @Sendable () -> Void
    
    public init(id: String, title: String, icon: String, shortcut: String? = nil, action: @escaping @Sendable () -> Void) {
        self.id = id
        self.title = title
        self.icon = icon
        self.shortcut = shortcut
        self.action = action
    }
}

// MARK: - 7. 右键上下文菜单扩展
public struct TTZipContextMenuAction: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let icon: String
    public let action: @Sendable (URL) -> Void
    
    public init(id: String, title: String, icon: String, action: @escaping @Sendable (URL) -> Void) {
        self.id = id
        self.title = title
        self.icon = icon
        self.action = action
    }
}
