// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import FileProvider
import Foundation

/// Read-only container enumerator translating virtual archive directory nodes into FileProvider items.
public final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let containerItemIdentifier: NSFileProviderItemIdentifier
    private let items: [FileProviderItem]

    public init(containerItemIdentifier: NSFileProviderItemIdentifier, items: [FileProviderItem]) {
        self.containerItemIdentifier = containerItemIdentifier
        self.items = items
        super.init()
    }

    public func invalidate() {
        // In-memory enumeration snapshot requires no external teardown
    }

    public func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }

    public func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // Static read-only archive trees produce zero mutations
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let staticAnchor = NSFileProviderSyncAnchor("static-v1".data(using: .utf8)!)
        completionHandler(staticAnchor)
    }
}
