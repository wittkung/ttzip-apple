// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore
import TTZipUI

public final class EPUBArchiveUnpacker {
    /// Unpacks and parses EPUB structure, preparing a localized sandbox directory for WKWebView rendering.
    public static func unpackAndParseEPUB(at epubURL: URL) -> EPUBBookModel? {
        guard let rustBook = TTZipCore.parseEpubMetadata(epubPath: epubURL.path) else {
            return nil
        }
        
        let hash = String(format: "%08x", abs(epubURL.path.hashValue))
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttzip_epub_\(hash)")
        
        if !FileManager.default.fileExists(atPath: stagingDir.path) {
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            Task.detached {
                _ = try? await TTZipEngineFacade.shared.quickExtract(
                    archivePath: epubURL.path,
                    destinationDir: stagingDir.path,
                    password: nil
                )
            }
        }
        
        let chapters = rustBook.chapters.enumerated().map { idx, ch in
            let chapterFileURL = stagingDir.appendingPathComponent(ch.href)
            return EPUBChapterItem(
                id: "\(idx)",
                title: ch.title,
                fileURL: chapterFileURL
            )
        }
        
        return EPUBBookModel(
            url: epubURL,
            title: rustBook.title,
            chapters: chapters,
            extractDir: stagingDir
        )
    }
    
    /// Cleans up staged sandbox directory upon reader dismissal.
    public static func cleanupTempDir(at extractDir: URL) {
        if FileManager.default.fileExists(atPath: extractDir.path) {
            try? FileManager.default.removeItem(at: extractDir)
        }
    }
}

