// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
#if canImport(TTZipAppServices)
#endif

/// Presentation-overlay state moved intact from AppSubStates.
@Observable
@MainActor
public final class OverlayState {
    public var showExtractModal: Bool = false
    public var showPasswordPrompt: Bool = false
    public var pendingEncryptedPath: String? = nil

    // Archive Inspector & Diagnostics
    public var showArchiveInspectorModal: Bool = false
    public var inspectingArchivePath: String? = nil
    public var showArchiveIntegrityModal: Bool = false
    public var integrityArchivePath: String? = nil

    // Immersive Fullscreen Media Browser
    public var showImmersiveMediaBrowser: Bool = false
    public var immersiveMediaItem: ImmersiveMediaItem? = nil

    // TTKit Universal Cmd+K Omnibar Modal
    public var showOmnibar: Bool = false

    // Forensic Collision Resolution Modal
    public var collisionPrompt: CollisionPrompt? = nil

    // Go to Folder… Panel (Slice A)
    public var showGoToFolderModal: Bool = false
    public var goToFolderInitialPath: String? = nil

    // Smart Folder… Editor & Active Saved Search (Slice B)
    public var showSmartFolderModal: Bool = false
    public var editingSmartFolderID: UUID? = nil
    public var smartFolderInitialScopeURL: URL? = nil
    public var activeSmartFolderID: UUID? = nil
    public var activeSmartFolderRecord: SmartFolderRecord? = nil
    public var activeSmartFolderResult: SmartFolderEvaluationResult? = nil
    public var isEvaluatingSmartFolder: Bool = false
    public var activeSmartFolderGeneration: UInt64 = 0
    @ObservationIgnored public var activeSmartFolderEvaluationTask: Task<Void, Never>? = nil

    // Connect to Server… Panel (Slice C)
    public var showConnectToServerModal: Bool = false
    public var connectToServerInitialAddress: String? = nil

    // Per-window Find Focus Signal Counter (⌘F / Dock Find…)
    public var findFocusRequestGeneration: UInt64 = 0

    public init() {}
}
