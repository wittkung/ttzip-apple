// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AppKit
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Abstraction interface for GUI desktop file reveal service.
public protocol FileViewerServiceProtocol: Sendable {
    /// Reveals and selects file or folder in macOS Finder.
    func revealInFinder(at path: String)
}

/// macOS NSWorkspace desktop file viewer default implementation.
public final class MacNSWorkspaceFileViewer: FileViewerServiceProtocol {
    public init() {}
    
    public func revealInFinder(at path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}

/// Headless / no-op file viewer implementation for non-GUI environments and testing.
public final class NoOpFileViewer: FileViewerServiceProtocol {
    public init() {}
    
    public func revealInFinder(at path: String) {
        // No-op for headless / non-GUI executions
    }
}
