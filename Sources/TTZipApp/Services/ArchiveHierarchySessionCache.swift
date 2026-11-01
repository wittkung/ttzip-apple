// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import os
import TTZipCore
import TTZipUI
import TTZipPreviewKit

// MARK: - Left-Child Right-Sibling (LCRS) Tree Structure

/// Cache-compact Left-Child Right-Sibling (LCRS) tree node representation.
public struct LCRSNode: Sendable, Equatable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let sizeBytes: Int64
    public var firstChildId: Int32
    public var nextSiblingId: Int32
    public var parentId: Int32

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        sizeBytes: Int64,
        firstChildId: Int32 = -1,
        nextSiblingId: Int32 = -1,
        parentId: Int32 = -1
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.firstChildId = firstChildId
        self.nextSiblingId = nextSiblingId
        self.parentId = parentId
    }
}

/// Contiguous array-backed Left-Child Right-Sibling tree supporting O(1) traversal without existential wrapper overhead.
public struct LCRSArchiveTree: Sendable {
    public let nodes: [LCRSNode]
    public let rootId: Int32

    public init(nodes: [LCRSNode], rootId: Int32) {
        self.nodes = nodes
        self.rootId = rootId
    }

    /// Obtains all immediate child nodes of the given parent index.
    public func childrenOf(parentId: Int32) -> [(LCRSNode, Int32)] {
        guard parentId >= 0, Int(parentId) < nodes.count else { return [] }
        var currentId = nodes[Int(parentId)].firstChildId
        var result: [(LCRSNode, Int32)] = []
        while currentId >= 0, Int(currentId) < nodes.count {
            let child = nodes[Int(currentId)]
            result.append((child, currentId))
            currentId = child.nextSiblingId
        }
        return result
    }

    /// Finds an immediate child of parentId matching the specified name.
    public func findChild(in parentId: Int32, named name: String) -> (LCRSNode, Int32)? {
        guard parentId >= 0, Int(parentId) < nodes.count else { return nil }
        var currentId = nodes[Int(parentId)].firstChildId
        while currentId >= 0, Int(currentId) < nodes.count {
            let child = nodes[Int(currentId)]
            if child.name == name {
                return (child, currentId)
            }
            currentId = child.nextSiblingId
        }
        return nil
    }

    /// Resolves a subpath through LCRS traversal without intermediate string array allocations.
    public func resolveSubpath(_ subpath: String) -> (LCRSNode, Int32)? {
        guard rootId >= 0, Int(rootId) < nodes.count else { return nil }
        if subpath.isEmpty {
            return (nodes[Int(rootId)], rootId)
        }

        var currentId = rootId
        var sliceStart = subpath.startIndex
        let end = subpath.endIndex

        while sliceStart < end {
            let nextSlash = subpath[sliceStart...].firstIndex(of: "/") ?? end
            let component = String(subpath[sliceStart..<nextSlash])

            guard let (_, nextId) = findChild(in: currentId, named: component) else {
                return nil
            }
            currentId = nextId

            if nextSlash == end { break }
            sliceStart = subpath.index(after: nextSlash)
        }

        guard currentId >= 0, Int(currentId) < nodes.count else { return nil }
        return (nodes[Int(currentId)], currentId)
    }
}

/// Lightweight composite adapter wrapping an LCRS node.
public struct LCRSComponent: ArchiveComponentProtocol, Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let sizeBytes: Int64
    public let tree: LCRSArchiveTree
    public let nodeId: Int32

    public init(name: String, path: String, isDirectory: Bool, sizeBytes: Int64, tree: LCRSArchiveTree, nodeId: Int32) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.tree = tree
        self.nodeId = nodeId
    }

    public func getChildren() -> [ArchiveComponentProtocol] {
        guard isDirectory else { return [] }
        return tree.childrenOf(parentId: nodeId).map { childNode, childId in
            LCRSComponent(
                name: childNode.name,
                path: childNode.path,
                isDirectory: childNode.isDirectory,
                sizeBytes: childNode.sizeBytes,
                tree: tree,
                nodeId: childId
            )
        }
    }

    public static func == (lhs: LCRSComponent, rhs: LCRSComponent) -> Bool {
        lhs.path == rhs.path && lhs.sizeBytes == rhs.sizeBytes && lhs.nodeId == rhs.nodeId
    }
}

// MARK: - ArchiveSubpathMap

/// High-performance lazy subpath resolver with Left-Child Right-Sibling topology
/// and native Rust VFS tree backing, achieving O(1) traversal and bounded memory overhead.
public struct ArchiveSubpathMap: Sendable {
    public let rootComposite: ArchiveCompositeDirectory?
    public let vfsTree: UniFfiVfsTree?
    public let lcrsTree: LCRSArchiveTree?
    private let cache: OSAllocatedUnfairLock<[String: ArchiveComponentProtocol]>
    private let maxCapacity: Int

    public init(
        rootComposite: ArchiveCompositeDirectory? = nil,
        vfsTree: UniFfiVfsTree? = nil,
        lcrsTree: LCRSArchiveTree? = nil,
        maxCapacity: Int = 1024
    ) {
        self.rootComposite = rootComposite
        self.vfsTree = vfsTree
        self.lcrsTree = lcrsTree
        self.maxCapacity = maxCapacity

        var initial: [String: ArchiveComponentProtocol] = [:]
        if vfsTree == nil, lcrsTree == nil, let root = rootComposite {
            initial[""] = root
        }
        self.cache = OSAllocatedUnfairLock(initialState: initial)
    }

    public subscript(subpath: String) -> ArchiveComponentProtocol? {
        resolve(subpath: subpath)
    }

    public func resolve(subpath: String) -> ArchiveComponentProtocol? {
        let normalized = subpath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if normalized.isEmpty {
            if let tree = vfsTree {
                let topCount = tree.getChildrenPaged(subpath: "", offset: 0, limit: 1).totalCount
                return ArchiveTreeNode(
                    name: rootComposite?.name ?? "",
                    path: "",
                    uncompressedSize: Int64(tree.getStats().totalUncompressedBytes),
                    isDirectory: true,
                    hasChildren: topCount > 0,
                    vfsTree: tree
                )
            }
            if let lcrs = lcrsTree, lcrs.rootId >= 0, Int(lcrs.rootId) < lcrs.nodes.count {
                let node = lcrs.nodes[Int(lcrs.rootId)]
                return LCRSComponent(
                    name: node.name,
                    path: node.path,
                    isDirectory: node.isDirectory,
                    sizeBytes: node.sizeBytes,
                    tree: lcrs,
                    nodeId: lcrs.rootId
                )
            }
            if let root = rootComposite {
                return root
            }
            return nil
        }

        if let cached = cache.withLock({ $0[normalized] }) {
            return cached
        }

        // 1. Rust VFS tree lookup
        if let tree = vfsTree {
            if let nodeId = try? tree.vfsResolvePath(path: normalized),
               let detail = try? tree.vfsGetNodeDetail(nodeId: nodeId) {
                let hasSubChildren = detail.isDir &&
                    tree.getChildrenPaged(subpath: detail.fullPath, offset: 0, limit: 1).totalCount > 0
                let node = ArchiveTreeNode(
                    name: detail.name,
                    path: detail.fullPath,
                    uncompressedSize: Int64(detail.size),
                    isDirectory: detail.isDir,
                    entry: nil,
                    compressedSize: Int64(detail.compressedSize),
                    crc32: detail.crc32,
                    modificationDate: detail.mtimeSecs > 0 ? Date(timeIntervalSince1970: TimeInterval(detail.mtimeSecs)) : nil,
                    posixPermissions: detail.mode,
                    isEncrypted: detail.isEncrypted,
                    hasChildren: hasSubChildren,
                    vfsTree: tree
                )
                putCache(key: normalized, value: node)
                return node
            }
        }

        // 2. LCRS flat tree traversal
        if let lcrs = lcrsTree {
            if let (node, id) = lcrs.resolveSubpath(normalized) {
                let comp = LCRSComponent(
                    name: node.name,
                    path: node.path,
                    isDirectory: node.isDirectory,
                    sizeBytes: node.sizeBytes,
                    tree: lcrs,
                    nodeId: id
                )
                putCache(key: normalized, value: comp)
                return comp
            }
        }

        // 3. Fallback traversal across rootComposite without string split allocations
        if let root = rootComposite {
            var current: ArchiveComponentProtocol = root
            var sliceStart = normalized.startIndex
            let end = normalized.endIndex

            while sliceStart < end {
                let nextSlash = normalized[sliceStart...].firstIndex(of: "/") ?? end
                let component = String(normalized[sliceStart..<nextSlash])

                guard let dir = current as? ArchiveCompositeDirectory,
                      let next = dir.findChild(named: component) else {
                    return nil
                }
                current = next

                if nextSlash == end { break }
                sliceStart = normalized.index(after: nextSlash)
            }

            putCache(key: normalized, value: current)
            return current
        }

        return nil
    }

    private func putCache(key: String, value: ArchiveComponentProtocol) {
        cache.withLock { dict in
            if dict.count >= maxCapacity {
                dict.removeAll(keepingCapacity: true)
                if vfsTree == nil, lcrsTree == nil, let root = rootComposite {
                    dict[""] = root
                }
            }
            dict[key] = value
        }
    }

    public var count: Int {
        cache.withLock { $0.count }
    }

    public var isEmpty: Bool {
        false
    }
}

// MARK: - ArchiveHierarchySession

/// Cached in-memory representation of an archive directory tree for O(1) subpath traversal.
public struct ArchiveHierarchySession: Sendable {
    public let archivePath: String
    public let modificationTimestamp: TimeInterval
    public let fileByteSize: Int64
    public let rootComposite: ArchiveCompositeDirectory
    public let entries: [ArchiveEntry]
    public let subpathMap: ArchiveSubpathMap
    public let unlockedPassword: String?
    public let cachedAt: Date
    public let vfsTree: UniFfiVfsTree?
    public let lcrsTree: LCRSArchiveTree?

    public init(
        archivePath: String,
        modificationTimestamp: TimeInterval,
        fileByteSize: Int64,
        rootComposite: ArchiveCompositeDirectory,
        entries: [ArchiveEntry],
        unlockedPassword: String?,
        vfsTree: UniFfiVfsTree? = nil,
        lcrsTree: LCRSArchiveTree? = nil
    ) {
        self.archivePath = archivePath
        self.modificationTimestamp = modificationTimestamp
        self.fileByteSize = fileByteSize
        self.rootComposite = rootComposite
        self.entries = entries
        self.unlockedPassword = unlockedPassword
        self.cachedAt = Date()
        self.vfsTree = vfsTree
        self.lcrsTree = lcrsTree
        self.subpathMap = ArchiveSubpathMap(
            rootComposite: rootComposite,
            vfsTree: vfsTree,
            lcrsTree: lcrsTree
        )
    }

    public subscript(subpath: String) -> ArchiveComponentProtocol? {
        subpathMap[subpath]
    }
}

// MARK: - ArchiveHierarchySessionCache

/// Result of a hierarchy fetch: the session plus the credential the engine discovered.
private struct ArchiveHierarchyFetchOutcome: Sendable {
    /// The fetched session.
    let session: ArchiveHierarchySession
    /// Credential the engine discovered during this fetch, if any.
    ///
    /// `nil` when the engine reused a credential the caller already had, which is the case for a
    /// shared-cache candidate and for the VFS fast path. Only a credential the engine found
    /// itself is new to the shared cache and therefore worth publishing.
    let discoveredPassword: String?
    /// The shared-cache candidate this fetch started from.
    ///
    /// A discovered credential is atomically published only while the shared cache still holds this value,
    /// so a credential another owner committed while the fetch was in flight is never
    /// overwritten.
    let startingCandidate: String?
}

/// Actor managing thread-safe archive tree sessions with LRU purging and modification date fingerprinting.
public actor ArchiveHierarchySessionCache {
    public static let shared = ArchiveHierarchySessionCache()

    private var cache: [String: ArchiveHierarchySession] = [:]
    private var inFlightTasks: [String: Task<ArchiveHierarchyFetchOutcome, any Error>] = [:]
    private var pathGenerations: [String: UInt64] = [:]
    private var globalGeneration: UInt64 = 0
    private let maxEntries: Int = 16

    /// Engine seam. Production always drives the shared facade; tests inject a facade that owns
    /// a controlled reader so the real fetch chain can be paused deterministically.
    private let facade: TTZipEngineFacade

    private init() {
        self.facade = TTZipEngineFacade.shared
    }

    internal init(facade: TTZipEngineFacade) {
        self.facade = facade
    }

    public func clearAll() {
        cache.removeAll()
        for (_, task) in inFlightTasks {
            task.cancel()
        }
        inFlightTasks.removeAll()
        globalGeneration &+= 1
    }

    public func invalidate(path: String) {
        cache.removeValue(forKey: path)
        inFlightTasks.removeValue(forKey: path)?.cancel()
        pathGenerations[path, default: 0] &+= 1
    }

    /// Invalidates resident and still-fetching sessions for one logical archive.
    public func invalidate(logicalKey: String) {
        let paths = Set(cache.keys).union(inFlightTasks.keys)
        for path in paths where ArchiveCredentialIdentity.logicalKey(for: path) == logicalKey {
            invalidate(path: path)
        }
    }

    /// Returns list of all archive file paths currently resident in memory.
    public func cachedArchivePaths() -> [String] {
        Array(cache.keys)
    }

    /// Returns the cached archive hierarchy session if resident in memory.
    public func cachedSession(for path: String) -> ArchiveHierarchySession? {
        cache[path]
    }

    /// Returns all archive hierarchy sessions currently resident in memory.
    public var allCachedSessions: [ArchiveHierarchySession] {
        Array(cache.values)
    }

    private static func makeShallowVfsRootComposite(
        archivePath: String,
        vfs: UniFfiVfsTree
    ) -> ArchiveCompositeDirectory {
        let rootName = (archivePath as NSString).lastPathComponent
        let rootNode = ArchiveTreeNode(
            name: rootName,
            path: "",
            uncompressedSize: Int64(vfs.getStats().totalUncompressedBytes),
            isDirectory: true,
            hasChildren: true,
            vfsTree: vfs
        )
        return ArchiveCompositeDirectory(
            name: rootName,
            path: "",
            entry: nil,
            children: rootNode.getChildren()
        )
    }

    /// Returns existing cached session if valid, otherwise constructs hierarchy using Rust VFS tree or engine inspection.
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

        if let ongoing = inFlightTasks[archivePath] {
            // A coalesced wait shares the outcome of the fetch that is already running. That
            // fetch owns the acceptance: it publishes a discovered credential and writes the
            // session under its own generation check, so this waiter never publishes on its own.
            return try await ongoing.value.session
        }

        let expectedPathGen = pathGenerations[archivePath, default: 0]
        let expectedGlobalGen = self.globalGeneration
        let logicalKey = ArchiveCredentialIdentity.logicalKey(for: archivePath)
        let expectedCredentialGen = ArchiveCredentialGeneration.shared.snapshot(for: logicalKey)
        let engineFacade = self.facade

        let task = Task<ArchiveHierarchyFetchOutcome, any Error> {
            let explicitPwd = password ?? ArchivePasswordStore.shared.getPassword(for: archivePath)

            // 1. Attempt loading native continuous-memory Rust VFS tree directly
            if let vfs = try? loadArchiveVfsTree(archivePath: archivePath, password: explicitPwd) {
                let rootComp = Self.makeShallowVfsRootComposite(archivePath: archivePath, vfs: vfs)
                return ArchiveHierarchyFetchOutcome(
                    session: ArchiveHierarchySession(
                        archivePath: archivePath,
                        modificationTimestamp: mtime,
                        fileByteSize: size,
                        rootComposite: rootComp,
                        entries: [],
                        unlockedPassword: explicitPwd,
                        vfsTree: vfs,
                        lcrsTree: nil
                    ),
                    // The VFS fast path never published a credential, and it discovered none.
                    discoveredPassword: nil,
                    startingCandidate: explicitPwd
                )
            }

            // The facade is the single password-retry boundary. A failed VFS fast path
            // does not establish encryption and must never trigger vault retries by itself.
            let result = try await engineFacade.inspectArchive(
                archivePath: archivePath,
                password: password,
                autoVaultUnlock: autoVaultUnlock
            )

            // The engine either reused the candidate this fetch already had, or it found a
            // credential itself (a vault unlock). Only the latter is new to the shared cache.
            let discoveredPassword: String? = {
                guard let unlocked = result.unlockedPassword, !unlocked.isEmpty else { return nil }
                return unlocked == explicitPwd ? nil : unlocked
            }()

            return ArchiveHierarchyFetchOutcome(
                session: ArchiveHierarchySession(
                    archivePath: archivePath,
                    modificationTimestamp: mtime,
                    fileByteSize: size,
                    rootComposite: result.treeNode,
                    entries: result.entries,
                    unlockedPassword: result.unlockedPassword,
                    vfsTree: nil,
                    lcrsTree: nil
                ),
                discoveredPassword: discoveredPassword,
                startingCandidate: explicitPwd
            )
        }

        inFlightTasks[archivePath] = task

        do {
            let outcome = try await task.value
            if pathGenerations[archivePath, default: 0] == expectedPathGen
                && globalGeneration == expectedGlobalGen {
                inFlightTasks.removeValue(forKey: archivePath)
            }

            // Reentrancy Guard: Discard write-back if invalidated or cleared during suspension
            if pathGenerations[archivePath, default: 0] == expectedPathGen &&
               self.globalGeneration == expectedGlobalGen &&
               ArchiveCredentialGeneration.shared.isCurrent(expectedCredentialGen, for: logicalKey) {
                if cache.count >= maxEntries {
                    if let oldestKey = cache.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key {
                        cache.removeValue(forKey: oldestKey)
                    }
                }
                cache[archivePath] = outcome.session
                publishDiscoveredPassword(
                    outcome, for: archivePath,
                    logicalKey: logicalKey, expectedCredentialGen: expectedCredentialGen
                )
            }
            return outcome.session
        } catch {
            if pathGenerations[archivePath, default: 0] == expectedPathGen
                && globalGeneration == expectedGlobalGen {
                inFlightTasks.removeValue(forKey: archivePath)
            }
            throw error
        }
    }

    /// Publishes a credential the engine discovered to the shared password cache.
    ///
    /// The cache comparison and write are atomic while it holds the candidate the fetch started from, so a
    /// credential another owner committed while the fetch was in flight is never overwritten.
    /// A reused candidate is never republished: publishing it again would restore an older
    /// credential over a newer one.
    private func publishDiscoveredPassword(
        _ outcome: ArchiveHierarchyFetchOutcome,
        for archivePath: String,
        logicalKey: String,
        expectedCredentialGen: UInt64
    ) {
        guard let discovered = outcome.discoveredPassword, !discovered.isEmpty else { return }
        _ = ArchiveCredentialGeneration.shared.performIfCurrent(
            expectedCredentialGen, for: logicalKey
        ) {
            ArchivePasswordStore.shared.setPassword(
                discovered, for: archivePath,
                ifCurrentPasswordIs: outcome.startingCandidate
            )
        }
    }
}
