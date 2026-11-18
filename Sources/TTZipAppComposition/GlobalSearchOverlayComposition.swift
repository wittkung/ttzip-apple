// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTZipSearchKit

@MainActor
package protocol GlobalSearchOverlayPanel: AnyObject {
    var onActivateItem: ((GlobalSearchResultItem) -> Void)? { get set }
    var onOpenArchive: ((String) -> Void)? { get set }
    var onSelectEntry: ((String, String) -> Void)? { get set }

    func setWindowContentView(_ view: NSView)
    func toggle()
    func hide()
}

@MainActor
package enum GlobalSearchOverlayComposition {
    package static func install<Content: View>(
        panel: any GlobalSearchOverlayPanel,
        content: Content,
        routeResult: @escaping (GlobalSearchResultItem) -> Void,
        openArchive: @escaping (String) -> Void,
        selectEntry: @escaping (String, String) -> Void,
        registerHotkey: (@escaping @MainActor () -> Void) -> Void,
        attachTermination: (@escaping @MainActor () -> Void) -> Void
    ) {
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        panel.setWindowContentView(hosting)
        panel.onActivateItem = routeResult
        panel.onOpenArchive = openArchive
        panel.onSelectEntry = selectEntry
        registerHotkey {
            panel.toggle()
        }
        attachTermination {
            panel.hide()
        }
    }
}
