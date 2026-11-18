// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

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
}
