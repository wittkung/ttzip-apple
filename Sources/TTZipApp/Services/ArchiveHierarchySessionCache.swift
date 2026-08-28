// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AppKit
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Cached in-memory representation of an archive directory tree for O(1) subpath traversal.
public struct ArchiveHierarchySession: Sendable {
    public let archivePath: String
    public let modificationTimestamp: TimeInterval
    public let fileByteSize: Int64
    public let rootComposite: ArchiveCompositeDirectory
    public let entries: [ArchiveEntry]
    public let subpathMap: [String: ArchiveComponentProtocol]
    public let unlockedPassword: String?
    public let cachedAt: Date
    
    public init(
        archivePath: String,
        modificationTimestamp: TimeInterval,
        fileByteSize: Int64,
        rootComposite: ArchiveCompositeDirectory,
        entries: [ArchiveEntry],
        unlockedPassword: String?
    ) {
        self.archivePath = archivePath
        self.modificationTimestamp = modificationTimestamp
        self.fileByteSize = fileByteSize
        self.rootComposite = rootComposite
        self.entries = entries
        self.unlockedPassword = unlockedPassword
        self.cachedAt = Date()
        
        var map: [String: ArchiveComponentProtocol] = [:]
        map[""] = rootComposite
        
        func indexHierarchy(component: ArchiveComponentProtocol, currentPath: String) {
            for child in component.getChildren() {
                let childPath = currentPath.isEmpty ? child.name : "\(currentPath)/\(child.name)"
                map[childPath] = child
                if child.isDirectory {
                    indexHierarchy(component: child, currentPath: childPath)
                }
            }
        }
        indexHierarchy(component: rootComposite, currentPath: "")
        self.subpathMap = map
    }
}

/// Actor managing thread-safe archive tree sessions with LRU purging and modification date fingerprinting.
public actor ArchiveHierarchySessionCache {
    public static let shared = ArchiveHierarchySessionCache()
    
    private var cache: [String: ArchiveHierarchySession] = [:]
    private let maxEntries: Int = 16
    
    private init() {}
    
    public func clearAll() {
        cache.removeAll()
    }
    
    public func invalidate(path: String) {
        cache.removeValue(forKey: path)
    }
    
    /// Returns existing cached session if valid, otherwise inspects archive and constructs hierarchy once.
    public func getOrFetchSession(
        for archivePath: String,
        password: String? = nil,
        autoVaultUnlock: Bool = true
    ) async throws -> ArchiveHierarchySession {
        let attrs = try FileManager.default.attributesOfItem(atPath: archivePath)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        
        if let existing = cache[archivePath],
           existing.fileByteSize == size,
           abs(existing.modificationTimestamp - mtime) < 0.001 {
            return existing
        }
        
        let result = try await TTZipEngineFacade.shared.inspectArchive(
            archivePath: archivePath,
            password: password,
            autoVaultUnlock: autoVaultUnlock
        )
        
        let root = result.treeNode
        let session = ArchiveHierarchySession(
            archivePath: archivePath,
            modificationTimestamp: mtime,
            fileByteSize: size,
            rootComposite: root,
            entries: result.entries,
            unlockedPassword: result.unlockedPassword
        )
        
        if cache.count >= maxEntries {
            if let oldestKey = cache.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
                cache.removeValue(forKey: oldestKey)
            }
        }
        cache[archivePath] = session
        return session
    }
}
