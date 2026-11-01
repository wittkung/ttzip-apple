// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

/// Discrete operational kind of a workspace tab session.
public enum TabKind: Hashable, Sendable {
    case directory
    case archive(path: String)
    case compressWorkspace
    case storageInspector

    public var isDirectory: Bool {
        if case .directory = self { return true }
        return false
    }

    public var isArchive: Bool {
        if case .archive = self { return true }
        return false
    }

    public var isCompressWorkspace: Bool {
        if case .compressWorkspace = self { return true }
        return false
    }

    public var isStorageInspector: Bool {
        if case .storageInspector = self { return true }
        return false
    }

    public var archivePath: String? {
        if case .archive(let path) = self { return path }
        return nil
    }
}

/// Single Source of Truth descriptor representing an isolated workspace tab session.
public struct WorkspaceTabSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: TabKind
    public var historyStack: WorkspaceHistoryStack
    public var viewState: TabViewState
    public var customTitle: String?

    public init(
        id: UUID = UUID(),
        kind: TabKind = .directory,
        historyStack: WorkspaceHistoryStack,
        viewState: TabViewState = TabViewState(),
        customTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.historyStack = historyStack
        self.viewState = viewState
        self.customTitle = customTitle
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        kind: TabKind = .directory,
        customTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.historyStack = WorkspaceHistoryStack(current: url)
        self.viewState = TabViewState()
        self.customTitle = customTitle
    }

    public var archivePath: String? {
        kind.archivePath
    }

    public var titleKey: (any LocaleKeyProtocol)? {
        guard customTitle == nil else { return nil }
        switch kind {
        case .compressWorkspace:
            return L10n.Sidebar.newArchive
        case .storageInspector:
            return L10n.Sidebar.storageInspector
        case .archive:
            return nil
        case .directory:
            let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
            if historyStack.current.standardizedFileURL.path == homeURL.path {
                return L10n.Sidebar.home
            }
            return nil
        }
    }

    public var displayTitle: String {
        if let customTitle { return customTitle }
        switch kind {
        case .compressWorkspace:
            return TTZipLocalizationManager.shared.string(for: L10n.Sidebar.newArchive)
        case .storageInspector:
            return TTZipLocalizationManager.shared.string(for: L10n.Sidebar.storageInspector)
        case .archive(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .directory:
            let path = historyStack.current.path
            let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
            if historyStack.current.standardizedFileURL.path == homeURL.path {
                return TTZipLocalizationManager.shared.string(for: L10n.Sidebar.home)
            }
            if path == "/" {
                return "Macintosh HD"
            }
            return historyStack.current.lastPathComponent.isEmpty ? path : historyStack.current.lastPathComponent
        }
    }

    public var title: String {
        displayTitle
    }

    public var iconName: String {
        switch kind {
        case .compressWorkspace:
            return "doc.zipper"
        case .storageInspector:
            return "chart.pie.fill"
        case .archive:
            return "doc.zipper"
        case .directory:
            let homeURL = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
            if historyStack.current.standardizedFileURL.path == homeURL.path {
                return "house.fill"
            }
            if historyStack.current.standardizedFileURL.path == "/" {
                return "internaldrive"
            }
            return "folder.fill"
        }
    }
}
