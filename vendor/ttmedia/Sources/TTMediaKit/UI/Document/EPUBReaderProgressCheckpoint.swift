// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

/// Per-view acknowledgement of the last restored or successfully saved position.
/// The Rust library remains authoritative; this only suppresses unchanged lifecycle writes.
public struct EPUBReaderProgressCheckpoint: Sendable {
    private var identity: String?
    private var anchor: EPUBReaderAnchor?

    public init() {}

    public mutating func restore(identity: String, anchor: EPUBReaderAnchor) {
        self.identity = identity
        self.anchor = anchor
    }

    @discardableResult
    public mutating func saveIfChanged(
        identity: String,
        anchor: EPUBReaderAnchor,
        using save: (String, EPUBReaderAnchor) throws -> Void
    ) throws -> Bool {
        guard self.identity != identity || self.anchor != anchor else { return false }
        try save(identity, anchor)
        restore(identity: identity, anchor: anchor)
        return true
    }
}
