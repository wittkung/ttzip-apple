// SPDX-License-Identifier: BSD-3-Clause OR Apache-2.0
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import Observation
import TTZipCore

/// Independent per-window / per-tab archive workspace session state machine.
@Observable
@MainActor
public final class ArchiveSessionContext: Identifiable {
    public let id: UUID
    public var windowTitle: String
    public var currentArchivePath: String?
    public var currentDirectory: URL
    public var activePassword: String?
    public var currentEntries: [ArchiveEntry] = []
    public var selectedEntryID: String?
    public var activePreviewFileURL: URL?
    public var activePreviewFileName: String?
    public var searchQuery: String = ""
    public var isBuildingTree: Bool = false
    public var rootNodes: [ArchiveTreeNode] = []
    public let vfsCacheSessionId: String
    
    public init(id: UUID = UUID(), initialURL: URL? = nil) {
        self.id = id
        self.vfsCacheSessionId = "vfs_session_\(id.uuidString)"
        if let url = initialURL {
            self.windowTitle = url.lastPathComponent
            self.currentDirectory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            if !url.hasDirectoryPath {
                self.currentArchivePath = url.path
            }
        } else {
            self.windowTitle = "TTZip"
            self.currentDirectory = FileManager.default.homeDirectoryForCurrentUser
        }
    }
    
    /// Filtered entries based on active search query.
    public var filteredEntries: [ArchiveEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return currentEntries }
        return currentEntries.filter { $0.path.lowercased().contains(trimmed) }
    }
    
    /// Loads an archive file into this isolated session context.
    public func loadArchive(path: String, password: String? = nil) async throws {
        self.isBuildingTree = true
        defer { self.isBuildingTree = false }
        
        let result = try await TTZipEngineFacade.shared.inspectArchive(
            archivePath: path,
            password: password,
            autoVaultUnlock: true
        )
        
        self.currentArchivePath = path
        self.currentEntries = result.entries
        self.activePassword = result.unlockedPassword
        self.windowTitle = (path as NSString).lastPathComponent
        self.rootNodes = FastArchiveTreeBuilder.buildTree(from: result.entries)
    }
    
    /// Closes the currently loaded archive and resets ephemeral session caches.
    public func closeArchive() {
        self.currentArchivePath = nil
        self.currentEntries = []
        self.activePassword = nil
        self.selectedEntryID = nil
        self.activePreviewFileURL = nil
        self.activePreviewFileName = nil
        self.searchQuery = ""
        self.rootNodes = []
        self.windowTitle = "TTZip"
    }
}
