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
/// Delegated directly to the Rust engine for concurrent POSIX scanning and pre-sorted summaries,
/// with automatic security-scoped volume authorization and resilient FileManager fallback.
public actor DiskDirectoryScannerActor {
    public static let shared = DiskDirectoryScannerActor()
    
    private init() {}
    
    /// Scans the target directory via the high-performance Rust engine with fallback protection.
    public func scanDirectory(at dirURL: URL) async -> [DiskItemInfo] {
        let isVolume = dirURL.path.hasPrefix("/Volumes/")
        let rootURL = await RootFolderAccessManager.shared.highestRootURL(for: dirURL)
        let isInternal = (try? rootURL.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) ?? false
        let isExternalVolume = isVolume && !isInternal
        
        let hasAccess = await RootFolderAccessManager.shared.ensureAccess(for: dirURL, promptIfMissing: isExternalVolume)
        
        return await Task.detached(priority: .userInitiated) {
            // 1. Primary path: High-throughput Rust POSIX engine
            do {
                let summaries = try TTZipCore.scanDirectory(path: dirURL.path, maxDepth: 1)
                return summaries.map { DiskItemInfo(summary: $0) }
            } catch {
                NSLog("[DiskDirectoryScannerActor] Rust scanDirectory failed at \(dirURL.path): \(error). Attempting FileManager fallback.")
                
                // 2. Secondary path: Foundation FileManager fallback
                do {
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: dirURL,
                        includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey, .creationDateKey],
                        options: [.skipsHiddenFiles]
                    )
                    var items: [DiskItemInfo] = []
                    items.reserveCapacity(contents.count)
                    for fileURL in contents {
                        if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey, .creationDateKey]) {
                            items.append(DiskItemInfo(url: fileURL, resourceValues: values))
                        } else {
                            items.append(DiskItemInfo(url: fileURL))
                        }
                    }
                    return items.sorted { a, b in
                        if a.isDirectory != b.isDirectory { return a.isDirectory }
                        return a.name.localizedStandardCompare(b.name) == .orderedAscending
                    }
                } catch let fmError {
                    NSLog("[DiskDirectoryScannerActor] FileManager fallback failed at \(dirURL.path): \(fmError)")
                    
                    // 3. Informational placeholder & notification when access is denied
                    let nsError = fmError as NSError
                    if !hasAccess || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError) {
                        Task { @MainActor in
                            NotificationCenter.default.post(
                                name: NSNotification.Name("TTZipDirectoryAccessDeniedNotification"),
                                object: dirURL
                            )
                        }
                        if isExternalVolume {
                            return [
                                DiskItemInfo(
                                    virtualName: "Volume Access Required (Click to authorize)",
                                    virtualURL: dirURL,
                                    isDirectory: false,
                                    isArchive: false,
                                    sizeText: "Permission Required",
                                    rawSizeBytes: 0,
                                    kindText: "Access Authorization"
                                )
                            ]
                        }
                    }
                    return []
                }
            }
        }.value
    }
}
