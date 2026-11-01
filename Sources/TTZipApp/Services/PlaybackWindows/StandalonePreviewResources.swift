// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit
import TTZipPreviewKit

/// Acquire-before-release resource ownership for exactly one standalone preview.
@MainActor
final class StandalonePreviewResources {
    let cacheLease: PreviewCacheLease?
    var sourceScopeLeaseKey: String? { sourceSecurityScope?.leaseKey }
    var readableScopeLeaseKey: String { securityScope.leaseKey }
    private let cacheManager: PreviewLRUCacheManager
    private let securityScope: SecurityScopeLease
    private let sourceSecurityScope: SecurityScopeLease?
    private let ephemeralBox: TTMediaEphemeralLeaseBox
    private var released = false

    private init(cacheLease: PreviewCacheLease?, cacheManager: PreviewLRUCacheManager,
                 securityScope: SecurityScopeLease, sourceSecurityScope: SecurityScopeLease?,
                 ephemeralBox: TTMediaEphemeralLeaseBox) {
        self.cacheLease = cacheLease
        self.cacheManager = cacheManager
        self.securityScope = securityScope
        self.sourceSecurityScope = sourceSecurityScope
        self.ephemeralBox = ephemeralBox
    }

    static func acquire(for item: ImmersiveMediaItem, cacheManager: PreviewLRUCacheManager) async -> (item: ImmersiveMediaItem, resources: StandalonePreviewResources)? {
        let box = TTMediaEphemeralLeaseBox()
        TTMediaDetector.beginFullscreenEphemeralHandoff(for: item.url)
        defer { TTMediaDetector.endFullscreenEphemeralHandoff(for: item.url) }
        guard bindIndependentEphemeral(item.url, to: box) else { return nil }
        let sourceScope = acquireReadableArchiveScope(for: item)
        var sourceScopeTransferred = false
        defer { if !sourceScopeTransferred { sourceScope?.release() } }
        let consumerID = UUID()
        let acquisition = await validatedURL(for: item, consumerID: consumerID, cacheManager: cacheManager)
        guard let acquisition else { box.release(); return nil }
        guard bindIndependentEphemeral(acquisition.url, to: box) else {
            await releaseFailedAcquisition(acquisition.lease, cacheManager: cacheManager, box: box)
            return nil
        }
        guard acquisition.url.isFileURL,
              let scope = RootFolderAccessManager.shared.acquireLease(for: acquisition.url) else {
            await releaseFailedAcquisition(acquisition.lease, cacheManager: cacheManager, box: box)
            return nil
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: acquisition.url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: acquisition.url.path) else {
            scope.release()
            await releaseFailedAcquisition(acquisition.lease, cacheManager: cacheManager, box: box)
            return nil
        }
        let resolvedItem = ImmersiveMediaItem(
            url: acquisition.url, name: item.name, fileSizeBytes: item.fileSizeBytes,
            sourceArchivePath: item.sourceArchivePath, archiveSubpath: item.archiveSubpath,
            resourceCacheKey: item.resourceCacheKey, isEditable: false,
            resourceContext: item.resolvedResourceContext.withReadableURL(acquisition.url).forcingReadOnly()
        )
        let resources = StandalonePreviewResources(
            cacheLease: acquisition.lease, cacheManager: cacheManager, securityScope: scope,
            sourceSecurityScope: sourceScope, ephemeralBox: box
        )
        sourceScopeTransferred = true
        return (resolvedItem, resources)
    }

    private static func acquireReadableArchiveScope(for item: ImmersiveMediaItem) -> SecurityScopeLease? {
        guard let archiveURL = item.resolvedResourceContext.archiveIdentity?.archiveURL,
              archiveURL.isFileURL,
              let scope = RootFolderAccessManager.shared.acquireLease(for: archiveURL) else { return nil }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: archiveURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: archiveURL.path) else {
            scope.release()
            return nil
        }
        return scope
    }

    private static func bindIndependentEphemeral(_ url: URL, to box: TTMediaEphemeralLeaseBox) -> Bool {
        guard TTMediaDetector.isEphemeralMediaFile(url) else {
            box.bind(url: url)
            return true
        }
        if box.boundURL?.standardizedFileURL == url.standardizedFileURL { return true }
        // bind() adopts an unclaimed lease. Create our own hold before that adoption,
        // preserving even a source consumer that has not claimed its detection lease yet.
        guard TTMediaDetector.retainEphemeralMediaFile(at: url) else { return false }
        guard TTMediaDetector.acquireConsumerEphemeralLease(for: url, consumerID: box.consumerID) else {
            TTMediaDetector.releaseEphemeralMediaFile(at: url)
            return false
        }
        box.bind(url: url)
        return true
    }

    private static func validatedURL(for item: ImmersiveMediaItem, consumerID: UUID,
                                     cacheManager: PreviewLRUCacheManager) async -> (url: URL, lease: PreviewCacheLease?)? {
        if let key = StandalonePlaybackWindowManager.resolvedCacheKey(for: item) {
            guard let hit = await cacheManager.acquireCachedURL(forKey: key, consumerID: consumerID) else { return nil }
            return (hit.url, hit.lease)
        }
        let root = cacheManager.getSessionRoot().standardizedFileURL.resolvingSymlinksInPath().path
        if item.url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root + "/") {
            let candidateKey = item.url.deletingLastPathComponent().lastPathComponent
            guard let hit = await cacheManager.acquireCachedURL(
                forKey: candidateKey, expectedFilename: item.url.lastPathComponent, consumerID: consumerID
            ) else { return nil }
            guard hit.url.standardizedFileURL.resolvingSymlinksInPath() == item.url.standardizedFileURL.resolvingSymlinksInPath() else {
                await cacheManager.releaseLease(hit.lease)
                return nil
            }
            return (hit.url, hit.lease)
        }
        return (item.url, nil)
    }

    private static func releaseFailedAcquisition(_ lease: PreviewCacheLease?, cacheManager: PreviewLRUCacheManager,
                                                  box: TTMediaEphemeralLeaseBox) async {
        if let lease { await cacheManager.releaseLease(lease, reclaimImmediatelyIfIdle: true) }
        box.release()
    }

    func release() async {
        guard !released else { return }
        released = true
        if let cacheLease { await cacheManager.releaseLease(cacheLease, reclaimImmediatelyIfIdle: true) }
        securityScope.release()
        sourceSecurityScope?.release()
        ephemeralBox.release()
    }
    deinit {
        securityScope.release()
        sourceSecurityScope?.release()
        ephemeralBox.release()
        if !released, let cacheLease {
            let manager = cacheManager
            Task { await manager.releaseLease(cacheLease, reclaimImmediatelyIfIdle: true) }
        }
    }

}
