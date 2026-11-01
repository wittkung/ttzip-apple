// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipUI
import TTZipBenchmarkKit
@testable import TTZipApp

/// Mock file viewer test double that records `revealInFinder` and `openFile` calls without triggering macOS Finder or external applications.
public final class MockFileViewerHarness: FileViewerServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _revealedPaths: [String] = []
    private var _openedURLs: [URL] = []
    private var _shouldSucceedOnOpen: Bool = true
    private var _openHandler: ((URL) -> Bool)?

    public var revealedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _revealedPaths
    }

    public var openedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _openedURLs
    }

    public var openedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _openedURLs.map(\.path)
    }

    public var shouldSucceedOnOpen: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _shouldSucceedOnOpen
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _shouldSucceedOnOpen = newValue
        }
    }

    public var openHandler: ((URL) -> Bool)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _openHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _openHandler = newValue
        }
    }

    public init(shouldSucceedOnOpen: Bool = true, openHandler: ((URL) -> Bool)? = nil) {
        self._shouldSucceedOnOpen = shouldSucceedOnOpen
        self._openHandler = openHandler
    }

    public func revealInFinder(at path: String) {
        lock.lock()
        defer { lock.unlock() }
        _revealedPaths.append(path)
    }

    @discardableResult
    public func openFile(at url: URL) -> Bool {
        lock.lock()
        _openedURLs.append(url)
        let handler = _openHandler
        let defaultSuccess = _shouldSucceedOnOpen
        lock.unlock()

        if let handler {
            return handler(url)
        }
        guard url.isFileURL,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                  .contains(where: { $0.name == "subpath" }) != true,
              FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        return defaultSuccess
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _revealedPaths.removeAll()
        _openedURLs.removeAll()
        _shouldSucceedOnOpen = true
        _openHandler = nil
    }
}
