// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation

// `UpdateManager` is the sole update coordinator for the macOS Desktop App (`TTZipApp`):
// - `MAS_BUILD`: managed by the Mac App Store client.
// - `STEAM_BUILD`: managed by the Steam client.
// - `DIRECT_BUILD`: managed by Sparkle 2.0 (`SPUStandardUpdaterController`) when linked, or GitHub Releases fallback.
//
// `UpdateManager` intentionally does not invoke `TTZipAppUpdateService` (`TTZipCore` SDK capability) for
// unauthenticated in-place app bundle binary self-patching.

#if MAS_BUILD || STEAM_BUILD
/// Store-managed sandbox build (Mac App Store or Steam): updates managed by platform store client.
@Observable
@MainActor
public final class UpdateManager {
    public static let shared = UpdateManager()

    public var canCheckForUpdates: Bool = false

    private init() {}

    public func checkForUpdates() {}
}
#elseif canImport(Sparkle)
/// Direct independent distribution channel: integrates Sparkle 2.0 automatic updater.
import Sparkle

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

extension UpdateManager {
    package static var manualUpdateAction: (@MainActor () -> Void)? {
        #if DIRECT_DISTRIBUTION || DIRECT_BUILD
        { shared.checkForUpdates() }
        #else
        nil
        #endif
    }
}
