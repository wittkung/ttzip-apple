// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import SwiftUI
import Observation

#if MAS_BUILD
/// Mac App Store (MAS) sandbox build: updates managed by App Store.
@Observable
@MainActor
public final class UpdateManager {
    public static let shared = UpdateManager()
    
    public var canCheckForUpdates: Bool = false
    
    private init() {}
    
    public func checkForUpdates() {
        // Managed by Mac App Store
    }
}
#else
/// Direct independent distribution channel: integrates Sparkle 2.0 automatic updater.
import Sparkle
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

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
#endif
