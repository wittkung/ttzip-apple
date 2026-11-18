// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation
import os
import TTZipArchiveContract
import TTZipEpub
import TTZipUI
import TTZipWebKit
import TTMediaKit

public final class EPUBArchiveUnpacker {
    private typealias SessionHandle = TTZipArchiveVfsProvider.SessionHandle
    
    private struct ActiveBookLease: Sendable {
        let bookModel: EPUBBookModel
        let session: SessionHandle

        func retainedBook() -> EPUBBookModel {
            EPUBBookModel(
                url: bookModel.url,
                title: bookModel.title,
                chapters: bookModel.chapters,
                extractDir: bookModel.extractDir,
                onRelease: { [session] in
                    EPUBArchiveUnpacker.releaseArchiveIdLease(session.archiveId, matching: session)
                }
            )
        }
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
            if url.scheme == ArchiveVfs.scheme {
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
            let provider = TTZipArchiveVfsProvider.shared
            let vfsHandler = VfsSchemeHandler(
                read: { uri in try await provider.loadResource(uri: uri) },
                readRange: { uri, range in try await provider.loadResourceRange(uri: uri, byteRange: range) }
            )
            config.setURLSchemeHandler(vfsHandler, forURLScheme: ArchiveVfs.scheme)
        }
        TTMediaBackgroundDetector.epubParser = { url in
            await EPUBArchiveUnpacker.acquireBookAsync(at: url)?.retainedBook()
        }
    }
    
    /// Acquires or reuses a reference-counted VFS session for `epubURL`, returning its virtual extract root URL.
    public static func unpackIfNeeded(epubURL: URL) -> URL? {
        unpackAndParseEPUB(at: epubURL)?.extractDir
    }
    
    /// Asynchronously unpacks and parses an EPUB from a disk URL or cold-cache `ttzip-vfs://` URI.
    public static func unpackAndParseEPUBAsync(at epubURL: URL) async -> EPUBBookModel? {
        await acquireBookAsync(at: epubURL)?.bookModel
    }

    private static func acquireBookAsync(at epubURL: URL) async -> ActiveBookLease? {
        if let existing = retainExistingBookLeaseIfAlive(for: epubURL) {
            return existing
        }
        if epubURL.scheme == ArchiveVfs.scheme {
            var data = TTZipArchiveVfsProvider.shared.cachedData(for: epubURL.absoluteString)
            if data == nil || data?.isEmpty == true {
                data = (try? await TTZipArchiveVfsProvider.shared.loadResource(uri: epubURL.absoluteString))?.data
            }
            guard let validData = data, !validData.isEmpty else {
                return nil
            }
            return parseEPUBModel(at: epubURL, inMemoryData: validData)
        }
        return acquireBook(at: epubURL)
    }
    
    /// Reads the EPUB outline and acquires a reference-counted VFS session.
    public static func unpackAndParseEPUB(at epubURL: URL) -> EPUBBookModel? {
        acquireBook(at: epubURL)?.bookModel
    }

    private static func acquireBook(at epubURL: URL) -> ActiveBookLease? {
        if let existing = retainExistingBookLeaseIfAlive(for: epubURL) {
            return existing
        }
        if epubURL.isFileURL {
            return parseEPUBModel(at: epubURL, inMemoryData: nil)
        } else if epubURL.scheme == ArchiveVfs.scheme {
            guard let data = TTZipArchiveVfsProvider.shared.cachedData(for: epubURL.absoluteString), !data.isEmpty else {
                return nil
            }
            return parseEPUBModel(at: epubURL, inMemoryData: data)
        }
        return nil
    }
    
    private static func retainExistingBookLeaseIfAlive(for epubURL: URL) -> ActiveBookLease? {
        let key = normalizedBookKey(for: epubURL)
        return stateLock.withLock { state in
            guard let lease = state.activeBookLeasesByURLKey[key] else {
                return nil
            }
            if TTZipArchiveVfsProvider.shared.retainSession(lease.session) {
                return lease
            }
            state.activeBookLeasesByURLKey.removeValue(forKey: key)
            state.urlKeyByArchiveId.removeValue(forKey: lease.session.archiveId)
            return nil
        }
    }
    
    private struct ExtractedEpubPackage {
        let session: SessionHandle
        let outline: EpubOutline
    }
    
    private static func parseEPUBModel(at epubURL: URL, inMemoryData: Data?) -> ActiveBookLease? {
        guard let package = extractEpubPackage(at: epubURL, inMemoryData: inMemoryData) else {
            return nil
        }
        let chapters = buildChapters(
            outline: package.outline,
            archiveId: package.session.archiveId
        )
        guard !chapters.isEmpty else {
            releaseArchiveIdLease(package.session.archiveId, matching: package.session)
            return nil
        }
        
        let virtualExtractDir = TTZipArchiveVfsProvider.shared.makeVfsURL(archiveId: package.session.archiveId, entryPath: "")
        let model = EPUBBookModel(
            url: epubURL,
            title: package.outline.title,
            chapters: chapters,
            extractDir: virtualExtractDir
        )
        let lease = ActiveBookLease(bookModel: model, session: package.session)
        guard recordActiveBookLease(for: epubURL, lease: lease) else {
            releaseArchiveIdLease(package.session.archiveId, matching: package.session)
            return nil
        }
        return lease
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
        guard TTZipArchiveVfsProvider.shared.parseVfsUri(epubURL.absoluteString) != nil,
              let outline = try? inspectEpubBytes(data: data, fileName: epubURL.lastPathComponent) else {
            return nil
        }
        let session = stageNestedEpubSpoolSession(for: epubURL, data: data)
        prewarmNestedEpubEntries(archiveId: session.archiveId, data: data, outline: outline)
        return ExtractedEpubPackage(session: session, outline: outline)
    }

    private static func extractDiskEpubPackage(at epubURL: URL) -> ExtractedEpubPackage? {
        guard let outline = try? inspectEpubFile(path: epubURL.path) else {
            return nil
        }
        let session = TTZipArchiveVfsProvider.shared.acquireSession(archivePath: epubURL.path)
        return ExtractedEpubPackage(session: session, outline: outline)
    }

    private static func recordActiveBookLease(for epubURL: URL, lease: ActiveBookLease) -> Bool {
        let key = normalizedBookKey(for: epubURL)
        return stateLock.withLock { state in
            guard TTZipArchiveVfsProvider.shared.isSessionActive(lease.session) else { return false }
            state.activeBookLeasesByURLKey[key] = lease
            state.urlKeyByArchiveId[lease.session.archiveId] = key
            return true
        }
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

    private static func stageNestedEpubSpoolSession(for epubURL: URL, data: Data) -> SessionHandle {
        let fm = FileManager.default
        let baseKey = TTZipArchiveVfsProvider.makeArchiveId(from: epubURL.absoluteString)
        let spoolDir = processSpoolDirectory
        try? fm.createDirectory(at: spoolDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: spoolDir.path)
        let spoolURL = spoolDir.appendingPathComponent("\(baseKey).epub")
        let stagedURL = spoolDir.appendingPathComponent("staging-\(UUID().uuidString).epub")
        defer { try? fm.removeItem(at: stagedURL) }
        let staged = (try? data.write(to: stagedURL, options: .atomic)) != nil
        if staged {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
        }

        return stateLock.withLock { state in
            let vfs = TTZipArchiveVfsProvider.shared
            let session: SessionHandle
            if staged, Darwin.rename(stagedURL.path, spoolURL.path) == 0 {
                session = vfs.acquireSession(archivePath: spoolURL.path)
                state.spoolFileByArchiveId[session.archiveId] = spoolURL
            } else {
                session = vfs.acquireSession(archivePath: epubURL.absoluteString)
            }
            state.inMemoryEpubDataByArchiveId[session.archiveId] = data
            return session
        }
    }
    
    private static func prewarmNestedEpubEntries(
        archiveId: String,
        data: Data,
        outline: EpubOutline
    ) {
        let vfs = TTZipArchiveVfsProvider.shared
        for href in outline.spine {
            let cleanHref = stripFragmentAndQuery(href)
            if let resource = try? readEpubResource(data: data, href: cleanHref) {
                vfs.cacheEntryData(archiveId: archiveId, entryPath: cleanHref, data: resource)
            }
        }
        if let cover = outline.coverPath, let resource = try? readEpubResource(data: data, href: cover) {
            vfs.cacheEntryData(archiveId: archiveId, entryPath: cover, data: resource)
        }
    }

    private static func extractInMemoryResource(for url: URL) -> Data? {
        guard let (archiveId, entryPath) = TTZipArchiveVfsProvider.shared.parseVfsUri(url.absoluteString),
              TTZipArchiveVfsProvider.shared.isSessionActive(archiveId: archiveId) else {
            return nil
        }
        let epubData = stateLock.withLock { $0.inMemoryEpubDataByArchiveId[archiveId] }
        guard let data = epubData else { return nil }
        guard let resource = try? readEpubResource(data: data, href: entryPath) else {
            return nil
        }
        TTZipArchiveVfsProvider.shared.cacheEntryData(archiveId: archiveId, entryPath: entryPath, data: resource)
        return resource
    }
    
    private static func buildChapters(outline: EpubOutline, archiveId: String) -> [EPUBChapterItem] {
        let vfs = TTZipArchiveVfsProvider.shared
        if outline.spine.isEmpty {
            return outline.diskFallback.enumerated().map { idx, chapter in
                EPUBChapterItem(
                    id: "\(idx)",
                    title: chapter.title,
                    fileURL: vfs.makeVfsURL(archiveId: archiveId, entryPath: chapter.href)
                )
            }
        }
        let titles = resolveSpineTitles(spine: outline.spine, toc: outline.toc)
        return outline.spine.enumerated().map { idx, href in
            EPUBChapterItem(
                id: "\(idx)",
                title: titles[idx],
                fileURL: vfs.makeVfsURL(archiveId: archiveId, entryPath: stripFragmentAndQuery(href))
            )
        }
    }

    private static func resolveSpineTitles(spine: [String], toc: [EpubTocNode]) -> [String] {
        var exactHrefToTitle: [String: String] = [:]
        var fragmentHrefToTitle: [String: String] = [:]
        
        func recordKeys(for rawHref: String, title: String, into map: inout [String: String]) {
            for key in candidateHrefKeys(for: rawHref) where map[key] == nil {
                map[key] = title
            }
        }
        
        func collectTocTitles(_ nodes: [EpubTocNode]) {
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
        
        return spine.enumerated().map { idx, href in
            let cleanHref = stripFragmentAndQuery(href)
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
        let session = stateLock.withLock { state -> SessionHandle? in
            if let lease = state.activeBookLeasesByURLKey[key] {
                return lease.session
            }
            if let (parsedId, _) = TTZipArchiveVfsProvider.shared.parseVfsUri(epubURL.absoluteString),
               let parsedKey = state.urlKeyByArchiveId[parsedId] {
                return state.activeBookLeasesByURLKey[parsedKey]?.session
            }
            return nil
        }
        if let session {
            releaseArchiveIdLease(session.archiveId, matching: session)
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
    
    private static func releaseArchiveIdLease(_ archiveId: String, matching expected: SessionHandle? = nil) {
        stateLock.withLock { state in
            let urlKey = state.urlKeyByArchiveId[archiveId]
            let recorded = urlKey.flatMap { state.activeBookLeasesByURLKey[$0]?.session }
            if let expected, let recorded, expected != recorded { return }

            let vfs = TTZipArchiveVfsProvider.shared
            let remaining: Int?
            if let session = expected ?? recorded {
                remaining = vfs.releaseSession(session)
            } else {
                remaining = vfs.releaseSession(archiveId: archiveId)
            }
            guard remaining == 0 else { return }

            if let urlKey {
                state.activeBookLeasesByURLKey.removeValue(forKey: urlKey)
                state.urlKeyByArchiveId.removeValue(forKey: archiveId)
            }
            state.inMemoryEpubDataByArchiveId.removeValue(forKey: archiveId)
            if let spoolURL = state.spoolFileByArchiveId.removeValue(forKey: archiveId) {
                try? FileManager.default.removeItem(at: spoolURL)
            }
        }
    }
}
