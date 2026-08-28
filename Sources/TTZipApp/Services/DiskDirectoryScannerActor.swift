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

/// Dedicated actor executing high-throughput non-blocking disk directory scans.
/// Delegated directly to the Rust engine for concurrent POSIX scanning and pre-sorted summaries.
public actor DiskDirectoryScannerActor {
    public static let shared = DiskDirectoryScannerActor()
    
    private init() {}
    
    /// Scans the target directory via the high-performance Rust engine.
    public func scanDirectory(at dirURL: URL) async -> [DiskItemInfo] {
        await RootFolderAccessManager.shared.ensureAccess(for: dirURL, promptIfMissing: false)
        
        return await Task.detached(priority: .userInitiated) {
            do {
                let summaries = try TTZipCore.scanDirectory(path: dirURL.path, maxDepth: 1)
                return summaries.map { DiskItemInfo(summary: $0) }
            } catch {
                return []
            }
        }.value
    }
}
