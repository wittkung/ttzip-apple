// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit
import TTZipCore
import TTZipPreviewKit

/// Explicit lifecycle transition states for the standalone video playback window (Feedback ②).
public enum StandalonePlaybackLifecycleEvent: String, Sendable, Equatable {
    case openedNewWindow
    case focusedExistingWindow
    case replacedMediaInPlace
    case originSelectionChanged
    case originBrowserWindowClosed
    case enteredSystemFullScreen
    case exitedSystemFullScreen
    case returnedToOriginPreview
    case closedStandalonePlayer
    case leaseAcquisitionFailed
    case handoffFailed
}

/// Immutable snapshot of an active standalone video playback session and its origin browser context.
public struct StandalonePlaybackSessionState: Sendable, Equatable {
    public let sessionID: UUID
    public var item: ImmersiveMediaItem
    public let canonicalIdentityKey: String
    public var originBrowserWindowID: UUID?
    public var originSelectedItem: DiskItemInfo?
    public var originDirectoryURL: URL?
    public var originArchivePath: String?
    public var isOriginWindowClosed: Bool
    public var hasOriginSelectionChanged: Bool
    public var isInSystemFullScreen: Bool
    public var focusRequestCount: Int
    public var handoffID: UUID?

    public init(
        sessionID: UUID = UUID(),
        item: ImmersiveMediaItem,
        canonicalIdentityKey: String,
        originBrowserWindowID: UUID?,
        originSelectedItem: DiskItemInfo?,
        originDirectoryURL: URL? = nil,
        originArchivePath: String? = nil,
        isOriginWindowClosed: Bool = false,
        hasOriginSelectionChanged: Bool = false,
        isInSystemFullScreen: Bool = false,
        focusRequestCount: Int = 1,
        handoffID: UUID? = nil
    ) {
        self.sessionID = sessionID
        self.item = item
        self.canonicalIdentityKey = canonicalIdentityKey
        self.originBrowserWindowID = originBrowserWindowID
        self.originSelectedItem = originSelectedItem
        self.originDirectoryURL = originDirectoryURL
        self.originArchivePath = originArchivePath
        self.isOriginWindowClosed = isOriginWindowClosed
        self.hasOriginSelectionChanged = hasOriginSelectionChanged
        self.isInSystemFullScreen = isInSystemFullScreen
        self.focusRequestCount = focusRequestCount
        self.handoffID = handoffID
    }
}

/// Independent per-handoff resource record created when returning playback to the origin preview.
/// Opening a new standalone video never cancels or drops cleanup responsibility for an earlier handoff record.
public struct StandalonePlaybackHandoffRecord {
    public let handoffID: UUID
    public let session: StandalonePlaybackSessionState
    public let mediaURL: URL
    public let cacheLease: PreviewCacheLease?
    public let cacheManager: PreviewLRUCacheManager
    package let ephemeralLeaseBox: TTMediaEphemeralLeaseBox
    package let securityScope: SecurityScopeLease?

    package init(
        handoffID: UUID,
        session: StandalonePlaybackSessionState,
        mediaURL: URL,
        cacheLease: PreviewCacheLease?,
        cacheManager: PreviewLRUCacheManager,
        ephemeralLeaseBox: TTMediaEphemeralLeaseBox,
        securityScope: SecurityScopeLease? = nil
    ) {
        self.handoffID = handoffID
        self.session = session
        self.mediaURL = mediaURL
        self.cacheLease = cacheLease
        self.cacheManager = cacheManager
        self.ephemeralLeaseBox = ephemeralLeaseBox
        self.securityScope = securityScope
    }

    @MainActor
    package func release() async {
        if let lease = cacheLease {
            await cacheManager.releaseLease(lease, reclaimImmediatelyIfIdle: true)
        }
        TTMediaDetector.endFullscreenEphemeralHandoff(for: mediaURL)
        ephemeralLeaseBox.release()
        securityScope?.release()
    }
}

/// Dedicated per-session resource bundle owning its own F4 consumer lease and ephemeral media box.
package struct StandalonePlaybackSessionResources {
    package let sessionID: UUID
    package let consumerID: UUID
    package let canonicalIdentityKey: String
    package let mediaURL: URL
    package let cacheLease: PreviewCacheLease?
    package let cacheManager: PreviewLRUCacheManager
    package let ephemeralLeaseBox: TTMediaEphemeralLeaseBox
    package let securityScope: SecurityScopeLease?

    @MainActor
    package func release() async {
        if let lease = cacheLease {
            await cacheManager.releaseLease(lease, reclaimImmediatelyIfIdle: true)
        }
        TTMediaDetector.endFullscreenEphemeralHandoff(for: mediaURL)
        ephemeralLeaseBox.release()
        securityScope?.release()
    }
}

/// Per-window origin bridge lease record binding `windowID + cacheKey + handoffID`.
package struct OriginWindowRestoredLeaseRecord {
    package let windowID: UUID
    package let handoffID: UUID
    package let selectedPath: String?
    package let lease: PreviewCacheLease
    package let cacheManager: PreviewLRUCacheManager
}

// MARK: - Lease Acquisition Validation Helpers

package struct ValidatedLeaseAcquisition {
    package let succeeded: Bool
    package let lease: PreviewCacheLease?
    package let resolvedURL: URL

    package init(succeeded: Bool, lease: PreviewCacheLease?, resolvedURL: URL) {
        self.succeeded = succeeded
        self.lease = lease
        self.resolvedURL = resolvedURL
    }
}

extension StandalonePlaybackWindowManager {
    package func acquireValidatedCacheLease(
        for item: ImmersiveMediaItem,
        requiredCacheKey: String?,
        consumerID: UUID,
        cacheManager: PreviewLRUCacheManager
    ) async -> ValidatedLeaseAcquisition {
        if let key = requiredCacheKey {
            if let cachedHit = await cacheManager.acquireCachedURL(forKey: key, consumerID: consumerID) {
                return ValidatedLeaseAcquisition(succeeded: true, lease: cachedHit.lease, resolvedURL: cachedHit.url)
            }
            if let urlLease = await cacheManager.acquireIndependentPlayerLease(forFileURL: item.url, consumerID: consumerID) {
                return ValidatedLeaseAcquisition(succeeded: true, lease: urlLease, resolvedURL: item.url)
            }
            return ValidatedLeaseAcquisition(succeeded: false, lease: nil, resolvedURL: item.url)
        }

        let cacheRootPath = cacheManager.getSessionRoot().standardizedFileURL.resolvingSymlinksInPath().path
        let itemPath = item.url.standardizedFileURL.resolvingSymlinksInPath().path
        if itemPath.hasPrefix(cacheRootPath + "/") {
            if let urlLease = await cacheManager.acquireIndependentPlayerLease(forFileURL: item.url, consumerID: consumerID) {
                return ValidatedLeaseAcquisition(succeeded: true, lease: urlLease, resolvedURL: item.url)
            }
            return ValidatedLeaseAcquisition(succeeded: false, lease: nil, resolvedURL: item.url)
        }

        return ValidatedLeaseAcquisition(succeeded: true, lease: nil, resolvedURL: item.url)
    }
}
