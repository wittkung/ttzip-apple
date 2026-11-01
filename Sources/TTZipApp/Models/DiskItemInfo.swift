// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

public struct DiskItemInfo: Identifiable, Hashable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let isArchive: Bool
    public let taxonomy: DocumentEntityTaxonomy
    public let sizeText: String
    public let rawSizeBytes: Int64
    public var fileSizeBytes: Int64? { isDirectory ? nil : rawSizeBytes }
    public let creationDate: Date?
    public let modificationDate: Date?
    public let kindText: String
    public let isEncryptedLockItem: Bool

    /// Whether this item represents a physical macOS application bundle (e.g., `.app` package directory)
    /// that should be launched via system file association rather than navigated into as a folder.
    public var isApplicationBundle: Bool {
        guard isDirectory else { return false }
        guard !path.hasPrefix("ttzip://"), !path.contains("?subpath=") else { return false }
        if taxonomy == .applicationPackage {
            let ext = ((name as NSString).pathExtension.isEmpty ? (path as NSString).pathExtension : (name as NSString).pathExtension).lowercased()
            if ext == "app" { return true }
        }
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "app" {
            return true
        }
        if let values = try? url.resourceValues(forKeys: [.isApplicationKey]),
           values.isApplication == true {
            return true
        }
        return false
    }

    /// Whether this item is a browsable directory in Miller columns (excludes `.app` application bundles).
    public var isBrowsableDirectory: Bool {
        isDirectory && !isApplicationBundle
    }
    
    /// User-visible display name resolved via fast non-blocking lookup to guarantee zero main-thread disk I/O.
    public let displayName: String
    
    /// Fast non-blocking resolution using cached localized name or fallback (zero synchronous disk IPC).
    public static func resolveDisplayName(path: String, fallbackName: String) -> String {
        return LocalizedDisplayNameCache.shared.fastDisplayName(path: path, fallbackName: fallbackName)
    }
    
    public static func == (lhs: DiskItemInfo, rhs: DiskItemInfo) -> Bool {
        return lhs.path == rhs.path && lhs.displayName == rhs.displayName && lhs.rawSizeBytes == rhs.rawSizeBytes && lhs.modificationDate == rhs.modificationDate
    }
    
    public init(summary: DiskItemSummary) {
        self.path = summary.path
        self.name = summary.name
        self.displayName = Self.resolveDisplayName(path: summary.path, fallbackName: summary.name)
        self.isDirectory = summary.isDirectory
        
        let url = URL(fileURLWithPath: summary.path)
        let rawExt = url.pathExtension.lowercased()
        let tax = DocumentEntityTaxonomy.classify(extension: rawExt, path: summary.path)
        self.taxonomy = tax
        self.isArchive = tax.isNavigableContainer
        
        self.creationDate = nil
        if summary.mtimeEpochSecs > 0 {
            self.modificationDate = Date(timeIntervalSince1970: TimeInterval(summary.mtimeEpochSecs))
        } else {
            self.modificationDate = nil
        }
        
        if !self.isDirectory {
            let bytes = Int64(summary.size)
            self.rawSizeBytes = bytes
            self.sizeText = ByteCountFormatterFlyweight.shared.string(fromByteCount: bytes)
            self.kindText = ArchiveCompressionFormat.kindDescription(forExtension: rawExt, isArchive: self.isArchive, path: summary.path)
        } else {
            self.rawSizeBytes = 0
            self.sizeText = ""
            self.kindText = "Folder"
        }
        self.isEncryptedLockItem = false
    }
    
    public init(url: URL, resourceValues: URLResourceValues) {
        self.path = url.path
        let fallback = url.lastPathComponent
        self.name = fallback
        self.displayName = resourceValues.localizedName ?? Self.resolveDisplayName(path: url.path, fallbackName: fallback)
        self.isDirectory = resourceValues.isDirectory ?? false
        
        let rawExt = url.pathExtension.lowercased()
        let tax = DocumentEntityTaxonomy.classify(extension: rawExt, path: url.path)
        self.taxonomy = tax
        self.isArchive = tax.isNavigableContainer
        
        self.creationDate = resourceValues.creationDate
        self.modificationDate = resourceValues.contentModificationDate
        
        if !self.isDirectory {
            let bytes = Int64(resourceValues.fileSize ?? 0)
            self.rawSizeBytes = bytes
            self.sizeText = ByteCountFormatterFlyweight.shared.string(fromByteCount: bytes)
            self.kindText = ArchiveCompressionFormat.kindDescription(forExtension: rawExt, isArchive: self.isArchive, path: url.path)
        } else {
            self.rawSizeBytes = 0
            self.sizeText = ""
            self.kindText = "Folder"
        }
        self.isEncryptedLockItem = false
    }
    
    /// Lightweight initializer avoiding disk stat calls for file sizes and dates during rapid autocompletion and enumeration.
    public init(url: URL, isDirectory: Bool, name: String? = nil) {
        self.path = url.path
        let resolvedName = name ?? url.lastPathComponent
        self.name = resolvedName
        self.displayName = Self.resolveDisplayName(path: url.path, fallbackName: resolvedName)
        self.isDirectory = isDirectory
        
        let rawExt = url.pathExtension.lowercased()
        let classified = DocumentEntityTaxonomy.classify(extension: rawExt, path: url.path)
        let tax = (isDirectory && classified != .applicationPackage) ? .plainFile : classified
        self.taxonomy = tax
        self.isArchive = tax.isNavigableContainer
        
        self.creationDate = nil
        self.modificationDate = nil
        self.rawSizeBytes = 0
        self.sizeText = ""
        self.kindText = isDirectory ? "Folder" : ArchiveCompressionFormat.kindDescription(forExtension: rawExt, isArchive: self.isArchive, path: url.path)
        self.isEncryptedLockItem = false
    }
    
    public init(url: URL) {
        self.path = url.path
        let resolvedName = url.lastPathComponent
        self.name = resolvedName
        self.displayName = Self.resolveDisplayName(path: url.path, fallbackName: resolvedName)
        
        let rawExt = url.pathExtension.lowercased()
        let tax = DocumentEntityTaxonomy.classify(extension: rawExt, path: url.path)
        self.taxonomy = tax
        self.isArchive = tax.isNavigableContainer
        
        if let res = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]) {
            self.isDirectory = res.isDirectory ?? false
            self.creationDate = res.creationDate
            self.modificationDate = res.contentModificationDate
            if !self.isDirectory {
                let bytes = Int64(res.fileSize ?? 0)
                self.rawSizeBytes = bytes
                self.sizeText = ByteCountFormatterFlyweight.shared.string(fromByteCount: bytes)
                self.kindText = ArchiveCompressionFormat.kindDescription(forExtension: rawExt, isArchive: self.isArchive, path: url.path)
            } else {
                self.rawSizeBytes = 0
                self.sizeText = ""
                self.kindText = "Folder"
            }
        } else {
            var isDir: ObjCBool = false
            self.isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            self.creationDate = nil
            self.modificationDate = nil
            self.rawSizeBytes = 0
            self.sizeText = ""
            self.kindText = self.isDirectory ? "Folder" : ArchiveCompressionFormat.kindDescription(forExtension: rawExt, isArchive: self.isArchive, path: url.path)
        }
        self.isEncryptedLockItem = false
    }
    
    public init(
        virtualName: String,
        virtualURL: URL,
        isDirectory: Bool,
        isArchive: Bool,
        taxonomy: DocumentEntityTaxonomy? = nil,
        sizeText: String,
        rawSizeBytes: Int64,
        kindText: String,
        modificationDate: Date? = nil,
        isEncryptedLockItem: Bool = false
    ) {
        self.path = virtualURL.absoluteString
        self.name = virtualName
        self.displayName = virtualName
        self.isDirectory = isDirectory
        let rawExt = (virtualName as NSString).pathExtension.lowercased()
        let classified = isDirectory ? .plainFile : DocumentEntityTaxonomy.classify(extension: rawExt, path: virtualName)
        let resolvedTax: DocumentEntityTaxonomy
        if let explicit = taxonomy {
            resolvedTax = explicit
        } else if isDirectory {
            resolvedTax = .plainFile
        } else if classified != .plainFile {
            resolvedTax = classified
        } else {
            resolvedTax = isArchive ? .physicalContainer : .plainFile
        }
        self.taxonomy = resolvedTax
        self.isArchive = resolvedTax.isNavigableContainer
        self.sizeText = sizeText
        self.rawSizeBytes = rawSizeBytes
        self.creationDate = nil
        self.modificationDate = modificationDate
        self.kindText = kindText
        self.isEncryptedLockItem = isEncryptedLockItem
    }
    
    public init(
        path: String,
        name: String,
        displayName: String,
        isDirectory: Bool,
        isArchive: Bool,
        taxonomy: DocumentEntityTaxonomy? = nil,
        sizeText: String,
        rawSizeBytes: Int64,
        creationDate: Date? = nil,
        modificationDate: Date?,
        kindText: String,
        isEncryptedLockItem: Bool = false
    ) {
        self.path = path
        self.name = name
        self.displayName = displayName
        self.isDirectory = isDirectory
        let ext = (name as NSString).pathExtension.lowercased()
        let classified = DocumentEntityTaxonomy.classify(extension: ext, path: name)
        let resolvedTax: DocumentEntityTaxonomy
        if let explicit = taxonomy {
            resolvedTax = explicit
        } else if isDirectory && classified != .applicationPackage {
            resolvedTax = .plainFile
        } else if classified != .plainFile {
            resolvedTax = classified
        } else {
            resolvedTax = isArchive ? .physicalContainer : .plainFile
        }
        self.taxonomy = resolvedTax
        self.isArchive = resolvedTax.isNavigableContainer
        self.sizeText = sizeText
        self.rawSizeBytes = rawSizeBytes
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.kindText = kindText
        self.isEncryptedLockItem = isEncryptedLockItem
    }
    
    /// Returns a copy of the item with an updated display name.
    public func withDisplayName(_ newDisplayName: String) -> DiskItemInfo {
        DiskItemInfo(
            path: self.path,
            name: self.name,
            displayName: newDisplayName,
            isDirectory: self.isDirectory,
            isArchive: self.isArchive,
            taxonomy: self.taxonomy,
            sizeText: self.sizeText,
            rawSizeBytes: self.rawSizeBytes,
            creationDate: self.creationDate,
            modificationDate: self.modificationDate,
            kindText: self.kindText,
            isEncryptedLockItem: self.isEncryptedLockItem
        )
    }
    
    /// Asynchronously batches localized display name resolution for a list of items on a background cooperative thread.
    public static func batchResolveDisplayNames(for items: [DiskItemInfo]) async -> [DiskItemInfo] {
        let uncachedPaths = items.compactMap { item -> String? in
            guard !item.path.isEmpty, !item.path.hasPrefix("ttzip://"), !item.path.contains("?subpath=") else { return nil }
            return LocalizedDisplayNameCache.shared.cachedName(for: item.path) == nil ? item.path : nil
        }
        if uncachedPaths.isEmpty {
            return items
        }
        let resolvedMap = await LocalizedDisplayNameCache.shared.batchResolveDisplayNames(for: uncachedPaths)
        return items.map { item in
            if let localized = resolvedMap[item.path], localized != item.displayName {
                return item.withDisplayName(localized)
            }
            return item
        }
    }
}

/// Thread-safe bounded in-memory cache for localized display names, eliminating repeated IPC calls to Finder/CoreServices.
public final class LocalizedDisplayNameCache: @unchecked Sendable {
    public static let shared = LocalizedDisplayNameCache()

    /// Maximum number of cached localized path entries before evicting oldest entries.
    public let maxEntries: Int

    private var cache: [String: String] = [:]
    private var insertionOrder: [String] = []
    private let lock = NSLock()

    public init(maxEntries: Int = 2048) {
        self.maxEntries = max(16, maxEntries)
        seedStandardDirectories()
    }

    private func seedStandardDirectories() {
        let homeURL = TTZipPathPresentationService.shared.realUserHomeURL
        let subfolders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Applications"]
        for sub in subfolders {
            let dirURL = homeURL.appendingPathComponent(sub)
            let name = TTZipPathPresentationService.shared.displayName(for: dirURL)
            insertLocked(name, for: dirURL.path)
        }
        insertLocked(TTZipPathPresentationService.shared.displayName(for: homeURL), for: homeURL.path)

        let standardDirs: [FileManager.SearchPathDirectory] = [
            .downloadsDirectory,
            .documentDirectory,
            .desktopDirectory,
            .picturesDirectory,
            .moviesDirectory,
            .musicDirectory,
            .applicationDirectory,
            .userDirectory
        ]
        let fm = FileManager.default
        for dir in standardDirs {
            if let url = fm.urls(for: dir, in: .userDomainMask).first {
                let name = fm.displayName(atPath: url.path)
                insertLocked(name, for: url.path)
            }
        }
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    public func clearCache() {
        lock.lock()
        cache.removeAll()
        insertionOrder.removeAll()
        lock.unlock()
    }

    public func cachedName(for path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[path]
    }

    public func storeName(_ name: String, for path: String) {
        lock.lock()
        insertLocked(name, for: path)
        lock.unlock()
    }

    private func insertLocked(_ name: String, for path: String) {
        if cache[path] == nil {
            while cache.count >= maxEntries, !insertionOrder.isEmpty {
                let oldest = insertionOrder.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            insertionOrder.append(path)
        }
        cache[path] = name
    }

    /// Synchronously returns cached localized name, or resolves via FileManager if uncached.
    public func fastDisplayName(path: String, fallbackName: String) -> String {
        guard !path.isEmpty, !path.hasPrefix("ttzip://"), !path.contains("?subpath=") else {
            return fallbackName
        }
        if let cached = cachedName(for: path) {
            return cached
        }
        let resolved = FileManager.default.displayName(atPath: path)
        storeName(resolved, for: path)
        return resolved
    }

    /// Resolves display name on demand (falling back to cache or FileManager).
    public func resolveDisplayName(path: String, fallbackName: String) -> String {
        if let cached = cachedName(for: path) {
            return cached
        }
        guard !path.isEmpty, !path.hasPrefix("ttzip://"), !path.contains("?subpath=") else {
            return fallbackName
        }
        let resolved = FileManager.default.displayName(atPath: path)
        storeName(resolved, for: path)
        return resolved
    }

    /// Asynchronously batches display name resolutions on a background cooperative thread.
    public func batchResolveDisplayNames(for paths: [String]) async -> [String: String] {
        await Task.detached(priority: .utility) { [weak self] in
            guard let self else { return [:] }
            var resolvedMap: [String: String] = [:]
            for path in paths {
                if Task.isCancelled { break }
                guard !path.isEmpty, !path.hasPrefix("ttzip://"), !path.contains("?subpath=") else {
                    continue
                }
                if let cached = self.cachedName(for: path) {
                    resolvedMap[path] = cached
                    continue
                }
                let resolved = FileManager.default.displayName(atPath: path)
                self.storeName(resolved, for: path)
                resolvedMap[path] = resolved
            }
            return resolvedMap
        }.value
    }
}
