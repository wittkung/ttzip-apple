// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit
import TTZipAppCore

/// The host associates temporary playback URLs with original archive sources before creating players.
@MainActor
public enum PreviewPlaybackPersistence {
    private static var contexts: [URL: TTPreviewResourceContext] = [:]
    private static var insertionOrder: [URL] = []

    public static func install() {
        PlaybackExperiencePolicy.resumePosition = { position, duration in
            mediaResumePosition(position: position, duration: duration)
        }
        PlaybackExperiencePolicy.resourceIdentity = { url in
            guard let context = contexts[url.standardizedFileURL], context.archiveIdentity != nil else { return nil }
            return PreviewReadingIdentity.resolve(context: context, fallbackURL: nil)
        }
    }

    public static func prepare(url: URL?, context: TTPreviewResourceContext) {
        guard let url, context.archiveIdentity != nil else { return }
        let key = url.standardizedFileURL
        if contexts[key] == nil { insertionOrder.append(key) }
        contexts[key] = context
        while insertionOrder.count > 500 {
            contexts.removeValue(forKey: insertionOrder.removeFirst())
        }
    }
}
