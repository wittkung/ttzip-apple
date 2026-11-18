// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import Observation

import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTKitUI

import TTMediaKit

/// Strongly-typed immutable descriptor for an item displayed in the immersive media browser.
public typealias ImmersiveMediaItem = TTZipPreviewKit.ImmersiveMediaItem

extension NSNotification.Name {
    public static let ttzipToggleMediaFocus = NSNotification.Name("TTZipToggleMediaFocusNotification")
}

/// 6. Selection and inspected disk item state as single source of truth.
@Observable
@MainActor
public final class SelectionState {
    public var ownerWindowID: UUID? = nil
    public var selectedDiskItem: DiskItemInfo? = nil
    public var selectedDiskItems: [DiskItemInfo]? = nil
    /// Active selected archive entry identifier within the archive table view.
    public var selectedEntryID: String? = nil
    
    public init(
        ownerWindowID: UUID? = nil,
        selectedDiskItem: DiskItemInfo? = nil,
        selectedDiskItems: [DiskItemInfo]? = nil,
        selectedEntryID: String? = nil
    ) {
        self.ownerWindowID = ownerWindowID
        self.selectedDiskItem = selectedDiskItem
        self.selectedDiskItems = selectedDiskItems
        self.selectedEntryID = selectedEntryID
    }
    
    public func select(_ item: DiskItemInfo?) {
        let previous = self.selectedDiskItem
        self.selectedDiskItem = item
        self.selectedDiskItems = item.map { [$0] }
        if let ownerWindowID {
            StandalonePlaybackWindowManager.shared.notifyOriginSelectionChanged(
                windowID: ownerWindowID,
                newSelectedItem: item
            )
        }
        if let prevPath = previous?.path, prevPath != item?.path, shouldStopGlobalPlayback() {
            TTPreviewPlaybackManager.stopAll()
        }
    }

    public func selectMultiple(_ items: [DiskItemInfo]) {
        self.selectedDiskItems = items
        self.selectedDiskItem = items.first
        if let ownerWindowID {
            StandalonePlaybackWindowManager.shared.notifyOriginSelectionChanged(
                windowID: ownerWindowID,
                newSelectedItem: items.first
            )
        }
        if shouldStopGlobalPlayback() {
            TTPreviewPlaybackManager.stopAll()
        }
    }
    
    public func clear() {
        let previous = self.selectedDiskItem
        self.selectedDiskItem = nil
        self.selectedDiskItems = nil
        self.selectedEntryID = nil
        if let ownerWindowID {
            StandalonePlaybackWindowManager.shared.notifyOriginSelectionChanged(
                windowID: ownerWindowID,
                newSelectedItem: nil
            )
        }
        if previous != nil, shouldStopGlobalPlayback() {
            TTPreviewPlaybackManager.stopAll()
        }
    }

    private func shouldStopGlobalPlayback() -> Bool {
        if StandalonePlaybackWindowManager.shared.hasActivePlaybackSession {
            return false
        }
        if let ownerWindowID {
            return BrowserWindowRegistry.shared.shouldStopGlobalPlaybackOnSelectionChange(for: ownerWindowID)
        }
        return true
    }
}
