// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import Foundation
import TTZipPreviewKit
import TTZipUI

extension RootFolderAccessManager {
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

    internal func saveBookmarks() {
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
    internal func activatePersistedBookmarkIfAvailable(
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
            bookmarkData, resolvedURL: resolvedURL, normalizedResolved: normalizedResolved,
            leaseKey: leaseKey, originalKey: key, isStale: isStale
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
            instanceID: instanceID, leaseKey: leaseKey, scopedResourceURL: finalScopedURL,
            canonicalURL: normalizedResolved, refCount: 1, isSecurityScoped: didStart
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
        if hasVerifiedReachability(for: normalizedURL) { return true }
        if promptIfMissing && !Self.isIsolatedVerificationProcess {
            requestRootAccess(for: normalizedURL)
        }
        return false
    }

    /// Asynchronously verifies reachability to target URL without leaking unowned lease reference counts.
    @discardableResult
    public func ensureAccess(for url: URL, promptIfMissing: Bool = false) async -> Bool {
        let normalizedURL = canonicalDirectoryURL(for: url)
        if hasVerifiedReachability(for: normalizedURL) { return true }
        if promptIfMissing && !Self.isIsolatedVerificationProcess {
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
                    completion?(self.persistBookmark(for: selectedURL) != nil)
                } else {
                    completion?(false)
                }
            }
            return
        }

        if NSClassFromString("XCTestCase") != nil || Self.isIsolatedVerificationProcess {
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
