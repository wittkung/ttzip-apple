// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import Observation

#if MAS_BUILD || STEAM_BUILD
/// Store-managed sandbox build (Mac App Store or Steam): updates managed by platform store client.
@Observable
@MainActor
public final class UpdateManager {
    public static let shared = UpdateManager()
    
    public var canCheckForUpdates: Bool = false
    
    private init() {}
    
    public func checkForUpdates() {
        // Managed by Mac App Store or Steam Client
    }
}
#elseif canImport(Sparkle)
/// Direct independent distribution channel: integrates Sparkle 2.0 automatic updater.
import Sparkle
import TTZipUI
import TTZipPreviewKit

@Observable
@MainActor
public final class UpdateManager: NSObject, SPUUpdaterDelegate {
    public static let shared = UpdateManager()
    
    public var canCheckForUpdates: Bool = false
    
    @ObservationIgnored
    private var updaterController: SPUStandardUpdaterController?
    
    private override init() {
        super.init()
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.updaterController = controller
        self.canCheckForUpdates = controller.updater.canCheckForUpdates
    }
    
    public func checkForUpdates() {
        updaterController?.checkForUpdates(self)
    }
}
#else
import AppKit

/// Standalone direct build when Sparkle framework is omitted: falls back to GitHub Releases page.
@Observable
@MainActor
public final class UpdateManager {
    public static let shared = UpdateManager()
    
    public var canCheckForUpdates: Bool = true
    
    private init() {}
    
    public func checkForUpdates() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        if let url = URL(string: "https://github.com/wittkung/ttzip-apple/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
