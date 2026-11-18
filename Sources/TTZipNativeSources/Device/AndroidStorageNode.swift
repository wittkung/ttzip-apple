// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Type taxonomy of virtual file system nodes accessible on an Android storage partition.
public enum AndroidVfsEntryType: String, Sendable, Hashable, Codable, CaseIterable, CustomStringConvertible {
    /// Regular file with readable or writable payload stream.
    case file = "File"
    /// Standard navigable directory node.
    case directory = "Directory"
    /// Symbolic or hard filesystem link.
    case symlink = "Symlink"
    /// System-protected directory subject to Android Scoped Storage restrictions (e.g., /Android/data).
    case restrictedDirectory = "RestrictedDirectory"

    public var description: String {
        rawValue
    }
}

/// Represents a file or directory node in the remote virtual file system hierarchy.
public struct AndroidStorageNode: Identifiable, Sendable, Hashable, Codable {
    /// Full normalized absolute path from the storage partition root (e.g. "/Download/archive.zip").
    public let path: String
    /// Base file or directory name including extension.
    public let name: String
    /// Specific VFS node type classification.
    public let entryType: AndroidVfsEntryType
    /// Total file size in bytes (0 for directories and symlinks).
    public let sizeBytes: UInt64
    /// Last modification timestamp as seconds since Unix epoch.
    public let modifiedTimestamp: UInt64
    /// Optional 32-bit MTP ObjectHandle if addressed through MTP protocol.
    public let objectHandle: UInt32?
    /// Flag indicating if the entry resides under an Android 11+ scoped storage restricted path.
    public let isRestricted: Bool

    /// Conformance to Identifiable using normalized path.
    public var id: String {
        path
    }

    /// Indicates whether the node represents a directory or restricted directory.
    public var isDirectory: Bool {
        entryType == .directory || entryType == .restrictedDirectory
    }

    /// Indicates whether the node is a regular file.
    public var isFile: Bool {
        entryType == .file
    }

    /// Indicates whether the node is a symbolic link.
    public var isSymlink: Bool {
        entryType == .symlink
    }

    /// Convenience date calculated from Unix modification timestamp.
    public var modifiedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(modifiedTimestamp))
    }

    /// Determines whether a given normalized VFS path falls under Android Scoped Storage restrictions.
    /// - Parameter path: Normalized VFS path string.
    /// - Returns: True if path is restricted under standard MTP access rules.
    public static func isRestrictedPath(_ path: String) -> Bool {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        return normalized.hasPrefix("/Android/data") || normalized.hasPrefix("/Android/obb")
    }

    /// Memberwise initializer for AndroidStorageNode with automatic restriction detection.
    public init(
        path: String,
        name: String,
        entryType: AndroidVfsEntryType,
        sizeBytes: UInt64 = 0,
        modifiedTimestamp: UInt64 = 0,
        objectHandle: UInt32? = nil,
        isRestricted: Bool? = nil
    ) {
        self.path = path
        self.name = name
        self.entryType = entryType
        self.sizeBytes = sizeBytes
        self.modifiedTimestamp = modifiedTimestamp
        self.objectHandle = objectHandle

        if let isRestricted {
            self.isRestricted = isRestricted
        } else {
            self.isRestricted = entryType == .restrictedDirectory || Self.isRestrictedPath(path)
        }
    }
}

/// Explicit directory listing lifecycle and error states.
/// Guarantees that permission restrictions, enumeration failures, and disconnections
/// are never masked as an "empty folder" in the user interface.
public enum AndroidDirectoryState: Equatable, Sendable {
    case idle
    case loading
    case loaded(entries: [AndroidStorageNode])
    case empty
    case permissionRestricted(reason: String)
    case failed(error: String)
    case disconnected

    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    public var entries: [AndroidStorageNode] {
        if case .loaded(let list) = self { return list }
        return []
    }
}

/// Canonical device location descriptor handed off to window navigation and the right inspector.
/// Decouples Android browsing location from the local Mac volume (e.g. Downloads APFS).
public struct AndroidLocationDescriptor: Equatable, Sendable, Identifiable {
    public var id: String { "\(deviceId):\(currentPath)" }
    public let deviceId: String
    public let deviceName: String
    public let connectionType: AndroidConnectionType
    public let partitionId: String
    public let partitionDisplayName: String
    public let currentPath: String
    public let breadcrumbs: [String]
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let filesystemDisplayName: String
    public let selectedNode: AndroidStorageNode?
    public let directoryState: AndroidDirectoryState

    public init(
        deviceId: String,
        deviceName: String,
        connectionType: AndroidConnectionType,
        partitionId: String,
        partitionDisplayName: String,
        currentPath: String,
        breadcrumbs: [String],
        totalBytes: UInt64,
        availableBytes: UInt64,
        filesystemDisplayName: String,
        selectedNode: AndroidStorageNode? = nil,
        directoryState: AndroidDirectoryState = .idle
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.connectionType = connectionType
        self.partitionId = partitionId
        self.partitionDisplayName = partitionDisplayName
        self.currentPath = currentPath
        self.breadcrumbs = breadcrumbs
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.filesystemDisplayName = filesystemDisplayName
        self.selectedNode = selectedNode
        self.directoryState = directoryState
    }

    public var deviceDisplayName: String { deviceName }
    public var currentDirectoryPath: String { currentPath }
    public var freeSpacePercentage: Double {
        guard totalBytes > 0 else { return 0.0 }
        return Double(availableBytes) / Double(totalBytes) * 100.0
    }
}

/// Window-isolated Android browsing and navigation state preventing cross-window directory bleeding.
public struct AndroidWindowBrowseState: Sendable {
    public var selectedPartition: AndroidStoragePartition?
    public var columnPaths: [String] = []
    public var selectedNodeByColumn: [Int: AndroidStorageNode] = [:]
    public var selectedNode: AndroidStorageNode?
    public var directoryStatesByPath: [String: AndroidDirectoryState] = [:]
    public var requestGeneration: UInt64 = 0

    public init(
        selectedPartition: AndroidStoragePartition? = nil,
        columnPaths: [String] = [],
        selectedNodeByColumn: [Int: AndroidStorageNode] = [:],
        selectedNode: AndroidStorageNode? = nil,
        directoryStatesByPath: [String: AndroidDirectoryState] = [:],
        requestGeneration: UInt64 = 0
    ) {
        self.selectedPartition = selectedPartition
        self.columnPaths = columnPaths
        self.selectedNodeByColumn = selectedNodeByColumn
        self.selectedNode = selectedNode
        self.directoryStatesByPath = directoryStatesByPath
        self.requestGeneration = requestGeneration
    }
}

/// Canonical device-, partition-, and path-scoped request key preventing cross-device/cross-partition cache and dedup collisions.
public struct AndroidDirectoryRequestKey: Hashable, Sendable {
    public let deviceId: String
    public let partitionId: String
    public let path: String

    public init(deviceId: String, partitionId: String, path: String) {
        self.deviceId = deviceId
        self.partitionId = partitionId
        self.path = (path.hasSuffix("/") && path.count > 1) ? String(path.dropLast()) : path
    }
}

