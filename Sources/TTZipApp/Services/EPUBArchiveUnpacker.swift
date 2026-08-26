// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore

public final class EPUBArchiveUnpacker {
    /// Unpacks and parses EPUB structure directly via Rust streaming microkernel without disk extraction.
    public static func unpackAndParseEPUB(at epubURL: URL) -> EPUBBookModel? {
        guard let rustBook = TTZipCore.parseEpubMetadata(epubPath: epubURL.path) else {
            return nil
        }
        
        let chapters = rustBook.chapters.enumerated().map { idx, ch in
            EPUBChapterItem(
                id: "\(idx)",
                title: ch.title,
                fileURL: URL(fileURLWithPath: ch.href)
            )
        }
        
        return EPUBBookModel(
            url: epubURL,
            title: rustBook.title,
            chapters: chapters,
            extractDir: epubURL.deletingLastPathComponent()
        )
    }
    
    /// Retained for backwards compatibility. Zero temporary files are created during stream parsing.
    public static func cleanupTempDir(at extractDir: URL) {
        // No-op: Stream-first introspection completely eliminates temporary disk footprints.
    }
}

