// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

public enum TTTextPreviewBytePolicy {
    /// Maximum UTF-8 byte budget for interactive text preview and in-place editing (2 MB).
    public nonisolated static let maxInteractiveTextUTF8Bytes: Int = 2 * 1024 * 1024

    /// Initial UTF-8 byte budget mounted synchronously for first-screen rendering (64 KB).
    nonisolated static let initialMountUTF8Bytes: Int = 64 * 1024

    /// Incremental UTF-8 byte budget appended per scroll/search chunk step (128 KB).
    nonisolated static let chunkStepUTF8Bytes: Int = 128 * 1024

    /// Safely truncates text to at most `maxUTF8Bytes` at a valid Unicode scalar boundary.
    public nonisolated static func truncateForPreview(
        _ text: String,
        maxUTF8Bytes: Int = maxInteractiveTextUTF8Bytes
    ) -> (displayText: String, isTruncated: Bool) {
        let result = TTSpreadsheetParser.truncateUTF8Prefix(text, maxBytes: maxUTF8Bytes)
        return (displayText: result.text, isTruncated: result.isTruncated)
    }
}
