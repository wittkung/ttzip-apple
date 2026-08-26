// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import Observation
import TTZipCore

/// 1. Navigation and routing state.
@Observable
@MainActor
public final class NavigationState {
    public var activeTab: WorkspaceTab = .home
    public var sidebarSelection: String? = nil
    public var isInspectorVisible: Bool = true
    public var currentDirectory: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
    public var isOmnibarFocused: Bool = false
    
    public init() {}
    
    public func triggerOmnibarFocus() {
        self.isOmnibarFocused = true
    }
}

/// 2. Archive explorer and in-archive preview state.
@Observable
@MainActor
public final class ArchiveExplorerState {
    public var currentArchivePath: String? = nil
    public var activePassword: String? = nil
    public var currentEntries: [ArchiveEntry] = []
    public var activePreviewFileURL: URL? = nil
    public var activePreviewFileName: String? = nil
    public var searchQuery: String = ""
    
    public init() {}
    
    public var filteredEntries: [ArchiveEntry] {
        let pattern = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if pattern.isEmpty {
            return currentEntries
        }
        return currentEntries.filter { $0.path.lowercased().contains(pattern) }
    }
}

/// 3. Background task execution and lifecycle state.
@Observable
@MainActor
public final class TaskExecutionState {
    public var isLoading: Bool = false
    public var statusMessage: String = "Ready"
    public var progressValue: Double = 0.0
    public var taskStateName: String = "Idle"
    public var canPauseTask: Bool = false
    public var canResumeTask: Bool = false
    public var canCancelTask: Bool = false
    public var currentTaskID: UUID? = nil
    
    // Command History (Undo / Redo)
    public var canUndo: Bool = false
    public var canRedo: Bool = false
    public var lastCommandDescription: String? = nil
    
    public init() {}
}

/// 4. Modal, Sheet, and Popover presentation overlay state.
@Observable
@MainActor
public final class OverlayState {
    public var showCompressModal: Bool = false
    public var showExtractModal: Bool = false
    public var showPasswordPrompt: Bool = false
    public var pendingEncryptedPath: String? = nil
    public var selectedDiskItem: DiskItemInfo? = nil
    public var selectedPathsToCompress: [String] = []
    
    // Archive Inspector & Diagnostics
    public var showArchiveInspectorModal: Bool = false
    public var inspectingArchivePath: String? = nil
    
    public init() {}
}
