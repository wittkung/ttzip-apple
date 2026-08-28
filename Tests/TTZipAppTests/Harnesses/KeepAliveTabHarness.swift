// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

@MainActor
public final class KeepAliveTabHarness {
    public private(set) var currentTab: WorkspaceTab
    public private(set) var visitedTabs: Set<WorkspaceTab> = []
    
    public init(initialTab: WorkspaceTab = .home) {
        self.currentTab = initialTab
        self.visitedTabs.insert(initialTab)
    }
    
    public func switchTab(to newTab: WorkspaceTab) {
        self.currentTab = newTab
        self.visitedTabs.insert(newTab)
    }
    
    public func reset() {
        self.visitedTabs.removeAll()
        self.visitedTabs.insert(currentTab)
    }
}
