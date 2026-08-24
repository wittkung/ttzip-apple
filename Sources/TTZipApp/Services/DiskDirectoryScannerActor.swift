// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore

/// Dedicated actor executing high-throughput non-blocking disk directory scans with batch attribute prefetching.
/// Leveraging POSIX getattrlistbulk under the hood via Foundation resource pre-population.
public actor DiskDirectoryScannerActor {
    public static let shared = DiskDirectoryScannerActor()
    
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .creationDateKey,
        .isPackageKey,
        .isHiddenKey
    ]
    
    private init() {}
    
    /// Scans the target directory with batch resource key prefetching in a single bulk system call.
    public func scanDirectory(at dirURL: URL) async -> [DiskItemInfo] {
        await RootFolderAccessManager.shared.ensureAccess(for: dirURL, promptIfMissing: false)
        
        return await Task.detached(priority: .userInitiated) {
            let keys = Array(Self.resourceKeys)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            
            var items: [DiskItemInfo] = []
            items.reserveCapacity(contents.count)
            
            for fileURL in contents {
                if let values = try? fileURL.resourceValues(forKeys: Self.resourceKeys) {
                    items.append(DiskItemInfo(url: fileURL, resourceValues: values))
                } else {
                    items.append(DiskItemInfo(url: fileURL))
                }
            }
            
            return items.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }.value
    }
}
