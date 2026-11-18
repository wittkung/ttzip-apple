// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import TTZipUI
import TTZipPreviewKit

/// Abstraction interface for GUI desktop file reveal and default application open service.
public protocol FileViewerServiceProtocol: Sendable {
    /// Reveals and selects file or folder in macOS Finder.
    func revealInFinder(at path: String)

    /// Opens a physical local file URL with its default system-associated application.
    /// Returns `true` if the system accepted the open request, `false` otherwise.
    @discardableResult
    func openFile(at url: URL) -> Bool
}

public extension FileViewerServiceProtocol {
    @discardableResult
    func openFile(at url: URL) -> Bool {
        false
    }
}

/// macOS NSWorkspace desktop file viewer default implementation.
public final class MacNSWorkspaceFileViewer: FileViewerServiceProtocol {
    public init() {}
    
    public func revealInFinder(at path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    @discardableResult
    public func openFile(at url: URL) -> Bool {
        guard url.isFileURL,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                  .contains(where: { $0.name == "subpath" }) != true else {
            return false
        }
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            return false
        }
        return NSWorkspace.shared.open(standardized)
    }
}

/// Headless / no-op file viewer implementation for non-GUI environments and testing.
public final class NoOpFileViewer: FileViewerServiceProtocol {
    public init() {}
    
    public func revealInFinder(at path: String) {
        // No-op for headless / non-GUI executions
    }

    @discardableResult
    public func openFile(at url: URL) -> Bool {
        false
    }
}
