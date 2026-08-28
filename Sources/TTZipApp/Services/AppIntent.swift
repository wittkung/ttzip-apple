// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

/// Source origin of an incoming application intent.
public enum AppIntentSource: String, Sendable, Codable, CustomStringConvertible {
    case finderSync = "finder_sync"
    case urlScheme = "url_scheme"
    case appKitMenu = "appkit_menu"
    case dragAndDrop = "drag_and_drop"
    case contextMenu = "context_menu"
    case toolbar = "toolbar"
    case internalNavigation = "internal_navigation"
    
    public var description: String { rawValue }
}

/// Strongly-typed compression options payload.
public struct CompressIntentOptions: Sendable, Codable, Equatable {
    public let presetID: UUID?
    public let targetFormat: ArchiveCompressionFormat?
    public let separateArchives: Bool
    public let deleteSourceAfterCompression: Bool
    public let customOutputPath: String?
    public let password: String?
    
    public init(
        presetID: UUID? = nil,
        targetFormat: ArchiveCompressionFormat? = nil,
        separateArchives: Bool = false,
        deleteSourceAfterCompression: Bool = false,
        customOutputPath: String? = nil,
        password: String? = nil
    ) {
        self.presetID = presetID
        self.targetFormat = targetFormat
        self.separateArchives = separateArchives
        self.deleteSourceAfterCompression = deleteSourceAfterCompression
        self.customOutputPath = customOutputPath
        self.password = password
    }
}

/// Strongly-typed extraction options payload.
public struct ExtractIntentOptions: Sendable, Codable, Equatable {
    public let destinationDirectory: URL?
    public let isSmartExtract: Bool
    public let deleteSourceAfterExtraction: Bool
    public let password: String?
    public let targetEntrySubpaths: [String]?
    
    public init(
        destinationDirectory: URL? = nil,
        isSmartExtract: Bool = true,
        deleteSourceAfterExtraction: Bool = false,
        password: String? = nil,
        targetEntrySubpaths: [String]? = nil
    ) {
        self.destinationDirectory = destinationDirectory
        self.isSmartExtract = isSmartExtract
        self.deleteSourceAfterExtraction = deleteSourceAfterExtraction
        self.password = password
        self.targetEntrySubpaths = targetEntrySubpaths
    }
}

/// Unified, strongly-typed application intent conforming to Sendable.
public enum AppIntent: Sendable, Equatable {
    // 1. Archive Browsing & Navigation
    case openArchive(url: URL, password: String?)
    case navigateToDirectory(url: URL)
    case switchTab(tab: WorkspaceTab)
    case pickAndOpenArchive
    
    // 2. Compression Workspace & Operations
    case createArchive(sourcePaths: [String], options: CompressIntentOptions)
    
    // 3. Extraction Operations
    case extractArchive(archivePaths: [String], options: ExtractIntentOptions)
    
    // 4. Inspection & Diagnostics
    case inspectArchive(archivePath: String)
    case verifyIntegrity(archivePath: String)
    
    // 5. Password Vault & Security
    case promptPassword(archivePath: String)
    case autofillVaultPassword(archivePath: String)
    
    // 6. In-Place Archive Mutation
    case addFilesToArchive(archivePath: String, sourcePaths: [String], destinationSubfolder: String?)
    case deleteArchiveEntries(archivePath: String, entryPaths: [String])
    
    // 7. Preview & System Integration
    case previewItem(url: URL)
    case revealInFinder(url: URL)
}

/// Envelope encapsulating an intent with metadata and telemetry traceability.
public struct AppIntentEnvelope: Sendable, Identifiable {
    public let id: UUID
    public let intent: AppIntent
    public let source: AppIntentSource
    public let timestamp: Date
    
    public init(intent: AppIntent, source: AppIntentSource, id: UUID = UUID(), timestamp: Date = Date()) {
        self.id = id
        self.intent = intent
        self.source = source
        self.timestamp = timestamp
    }
}
