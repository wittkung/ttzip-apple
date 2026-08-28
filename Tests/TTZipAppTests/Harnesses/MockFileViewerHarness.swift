// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

/// Mock file viewer test double that records `revealInFinder` calls without triggering macOS Finder windows.
public final class MockFileViewerHarness: FileViewerServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _revealedPaths: [String] = []

    public var revealedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _revealedPaths
    }

    public init() {}

    public func revealInFinder(at path: String) {
        lock.lock()
        defer { lock.unlock() }
        _revealedPaths.append(path)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _revealedPaths.removeAll()
    }
}
