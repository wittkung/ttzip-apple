// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import TTZipSearchKit
import Foundation
import TTZipPreviewKit
import TTZipUI

/// Security-scoped bookmark and directory access manager with reference-counted RAII leases.
/// Enforces Apple App Store Review Guideline 2.4.5(i) Least Privilege without path escalation.
@MainActor
public final class RootFolderAccessManager {
    public static let shared = RootFolderAccessManager()

    internal struct LeaseEntry {
        let instanceID: UUID
        let leaseKey: String
        var scopedResourceURL: URL
        var canonicalURL: URL
        var refCount: Int
        var isSecurityScoped: Bool
    }

    internal let bookmarksKey = "TTZipSecurityScopedBookmarksKey"
    internal var persistedBookmarks: [String: Data] = [:]
    package var activeBookmarks: [URL: Data] = [:]
    internal var leaseEntries: [String: LeaseEntry] = [:]
    internal var retiringLeaseEntries: [UUID: LeaseEntry] = [:]
    internal var revokedScopePaths: Set<String> = []

    /// Optional override for directory authorization prompts during automated testing.
    public var authorizationPromptHandler: (@MainActor (URL, String?) async -> URL?)?
    public internal(set) var lastRequestedAuthorizationURL: URL?

    /// Whether automated background semantic indexing on bookmark restore/persist is enabled.
    /// Defaults to `false` inside XCTest runs unless explicitly enabled by lifecycle tests.
    public var isAutoSemanticIndexingEnabled: Bool = (NSClassFromString("XCTestCase") == nil)

    /// Target semantic search engine receiving automatic bookmark registration and revocation events.
    /// Registered at startup by `LocalModelManager` (`nil` until wired); overridable in lifecycle tests.
    public var autoSemanticIndexingEngineProvider: (() -> SemanticSearchEngine)? = nil

    /// Injectable hook for starting system security-scoped resource access.
    /// Defaults to `url.startAccessingSecurityScopedResource()`.
    public var startSecurityScopedAccess: @MainActor (URL) -> Bool = { url in
        url.startAccessingSecurityScopedResource()
    }

    /// Injectable hook for stopping system security-scoped resource access.
    /// Defaults to `url.stopAccessingSecurityScopedResource()`.
    public var stopSecurityScopedAccess: @MainActor (URL) -> Void = { url in
        url.stopAccessingSecurityScopedResource()
    }

    /// Active security-scoped URLs currently accessed by the process.
    public var accessingURLs: Set<URL> {
        Set(leaseEntries.values.filter { $0.refCount > 0 }.map { $0.canonicalURL })
    }

    /// Total reference count across all active leases.
    public var totalActiveLeaseCount: Int {
        leaseEntries.values.reduce(0) { $0 + $1.refCount }
    }

    /// Total reference count across all revoked/retiring leases still held by in-flight consumers.
    public var totalRetiringLeaseCount: Int {
        retiringLeaseEntries.values.reduce(0) { $0 + $1.refCount }
    }

    private init() {
        restoreBookmarks()
    }

    deinit {
        var stoppedKeys = Set<String>()
        for entry in leaseEntries.values where entry.refCount > 0 && entry.isSecurityScoped {
            if stoppedKeys.insert(entry.leaseKey).inserted {
                entry.scopedResourceURL.stopAccessingSecurityScopedResource()
            }
        }
        for entry in retiringLeaseEntries.values where entry.refCount > 0 && entry.isSecurityScoped {
            if stoppedKeys.insert(entry.leaseKey).inserted {
                entry.scopedResourceURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// Resolves the physical user home directory outside the App Sandbox container.
    public static var realUserHomeURL: URL {
        if let pw = getpwuid(getuid()), let homeDir = pw.pointee.pw_dir {
            let path = String(cString: homeDir)
            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        }
        let rawHome = NSHomeDirectory()
        if let range = rawHome.range(of: "/Library/Containers/") {
            let base = String(rawHome[..<range.lowerBound])
            return URL(fileURLWithPath: base).standardizedFileURL.resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: rawHome).standardizedFileURL.resolvingSymlinksInPath()
    }

    nonisolated public static func isIsolatedVerificationEnvironment(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String]? = nil
    ) -> Bool {
        if let environment {
            if environment["TTZIP_GUI_VERIFY_ISOLATED"] == "1" { return true }
        } else if ProcessInfo.processInfo.environment["TTZIP_GUI_VERIFY_ISOLATED"] == "1"
            || (getenv("TTZIP_GUI_VERIFY_ISOLATED").map { String(cString: $0) == "1" } ?? false) {
            return true
        }
        guard let bundleIdentifier else { return false }
        return bundleIdentifier.contains(".axverify-") || bundleIdentifier.contains(".cuverify-")
    }

    nonisolated public static var isIsolatedVerificationProcess: Bool {
        isIsolatedVerificationEnvironment()
    }

    nonisolated public static func defaultInitialDirectoryURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        environment: [String: String]? = nil
    ) -> URL {
        if isIsolatedVerificationEnvironment(bundleIdentifier: bundleIdentifier, environment: environment) {
            let env = environment ?? ProcessInfo.processInfo.environment
            let raw = env["TTZIP_GUI_VERIFY_INITIAL_DIR"]
                ?? (Bundle.main.object(forInfoDictionaryKey: "TTZipInitialDirectoryPath") as? String)
            if let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path).standardizedFileURL
            }
            return FileManager.default.temporaryDirectory.standardizedFileURL
        }
        return URL(fileURLWithPath: (NSHomeDirectory() as NSString).expandingTildeInPath + "/Downloads").standardizedFileURL
    }

    /// Resolves canonical file URL with symlink resolution, strictly enforcing least privilege.
    /// Strictly complies with Apple App Store Review Guideline 2.4.5(i) without escalating paths to root or user home.
    nonisolated public func canonicalDirectoryURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    nonisolated private static func isSameOrSubpath(_ targetPath: String, of rootPath: String) -> Bool {
        if targetPath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return targetPath.hasPrefix(prefix)
    }

    nonisolated public static func makeBookmarkData(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    nonisolated public static func resolveBookmarkData(_ data: Data) -> (url: URL, isStale: Bool)? {
        for options: URL.BookmarkResolutionOptions in [.withSecurityScope, [.withoutUI]] {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return (resolved, isStale)
            }
        }
        return nil
    }

    private func isOverriddenByRevocation(forPath path: String, candidateRootKey: String) -> Bool {
        revokedScopePaths.contains {
            $0.count >= candidateRootKey.count && Self.isSameOrSubpath(path, of: $0)
        }
    }

    internal func matchingActiveLeaseKey(forPath path: String) -> String? {
        guard let key = leaseEntries.keys
            .filter({ (leaseEntries[$0]?.refCount ?? 0) > 0 && Self.isSameOrSubpath(path, of: $0) })
            .sorted(by: { $0.count > $1.count })
            .first
        else { return nil }
        return isOverriddenByRevocation(forPath: path, candidateRootKey: key) ? nil : key
    }

    internal func matchingBookmarkKey(forPath path: String) -> String? {
        guard let key = persistedBookmarks.keys
            .filter({ Self.isSameOrSubpath(path, of: $0) })
            .sorted(by: { $0.count > $1.count })
            .first
        else { return nil }
        return isOverriddenByRevocation(forPath: path, candidateRootKey: key) ? nil : key
    }

    /// Returns `true` if `url` or a covering ancestor directory currently has a persisted bookmark.
    public func hasPersistedBookmark(for url: URL) -> Bool {
        let normalized = canonicalDirectoryURL(for: url)
        return matchingBookmarkKey(forPath: normalized.path) != nil
    }

    internal func isBlockedByRevokedOrRetiringScope(forPath path: String) -> Bool {
        if retiringLeaseEntries.values.contains(where: { $0.refCount > 0 && Self.isSameOrSubpath(path, of: $0.leaseKey) }) {
            return true
        }
        return revokedScopePaths.contains { Self.isSameOrSubpath(path, of: $0) }
    }

    internal func clearRevokedScopeState(forAuthorizedPath authorizedPath: String) {
        revokedScopePaths = revokedScopePaths.filter { revokedPath in
            !(revokedPath == authorizedPath || Self.isSameOrSubpath(revokedPath, of: authorizedPath))
        }
    }

    // MARK: - Reference-Counted Lease Acquisition

    internal func liveRetiringSecurityScopedURL(forLeaseKey leaseKey: String) -> URL? {
        retiringLeaseEntries.values.first {
            $0.leaseKey == leaseKey && $0.refCount > 0 && $0.isSecurityScoped
        }?.scopedResourceURL
    }

    internal func hasLiveSecurityScopedHolder(forLeaseKey leaseKey: String) -> Bool {
        if let active = leaseEntries[leaseKey], active.refCount > 0, active.isSecurityScoped {
            return true
        }
        return retiringLeaseEntries.values.contains {
            $0.leaseKey == leaseKey && $0.refCount > 0 && $0.isSecurityScoped
        }
    }

    private func stopSecurityScopedAccessIfNoLiveHolders(forLeaseKey leaseKey: String, scopedURL: URL) {
        guard !hasLiveSecurityScopedHolder(forLeaseKey: leaseKey) else { return }
        stopSecurityScopedAccess(scopedURL)
    }

    private func retireActiveLeaseEntry(forKey key: String) {
        guard let entry = leaseEntries.removeValue(forKey: key) else { return }
        if entry.refCount > 0 {
            retiringLeaseEntries[entry.instanceID] = entry
        } else if entry.isSecurityScoped {
            stopSecurityScopedAccessIfNoLiveHolders(
                forLeaseKey: entry.leaseKey,
                scopedURL: entry.scopedResourceURL
            )
        }
    }

    internal func retireAllActiveLeases() {
        for key in Array(leaseEntries.keys) {
            retireActiveLeaseEntry(forKey: key)
        }
    }

    /// Acquires a reference-counted RAII lease for the specified target URL.
    /// Balances startAccessingSecurityScopedResource with stopAccessingSecurityScopedResource.
    public func acquireLease(for url: URL) -> SecurityScopeLease? {
        let requestedCanonical = canonicalDirectoryURL(for: url)

        let bookmarkKey = matchingBookmarkKey(forPath: requestedCanonical.path)
        if let activeKey = matchingActiveLeaseKey(forPath: requestedCanonical.path),
           bookmarkKey == nil || activeKey.count >= (bookmarkKey?.count ?? 0),
           var entry = leaseEntries[activeKey] {
            entry.refCount += 1
            leaseEntries[activeKey] = entry
            return makeLease(
                requestedURL: requestedCanonical, activatedURL: entry.scopedResourceURL,
                leaseKey: activeKey, instanceID: entry.instanceID, ownsSecurityScope: true
            )
        }

        if let activated = activatePersistedBookmarkIfAvailable(for: requestedCanonical) {
            return makeLease(
                requestedURL: requestedCanonical, activatedURL: activated.scopedURL,
                leaseKey: activated.leaseKey, instanceID: activated.instanceID, ownsSecurityScope: true
            )
        }

        guard !isBlockedByRevokedOrRetiringScope(forPath: requestedCanonical.path) else { return nil }

        let leaseKey = requestedCanonical.path
        let didStartDirect = startSecurityScopedAccess(url)
        let isReadable = didStartDirect || FileManager.default.isReadableFile(atPath: requestedCanonical.path)
        guard didStartDirect || isReadable else { return nil }

        let scopedURL = didStartDirect ? url : requestedCanonical
        let instanceID = UUID()
        leaseEntries[leaseKey] = LeaseEntry(
            instanceID: instanceID, leaseKey: leaseKey, scopedResourceURL: scopedURL,
            canonicalURL: requestedCanonical, refCount: 1, isSecurityScoped: didStartDirect
        )
        return makeLease(
            requestedURL: requestedCanonical, activatedURL: scopedURL,
            leaseKey: leaseKey, instanceID: instanceID, ownsSecurityScope: true
        )
    }

    private func releaseLease(instanceID: UUID, fallbackKey: String) {
        if var active = leaseEntries[fallbackKey], active.instanceID == instanceID {
            if active.refCount <= 1 {
                leaseEntries.removeValue(forKey: fallbackKey)
                if active.isSecurityScoped {
                    stopSecurityScopedAccessIfNoLiveHolders(forLeaseKey: active.leaseKey, scopedURL: active.scopedResourceURL)
                }
            } else {
                active.refCount -= 1
                leaseEntries[fallbackKey] = active
            }
            return
        }
        if var retiring = retiringLeaseEntries[instanceID] {
            if retiring.refCount <= 1 {
                retiringLeaseEntries.removeValue(forKey: instanceID)
                if retiring.isSecurityScoped {
                    stopSecurityScopedAccessIfNoLiveHolders(forLeaseKey: retiring.leaseKey, scopedURL: retiring.scopedResourceURL)
                }
            } else {
                retiring.refCount -= 1
                retiringLeaseEntries[instanceID] = retiring
            }
        }
    }

    /// Releases a single reference-counted lease identified by its canonical lease key.
    public func releaseLease(forKey leaseKey: String) {
        if let entry = leaseEntries[leaseKey], entry.refCount > 0 {
            releaseLease(instanceID: entry.instanceID, fallbackKey: leaseKey)
            return
        }
        if let retiring = retiringLeaseEntries.values.first(where: { $0.leaseKey == leaseKey && $0.refCount > 0 }) {
            releaseLease(instanceID: retiring.instanceID, fallbackKey: leaseKey)
        }
    }

    /// Releases a single reference-counted lease for the specified URL.
    public func releaseLease(for url: URL) {
        let normalized = canonicalDirectoryURL(for: url)
        if leaseEntries[normalized.path] != nil {
            releaseLease(forKey: normalized.path)
            return
        }
        if let ancestorKey = matchingActiveLeaseKey(forPath: normalized.path) {
            releaseLease(forKey: ancestorKey)
            return
        }
        if let retiring = retiringLeaseEntries.values.first(where: {
            $0.refCount > 0 && ($0.leaseKey == normalized.path || Self.isSameOrSubpath(normalized.path, of: $0.leaseKey))
        }) {
            releaseLease(instanceID: retiring.instanceID, fallbackKey: retiring.leaseKey)
        }
    }

    private func makeLease(
        requestedURL: URL,
        activatedURL: URL,
        leaseKey: String,
        instanceID: UUID,
        ownsSecurityScope: Bool
    ) -> SecurityScopeLease {
        SecurityScopeLease(
            url: requestedURL,
            activatedURL: activatedURL,
            leaseKey: leaseKey,
            ownsSecurityScope: ownsSecurityScope
        ) { @Sendable key in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    RootFolderAccessManager.shared.releaseLease(instanceID: instanceID, fallbackKey: key)
                }
            } else {
                Task { @MainActor in
                    RootFolderAccessManager.shared.releaseLease(instanceID: instanceID, fallbackKey: key)
                }
            }
        }
    }

    /// Returns active reference count for the specified lease key.
    public func activeLeaseCount(forKey leaseKey: String) -> Int {
        leaseEntries[leaseKey]?.refCount ?? 0
    }

    /// Returns active reference count for the specified URL (or its covering ancestor lease).
    public func activeLeaseCount(for url: URL) -> Int {
        let normalized = canonicalDirectoryURL(for: url)
        if let activeKey = matchingActiveLeaseKey(forPath: normalized.path) {
            return leaseEntries[activeKey]?.refCount ?? 0
        }
        return 0
    }

    /// Returns retiring reference count for the specified canonical lease key.
    public func retiringLeaseCount(forKey leaseKey: String) -> Int {
        retiringLeaseEntries.values
            .filter { $0.leaseKey == leaseKey && $0.refCount > 0 }
            .reduce(0) { $0 + $1.refCount }
    }

    /// Returns retiring reference count for the specified URL (or its covering ancestor lease).
    public func retiringLeaseCount(for url: URL) -> Int {
        let normalized = canonicalDirectoryURL(for: url)
        let exact = retiringLeaseCount(forKey: normalized.path)
        if exact > 0 {
            return exact
        }
        return retiringLeaseEntries.values
            .filter { $0.refCount > 0 && Self.isSameOrSubpath(normalized.path, of: $0.leaseKey) }
            .reduce(0) { $0 + $1.refCount }
    }

    // MARK: - Access Revocation

    /// Revokes security-scoped access for a specific directory URL and cleans its bookmark.
    /// Separates revoking new admission/persistent bookmarks from retiring in-flight leases:
    /// active leases with `refCount > 0` are moved to `retiringLeaseEntries` and only invoke
    /// `stopSecurityScopedAccess` when the last in-flight holder calls `release()`.
    public func revokeAccess(for url: URL) {
        let target = canonicalDirectoryURL(for: url)
        revokedScopePaths.insert(target.path)
        let keysToRevoke = leaseEntries.keys.filter {
            $0 == target.path || Self.isSameOrSubpath($0, of: target.path)
        }
        for key in keysToRevoke {
            revokedScopePaths.insert(key)
            retireActiveLeaseEntry(forKey: key)
        }
        var revokedURLs: Set<URL> = [target.standardizedFileURL]
        activeBookmarks.removeValue(forKey: target)
        for key in Array(activeBookmarks.keys) {
            let canonicalKeyPath = canonicalDirectoryURL(for: key).path
            if canonicalKeyPath == target.path || Self.isSameOrSubpath(canonicalKeyPath, of: target.path) {
                activeBookmarks.removeValue(forKey: key)
                revokedScopePaths.insert(canonicalKeyPath)
                revokedURLs.insert(URL(fileURLWithPath: canonicalKeyPath).standardizedFileURL)
            }
        }
        persistedBookmarks.removeValue(forKey: target.path)
        for key in Array(persistedBookmarks.keys) {
            let canonicalKeyPath = canonicalDirectoryURL(for: URL(fileURLWithPath: key)).path
            if canonicalKeyPath == target.path || Self.isSameOrSubpath(canonicalKeyPath, of: target.path) {
                persistedBookmarks.removeValue(forKey: key)
                revokedScopePaths.insert(canonicalKeyPath)
                revokedURLs.insert(URL(fileURLWithPath: canonicalKeyPath).standardizedFileURL)
            }
        }
        saveBookmarks()
        notifyAutoSemanticRevocation(for: revokedURLs)
    }

    /// Revokes all active security-scoped resource accesses and clears persisted bookmarks.
    public func revokeAllAccess() {
        let urlsToRevoke = Set(
            activeBookmarks.keys.map(\.standardizedFileURL)
                + persistedBookmarks.keys.map { URL(fileURLWithPath: $0).standardizedFileURL }
                + leaseEntries.values.map { $0.canonicalURL.standardizedFileURL }
                + retiringLeaseEntries.values.map { $0.canonicalURL.standardizedFileURL }
        )
        for url in urlsToRevoke {
            revokedScopePaths.insert(canonicalDirectoryURL(for: url).path)
        }
        retireAllActiveLeases()
        activeBookmarks.removeAll()
        persistedBookmarks.removeAll()
        UserDefaults.standard.removeObject(forKey: bookmarksKey)
        notifyAutoSemanticRevocation(for: urlsToRevoke)
    }

    private func notifyAutoSemanticRevocation(for standardizedURLs: Set<URL>) {
        guard isAutoSemanticIndexingEnabled,
              let semanticEngine = autoSemanticIndexingEngineProvider?()
        else { return }
        for standardizedURL in standardizedURLs {
            Task {
                _ = await semanticEngine.revokeAuthorizedDirectory(url: standardizedURL)
            }
        }
    }

    package func notifyAutoSemanticRegistration(for normalizedURL: URL) {
        guard isAutoSemanticIndexingEnabled,
              let semanticEngine = autoSemanticIndexingEngineProvider?()
        else { return }
        let standardizedURL = normalizedURL.standardizedFileURL
        Task {
            _ = await semanticEngine.registerAuthorizedDirectory(
                url: standardizedURL,
                isAuthorized: true,
                startIndexingImmediately: true
            )
        }
    }
}
