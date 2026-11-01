// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

/// Captured identities from existing owners; this does not introduce another request epoch.
package struct ArchiveEntryPreviewRequest: Sendable, Equatable {
    package let windowID: UUID
    package let sessionID: UUID
    package let operationEpoch: UInt64
    package let location: URL
    /// The selected entry's read address; a browsing URL may use another local path spelling.
    package let archivePath: String
    package let itemPath: String
    package let entryPath: String
    package let selectedEntryID: String?

    package init(
        windowID: UUID, sessionID: UUID, operationEpoch: UInt64, location: URL,
        archivePath: String, itemPath: String, entryPath: String, selectedEntryID: String?
    ) {
        self.windowID = windowID
        self.sessionID = sessionID
        self.operationEpoch = operationEpoch
        self.location = location
        self.archivePath = archivePath
        self.itemPath = itemPath
        self.entryPath = entryPath
        self.selectedEntryID = selectedEntryID
    }
}

/// Preserves the reader's typed password evidence without treating arbitrary errors as passwords.
package enum ArchiveEntryPreviewFailure: Sendable, Equatable {
    case archive(ArchiveError, attemptedPassword: String?)
    case other(String)
    case cancelled

    package static func captured(_ error: Error, attemptedPassword: String? = nil) -> Self {
        if Task.isCancelled || error is CancellationError { return .cancelled }
        if let archiveError = error as? ArchiveError {
            if archiveError == .cancelled || archiveError == .extractionStopped { return .cancelled }
            return .archive(archiveError, attemptedPassword: attemptedPassword)
        }
        return .other(error.localizedDescription)
    }

    package var isPasswordRelated: Bool {
        if case .archive(let error, _) = self { return error.isPasswordRelated }
        return false
    }

    package var message: String {
        switch self {
        case .archive(let error, _): return error.errorDescription ?? String(describing: error)
        case .other(let message): return message
        case .cancelled: return ""
        }
    }
}
