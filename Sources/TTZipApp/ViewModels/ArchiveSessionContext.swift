// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import Observation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
#if canImport(TTZipAppServices)
#endif

/// Independent per-window / per-tab archive workspace session state machine.
@Observable
@MainActor
public final class ArchiveSessionContext: Identifiable {
    public let id: UUID
    public var windowTitle: String
    public var currentArchivePath: String?
    public var currentDirectory: URL
    public var activePassword: String?
    public var currentEntries: [ArchiveEntry] = []
    public var selectedEntryID: String?
    public var activePreviewFileURL: URL?
    public var activePreviewFileName: String?
    public var searchQuery: String = ""
    public var isBuildingTree: Bool = false
    public var rootNodes: [ArchiveTreeNode] = []
    public var vfsTree: UniFfiVfsTree? = nil
    public let vfsCacheSessionId: String
    
    /// Active state flag indicating whether this session has been closed or decommissioned.
    public private(set) var isClosed: Bool = false
    private var loadEpoch: UInt64 = 0
    private var loadingArchivePath: String?

    /// Engine seam. Production always drives the shared facade; tests inject a facade that owns
    /// a controlled reader so the real load chain can be paused deterministically.
    internal var facade: TTZipEngineFacade = TTZipEngineFacade.shared
    internal var passwordVerificationDriver: any ArchivePasswordOperationsDriver =
        DefaultArchivePasswordOperationsDriver.shared

    public init(id: UUID = UUID(), initialURL: URL? = nil) {
        self.id = id
        self.vfsCacheSessionId = "vfs_session_\(id.uuidString)"
        if let url = initialURL {
            self.windowTitle = url.lastPathComponent
            self.currentDirectory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            if !url.hasDirectoryPath {
                self.currentArchivePath = url.path
            }
        } else {
            self.windowTitle = "TTZip"
            self.currentDirectory = FileManager.default.homeDirectoryForCurrentUser
        }
    }
    
    /// Filtered entries based on active search query.
    public var filteredEntries: [ArchiveEntry] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return currentEntries }
        return currentEntries.filter { $0.path.lowercased().contains(trimmed) }
    }
    
    /// Loads an archive file into this isolated session context.
    public func loadArchive(path: String, password: String? = nil) async throws {
        self.isClosed = false
        self.loadEpoch &+= 1
        let currentEpoch = self.loadEpoch
        self.loadingArchivePath = path
        self.isBuildingTree = true
        defer {
            if self.loadEpoch == currentEpoch {
                self.loadingArchivePath = nil
                self.isBuildingTree = false
            }
        }
        
        let startingCandidate = ArchivePasswordStore.shared.getPassword(for: path)
        let inspection = try await inspectWithPasswordEvidence(path: path, password: password)
        let result = inspection.result
        
        // Active state guard: Discard asynchronous inspection results if cancelled,
        // if closeArchive() was invoked during suspension, or if a newer load has superseded this one.
        guard !Task.isCancelled, !self.isClosed, self.loadEpoch == currentEpoch else {
            return
        }

        // The inspection is a query and never writes the shared password cache, so this
        // session is the owner that commits the credential it accepted. A result that was
        // cancelled, closed or superseded never reaches this block and therefore never
        // publishes a credential.
        if let verified = inspection.verifiedPassword, !verified.isEmpty {
            if let password, !password.isEmpty {
                ArchivePasswordStore.shared.setPassword(verified, for: path)
            } else if verified != startingCandidate {
                // A reused cache candidate is not a new authorization; a vault discovery is.
                ArchivePasswordStore.shared.setPassword(
                    verified, for: path, ifCurrentPasswordIs: startingCandidate
                )
            }
        }

        self.currentArchivePath = path
        self.currentEntries = result.entries
        self.activePassword = inspection.verifiedPassword
        self.windowTitle = (path as NSString).lastPathComponent

        // For large archives (> 5,000 entries), prefer native UniFfiVfsTree viewport paging
        // to avoid instantiating 100k+ tree node allocations and 60MB+ heap overhead upfront.
        if result.entries.count > 5000 {
            if let tree = try? loadArchiveVfsTree(archivePath: path, password: inspection.verifiedPassword) {
                guard !Task.isCancelled, !self.isClosed, self.loadEpoch == currentEpoch else { return }
                self.vfsTree = tree
                self.rootNodes = ArchiveTreeNode.buildRootNodes(from: tree)
            } else {
                guard !Task.isCancelled, !self.isClosed, self.loadEpoch == currentEpoch else { return }
                self.vfsTree = nil
                self.rootNodes = FastArchiveTreeBuilder.buildTree(from: result.entries)
            }
        } else {
            self.vfsTree = nil
            self.rootNodes = FastArchiveTreeBuilder.buildTree(from: result.entries)
        }
    }
    
    /// Separates a readable catalog from evidence that a credential actually worked.
    private func inspectWithPasswordEvidence(
        path: String,
        password: String?
    ) async throws -> (result: ArchiveInspectionResult, verifiedPassword: String?) {
        let catalog: ArchiveInspectionResult
        do {
            // Empty means an unauthenticated query: bypass the facade's implicit cache candidate.
            catalog = try await facade.inspectArchive(
                archivePath: path, password: "", autoVaultUnlock: false
            )
        } catch {
            guard ArchivePasswordErrorClassifier.classify(error).category == .wrongPassword else {
                throw error
            }
            // A credential that opens an otherwise unreadable header proves headerCatalog scope.
            let unlocked = try await facade.inspectArchive(
                archivePath: path, password: password, autoVaultUnlock: true
            )
            return (unlocked, unlocked.unlockedPassword)
        }
        guard catalog.entries.contains(where: \.isEncrypted),
              let candidate = password ?? ArchivePasswordStore.shared.getPassword(for: path),
              !candidate.isEmpty else {
            return (catalog, nil)
        }
        let outcome = await ArchivePlaintextCatalogPasswordVerifier.verify(
            archivePath: path, entries: catalog.entries, password: candidate,
            driver: passwordVerificationDriver
        )
        switch outcome {
        case .verified:
            return (catalog, candidate)
        case .noAvailableEvidence:
            return (catalog, nil)
        case .wrongPassword:
            throw ArchiveError.wrongPassword(archivePath: path)
        case .otherFailure(let category, let message):
            throw ArchivePasswordProbeFailure(category: category, message: message)
        }
    }

    /// Closes the currently loaded archive and resets ephemeral session caches.
    public func closeArchive() {
        self.isClosed = true
        self.loadEpoch &+= 1
        self.loadingArchivePath = nil
        self.isBuildingTree = false
        self.currentArchivePath = nil
        self.currentEntries = []
        self.activePassword = nil
        self.selectedEntryID = nil
        self.activePreviewFileURL = nil
        self.activePreviewFileName = nil
        self.searchQuery = ""
        self.rootNodes = []
        self.vfsTree = nil
        self.windowTitle = "TTZip"
    }

    /// Invalidates a pending load so it cannot republish an archive password after Forget.
    public func forgetPassword(forLogicalKey logicalKey: String) {
        let currentMatches = currentArchivePath.map {
            ArchiveCredentialIdentity.logicalKey(for: $0) == logicalKey
        } ?? false
        let loadingMatches = loadingArchivePath.map {
            ArchiveCredentialIdentity.logicalKey(for: $0) == logicalKey
        } ?? false
        guard currentMatches || loadingMatches else { return }
        loadEpoch &+= 1
        loadingArchivePath = nil
        isBuildingTree = false
        activePassword = nil
        vfsTree = nil
        rootNodes = []
    }
}
