// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import FileProvider
import Foundation
import UniformTypeIdentifiers

/// Represents a read-only virtual item exposed to the macOS FileProvider subsystem.
public final class FileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    public let itemIdentifier: NSFileProviderItemIdentifier
    public let parentItemIdentifier: NSFileProviderItemIdentifier
    public let filename: String
    public let contentType: UTType
    public let documentSize: NSNumber?
    public let childItemCount: NSNumber?
    public let creationDate: Date?
    public let contentModificationDate: Date?
    public let isDirectory: Bool

    public init(
        identifier: NSFileProviderItemIdentifier,
        parentIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        contentType: UTType,
        documentSize: Int64? = nil,
        childItemCount: Int? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        isDirectory: Bool = false
    ) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parentIdentifier
        self.filename = filename
        self.contentType = contentType
        self.documentSize = documentSize.map { NSNumber(value: $0) }
        self.childItemCount = childItemCount.map { NSNumber(value: $0) }
        self.creationDate = creationDate
        self.contentModificationDate = modificationDate ?? Date()
        self.isDirectory = isDirectory
        super.init()
    }

    /// Factory method for domain root container.
    public static func rootContainerItem(domainIdentifier: String) -> FileProviderItem {
        FileProviderItem(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: domainIdentifier,
            contentType: .folder,
            isDirectory: true
        )
    }

    // MARK: - NSFileProviderItem Protocol Properties

    public var capabilities: NSFileProviderItemCapabilities {
        if isDirectory {
            return [.allowsReading, .allowsContentEnumerating]
        }
        return [.allowsReading]
    }

    public var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: "1.0".data(using: .utf8)!, metadataVersion: "1.0".data(using: .utf8)!)
    }
}
