// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import Observation
import SwiftUI
import TTKitCore
import TTMediaKit
import TTZipUI

/// Typealias for secondary tool modal presentation targets.
public typealias ActiveSecondaryTool = WorkspaceTab

/// Priority tier hierarchy for active modal presentations.
/// - Tier 1: Fluid overlays (Omnibar, Immersive Media, QuickLook, Search Panel)
/// - Tier 2: Standard sheets (Extract, Inspector, Integrity, Secondary tools, AdbGuide)
/// - Tier 3: Critical alerts and blocking prompts (Password prompt, Forensic collision, Error alerts)
public enum ActiveModalPresentation: Identifiable, Equatable, Sendable {
    // Priority Tier 1: Fluid Overlays
    case omnibar
    case immersiveMedia(ImmersiveMediaItem)
    case globalSearch

    // Priority Tier 2: Standard Sheets
    case extract
    case archiveInspector
    case archiveIntegrity
    case secondaryTool(ActiveSecondaryTool)
    case adbGuide

    // Priority Tier 3: Critical Alerts
    case passwordPrompt
    case collisionPrompt
    case errorAlert

    public var id: String {
        switch self {
        case .omnibar:
            return "omnibar"
        case .immersiveMedia(let item):
            return "immersiveMedia_\(item.url.path)"
        case .globalSearch:
            return "globalSearch"
        case .extract:
            return "extract"
        case .archiveInspector:
            return "archiveInspector"
        case .archiveIntegrity:
            return "archiveIntegrity"
        case .secondaryTool(let tool):
            return "secondaryTool_\(tool.id)"
        case .adbGuide:
            return "adbGuide"
        case .passwordPrompt:
            return "passwordPrompt"
        case .collisionPrompt:
            return "collisionPrompt"
        case .errorAlert:
            return "errorAlert"
        }
    }

    /// Numeric tier weighting (Tier 1 < Tier 2 < Tier 3).
    public var tier: Int {
        switch self {
        case .omnibar, .immersiveMedia, .globalSearch:
            return 1
        case .extract, .archiveInspector, .archiveIntegrity, .secondaryTool, .adbGuide:
            return 2
        case .passwordPrompt, .collisionPrompt, .errorAlert:
            return 3
        }
    }
}

/// Central presentation coordinator managing active modals, sheets, and priority overlays.
/// Inherits from TTKitCore.TTPresentationCoordinator conforming to TTKit Architecture Spec §6.
@MainActor
@Observable
public final class PresentationCoordinator: TTPresentationCoordinator<ActiveModalPresentation> {
    /// Shared singleton instance.
    public static let shared = PresentationCoordinator()

    /// Active presentation hierarchy stack.
    private var stack: [ActiveModalPresentation] = []

    /// Weak reference to bound AppViewState for two-way synchronization.
    public private(set) weak var boundViewState: AppViewState?

    public init(boundViewState: AppViewState? = nil) {
        self.boundViewState = boundViewState
        super.init(initialModal: nil)
        if boundViewState != nil {
            syncFromBoundState()
            startObservingBoundState()
        }
    }

    /// Binds the presentation coordinator to an AppViewState instance.
    public func bind(to state: AppViewState) {
        guard self.boundViewState !== state else { return }
        self.boundViewState = state
        syncFromBoundState()
        startObservingBoundState()
    }

    /// Activates and pushes a modal presentation into the coordinator stack.
    public override func present(_ modal: ActiveModalPresentation) {
        stack.removeAll { $0 == modal }
        stack.append(modal)
        activeModal = modal
        syncToBoundState(presented: modal)
    }

    /// Dismisses the given presentation, or the topmost presentation if unspecified.
    public func dismiss(_ presentation: ActiveModalPresentation? = nil) {
        let dismissedTarget: ActiveModalPresentation?
        if let target = presentation {
            stack.removeAll { $0 == target }
            dismissedTarget = target
        } else {
            dismissedTarget = stack.popLast()
        }
        if let dismissedTarget {
            syncToBoundState(dismissed: dismissedTarget)
        }
        activeModal = stack.last
    }

    /// Clears the topmost presentation conforming to TTPresentationCoordinator.
    public override func dismiss() {
        dismiss(nil)
    }

    /// Clears all active presentations from the coordinator.
    public func dismissAll() {
        let all = stack
        stack.removeAll()
        for item in all {
            syncToBoundState(dismissed: item)
        }
        activeModal = nil
    }

    /// Checks if a specific presentation is currently in the stack.
    public func isPresented(_ presentation: ActiveModalPresentation) -> Bool {
        stack.contains(presentation)
    }

    // MARK: - State Synchronization

    private func syncToBoundState(presented: ActiveModalPresentation) {
        guard let state = boundViewState else { return }
        switch presented {
        case .extract:
            if !state.overlayState.showExtractModal { state.overlayState.showExtractModal = true }
        case .archiveInspector:
            if !state.overlayState.showArchiveInspectorModal { state.overlayState.showArchiveInspectorModal = true }
        case .archiveIntegrity:
            if !state.overlayState.showArchiveIntegrityModal { state.overlayState.showArchiveIntegrityModal = true }
        case .passwordPrompt:
            if !state.overlayState.showPasswordPrompt { state.overlayState.showPasswordPrompt = true }
        case .immersiveMedia(let item):
            if !state.overlayState.showImmersiveMediaBrowser { state.overlayState.showImmersiveMediaBrowser = true }
            if state.overlayState.immersiveMediaItem != item { state.overlayState.immersiveMediaItem = item }
        case .omnibar:
            if !state.overlayState.showOmnibar { state.overlayState.showOmnibar = true }
        default:
            break
        }
    }

    private func syncToBoundState(dismissed: ActiveModalPresentation) {
        guard let state = boundViewState else { return }
        switch dismissed {
        case .extract:
            if state.overlayState.showExtractModal { state.overlayState.showExtractModal = false }
        case .archiveInspector:
            if state.overlayState.showArchiveInspectorModal { state.overlayState.showArchiveInspectorModal = false }
        case .archiveIntegrity:
            if state.overlayState.showArchiveIntegrityModal { state.overlayState.showArchiveIntegrityModal = false }
        case .passwordPrompt:
            if state.overlayState.showPasswordPrompt { state.overlayState.showPasswordPrompt = false }
        case .immersiveMedia:
            if state.overlayState.showImmersiveMediaBrowser { state.overlayState.showImmersiveMediaBrowser = false }
            state.overlayState.immersiveMediaItem = nil
        case .omnibar:
            if state.overlayState.showOmnibar { state.overlayState.showOmnibar = false }
        case .collisionPrompt:
            state.overlayState.collisionPrompt = nil
        default:
            break
        }
    }

    private func startObservingBoundState() {
        guard let state = boundViewState else { return }
        withObservationTracking {
            _ = state.overlayState.showExtractModal
            _ = state.overlayState.showArchiveInspectorModal
            _ = state.overlayState.showArchiveIntegrityModal
            _ = state.overlayState.showPasswordPrompt
            _ = state.overlayState.showImmersiveMediaBrowser
            _ = state.overlayState.immersiveMediaItem
            _ = state.overlayState.showOmnibar
            _ = state.overlayState.collisionPrompt
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncFromBoundState()
                self.startObservingBoundState()
            }
        }
    }

    private func syncFromBoundState() {
        guard let state = boundViewState else { return }
        let overlay = state.overlayState

        if overlay.showOmnibar {
            if activeModal != .omnibar { present(.omnibar) }
        } else if activeModal == .omnibar {
            dismiss(.omnibar)
        }

        if overlay.showPasswordPrompt {
            if activeModal != .passwordPrompt { present(.passwordPrompt) }
        } else if activeModal == .passwordPrompt {
            dismiss(.passwordPrompt)
        }

        if overlay.showImmersiveMediaBrowser, let item = overlay.immersiveMediaItem {
            if activeModal != .immersiveMedia(item) { present(.immersiveMedia(item)) }
        } else if !overlay.showImmersiveMediaBrowser, case .immersiveMedia = activeModal {
            dismiss()
        }

        if overlay.collisionPrompt != nil {
            if activeModal != .collisionPrompt { present(.collisionPrompt) }
        } else if activeModal == .collisionPrompt {
            dismiss(.collisionPrompt)
        }

        if overlay.showExtractModal {
            if activeModal != .extract { present(.extract) }
        } else if activeModal == .extract {
            dismiss(.extract)
        }

        if overlay.showArchiveInspectorModal {
            if activeModal != .archiveInspector { present(.archiveInspector) }
        } else if activeModal == .archiveInspector {
            dismiss(.archiveInspector)
        }

        if overlay.showArchiveIntegrityModal {
            if activeModal != .archiveIntegrity { present(.archiveIntegrity) }
        } else if activeModal == .archiveIntegrity {
            dismiss(.archiveIntegrity)
        }
    }
}
