// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTKitCore
import TTZipCore

/// Discriminated union defining the presentation mode of the right-hand inspector surface,
/// reusing the canonical 4-state `TTKitCore.TTInspectorSurfaceMode`.
public typealias InspectorSurfaceMode = TTInspectorSurfaceMode<FileSystemEntryMetadata, AggregatedSelectionMetrics, String>

extension TTInspectorSurfaceMode where Item == FileSystemEntryMetadata, Metrics == AggregatedSelectionMetrics, Context == String {
    /// Convenience constructor for the storage inspector workspace surface.
    public static var storageInspectorActive: Self {
        .workspace(context: "storage")
    }

    /// Convenience constructor matching `metadata:` parameter label.
    public static func single(metadata: FileSystemEntryMetadata) -> Self {
        .single(item: metadata)
    }
}

/// Normalized file system entry metadata for single-item inspection.
public struct FileSystemEntryMetadata: Equatable, Sendable, Identifiable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let name: String
    public let sizeInBytes: Int64
    public let isDirectory: Bool
    public let modifiedDate: Date
    public let mimeType: String
    public let isArchive: Bool

    public init(
        url: URL,
        name: String,
        sizeInBytes: Int64,
        isDirectory: Bool,
        modifiedDate: Date = Date(),
        mimeType: String = "",
        isArchive: Bool = false
    ) {
        self.url = url
        self.name = name
        self.sizeInBytes = sizeInBytes
        self.isDirectory = isDirectory
        self.modifiedDate = modifiedDate
        self.mimeType = mimeType
        self.isArchive = isArchive
    }

    public init(diskItem: DiskItemInfo) {
        let parsedURL: URL
        if let direct = URL(string: diskItem.path), direct.scheme != nil {
            parsedURL = direct
        } else {
            parsedURL = URL(fileURLWithPath: diskItem.path)
        }
        self.init(
            url: parsedURL,
            name: diskItem.displayName,
            sizeInBytes: diskItem.rawSizeBytes,
            isDirectory: diskItem.isDirectory,
            modifiedDate: diskItem.modificationDate ?? Date(),
            mimeType: diskItem.kindText,
            isArchive: diskItem.isArchive
        )
    }

    public func toDiskItemInfo() -> DiskItemInfo {
        let sizeString = isDirectory ? "Folder" : ByteCountFormatterFlyweight.shared.string(fromByteCount: sizeInBytes)
        if url.isFileURL && !(url.query?.contains("subpath=") ?? false) {
            return DiskItemInfo(
                path: url.path,
                name: url.lastPathComponent.isEmpty ? name : url.lastPathComponent,
                displayName: name,
                isDirectory: isDirectory,
                isArchive: isArchive,
                sizeText: sizeString,
                rawSizeBytes: sizeInBytes,
                kindText: mimeType.isEmpty ? (isDirectory ? "Folder" : "File") : mimeType,
                modificationDate: modifiedDate
            )
        }
        return DiskItemInfo(
            virtualName: name,
            virtualURL: url,
            isDirectory: isDirectory,
            isArchive: isArchive,
            sizeText: sizeString,
            rawSizeBytes: sizeInBytes,
            kindText: mimeType.isEmpty ? (isDirectory ? "Folder" : "File") : mimeType,
            modificationDate: modifiedDate
        )
    }
}

extension DiskItemInfo {
    public init(
        path: String,
        name: String,
        displayName: String,
        isDirectory: Bool,
        isArchive: Bool,
        taxonomy: DocumentEntityTaxonomy? = nil,
        sizeText: String,
        rawSizeBytes: Int64,
        kindText: String,
        modificationDate: Date? = nil,
        creationDate: Date? = nil,
        isEncryptedLockItem: Bool = false
    ) {
        self.init(
            path: path,
            name: name,
            displayName: displayName,
            isDirectory: isDirectory,
            isArchive: isArchive,
            taxonomy: taxonomy,
            sizeText: sizeText,
            rawSizeBytes: rawSizeBytes,
            creationDate: creationDate,
            modificationDate: modificationDate,
            kindText: kindText,
            isEncryptedLockItem: isEncryptedLockItem
        )
    }
}

/// Aggregated metrics across a multi-selection set.
public struct AggregatedSelectionMetrics: Equatable, Sendable {
    public let totalItemCount: Int
    public let totalByteSize: Int64
    public let directoryCount: Int
    public let fileCount: Int
    public let largestItemName: String?
    public let largestItemBytes: Int64
    public let topMimeTypes: [String: Int]

    public init(
        totalItemCount: Int = 0,
        totalByteSize: Int64 = 0,
        directoryCount: Int = 0,
        fileCount: Int = 0,
        largestItemName: String? = nil,
        largestItemBytes: Int64 = 0,
        topMimeTypes: [String: Int] = [:]
    ) {
        self.totalItemCount = totalItemCount
        self.totalByteSize = totalByteSize
        self.directoryCount = directoryCount
        self.fileCount = fileCount
        self.largestItemName = largestItemName
        self.largestItemBytes = largestItemBytes
        self.topMimeTypes = topMimeTypes
    }

    public static func placeholder(count: Int) -> AggregatedSelectionMetrics {
        AggregatedSelectionMetrics(
            totalItemCount: count,
            totalByteSize: 0,
            directoryCount: 0,
            fileCount: count,
            largestItemName: nil,
            largestItemBytes: 0,
            topMimeTypes: [:]
        )
    }
}
