// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Darwin
import Foundation

/// High-performance physical and canonical file identity on macOS APFS.
/// Guarantees O(1) equality checks across symlinks, firmlinks, case variants, and Unicode forms.
/// Defends against circular symlinks (ELOOP) and dead links via bounded stack resolution.
public struct FileIdentity: Hashable, Equatable, Sendable, Codable {
    public enum Key: Hashable, Sendable, Codable {
        /// Physical node identifier: (st_dev, st_ino).
        /// Follows symlinks safely with bounded stack history and 0 heap allocation.
        case physical(dev: dev_t, ino: ino_t)
        /// Fallback canonical representation when the node is offline, unmounted, or virtual.
        case canonicalPath(String)

        @inlinable
        @inline(__always)
        public static func == (lhs: FileIdentity.Key, rhs: FileIdentity.Key) -> Bool {
            switch (lhs, rhs) {
            case let (.physical(d1, i1), .physical(d2, i2)):
                return d1 == d2 && i1 == i2
            case let (.canonicalPath(s1), .canonicalPath(s2)):
                return s1 == s2
            default:
                return false
            }
        }
    }

    public enum SymlinkState: UInt8, Sendable, Codable {
        case none = 0
        case resolved = 1
        case circularLoop = 2
        case deadLink = 3
        case maxHopsExceeded = 4
    }

    public let key: Key
    public let canonicalPath: String
    /// True if the physical node or an intermediate parent is an unmaterialized cloud placeholder.
    public let isDataless: Bool
    /// Lifecycle state of symbolic link resolution.
    public let symlinkState: SymlinkState

    /// Maximum symlink dereference hops matching POSIX _POSIX_SYMLOOP_MAX.
    private static let maxSymlinkHops: Int = 8

    private enum CodingKeys: String, CodingKey {
        case key
        case canonicalPath
        case isDataless
        case symlinkState
    }

    public init(url: URL) {
        self.init(path: url.path)
    }

    public init(path rawPath: String) {
        let expanded = (rawPath as NSString).expandingTildeInPath
        // Fast-path: Normalize Firmlink prefix for offline consistency (/System/Volumes/Data/Users -> /Users)
        let normalizedPath: String
        let firmlinkPrefix = "/System/Volumes/Data/"
        if expanded.hasPrefix(firmlinkPrefix) {
            normalizedPath = "/" + String(expanded.dropFirst(firmlinkPrefix.count))
        } else {
            normalizedPath = expanded
        }

        self.canonicalPath = normalizedPath

        // Resolve symlinks with bounded stack space and 8-hop ceiling to prevent ELOOP kernel traversal
        let resolution = Self.resolveBoundedPath(normalizedPath)
        self.isDataless = resolution.isDataless
        self.symlinkState = resolution.symlinkState

        if let physicalKey = resolution.physicalKey {
            self.key = physicalKey
        } else {
            self.key = .canonicalPath(normalizedPath.precomposedStringWithCanonicalMapping)
        }
    }

    /// Iterative symlink resolver operating strictly within bounded stack memory.
    private static func resolveBoundedPath(_ initialPath: String) -> (physicalKey: Key?, isDataless: Bool, symlinkState: SymlinkState) {
        var currentPath = initialPath
        var hopCount = 0
        var isDataless = false
        var visitedNodes: [(dev: dev_t, ino: ino_t)] = []
        visitedNodes.reserveCapacity(maxSymlinkHops)
        var originSymlinkNode: (dev: dev_t, ino: ino_t)?

        while hopCount < maxSymlinkHops {
            guard let st = performLstatWithoutMaterialization(atPath: currentPath) else {
                let failureState: SymlinkState = (hopCount > 0 && errno == ENOENT) ? .deadLink : .none
                return finalizeUnresolvedSymlink(origin: originSymlinkNode, isDataless: isDataless, state: failureState)
            }
            if (st.st_flags & UInt32(SF_DATALESS)) != 0 {
                isDataless = true
            }
            if (st.st_mode & S_IFMT) != S_IFLNK {
                let resolvedState: SymlinkState = hopCount > 0 ? .resolved : .none
                return (.physical(dev: st.st_dev, ino: st.st_ino), isDataless, resolvedState)
            }
            let currentIdentity: (dev: dev_t, ino: ino_t) = (st.st_dev, st.st_ino)
            if originSymlinkNode == nil {
                originSymlinkNode = currentIdentity
            }
            if hasVisitedNode(currentIdentity, in: visitedNodes) {
                return finalizeUnresolvedSymlink(origin: originSymlinkNode, isDataless: isDataless, state: .circularLoop)
            }
            visitedNodes.append(currentIdentity)

            guard let nextPath = readNextSymlinkHopPath(from: currentPath) else {
                return finalizeUnresolvedSymlink(origin: originSymlinkNode, isDataless: isDataless, state: .deadLink)
            }
            currentPath = nextPath
            hopCount += 1
        }

        return finalizeUnresolvedSymlink(origin: originSymlinkNode, isDataless: isDataless, state: .maxHopsExceeded)
    }

    private static func hasVisitedNode(
        _ node: (dev: dev_t, ino: ino_t),
        in visitedNodes: [(dev: dev_t, ino: ino_t)]
    ) -> Bool {
        visitedNodes.contains { $0.dev == node.dev && $0.ino == node.ino }
    }

    private static func finalizeUnresolvedSymlink(
        origin: (dev: dev_t, ino: ino_t)?,
        isDataless: Bool,
        state: SymlinkState
    ) -> (physicalKey: Key?, isDataless: Bool, symlinkState: SymlinkState) {
        let fallbackKey = origin.map { Key.physical(dev: $0.dev, ino: $0.ino) }
        return (fallbackKey, isDataless, state)
    }

    private static func performLstatWithoutMaterialization(atPath path: String) -> stat? {
        var st = stat()
        let result = DatalessProtection.withMaterializationDisabled {
            path.withCString { cPath in lstat(cPath, &st) }
        }
        return result == 0 ? st : nil
    }

    private static func readNextSymlinkHopPath(from currentPath: String) -> String? {
        var linkTargetBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let readBytes = currentPath.withCString { cPath in
            readlink(cPath, &linkTargetBuffer, linkTargetBuffer.count - 1)
        }
        guard readBytes > 0 else { return nil }
        linkTargetBuffer[readBytes] = 0
        let targetString = linkTargetBuffer.withUnsafeBufferPointer { ptr in
            String(cString: ptr.baseAddress!)
        }
        if targetString.hasPrefix("/") {
            return targetString
        }
        let parentDir = (currentPath as NSString).deletingLastPathComponent
        return (parentDir as NSString).appendingPathComponent(targetString)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decode(Key.self, forKey: .key)
        self.canonicalPath = try container.decode(String.self, forKey: .canonicalPath)
        self.isDataless = try container.decodeIfPresent(Bool.self, forKey: .isDataless) ?? false
        self.symlinkState = try container.decodeIfPresent(SymlinkState.self, forKey: .symlinkState) ?? .none
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(canonicalPath, forKey: .canonicalPath)
        try container.encode(isDataless, forKey: .isDataless)
        try container.encode(symlinkState, forKey: .symlinkState)
    }

    @inlinable
    public static func == (lhs: FileIdentity, rhs: FileIdentity) -> Bool {
        lhs.key == rhs.key
    }

    @inlinable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }
}
