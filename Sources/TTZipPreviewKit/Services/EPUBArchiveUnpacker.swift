// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os
import TTZipCore
import TTZipUI
import TTMediaKit

public final class EPUBArchiveUnpacker {
    
    private struct ActiveBookLease: Sendable {
        let bookModel: EPUBBookModel
        let rootURL: URL
        let archiveId: String
        var refCount: Int
    }
    
    private struct UnpackerState: Sendable {
        var inMemoryEpubDataByArchiveId: [String: Data] = [:]
        var spoolFileByArchiveId: [String: URL] = [:]
        var activeBookLeasesByURLKey: [String: ActiveBookLease] = [:]
        var urlKeyByArchiveId: [String: String] = [:]
    }
    
    private static let stateLock = OSAllocatedUnfairLock(initialState: UnpackerState())
    @MainActor private static var isRegistered = false
    
    private static func normalizedBookKey(for epubURL: URL) -> String {
        if epubURL.isFileURL {
            return epubURL.standardizedFileURL.resolvingSymlinksInPath().path
        }
        return epubURL.absoluteString
    }
    
    @MainActor public static func register() {
        guard !isRegistered else { return }
        isRegistered = true
        
        EPUBChapterContentLoaderActor.customDataProvider = { url in
            if url.scheme == TTZipVfsSchemeHandler.scheme {
                if let (data, _) = try? await TTZipArchiveVfsProvider.shared.loadResource(uri: url.absoluteString) {
                    return data
                }
                if let cached = TTZipArchiveVfsProvider.shared.cachedData(for: url.absoluteString) {
                    return cached
                }
                return EPUBArchiveUnpacker.extractInMemoryResource(for: url)
            }
            return nil
        }
        EPUBNativeWKWebView.webViewConfigurationCustomizer = { config in
            let vfsHandler = TTZipVfsSchemeHandler(provider: TTZipArchiveVfsProvider.shared)
            config.setURLSchemeHandler(vfsHandler, forURLScheme: TTZipVfsSchemeHandler.scheme)
        }
        TTMediaBackgroundDetector.epubParser = { url in
            await EPUBArchiveUnpacker.unpackAndParseEPUBAsync(at: url)
        }
    }
    
    /// Acquires or reuses a reference-counted VFS session for `epubURL`, returning its virtual extract root URL.
    public static func unpackIfNeeded(epubURL: URL) -> URL? {
        unpackAndParseEPUB(at: epubURL)?.extractDir
    }
    
    /// Asynchronously unpacks and parses an EPUB from a disk URL or cold-cache `ttzip-vfs://` URI.
    public static func unpackAndParseEPUBAsync(at epubURL: URL) async -> EPUBBookModel? {
        if let existing = retainExistingBookLeaseIfAlive(for: epubURL) {
            return existing
        }
        if epubURL.scheme == TTZipVfsSchemeHandler.scheme {
            var data = TTZipArchiveVfsProvider.shared.cachedData(for: epubURL.absoluteString)
            if data == nil || data?.isEmpty == true {
                data = (try? await TTZipArchiveVfsProvider.shared.loadResource(uri: epubURL.absoluteString))?.data
            }
            guard let validData = data, !validData.isEmpty else {
                return nil
            }
            return parseEPUBModel(at: epubURL, inMemoryData: validData)
        }
        return unpackAndParseEPUB(at: epubURL)
    }
    
    /// Parses EPUB structure via TTZipEbookReaderService and sets up zero-disk VFS routing with reference-counted session leases.
    public static func unpackAndParseEPUB(at epubURL: URL) -> EPUBBookModel? {
        if let existing = retainExistingBookLeaseIfAlive(for: epubURL) {
            return existing
        }
        if epubURL.isFileURL {
            return parseEPUBModel(at: epubURL, inMemoryData: nil)
        } else if epubURL.scheme == TTZipVfsSchemeHandler.scheme {
            guard let data = TTZipArchiveVfsProvider.shared.cachedData(for: epubURL.absoluteString), !data.isEmpty else {
                return nil
            }
            return parseEPUBModel(at: epubURL, inMemoryData: data)
        }
        return nil
    }
    
    private static func retainExistingBookLeaseIfAlive(for epubURL: URL) -> EPUBBookModel? {
        let key = normalizedBookKey(for: epubURL)
        return stateLock.withLock { state -> EPUBBookModel? in
            guard var lease = state.activeBookLeasesByURLKey[key] else {
                return nil
            }
            if TTZipArchiveVfsProvider.shared.retainSession(archiveId: lease.archiveId) {
                lease.refCount += 1
                state.activeBookLeasesByURLKey[key] = lease
                return lease.bookModel
            } else {
                state.activeBookLeasesByURLKey.removeValue(forKey: key)
                state.urlKeyByArchiveId.removeValue(forKey: lease.archiveId)
                return nil
            }
        }
    }
    
    private struct ExtractedEpubPackage {
        let archiveId: String
        let metadata: TTZipEbookMetadata?
        let spine: [TTZipEbookSpineItem]
        let toc: [TTZipEbookTocNode]
    }
    
    private static func parseEPUBModel(at epubURL: URL, inMemoryData: Data?) -> EPUBBookModel? {
        guard let package = extractEpubPackage(at: epubURL, inMemoryData: inMemoryData) else {
            return nil
        }
        let chapters = buildChapters(
            epubURL: epubURL,
            archiveId: package.archiveId,
            spine: package.spine,
            toc: package.toc
        )
        guard !chapters.isEmpty else {
            _ = TTZipArchiveVfsProvider.shared.releaseSession(archiveId: package.archiveId)
            cleanupSpoolIfUnreferenced(archiveId: package.archiveId)
            return nil
        }
        
        let bookTitle = package.metadata?.title ?? epubURL.deletingPathExtension().lastPathComponent
        let virtualExtractDir = TTZipArchiveVfsProvider.shared.makeVfsURL(archiveId: package.archiveId, entryPath: "")
        let model = EPUBBookModel(
            url: epubURL,
            title: bookTitle,
            chapters: chapters,
            extractDir: virtualExtractDir
        )
        recordActiveBookLease(for: epubURL, model: model, archiveId: package.archiveId)
        return model
    }
    
    private static func extractEpubPackage(at epubURL: URL, inMemoryData: Data?) -> ExtractedEpubPackage? {
        if let data = inMemoryData {
            return extractInMemoryEpubPackage(at: epubURL, data: data)
        }
        if epubURL.isFileURL {
            return extractDiskEpubPackage(at: epubURL)
        }
        return nil
    }
    
    private static func extractInMemoryEpubPackage(at epubURL: URL, data: Data) -> ExtractedEpubPackage? {
        guard TTZipArchiveVfsProvider.shared.parseVfsUri(epubURL.absoluteString) != nil else {
            return nil
        }
        let ebookService = TTZipEbookReaderService.shared
        let fileName = epubURL.lastPathComponent
        let metadata = try? ebookService.extractMetadataSync(from: data, fileName: fileName)
        let spine = (try? ebookService.getSpineSync(from: data, fileName: fileName)) ?? []
        let toc = (try? ebookService.extractTocSync(from: data, fileName: fileName)) ?? []
        let archiveId = registerNestedEpubSession(for: epubURL, data: data, spine: spine, coverPath: metadata?.coverPath)
        return ExtractedEpubPackage(archiveId: archiveId, metadata: metadata, spine: spine, toc: toc)
    }
    
    private static func extractDiskEpubPackage(at epubURL: URL) -> ExtractedEpubPackage? {
        guard FileManager.default.fileExists(atPath: epubURL.path) else {
            return nil
        }
        let ebookService = TTZipEbookReaderService.shared
        let archiveId = TTZipArchiveVfsProvider.shared.registerArchive(archivePath: epubURL.path, password: nil)
        let metadata = try? ebookService.extractMetadataSync(at: epubURL.path)
        let spine = (try? ebookService.getSpineSync(at: epubURL.path)) ?? []
        let toc = (try? ebookService.extractTocSync(at: epubURL.path)) ?? []
        return ExtractedEpubPackage(archiveId: archiveId, metadata: metadata, spine: spine, toc: toc)
    }
    
    private static func recordActiveBookLease(for epubURL: URL, model: EPUBBookModel, archiveId: String) {
        let key = normalizedBookKey(for: epubURL)
        stateLock.withLock { state in
            let currentRefCount = max(1, TTZipArchiveVfsProvider.shared.sessionReferenceCount(archiveId: archiveId))
            state.activeBookLeasesByURLKey[key] = ActiveBookLease(
                bookModel: model,
                rootURL: model.extractDir,
                archiveId: archiveId,
                refCount: currentRefCount
            )
            state.urlKeyByArchiveId[archiveId] = key
        }
    }
    
    private static func registerNestedEpubSession(
        for epubURL: URL,
        data: Data,
        spine: [TTZipEbookSpineItem],
        coverPath: String?
    ) -> String {
        let archiveId = stageNestedEpubSpoolSession(for: epubURL, data: data)
        prewarmNestedEpubEntries(
            archiveId: archiveId,
            data: data,
            fileName: epubURL.lastPathComponent,
            spine: spine,
            coverPath: coverPath
        )
        return archiveId
    }
    
    private static let processSpoolDirectory: URL = {
        let baseTmp: URL
        if let rawTmp = ProcessInfo.processInfo.environment["TMPDIR"], !rawTmp.isEmpty {
            baseTmp = URL(fileURLWithPath: rawTmp, isDirectory: true)
        } else {
            baseTmp = FileManager.default.temporaryDirectory
        }
        return baseTmp
            .appendingPathComponent("TTZipEphemeralEPUB", isDirectory: true)
            .appendingPathComponent("session-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
    }()

    private static func stageNestedEpubSpoolSession(for epubURL: URL, data: Data) -> String {
        let fm = FileManager.default
        let baseKey = TTZipArchiveVfsProvider.makeArchiveId(from: epubURL.absoluteString)
        let spoolDir = processSpoolDirectory
        try? fm.createDirectory(at: spoolDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: spoolDir.path)
        let spoolURL = spoolDir.appendingPathComponent("\(baseKey).epub")
        
        if (try? data.write(to: spoolURL, options: .atomic)) != nil {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: spoolURL.path)
            let archiveId = TTZipArchiveVfsProvider.shared.registerArchive(archivePath: spoolURL.path, password: nil)
            stateLock.withLock { state in
                state.inMemoryEpubDataByArchiveId[archiveId] = data
                state.spoolFileByArchiveId[archiveId] = spoolURL
            }
            return archiveId
        }
        let archiveId = TTZipArchiveVfsProvider.shared.registerArchive(archivePath: epubURL.absoluteString, password: nil)
        stateLock.withLock { state in
            state.inMemoryEpubDataByArchiveId[archiveId] = data
        }
        return archiveId
    }
    
    private static func prewarmNestedEpubEntries(
        archiveId: String,
        data: Data,
        fileName: String,
        spine: [TTZipEbookSpineItem],
        coverPath: String?
    ) {
        let fI = UniFfiEbookService()
        for item in spine {
            let cleanHref = stripFragmentAndQuery(item.href)
            if let res = try? fI.extractResource(data: data, href: cleanHref, fileName: fileName) {
                TTZipArchiveVfsProvider.shared.cacheEntryData(archiveId: archiveId, entryPath: cleanHref, data: res.data)
            }
        }
        if let cover = coverPath,
           let res = try? fI.extractResource(data: data, href: cover, fileName: fileName) {
            TTZipArchiveVfsProvider.shared.cacheEntryData(archiveId: archiveId, entryPath: cover, data: res.data)
        }
    }
    
    private static func extractInMemoryResource(for url: URL) -> Data? {
        guard let (archiveId, entryPath) = TTZipArchiveVfsProvider.shared.parseVfsUri(url.absoluteString),
              TTZipArchiveVfsProvider.shared.isSessionActive(archiveId: archiveId) else {
            return nil
        }
        let epubData = stateLock.withLock { $0.inMemoryEpubDataByArchiveId[archiveId] }
        guard let data = epubData else { return nil }
        guard let resource = try? UniFfiEbookService().extractResource(data: data, href: entryPath, fileName: nil) else {
            return nil
        }
        TTZipArchiveVfsProvider.shared.cacheEntryData(archiveId: archiveId, entryPath: entryPath, data: resource.data)
        return resource.data
    }
    
    private static func buildChapters(
        epubURL: URL,
        archiveId: String,
        spine: [TTZipEbookSpineItem],
        toc: [TTZipEbookTocNode]
    ) -> [EPUBChapterItem] {
        if !spine.isEmpty {
            let titles = resolveSpineTitles(spine: spine, toc: toc)
            return spine.enumerated().map { idx, item in
                let cleanHref = stripFragmentAndQuery(item.href)
                let chapterVfsURL = TTZipArchiveVfsProvider.shared.makeVfsURL(archiveId: archiveId, entryPath: cleanHref)
                return EPUBChapterItem(
                    id: "\(idx)",
                    title: titles[idx],
                    fileURL: chapterVfsURL
                )
            }
        }
        if epubURL.isFileURL, let rustBook = TTZipCore.parseEpubMetadata(epubPath: epubURL.path) {
            return rustBook.chapters.enumerated().map { idx, ch in
                let chapterVfsURL = TTZipArchiveVfsProvider.shared.makeVfsURL(archiveId: archiveId, entryPath: ch.href)
                return EPUBChapterItem(
                    id: "\(idx)",
                    title: ch.title,
                    fileURL: chapterVfsURL
                )
            }
        }
        return []
    }
    
    private static func resolveSpineTitles(
        spine: [TTZipEbookSpineItem],
        toc: [TTZipEbookTocNode]
    ) -> [String] {
        var exactHrefToTitle: [String: String] = [:]
        var fragmentHrefToTitle: [String: String] = [:]
        
        func recordKeys(for rawHref: String, title: String, into map: inout [String: String]) {
            for key in candidateHrefKeys(for: rawHref) where map[key] == nil {
                map[key] = title
            }
        }
        
        func collectTocTitles(_ nodes: [TTZipEbookTocNode]) {
            for node in nodes {
                let trimmedTitle = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanHref = stripFragmentAndQuery(node.href)
                if !trimmedTitle.isEmpty && !cleanHref.isEmpty {
                    if node.href.contains("#") {
                        recordKeys(for: cleanHref, title: trimmedTitle, into: &fragmentHrefToTitle)
                    } else {
                        recordKeys(for: cleanHref, title: trimmedTitle, into: &exactHrefToTitle)
                    }
                }
                collectTocTitles(node.children)
            }
        }
        collectTocTitles(toc)
        
        return spine.enumerated().map { idx, item in
            let cleanHref = stripFragmentAndQuery(item.href)
            let keys = candidateHrefKeys(for: cleanHref)
            let matchedTitle = keys.lazy.compactMap({ exactHrefToTitle[$0] }).first
                ?? keys.lazy.compactMap({ fragmentHrefToTitle[$0] }).first
            if let title = matchedTitle, !title.isEmpty {
                return title
            }
            let lowerHref = cleanHref.lowercased()
            if lowerHref.contains("titlepage") || lowerHref.contains("cover") {
                return "Cover"
            }
            return "Chapter \(idx + 1)"
        }
    }
    
    private static func stripFragmentAndQuery(_ href: String) -> String {
        let withoutFragment = href.components(separatedBy: "#").first ?? href
        return withoutFragment.components(separatedBy: "?").first ?? withoutFragment
    }
    
    private static func candidateHrefKeys(for cleanHref: String) -> [String] {
        let normalized = TTZipArchiveVfsProvider.normalizePath(cleanHref)
        let decodedRaw = cleanHref.removingPercentEncoding ?? cleanHref
        let decodedNormalized = TTZipArchiveVfsProvider.normalizePath(decodedRaw)
        let lowerDecoded = decodedNormalized.lowercased()
        let basename = (lowerDecoded as NSString).lastPathComponent
        var keys = [cleanHref, normalized, decodedNormalized, lowerDecoded]
        if !basename.isEmpty {
            keys.append("basename:\(basename)")
        }
        return keys
    }
    
    /// Releases one reference lease for the book session opened from `epubURL`.
    /// Only closes the underlying VFS session and deletes temporary spool files when the reference count reaches zero.
    public static func releaseSession(for epubURL: URL) {
        let key = normalizedBookKey(for: epubURL)
        let archiveIdToRelease = stateLock.withLock { state -> String? in
            if let lease = state.activeBookLeasesByURLKey[key] {
                return lease.archiveId
            }
            if let (parsedId, _) = TTZipArchiveVfsProvider.shared.parseVfsUri(epubURL.absoluteString),
               state.urlKeyByArchiveId[parsedId] != nil {
                return parsedId
            }
            return nil
        }
        if let archiveId = archiveIdToRelease {
            releaseArchiveIdLease(archiveId)
        } else {
            let fallbackId = TTZipArchiveVfsProvider.makeArchiveId(from: epubURL.isFileURL ? epubURL.path : epubURL.absoluteString)
            releaseArchiveIdLease(fallbackId)
        }
    }
    
    /// Releases one reference lease for a book session given its `extractDir` or book URL.
    public static func cleanupTempDir(at extractDir: URL) {
        if let (archiveId, _) = TTZipArchiveVfsProvider.shared.parseVfsUri(extractDir.absoluteString) {
            releaseArchiveIdLease(archiveId)
        } else {
            releaseSession(for: extractDir)
        }
    }
    
    private static func releaseArchiveIdLease(_ archiveId: String) {
        let remaining = TTZipArchiveVfsProvider.shared.releaseSession(archiveId: archiveId)
        stateLock.withLock { state in
            if let urlKey = state.urlKeyByArchiveId[archiveId] {
                if remaining <= 0 {
                    state.activeBookLeasesByURLKey.removeValue(forKey: urlKey)
                    state.urlKeyByArchiveId.removeValue(forKey: archiveId)
                } else if var lease = state.activeBookLeasesByURLKey[urlKey] {
                    lease.refCount = remaining
                    state.activeBookLeasesByURLKey[urlKey] = lease
                }
            }
        }
        if remaining <= 0 {
            cleanupSpoolIfUnreferenced(archiveId: archiveId)
        }
    }
    
    private static func cleanupSpoolIfUnreferenced(archiveId: String) {
        let spoolURL = stateLock.withLock { state -> URL? in
            state.inMemoryEpubDataByArchiveId.removeValue(forKey: archiveId)
            return state.spoolFileByArchiveId.removeValue(forKey: archiveId)
        }
        if let url = spoolURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
