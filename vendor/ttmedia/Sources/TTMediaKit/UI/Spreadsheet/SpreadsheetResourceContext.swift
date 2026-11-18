// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

// MARK: - F4 Resource Context & Edit Capability Bridge for SpreadsheetSavePolicy

public extension TTPreviewReadOnlyReason {
    nonisolated static var derivedRepresentation: TTPreviewReadOnlyReason { .derivedContent }
    nonisolated static var previewTruncated: TTPreviewReadOnlyReason { .truncatedPreview }
    nonisolated static var missingFileURL: TTPreviewReadOnlyReason { .unknownOrigin }
    nonisolated static var ephemeralStagingPath: TTPreviewReadOnlyReason { .managedStagingCachePath }
    nonisolated static var unsupportedExtension: TTPreviewReadOnlyReason { .unsupportedInPlaceFormat }
    nonisolated static var fileSystemReadOnly: TTPreviewReadOnlyReason { .unwritableDiskFile }
}

public extension TTPreviewEditCapability {
    nonisolated static func readOnly(_ reason: TTPreviewReadOnlyReason) -> TTPreviewEditCapability {
        .readOnly(reason: reason)
    }

    nonisolated static func editableInPlace(targetURL: URL) -> TTPreviewEditCapability {
        .editableInPlace(targetFileURL: targetURL)
    }

    nonisolated var isEditableInPlace: Bool {
        if case .editableInPlace = self {
            return true
        }
        return false
    }

    nonisolated var writableTargetURL: URL? {
        if case .editableInPlace(let targetFileURL) = self {
            return targetFileURL
        }
        return nil
    }
}

public extension TTPreviewResourceContext {
    nonisolated func effectiveEditCapability(
        isTruncated: Bool = false,
        isDerived: Bool = false,
        allowedExtensions: Set<String>? = nil
    ) -> TTPreviewEditCapability {
        if isPreviewTruncated || isTruncated {
            return .readOnly(reason: .truncatedPreview)
        }
        if isDerivedRepresentation || isDerived {
            return .readOnly(reason: .derivedContent)
        }
        if let targetURL = validateInPlaceSaveTarget(
            allowedExtensions: allowedExtensions,
            isTruncated: isTruncated,
            isDerived: isDerived
        ) {
            return .editableInPlace(targetFileURL: targetURL)
        }
        if case .editableInPlace = editCapability, allowedExtensions != nil {
            return .readOnly(reason: .unsupportedInPlaceFormat)
        }
        return editCapability
    }
}
