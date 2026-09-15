// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

/// Defines the target context for which a native Finder-style context menu is constructed.
public enum TTZipContextMenuTarget: Sendable, Equatable {
    /// A single physical filesystem item (file, folder, or archive file).
    case singleItem(url: URL, isDirectory: Bool, isArchive: Bool)
    
    /// Multiple physical filesystem items selected concurrently.
    case multipleItems(urls: [URL])
    
    /// A virtual entry inside an opened archive (e.g. tar/zip/7z item).
    case virtualArchiveEntry(archivePath: String, subpath: String, isDirectory: Bool)
    
    /// The empty background area of an explorer column or directory canvas.
    case columnBackground(directoryURL: URL)
}
