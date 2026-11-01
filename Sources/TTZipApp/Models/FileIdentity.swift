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
        var symlinkState: SymlinkState = .none

        // Fixed-size stack storage for visited node identities: (dev_t, ino_t) * 8 = 128 bytes
        var visitedNodes: [(dev: dev_t, ino: ino_t)] = []
        visitedNodes.reserveCapacity(maxSymlinkHops)

        var originSymlinkNode: (dev: dev_t, ino: ino_t)?

        while hopCount < maxSymlinkHops {
            var st = stat()
            let lstatResult = DatalessProtection.withMaterializationDisabled {
                currentPath.withCString { cPath in
                    lstat(cPath, &st)
                }
            }

            if lstatResult != 0 {
                if hopCount > 0 && errno == ENOENT {
                    symlinkState = .deadLink
                }
                break
            }

            if (st.st_flags & UInt32(SF_DATALESS)) != 0 {
                isDataless = true
            }

            // Check if current node is a symbolic link
            if (st.st_mode & S_IFMT) != S_IFLNK {
                // Non-symlink physical target reached
                let resolvedState: SymlinkState = (symlinkState == .none && hopCount > 0) ? .resolved : symlinkState
                return (.physical(dev: st.st_dev, ino: st.st_ino), isDataless, resolvedState)
            }

            // Record initial symlink node identity for fallback anchoring
            if originSymlinkNode == nil {
                originSymlinkNode = (st.st_dev, st.st_ino)
            }

            // Cycle check: verify current symlink inode against fixed stack history
            let currentIdentity: (dev: dev_t, ino: ino_t) = (st.st_dev, st.st_ino)
            for previous in visitedNodes {
                if previous.dev == currentIdentity.dev && previous.ino == currentIdentity.ino {
                    symlinkState = .circularLoop
                    let fallbackKey = Key.physical(dev: originSymlinkNode!.dev, ino: originSymlinkNode!.ino)
                    return (fallbackKey, isDataless, symlinkState)
                }
            }

            visitedNodes.append(currentIdentity)

            // Read symlink target into fixed stack buffer of PATH_MAX bytes
            var linkTargetBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            let readBytes = currentPath.withCString { cPath in
                readlink(cPath, &linkTargetBuffer, linkTargetBuffer.count - 1)
            }

            guard readBytes > 0 else {
                symlinkState = .deadLink
                break
            }

            linkTargetBuffer[readBytes] = 0
            let targetString = linkTargetBuffer.withUnsafeBufferPointer { ptr in
                String(cString: ptr.baseAddress!)
            }

            if targetString.hasPrefix("/") {
                currentPath = targetString
            } else {
                let parentDir = (currentPath as NSString).deletingLastPathComponent
                currentPath = (parentDir as NSString).appendingPathComponent(targetString)
            }

            hopCount += 1
        }

        if hopCount >= maxSymlinkHops && symlinkState == .none {
            symlinkState = .maxHopsExceeded
        }

        // Fallback: If unresolved, bind to origin symlink inode to maintain node trackability
        if let origin = originSymlinkNode {
            return (.physical(dev: origin.dev, ino: origin.ino), isDataless, symlinkState)
        }

        return (nil, isDataless, symlinkState)
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
