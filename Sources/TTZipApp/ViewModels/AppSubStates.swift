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
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Window layout presentation mode for standard and immersive media focus states.
public enum WindowLayoutMode: Sendable, Hashable {
    case standard
    case mediaFocus
}

extension NSNotification.Name {
    public static let ttzipToggleMediaFocus = NSNotification.Name("TTZipToggleMediaFocusNotification")
}

/// 1. Navigation and routing state.
@Observable
@MainActor
public final class NavigationState {
    public var activeTab: WorkspaceTab = .home
    public var sidebarSelection: String? = nil
    public var isInspectorVisible: Bool = true
    public var currentDirectory: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
    public var isOmnibarFocused: Bool = false
    public var layoutMode: WindowLayoutMode = .standard
    
    public init() {}
    
    public func triggerOmnibarFocus() {
        self.isOmnibarFocused = true
    }
    
    public func toggleMediaFocusMode() {
        layoutMode = (layoutMode == .standard ? .mediaFocus : .standard)
    }
    
    public func setLayoutMode(_ mode: WindowLayoutMode) {
        self.layoutMode = mode
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

/// 5. Isolated observable state tracking high-frequency background task progress and status messages,
/// decoupling rapid rendering updates from the top-level AppViewState and MainView hierarchy.
@Observable
@MainActor
public final class TaskProgressObservable {
    public var progressValue: Double = 0.0
    public var statusMessage: String = "Ready"
    public var isIndeterminate: Bool = false
    
    public init(progressValue: Double = 0.0, statusMessage: String = "Ready", isIndeterminate: Bool = false) {
        self.progressValue = progressValue
        self.statusMessage = statusMessage
        self.isIndeterminate = isIndeterminate
    }
    
    public func reset() {
        self.progressValue = 0.0
        self.statusMessage = "Ready"
        self.isIndeterminate = false
    }
    
    public func update(progress: Double, message: String? = nil) {
        self.progressValue = progress
        if let msg = message {
            self.statusMessage = msg
        }
    }
}
