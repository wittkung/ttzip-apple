// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import os
import TTZipCore

/// Thread-safe in-memory Virtual File System (VFS) resource provider for archive contents.
/// Resolves `ttzip-vfs://<archiveId>/<entryPath>` URIs without extracting files to disk.
public final class TTZipArchiveVfsProvider: TTZipVfsResourceProvider, @unchecked Sendable {
    
    public static let shared = TTZipArchiveVfsProvider()
    
    private struct ArchiveSession {
        let archivePath: String
        let password: String?
        var inMemoryEntries: [String: Data]
    }
    
    private let lock = OSAllocatedUnfairLock(initialState: [String: ArchiveSession]())
    
    public init() {}
    
    // MARK: - Session Registration
    
    /// Registers or retrieves an archive session ID for VFS streaming.
    @discardableResult
    public func registerArchive(archivePath: String, password: String? = nil) -> String {
        let archiveId = Self.makeArchiveId(from: archivePath)
        lock.withLock { sessions in
            if sessions[archiveId] == nil {
                sessions[archiveId] = ArchiveSession(
                    archivePath: archivePath,
                    password: password,
                    inMemoryEntries: [:]
                )
            }
        }
        return archiveId
    }
    
    /// Pre-populates in-memory entry data for an archive.
    public func cacheEntryData(archiveId: String, entryPath: String, data: Data) {
        let normalizedPath = Self.normalizePath(entryPath)
        lock.withLock { sessions in
            sessions[archiveId]?.inMemoryEntries[normalizedPath] = data
        }
    }
    
    /// Synchronously retrieves cached in-memory entry data if present.
    public func cachedData(for uri: String) -> Data? {
        guard let (archiveId, entryPath) = parseVfsUri(uri) else { return nil }
        return lock.withLock { sessions in
            sessions[archiveId]?.inMemoryEntries[entryPath]
        }
    }
    
    /// Builds a canonical `ttzip-vfs://` URL for an archive entry.
    public func vfsURL(archivePath: String, password: String? = nil, entryPath: String) -> URL {
        let archiveId = registerArchive(archivePath: archivePath, password: password)
        return makeVfsURL(archiveId: archiveId, entryPath: entryPath)
    }
    
    /// Builds a `ttzip-vfs://` URL given an archive ID and entry path.
    public func makeVfsURL(archiveId: String, entryPath: String) -> URL {
        let cleanPath = Self.normalizePath(entryPath)
        let encodedPath = cleanPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanPath
        let urlString = "\(TTZipVfsSchemeHandler.scheme)://\(archiveId)/\(encodedPath)"
        return URL(string: urlString) ?? URL(string: "\(TTZipVfsSchemeHandler.scheme)://\(archiveId)")!
    }
    
    /// Unregisters an archive session from the VFS provider.
    public func unregisterArchive(archiveId: String) {
        lock.withLock { sessions in
            _ = sessions.removeValue(forKey: archiveId)
        }
    }
    
    // MARK: - TTZipVfsResourceProvider Conformance
    
    public func loadResource(uri: String) async throws -> (data: Data, mimeType: String)? {
        guard let (archiveId, entryPath) = parseVfsUri(uri) else { return nil }
        
        // 1. Check in-memory session cache
        let (archivePath, password, cachedData) = lock.withLock { sessions -> (String?, String?, Data?) in
            guard let session = sessions[archiveId] else { return (nil, nil, nil) }
            return (session.archivePath, session.password, session.inMemoryEntries[entryPath])
        }
        
        let mimeType = Self.mimeType(for: entryPath)
        if let data = cachedData {
            return (data, mimeType)
        }
        
        guard let validArchivePath = archivePath else { return nil }
        
        // 2. Extract from archive in-memory via ArchiveSelectiveExtractor
        if let data = try await ArchiveSelectiveExtractor.shared.extractSingleEntryData(
            archivePath: validArchivePath,
            entryPath: entryPath,
            password: password
        ) {
            cacheEntryData(archiveId: archiveId, entryPath: entryPath, data: data)
            return (data, mimeType)
        }
        
        return nil
    }
    
    public func loadResourceRange(uri: String, byteRange: ClosedRange<Int>?) async throws -> (data: Data, fullSize: Int64, mimeType: String)? {
        guard let (fullData, mimeType) = try await loadResource(uri: uri) else { return nil }
        let fullSize = Int64(fullData.count)
        
        guard let range = byteRange else {
            return (fullData, fullSize, mimeType)
        }
        
        let start = max(0, min(range.lowerBound, fullData.count))
        let end = max(start, min(range.upperBound + 1, fullData.count))
        let slicedData = fullData.subdata(in: start..<end)
        return (slicedData, fullSize, mimeType)
    }
    
    // MARK: - URI Parsing & Path Normalization
    
    public func parseVfsUri(_ uri: String) -> (archiveId: String, entryPath: String)? {
        guard let url = URL(string: uri), url.scheme == TTZipVfsSchemeHandler.scheme else {
            return nil
        }
        
        guard let host = url.host, !host.isEmpty else { return nil }
        let rawPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        let normalizedPath = Self.normalizePath(decodedPath)
        return (host, normalizedPath)
    }
    
    public static func makeArchiveId(from archivePath: String) -> String {
        let hash = String(format: "%08x", abs(archivePath.hashValue))
        let baseName = (archivePath as NSString).lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
        return "\(baseName.prefix(12))_\(hash)"
    }
    
    public static func normalizePath(_ path: String) -> String {
        var clean = path.replacingOccurrences(of: "\\", with: "/")
        while clean.hasPrefix("/") { clean.removeFirst() }
        var parts: [String] = []
        for segment in clean.split(separator: "/") {
            if segment == "." || segment.isEmpty { continue }
            if segment == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(segment))
            }
        }
        return parts.joined(separator: "/")
    }
    
    // MARK: - MIME Sniffing
    
    public static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "xhtml": return "application/xhtml+xml; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "xml": return "application/xml; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "pdf": return "application/pdf"
        case "epub": return "application/epub+zip"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "m4a", "aac": return "audio/mp4"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
