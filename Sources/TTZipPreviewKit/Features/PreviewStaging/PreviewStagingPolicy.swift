// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit

enum PreviewStagingPolicy {
    // Standardization can remove a staging directory from a path containing "..".
    private static let rawPathMarkers = [
        "TTZipLRUPreviewCache", "TTMediaEphemeralStorage", "TTZipPreviewCache",
        "TTZipArchiveMediaCache", ".ttzip-staging-", "ttzip_vfs_"
    ]

    static func hasStagingURL(_ url: URL?, context: TTPreviewResourceContext? = nil) -> Bool {
        isStagingURL(url) || isStagingURL(context?.readableURL)
    }

    static func isArchiveBacked(
        _ url: URL?,
        context: TTPreviewResourceContext?,
        hasArchiveIdentity: Bool
    ) -> Bool {
        if hasArchiveIdentity || context?.isArchiveEntry == true {
            return true
        }
        if let url, !url.isFileURL {
            return true
        }
        return hasStagingURL(url, context: context)
    }

    static func restrictDiskWriteBack(
        _ context: TTPreviewResourceContext,
        archiveBacked: Bool
    ) -> TTPreviewResourceContext {
        guard archiveBacked, case .diskFile = context.origin else { return context }
        return context.forcingReadOnly()
    }

    private static func isStagingURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if TTPreviewResourceContext.isManagedPreviewStagingURL(url) || url.scheme?.lowercased() == "ttzip" {
            return true
        }
        return rawPathMarkers.contains { url.path.contains($0) }
    }
}
