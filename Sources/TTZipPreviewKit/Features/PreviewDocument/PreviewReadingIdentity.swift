// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit

/// Identifies the source, never a disposable extracted EPUB path.
public enum PreviewReadingIdentity {
    public static func resolve(context: TTPreviewResourceContext, fallbackURL: URL?) -> String? {
        if let archive = context.archiveIdentity {
            return fingerprint(archive.archiveURL).map { "archive-reader-v1#\($0)#\(archive.entryPath)" }
        }
        switch context.origin {
        case .diskFile(let url): return fingerprint(url).map { "file-reader-v1#\($0)" }
        default: return fallbackURL.flatMap(fingerprint).map { "file-reader-v1#\($0)" }
        }
    }

    private static func fingerprint(_ url: URL) -> String? {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !path.contains("TTZipLRUPreviewCache"),
              !path.contains("TTMediaEphemeralStorage") else { return nil }
        return PlaybackExperienceStore.fileVersionIdentity(for: url)
    }
}
