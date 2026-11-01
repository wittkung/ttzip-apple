// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTZipPreviewKit
import TTZipUI

/// Security-scoped bookmark and directory access manager with reference-counted RAII leases.
/// Enforces Apple App Store Review Guideline 2.4.5(i) Least Privilege without path escalation.
@MainActor
public final class RootFolderAccessManager {
    public static let shared = RootFolderAccessManager()

    private struct LeaseEntry {
        let instanceID: UUID
        let leaseKey: String
        var scopedResourceURL: URL
        var canonicalURL: URL
        var refCount: Int
        var isSecurityScoped: Bool
    }

    private let bookmarksKey = "TTZipSecurityScopedBookmarksKey"
    private var persistedBookmarks: [String: Data] = [:]
    private var activeBookmarks: [URL: Data] = [:]
    private var leaseEntries: [String: LeaseEntry] = [:]
    private var retiringLeaseEntries: [UUID: LeaseEntry] = [:]
    private var revokedScopePaths: Set<String> = []

    /// Optional override for directory authorization prompts during automated testing.
    public var authorizationPromptHandler: (@MainActor (URL, String?) async -> URL?)?
    public private(set) var lastRequestedAuthorizationURL: URL?

    /// Whether automated background semantic indexing on bookmark restore/persist is enabled.
    /// Defaults to `false` inside XCTest runs unless explicitly enabled by lifecycle tests.
    public var isAutoSemanticIndexingEnabled: Bool = (NSClassFromString("XCTestCase") == nil)

    /// Target semantic search engine receiving automatic bookmark registration and revocation events.
    /// Defaults to `LocalModelManager.shared.engine`; overridable in lifecycle tests.
    public var autoSemanticIndexingEngineProvider: () -> SemanticSearchEngine = {
        LocalModelManager.shared.engine
    }

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
        if let scoped = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    nonisolated public static func resolveBookmarkData(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        if let resolved = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (resolved, isStale)
        }
        isStale = false
        if let resolved = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (resolved, isStale)
        }
        return nil
    }

    private func isOverriddenByRevocation(forPath path: String, candidateRootKey: String) -> Bool {
        revokedScopePaths.contains {
            $0.count >= candidateRootKey.count && Self.isSameOrSubpath(path, of: $0)
        }
    }

    private func matchingActiveLeaseKey(forPath path: String) -> String? {
        guard let key = leaseEntries.keys
            .filter({ (leaseEntries[$0]?.refCount ?? 0) > 0 && Self.isSameOrSubpath(path, of: $0) })
            .sorted(by: { $0.count > $1.count })
            .first
        else { return nil }
        return isOverriddenByRevocation(forPath: path, candidateRootKey: key) ? nil : key
    }

    private func matchingBookmarkKey(forPath path: String) -> String? {
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

    private func isBlockedByRevokedOrRetiringScope(forPath path: String) -> Bool {
        if retiringLeaseEntries.values.contains(where: { $0.refCount > 0 && Self.isSameOrSubpath(path, of: $0.leaseKey) }) {
            return true
        }
        return revokedScopePaths.contains { Self.isSameOrSubpath(path, of: $0) }
    }

    private func clearRevokedScopeState(forAuthorizedPath authorizedPath: String) {
        revokedScopePaths = revokedScopePaths.filter { revokedPath in
            !(revokedPath == authorizedPath || Self.isSameOrSubpath(revokedPath, of: authorizedPath))
        }
    }

    // MARK: - Reference-Counted Lease Acquisition

    private func liveRetiringSecurityScopedURL(forLeaseKey leaseKey: String) -> URL? {
        retiringLeaseEntries.values.first {
            $0.leaseKey == leaseKey && $0.refCount > 0 && $0.isSecurityScoped
        }?.scopedResourceURL
    }

    private func hasLiveSecurityScopedHolder(forLeaseKey leaseKey: String) -> Bool {
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

    private func retireAllActiveLeases() {
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
                requestedURL: requestedCanonical,
                activatedURL: entry.scopedResourceURL,
                leaseKey: activeKey,
                instanceID: entry.instanceID,
                ownsSecurityScope: true
            )
        }

        if let activated = activatePersistedBookmarkIfAvailable(for: requestedCanonical) {
            return makeLease(
                requestedURL: requestedCanonical,
                activatedURL: activated.scopedURL,
                leaseKey: activated.leaseKey,
                instanceID: activated.instanceID,
                ownsSecurityScope: true
            )
        }

        guard !isBlockedByRevokedOrRetiringScope(forPath: requestedCanonical.path) else {
            return nil
        }

        let leaseKey = requestedCanonical.path
        let didStartDirect = startSecurityScopedAccess(url)
        let isReadable = didStartDirect || FileManager.default.isReadableFile(atPath: requestedCanonical.path)
        guard didStartDirect || isReadable else {
            return nil
        }

        let scopedURL = didStartDirect ? url : requestedCanonical
        let instanceID = UUID()
        leaseEntries[leaseKey] = LeaseEntry(
            instanceID: instanceID,
            leaseKey: leaseKey,
            scopedResourceURL: scopedURL,
            canonicalURL: requestedCanonical,
            refCount: 1,
            isSecurityScoped: didStartDirect
        )
        return makeLease(
            requestedURL: requestedCanonical,
            activatedURL: scopedURL,
            leaseKey: leaseKey,
            instanceID: instanceID,
            ownsSecurityScope: true
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
        guard isAutoSemanticIndexingEnabled else { return }
        let semanticEngine = autoSemanticIndexingEngineProvider()
        for standardizedURL in standardizedURLs {
            Task {
                _ = await semanticEngine.revokeAuthorizedDirectory(url: standardizedURL)
            }
        }
    }

    private func notifyAutoSemanticRegistration(for normalizedURL: URL) {
        guard isAutoSemanticIndexingEnabled else { return }
        let standardizedURL = normalizedURL.standardizedFileURL
        let semanticEngine = autoSemanticIndexingEngineProvider()
        Task {
            _ = await semanticEngine.registerAuthorizedDirectory(
                url: standardizedURL,
                isAuthorized: true,
                startIndexingImmediately: true
            )
        }
    }

    // MARK: - Bookmark Restoration & Persistence

    /// Creates and persists a security-scoped bookmark for the specified URL.
    @discardableResult
    public func persistBookmark(for url: URL) -> Data? {
        let normalized = canonicalDirectoryURL(for: url)
        guard let bookmarkData = Self.makeBookmarkData(for: url) ?? Self.makeBookmarkData(for: normalized) else {
            return nil
        }
        clearRevokedScopeState(forAuthorizedPath: normalized.path)
        activeBookmarks[normalized] = bookmarkData
        persistedBookmarks[normalized.path] = bookmarkData
        saveBookmarks()
        notifyAutoSemanticRegistration(for: normalized)
        return bookmarkData
    }

    /// Restores saved security-scoped bookmarks without leaking unowned active lease counts.
    /// Unresolved bookmarks (e.g. offline or unmounted volumes) are preserved in storage.
    public func restoreBookmarks() {
        retireAllActiveLeases()
        activeBookmarks.removeAll()
        revokedScopePaths.removeAll()

        guard let data = UserDefaults.standard.data(forKey: bookmarksKey),
              let dict = try? PropertyListDecoder().decode([String: Data].self, from: data) else {
            persistedBookmarks = [:]
            return
        }

        self.persistedBookmarks = dict
        var hasPersistedUpdates = false

        for (savedPath, bookmarkData) in dict {
            guard let (resolvedURL, isStale) = Self.resolveBookmarkData(bookmarkData) else {
                continue
            }

            let normalizedURL = canonicalDirectoryURL(for: resolvedURL)
            if isStale, let freshData = Self.makeBookmarkData(for: resolvedURL) {
                activeBookmarks[normalizedURL] = freshData
                persistedBookmarks[normalizedURL.path] = freshData
                if normalizedURL.path != savedPath {
                    persistedBookmarks.removeValue(forKey: savedPath)
                }
                hasPersistedUpdates = true
            } else {
                activeBookmarks[normalizedURL] = bookmarkData
                if normalizedURL.path != savedPath {
                    persistedBookmarks[normalizedURL.path] = bookmarkData
                    persistedBookmarks.removeValue(forKey: savedPath)
                    hasPersistedUpdates = true
                }
            }
            notifyAutoSemanticRegistration(for: normalizedURL)
        }

        if hasPersistedUpdates {
            saveBookmarks()
        }
    }

    private func saveBookmarks() {
        if let encoded = try? PropertyListEncoder().encode(persistedBookmarks) {
            UserDefaults.standard.set(encoded, forKey: bookmarksKey)
        }
    }

    private func recordActivatedBookmark(
        _ bookmarkData: Data,
        resolvedURL: URL,
        normalizedResolved: URL,
        leaseKey: String,
        originalKey: String,
        isStale: Bool
    ) {
        guard isStale, let freshData = Self.makeBookmarkData(for: resolvedURL) else {
            activeBookmarks[normalizedResolved] = bookmarkData
            return
        }
        activeBookmarks[normalizedResolved] = freshData
        persistedBookmarks[leaseKey] = freshData
        if leaseKey != originalKey {
            persistedBookmarks.removeValue(forKey: originalKey)
        }
        saveBookmarks()
    }

    /// Attempts to activate a persisted bookmark for a target directory or any of its ancestors.
    /// Calls `startAccessingSecurityScopedResource()` on `resolvedURL` directly to preserve its kernel token.
    private func activatePersistedBookmarkIfAvailable(
        for targetURL: URL
    ) -> (leaseKey: String, scopedURL: URL, instanceID: UUID)? {
        let normalized = canonicalDirectoryURL(for: targetURL)
        guard let key = matchingBookmarkKey(forPath: normalized.path),
              let bookmarkData = persistedBookmarks[key],
              let (resolvedURL, isStale) = Self.resolveBookmarkData(bookmarkData) else {
            return nil
        }

        let normalizedResolved = canonicalDirectoryURL(for: resolvedURL)
        let leaseKey = normalizedResolved.path
        recordActivatedBookmark(
            bookmarkData,
            resolvedURL: resolvedURL,
            normalizedResolved: normalizedResolved,
            leaseKey: leaseKey,
            originalKey: key,
            isStale: isStale
        )

        if var existing = leaseEntries[leaseKey], existing.refCount > 0 {
            existing.refCount += 1
            leaseEntries[leaseKey] = existing
            return (leaseKey, existing.scopedResourceURL, existing.instanceID)
        }

        let existingRetiringScopedURL = liveRetiringSecurityScopedURL(forLeaseKey: leaseKey)
        let didStart = existingRetiringScopedURL != nil ? true : startSecurityScopedAccess(resolvedURL)
        let isAccessible = didStart
            || FileManager.default.isReadableFile(atPath: normalized.path)
            || FileManager.default.fileExists(atPath: normalized.path)
            || FileManager.default.isReadableFile(atPath: resolvedURL.path)

        guard isAccessible else {
            if didStart && existingRetiringScopedURL == nil {
                stopSecurityScopedAccess(resolvedURL)
            }
            return nil
        }

        let finalScopedURL = existingRetiringScopedURL ?? resolvedURL
        let instanceID = UUID()
        leaseEntries[leaseKey] = LeaseEntry(
            instanceID: instanceID,
            leaseKey: leaseKey,
            scopedResourceURL: finalScopedURL,
            canonicalURL: normalizedResolved,
            refCount: 1,
            isSecurityScoped: didStart
        )
        return (leaseKey, finalScopedURL, instanceID)
    }

    /// Non-mutating probe checking whether a persisted bookmark grants reachability to `targetURL`.
    private func canAccessViaPersistedBookmark(for targetURL: URL) -> Bool {
        let normalized = canonicalDirectoryURL(for: targetURL)
        guard let key = matchingBookmarkKey(forPath: normalized.path),
              let bookmarkData = persistedBookmarks[key],
              let (resolvedURL, _) = Self.resolveBookmarkData(bookmarkData) else {
            return false
        }

        let normalizedResolved = canonicalDirectoryURL(for: resolvedURL)
        if hasLiveSecurityScopedHolder(forLeaseKey: normalizedResolved.path) {
            return true
        }
        let didStart = startSecurityScopedAccess(resolvedURL)
        defer {
            if didStart {
                stopSecurityScopedAccess(resolvedURL)
            }
        }
        return didStart
            || FileManager.default.isReadableFile(atPath: normalized.path)
            || FileManager.default.fileExists(atPath: normalized.path)
            || FileManager.default.isReadableFile(atPath: resolvedURL.path)
    }

    private func hasVerifiedReachability(for normalizedURL: URL) -> Bool {
        if matchingActiveLeaseKey(forPath: normalizedURL.path) != nil {
            return true
        }
        if canAccessViaPersistedBookmark(for: normalizedURL) {
            return true
        }
        if !isBlockedByRevokedOrRetiringScope(forPath: normalizedURL.path),
           FileManager.default.isReadableFile(atPath: normalizedURL.path) {
            return true
        }
        return false
    }

    // MARK: - Access Verification (Least Privilege Probe)

    /// Verifies read/write reachability to target URL without leaking unowned lease reference counts.
    @discardableResult
    public func ensureAccess(for url: URL, promptIfMissing: Bool = false) -> Bool {
        let normalizedURL = canonicalDirectoryURL(for: url)
        if hasVerifiedReachability(for: normalizedURL) {
            return true
        }
        if promptIfMissing {
            requestRootAccess(for: normalizedURL)
            return false
        }
        return false
    }

    /// Asynchronously verifies reachability to target URL without leaking unowned lease reference counts.
    @discardableResult
    public func ensureAccess(for url: URL, promptIfMissing: Bool = false) async -> Bool {
        let normalizedURL = canonicalDirectoryURL(for: url)
        if hasVerifiedReachability(for: normalizedURL) {
            return true
        }
        if promptIfMissing {
            return await requestRootAccess(for: normalizedURL)
        }
        return false
    }

    /// Prompts user for directory access permission asynchronously using non-blocking NSOpenPanel.
    @discardableResult
    public func requestRootAccess(for rootURL: URL, message: String? = nil) async -> Bool {
        await requestRootAccess(suggestedURL: rootURL, message: message)
    }

    /// Prompts user for directory access permission with a suggested directory URL and custom message.
    @discardableResult
    public func requestRootAccess(suggestedURL: URL, message: String? = nil) async -> Bool {
        let normalizedTarget = canonicalDirectoryURL(for: suggestedURL)
        return await withCheckedContinuation { continuation in
            requestRootAccess(for: normalizedTarget, message: message) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Prompts user for directory access permission targeting only the specific required directory.
    public func requestRootAccess(
        suggestedURL: URL,
        message: String? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        requestRootAccess(for: suggestedURL, message: message, completion: completion)
    }

    /// Prompts user for directory access permission targeting only the specific required directory.
    /// Strictly complies with Apple App Store Review Guideline 2.4.5(i) Least Privilege.
    public func requestRootAccess(
        for rootURL: URL,
        message: String? = nil,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let normalizedTarget = canonicalDirectoryURL(for: rootURL)
        lastRequestedAuthorizationURL = normalizedTarget

        if let handler = authorizationPromptHandler {
            Task { @MainActor in
                if let selectedURL = await handler(normalizedTarget, message) {
                    let ok = self.persistBookmark(for: selectedURL) != nil
                    completion?(ok)
                } else {
                    completion?(false)
                }
            }
            return
        }

        if NSClassFromString("XCTestCase") != nil {
            completion?(false)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = normalizedTarget
        panel.title = "TTZip Directory Authorization"
        panel.prompt = "Authorize Access"
        panel.message = message ?? "Authorize TTZip to access directory (\(normalizedTarget.path)) for seamless navigation."

        panel.begin { [weak self] response in
            guard let self = self else {
                completion?(false)
                return
            }
            if response == .OK, let selectedURL = panel.url, self.persistBookmark(for: selectedURL) != nil {
                completion?(true)
                return
            }
            completion?(false)
        }
    }

    /// Registers and persists an external security-scoped bookmark without adding unowned lease counts.
    public func registerSecurityScopedBookmark(_ data: Data, for path: String) {
        let normalized = canonicalDirectoryURL(for: URL(fileURLWithPath: path))
        clearRevokedScopeState(forAuthorizedPath: normalized.path)
        guard let (resolvedURL, isStale) = Self.resolveBookmarkData(data) else {
            persistedBookmarks[normalized.path] = data
            saveBookmarks()
            return
        }

        let activeURL = canonicalDirectoryURL(for: resolvedURL)
        clearRevokedScopeState(forAuthorizedPath: activeURL.path)
        let finalData: Data
        if isStale, let freshData = Self.makeBookmarkData(for: resolvedURL) {
            finalData = freshData
        } else {
            finalData = data
        }

        activeBookmarks[activeURL] = finalData
        persistedBookmarks[activeURL.path] = finalData
        saveBookmarks()
    }
}
