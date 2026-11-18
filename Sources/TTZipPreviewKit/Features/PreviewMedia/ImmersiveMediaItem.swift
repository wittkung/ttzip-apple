// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit

/// Strongly-typed immutable descriptor for an item displayed in the immersive media browser.
/// Carries F4 archive source identity, deterministic cache key, and editability permissions across fullscreen and sibling navigation.
public struct ImmersiveMediaItem: Sendable, Hashable {
    public let url: URL
    public let name: String
    public let fileSizeBytes: Int64?
    public let sourceArchivePath: String?
    public let archiveSubpath: String?
    public let resourceCacheKey: String?
    public let isEditable: Bool
    public let resourceContext: TTPreviewResourceContext?

    /// Indicates whether this item originates from an archive container or ephemeral staging cache.
    public var isFromArchive: Bool {
        PreviewStagingPolicy.isArchiveBacked(
            url,
            context: resourceContext,
            hasArchiveIdentity: sourceArchivePath != nil || archiveSubpath != nil
        )
    }

    /// Canonical F4 `TTPreviewResourceContext` derived from the item's archive or disk origin.
    public var resolvedResourceContext: TTPreviewResourceContext {
        if let resourceContext {
            return PreviewStagingPolicy.restrictDiskWriteBack(resourceContext, archiveBacked: isFromArchive)
        }
        let querySubpath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "subpath" })?
            .value
        if let archPath = sourceArchivePath ?? (querySubpath != nil ? url.path : nil) {
            let entryPath = archiveSubpath ?? querySubpath ?? name
            let stagedURL = (url.isFileURL && querySubpath == nil) ? url : nil
            return .archiveEntry(
                archivePath: archPath,
                entryPath: entryPath,
                stagedReadURL: stagedURL,
                fileName: name
            )
        }
        if isFromArchive {
            return .unknown(readableURL: url, fileName: name)
        }
        if url.isFileURL {
            return .diskFile(url: url, fileName: name, allowsEditing: isEditable)
        }
        return .unknown(readableURL: url, fileName: name)
    }

    public init(
        url: URL,
        name: String,
        fileSizeBytes: Int64? = nil,
        sourceArchivePath: String? = nil,
        archiveSubpath: String? = nil,
        resourceCacheKey: String? = nil,
        isEditable: Bool? = nil,
        resourceContext: TTPreviewResourceContext? = nil
    ) {
        self.url = url
        self.name = name
        self.fileSizeBytes = fileSizeBytes
        let resolvedArchPath = sourceArchivePath ?? resourceContext?.archiveIdentity?.archivePath
        let resolvedSubpath = archiveSubpath ?? resourceContext?.archiveIdentity?.entryPath
        self.sourceArchivePath = resolvedArchPath
        self.archiveSubpath = resolvedSubpath
        self.resourceCacheKey = resourceCacheKey
        self.resourceContext = resourceContext
        self.isEditable = Self.deriveIsEditable(
            url: url,
            name: name,
            hasArchiveOrigin: PreviewStagingPolicy.isArchiveBacked(
                url,
                context: resourceContext,
                hasArchiveIdentity: resolvedArchPath != nil || resolvedSubpath != nil
            ),
            explicitEditable: isEditable,
            resourceContext: resourceContext
        )
    }

    private static func deriveIsEditable(
        url: URL,
        name: String,
        hasArchiveOrigin: Bool,
        explicitEditable: Bool?,
        resourceContext: TTPreviewResourceContext?
    ) -> Bool {
        guard !hasArchiveOrigin else { return false }
        if let context = resourceContext {
            return context.isEditableInPlace
        }
        if let explicit = explicitEditable {
            return explicit
        }
        let nameExt = (name as NSString).pathExtension
        let rawExt = nameExt.isEmpty ? url.pathExtension : nameExt
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: rawExt)
        let canEditFormat = TTMediaCapabilityMatrix.descriptor(for: ext)?.isEditableSource ?? false
        return canEditFormat && FileManager.default.isWritableFile(atPath: url.path)
    }
}
