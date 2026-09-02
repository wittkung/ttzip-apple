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
    
    /// Parses EPUB structure via UniFfiEbookService and sets up zero-disk VFS routing.
    public static func unpackAndParseEPUB(at epubURL: URL) -> EPUBBookModel? {
        let ebookService = UniFfiEbookService()
        
        let metadata: UniFfiEbookMetadata?
        let spine: [UniFfiEbookSpineItem]
        let toc: [UniFfiEbookTocNode]
        let archiveId: String
        
        if epubURL.isFileURL {
            archiveId = TTZipArchiveVfsProvider.shared.registerArchive(archivePath: epubURL.path, password: nil)
            metadata = try? ebookService.extractMetadataFromFile(filePath: epubURL.path)
            spine = (try? ebookService.getSpineFromFile(filePath: epubURL.path)) ?? []
            toc = (try? ebookService.extractTocFromFile(filePath: epubURL.path)) ?? []
        } else if epubURL.scheme == TTZipVfsSchemeHandler.scheme {
            guard let (parsedArchiveId, _) = TTZipArchiveVfsProvider.shared.parseVfsUri(epubURL.absoluteString) else {
                return nil
            }
            archiveId = parsedArchiveId
            guard let data = TTZipArchiveVfsProvider.shared.cachedData(for: epubURL.absoluteString), !data.isEmpty else {
                return nil
            }
            metadata = try? ebookService.extractMetadata(data: data, fileName: epubURL.lastPathComponent)
            spine = (try? ebookService.getSpine(data: data, fileName: epubURL.lastPathComponent)) ?? []
            toc = (try? ebookService.extractToc(data: data, fileName: epubURL.lastPathComponent)) ?? []
        } else {
            return nil
        }
        
        // Build map from href to TOC title for clean chapter names
        var hrefToTitle: [String: String] = [:]
        func collectTocTitles(_ nodes: [UniFfiEbookTocNode]) {
            for node in nodes {
                let cleanHref = node.href.components(separatedBy: "#").first ?? node.href
                if !node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hrefToTitle[cleanHref] = node.title
                    hrefToTitle[TTZipArchiveVfsProvider.normalizePath(cleanHref)] = node.title
                }
                collectTocTitles(node.children)
            }
        }
        collectTocTitles(toc)
        
        // Build chapters from spine
        var chapters: [EPUBChapterItem] = []
        if !spine.isEmpty {
            chapters = spine.enumerated().map { idx, item in
                let cleanHref = item.href.components(separatedBy: "#").first ?? item.href
                let chapterTitle = hrefToTitle[cleanHref]
                    ?? hrefToTitle[TTZipArchiveVfsProvider.normalizePath(cleanHref)]
                    ?? "Chapter \(idx + 1)"
                let chapterVfsURL = TTZipArchiveVfsProvider.shared.makeVfsURL(archiveId: archiveId, entryPath: cleanHref)
                return EPUBChapterItem(
                    id: "\(idx)",
                    title: chapterTitle,
                    fileURL: chapterVfsURL
                )
            }
        } else if epubURL.isFileURL, let rustBook = TTZipCore.parseEpubMetadata(epubPath: epubURL.path) {
            chapters = rustBook.chapters.enumerated().map { idx, ch in
                let chapterVfsURL = TTZipArchiveVfsProvider.shared.makeVfsURL(archiveId: archiveId, entryPath: ch.href)
                return EPUBChapterItem(
                    id: "\(idx)",
                    title: ch.title,
                    fileURL: chapterVfsURL
                )
            }
        }
        
        guard !chapters.isEmpty else { return nil }
        
        let bookTitle = metadata?.title ?? (epubURL.deletingPathExtension().lastPathComponent)
        let virtualExtractDir = TTZipArchiveVfsProvider.shared.makeVfsURL(archiveId: archiveId, entryPath: "")
        
        return EPUBBookModel(
            url: epubURL,
            title: bookTitle,
            chapters: chapters,
            extractDir: virtualExtractDir
        )
    }
    
    /// Cleans up staged resources upon reader dismissal (zero-disk architecture).
    public static func cleanupTempDir(at extractDir: URL) {
        if let (archiveId, _) = TTZipArchiveVfsProvider.shared.parseVfsUri(extractDir.absoluteString) {
            TTZipArchiveVfsProvider.shared.unregisterArchive(archiveId: archiveId)
        }
    }
}
