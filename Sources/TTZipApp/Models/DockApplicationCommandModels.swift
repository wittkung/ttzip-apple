// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

// MARK: - 1. Unified Application Command & Target Window Delivery

/// High-level application command triggered from the native Dock menu, main menu bar, or keyboard shortcuts.
public enum ApplicationWindowCommand: Sendable, Equatable {
    case openNewWindow
    case presentNewSmartFolder(initialScopeDirectory: URL?)
    case openSmartFolder(id: UUID)
    case focusFind(initialQuery: String?)
    case presentGoToFolder(initialPath: String?)
    case presentConnectToServer(initialAddress: String?)
    case navigateToFavoriteLocation(path: String, bookmarkData: Data?, healthState: SidebarItemHealthState)
    case openRecentItem(RecentLocationItem)
}

// MARK: - 2. Recent Locations & Items (Unified Folder + Archive Recents)

/// Discriminated kind for a recently visited or opened item in TTZip.
public enum RecentLocationKind: String, Codable, Sendable, Equatable, Hashable {
    case directory
    case archive
}

/// Persistent record representing a recently visited folder or opened archive in TTZip.
public struct RecentLocationItem: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { "\(kind.rawValue):\(canonicalPath)" }
    public let path: String
    public let canonicalPath: String
    public let displayName: String
    public let kind: RecentLocationKind
    public let lastAccessedAt: Date
    public var bookmarkData: Data?
    public let identity: FileIdentity

    public init(
        path: String,
        displayName: String? = nil,
        kind: RecentLocationKind,
        lastAccessedAt: Date = Date(),
        bookmarkData: Data? = nil,
        identity: FileIdentity? = nil
    ) {
        let resolvedIdentity = identity ?? FileIdentity(path: path)
        self.path = path
        self.canonicalPath = resolvedIdentity.canonicalPath
        if let displayName, !displayName.isEmpty {
            self.displayName = displayName
        } else {
            let last = (path as NSString).lastPathComponent
            self.displayName = last.isEmpty ? path : last
        }
        self.kind = kind
        self.lastAccessedAt = lastAccessedAt
        self.bookmarkData = bookmarkData
        self.identity = resolvedIdentity
    }
}

/// Snapshot of a favorite shortcut item prepared for synchronous, zero-I/O Dock menu rendering.
public struct DockMenuFavoriteEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let disambiguatedTitle: String
    public let path: String
    public let canonicalPath: String
    public let systemImage: String
    public let identity: FileIdentity
    public let healthState: SidebarItemHealthState
    public let bookmarkData: Data?
    public let isCustomPinned: Bool

    public init(
        id: String,
        title: String,
        disambiguatedTitle: String,
        path: String,
        canonicalPath: String,
        systemImage: String,
        identity: FileIdentity,
        healthState: SidebarItemHealthState,
        bookmarkData: Data?,
        isCustomPinned: Bool
    ) {
        self.id = id
        self.title = title
        self.disambiguatedTitle = disambiguatedTitle
        self.path = path
        self.canonicalPath = canonicalPath
        self.systemImage = systemImage
        self.identity = identity
        self.healthState = healthState
        self.bookmarkData = bookmarkData
        self.isCustomPinned = isCustomPinned
    }
}

/// Snapshot of a recent item prepared for synchronous, zero-I/O Dock menu rendering.
public struct DockMenuRecentEntry: Identifiable, Sendable, Equatable {
    public var id: String { item.id }
    public let item: RecentLocationItem
    public let disambiguatedTitle: String
    public let systemImage: String

    public init(item: RecentLocationItem, disambiguatedTitle: String, systemImage: String) {
        self.item = item
        self.disambiguatedTitle = disambiguatedTitle
        self.systemImage = systemImage
    }
}

// MARK: - 3. Slice B: Smart Folder (Saved Search) Narrow Contract

/// Search scope persisted inside a `SmartFolderRecord`.
public enum SmartFolderSearchScope: Codable, Sendable, Equatable, Hashable {
    /// Scoped to a specific local directory (including accessible subdirectories).
    case directory(path: String, bookmarkData: Data?)
    /// Scoped to full-disk accessible Spotlight index and authorized folders.
    case fullDisk

    public var isFullDisk: Bool {
        if case .fullDisk = self { return true }
        return false
    }

    public var directoryPath: String? {
        if case .directory(let path, _) = self { return path }
        return nil
    }

    public var bookmarkData: Data? {
        if case .directory(_, let data) = self { return data }
        return nil
    }
}

/// File kind filter criterion for a Smart Folder saved search.
public enum SmartFolderKindFilter: String, Codable, CaseIterable, Sendable, Equatable, Hashable, Identifiable {
    case any = "any"
    case archivesOnly = "archives_only"
    case foldersOnly = "folders_only"
    case filesOnly = "files_only"

    public var id: String { rawValue }
}

/// Structured query criteria for a Smart Folder.
/// Saved searches evaluate dynamically against live directory contents or system indexes
/// and never copy, move, or duplicate physical files.
public struct SmartFolderCriteria: Codable, Sendable, Equatable, Hashable {
    /// Name or path substring tokens (whitespace-separated; may be empty if extension or kind filter is set).
    public var nameQuery: String
    /// Optional file extension filter without leading dot (e.g., `"zip"`, `"pdf"`, `"swift"`).
    public var fileExtension: String
    /// Broad file kind filter (`any`, `archivesOnly`, `foldersOnly`, `filesOnly`).
    public var kindFilter: SmartFolderKindFilter

    public init(
        nameQuery: String = "",
        fileExtension: String = "",
        kindFilter: SmartFolderKindFilter = .any
    ) {
        self.nameQuery = nameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanExt = fileExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        self.fileExtension = cleanExt
        self.kindFilter = kindFilter
    }

    /// True when no name tokens, extension filter, or specific kind filter have been configured.
    public var isEmptyCondition: Bool {
        nameQuery.isEmpty && fileExtension.isEmpty && kindFilter == .any
    }

    /// Synthesizes the search query string passed to lexical/Spotlight scanners.
    public var effectiveScannerQuery: String {
        var tokens: [String] = []
        if !nameQuery.isEmpty {
            tokens.append(nameQuery)
        }
        if !fileExtension.isEmpty {
            tokens.append(".\(fileExtension)")
        }
        if tokens.isEmpty && kindFilter != .any {
            // Wildcard-compatible fallback token for kind-only filters when scanning directory entries
            return "*"
        }
        return tokens.joined(separator: " ")
    }
}

/// Persistent Smart Folder (Saved Search) definition.
///
/// Compatibility Decision:
/// TTZip persists Smart Folders in its own structured JSON store (`com.metastudyline.ttzip.smart-folders.v1`)
/// rather than emitting partial or incompatible Finder `.savedSearch` raw PropertyList query trees.
/// Existing Finder `.savedSearch` files on disk are inspected read-only if opened (extracting `RawQuery` /
/// `SearchScopes` when present) and never overwritten or corrupted.
public struct SmartFolderRecord: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var criteria: SmartFolderCriteria
    public var scope: SmartFolderSearchScope
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        criteria: SmartFolderCriteria,
        scope: SmartFolderSearchScope,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.criteria = criteria
        self.scope = scope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Explicit scan budget limits disclosed by `SmartFolderEvaluationResult` and `ActiveSmartFolderResultsBannerView`.
public struct SmartFolderScanBudget: Sendable, Equatable {
    public static let defaultBudget = SmartFolderScanBudget(
        maxDirectoryResults: 160,
        maxVisitedEntries: 10_000,
        maxDepth: 12,
        maxSpotlightResults: 80
    )

    public let maxDirectoryResults: Int
    public let maxVisitedEntries: Int
    public let maxDepth: Int
    public let maxSpotlightResults: Int

    public init(
        maxDirectoryResults: Int,
        maxVisitedEntries: Int,
        maxDepth: Int,
        maxSpotlightResults: Int
    ) {
        self.maxDirectoryResults = maxDirectoryResults
        self.maxVisitedEntries = maxVisitedEntries
        self.maxDepth = maxDepth
        self.maxSpotlightResults = maxSpotlightResults
    }
}

/// Domain errors for Smart Folder creation and mutation.
public enum SmartFolderOperationError: Error, LocalizedError, Sendable, Equatable {
    case emptyName
    case emptyCriteria
    case notFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Please enter a name for the Smart Folder."
        case .emptyCriteria:
            return "Please specify at least one search criterion (name, extension, or file kind)."
        case .notFound(let id):
            return "Smart Folder \(id.uuidString) could not be found."
        }
    }
}

// MARK: - 4. Slice C: Connect to Server (Network Share Connection) Contract

/// Network file sharing protocols explicitly supported by TTZip's Connect to Server workflow.
public enum SupportedNetworkShareScheme: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case smb = "smb"
    case afp = "afp"
    case nfs = "nfs"

    public var defaultPrefix: String {
        "\(rawValue)://"
    }

    public var displayBadge: String {
        rawValue.uppercased()
    }
}

/// Validated, credential-scrubbed network share endpoint descriptor.
/// Guarantees that passwords are NEVER stored in URL strings, recents, logs, or UserDefaults.
public struct ValidatedServerEndpoint: Sendable, Equatable, Hashable, Codable {
    public let scheme: SupportedNetworkShareScheme
    public let host: String
    public let port: Int?
    public let sharePath: String
    public let username: String?

    public init(
        scheme: SupportedNetworkShareScheme,
        host: String,
        port: Int? = nil,
        sharePath: String = "",
        username: String? = nil
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.sharePath = sharePath
        self.username = username
    }

    /// Reconstructs a sanitized URL suitable for mounting and persistence (never contains a password).
    public var sanitizedURL: URL? {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        if let username, !username.isEmpty {
            components.user = username
        }
        components.password = nil
        if sharePath.isEmpty {
            components.path = ""
        } else {
            components.path = sharePath.hasPrefix("/") ? sharePath : "/" + sharePath
        }
        return components.url
    }

    /// Canonical display string without credentials for recents and UI labels (e.g. `smb://nas.local/media`).
    public var sanitizedAddressString: String {
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        if sharePath.isEmpty {
            components.path = ""
        } else {
            components.path = sharePath.hasPrefix("/") ? sharePath : "/" + sharePath
        }
        return components.string ?? "\(scheme.rawValue)://\(host)\(sharePath)"
    }
}

/// Validation errors when parsing user-supplied server addresses.
public enum ServerAddressValidationError: Error, LocalizedError, Sendable, Equatable {
    case emptyInput
    case unsupportedScheme(String)
    case missingHost
    case invalidSyntax(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Please enter a server address (for example, smb://server/share)."
        case .unsupportedScheme(let scheme):
            return "Unsupported protocol “\(scheme)://”. TTZip supports SMB (smb://), AFP (afp://), and NFS (nfs://)."
        case .missingHost:
            return "Server hostname or IP address is missing."
        case .invalidSyntax(let raw):
            return "Invalid server address format: \(raw)"
        }
    }
}

/// Lifecycle state of a user-initiated network server connection attempt.
public enum ServerConnectionState: Sendable, Equatable {
    case idle
    case connecting(endpoint: ValidatedServerEndpoint)
    case connected(mountPointURL: URL, reusedExistingMount: Bool)
    case cancelled
    case failed(ServerConnectionFailureReason)

    public var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }
}

/// Classified failure reasons for a network share connection attempt.
public enum ServerConnectionFailureReason: Error, LocalizedError, Sendable, Equatable {
    case validationError(ServerAddressValidationError)
    case authenticationFailed(String)
    case hostUnreachable(String)
    case shareNotFound(String)
    case permissionDenied(String)
    case sandboxAuthorizationDeclined(String)
    case mountFailed(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .validationError(let err):
            return err.errorDescription
        case .authenticationFailed(let host):
            return "Authentication failed or was declined for \(host)."
        case .hostUnreachable(let host):
            return "Server “\(host)” is unreachable or timed out."
        case .shareNotFound(let share):
            return "The requested network share “\(share)” could not be found."
        case .permissionDenied(let host):
            return "Access to “\(host)” was denied by the server."
        case .sandboxAuthorizationDeclined(let path):
            return "Read access to the mounted volume at “\(path)” was not granted."
        case .mountFailed(_, let message):
            return message
        }
    }
}
