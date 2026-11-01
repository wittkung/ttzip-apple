// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipPreviewKit

extension ExplorerItemInspectorView {
    public typealias VirtualEntryExtractor = AppViewState.VirtualEntryExtractor
    public typealias VirtualPreviewResolution = AppViewState.VirtualPreviewResolution

    /// Resolves, quota-reserves, extracts, validates, and acquires a per-consumer `PreviewCacheLease` in `PreviewLRUCacheManager`.
    /// Releases `previousLease` (or `previousPinnedKey`) first so switching inspector items drops only that consumer's prior hold.
    package static func resolveAndPinVirtualPreviewURL(
        archivePath: String,
        subpath: String,
        estimatedBytes: Int64 = 0,
        consumerID: UUID = UUID(),
        previousLease: PreviewCacheLease? = nil,
        previousPinnedKey: String? = nil,
        cacheManager: PreviewLRUCacheManager = .shared,
        passwordRequiredWithoutCache: Bool = false,
        customExtractor: VirtualEntryExtractor? = nil
    ) async -> VirtualPreviewResolution {
        await AppViewState.resolveAndPinVirtualPreviewURL(
            archivePath: archivePath,
            subpath: subpath,
            estimatedBytes: estimatedBytes,
            consumerID: consumerID,
            previousLease: previousLease,
            previousPinnedKey: previousPinnedKey,
            cacheManager: cacheManager,
            passwordRequiredWithoutCache: passwordRequiredWithoutCache,
            customExtractor: customExtractor
        )
    }

    /// Resolves and validates a virtual archive item's cached/extracted preview URL.
    /// Returns a URL only when it passes cache boundary, non-symlink, regular-file, quota, and entry-name verification.
    package static func resolveVirtualPreviewURL(
        archivePath: String,
        subpath: String,
        estimatedBytes: Int64 = 0,
        cacheManager: PreviewLRUCacheManager = .shared
    ) async -> URL? {
        let result = await resolveAndPinVirtualPreviewURL(
            archivePath: archivePath,
            subpath: subpath,
            estimatedBytes: estimatedBytes,
            previousLease: nil,
            cacheManager: cacheManager
        )
        if let lease = result.lease {
            await cacheManager.releaseLease(lease)
        }
        return result.url
    }
}
