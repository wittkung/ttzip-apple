// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import FileProvider
import Foundation
import TTZipCore
import UniformTypeIdentifiers

/// Thread-safe in-memory cache for parsed archive entry hierarchies.
private actor EntryCache {
    private var entries: [ArchiveEntry] = []
    private var isLoaded = false

    func loadEntries(archivePath: String?) async throws -> [ArchiveEntry] {
        if isLoaded {
            return entries
        }
        guard let path = archivePath, FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
        }

        let reader = ArchiveReader()
        let fetched = try await reader.listEntries(archivePath: path)
        self.entries = fetched
        self.isLoaded = true
        return fetched
    }

    func clear() {
        entries.removeAll()
        isLoaded = false
    }
}

/// Sendable wrapper box for cross-boundary Objective-C completion blocks.
private final class UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Thread-safe synchronization holder for bridging synchronous enumerator creation.
private final class SyncResultBox<T: Sendable>: @unchecked Sendable {
    var result: T?
    var error: Error?
}

/// Replicated file provider extension exposing archive contents as a virtual filesystem in macOS Finder.
@objc(TTZipFileProviderExtension)
public final class TTZipFileProviderExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    private let domain: NSFileProviderDomain
    private let archivePath: String?
    private let cache = EntryCache()

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let defaults = UserDefaults(suiteName: "group.com.metastudyline.ttzip")
        self.archivePath = defaults?.string(forKey: "mount_domain_\(domain.identifier.rawValue)")
        super.init()
    }

    public func invalidate() {
        Task {
            await cache.clear()
        }
    }

    // MARK: - Internal Metadata Helpers

    private func makeItem(from entry: ArchiveEntry, domainIdentifier: String) -> FileProviderItem {
        let cleanPath = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = cleanPath.split(separator: "/").map(String.init)
        let filename = segments.last ?? cleanPath

        let parentId: NSFileProviderItemIdentifier
        if segments.count <= 1 {
            parentId = .rootContainer
        } else {
            let parentPath = segments.dropLast().joined(separator: "/")
            parentId = NSFileProviderItemIdentifier(parentPath)
        }

        let contentType: UTType
        if entry.isDirectory {
            contentType = .folder
        } else if let ext = filename.split(separator: ".").last.map(String.init),
                  let inferredType = UTType(filenameExtension: ext) {
            contentType = inferredType
        } else {
            contentType = .data
        }

        return FileProviderItem(
            identifier: NSFileProviderItemIdentifier(cleanPath),
            parentIdentifier: parentId,
            filename: filename,
            contentType: contentType,
            documentSize: entry.isDirectory ? nil : entry.uncompressedSize,
            childItemCount: entry.isDirectory ? 0 : nil,
            modificationDate: entry.modificationDate,
            isDirectory: entry.isDirectory
        )
    }

    // MARK: - NSFileProviderReplicatedExtension Protocol

    public func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        if identifier == .rootContainer {
            completionHandler(FileProviderItem.rootContainerItem(domainIdentifier: domain.identifier.rawValue), nil)
            return progress
        }

        let handlerBox = UncheckedSendableBox(completionHandler)
        Task {
            do {
                let entries = try await self.cache.loadEntries(archivePath: self.archivePath)
                let targetPath = identifier.rawValue
                if let entry = entries.first(where: {
                    $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == targetPath
                }) {
                    let item = self.makeItem(from: entry, domainIdentifier: self.domain.identifier.rawValue)
                    handlerBox.value(item, nil)
                    return
                }

                // Fallback: Synthesize virtual intermediate directory node if subpaths exist
                let hasChildren = entries.contains(where: {
                    let clean = $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return clean.hasPrefix(targetPath + "/")
                })

                if hasChildren {
                    let segments = targetPath.split(separator: "/").map(String.init)
                    let filename = segments.last ?? targetPath
                    let parentId: NSFileProviderItemIdentifier = segments.count <= 1
                        ? .rootContainer
                        : NSFileProviderItemIdentifier(segments.dropLast().joined(separator: "/"))

                    let virtualDir = FileProviderItem(
                        identifier: identifier,
                        parentIdentifier: parentId,
                        filename: filename,
                        contentType: .folder,
                        isDirectory: true
                    )
                    handlerBox.value(virtualDir, nil)
                    return
                }

                handlerBox.value(nil, NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil))
            } catch {
                handlerBox.value(nil, error)
            }
        }

        return progress
    }

    public func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        let box = SyncResultBox<[ArchiveEntry]>()
        let sema = DispatchSemaphore(value: 0)

        Task {
            do {
                box.result = try await self.cache.loadEntries(archivePath: self.archivePath)
            } catch {
                box.error = error
            }
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 5.0)

        if let error = box.error {
            throw error
        }

        let resolvedEntries = box.result ?? []

        let containerPath: String
        if containerItemIdentifier == .rootContainer {
            containerPath = ""
        } else {
            containerPath = containerItemIdentifier.rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        var directChildren: [FileProviderItem] = []
        var seenNames = Set<String>()

        for entry in resolvedEntries {
            let clean = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if containerPath.isEmpty {
                // Top-level children
                let firstSegment = clean.split(separator: "/").first.map(String.init) ?? clean
                if !seenNames.contains(firstSegment) {
                    seenNames.insert(firstSegment)
                    if clean.contains("/") {
                        // Virtual intermediate directory
                        directChildren.append(FileProviderItem(
                            identifier: NSFileProviderItemIdentifier(firstSegment),
                            parentIdentifier: .rootContainer,
                            filename: firstSegment,
                            contentType: .folder,
                            isDirectory: true
                        ))
                    } else {
                        directChildren.append(self.makeItem(from: entry, domainIdentifier: self.domain.identifier.rawValue))
                    }
                }
            } else if clean.hasPrefix(containerPath + "/") {
                let remainder = String(clean.dropFirst(containerPath.count + 1))
                let nextSegment = remainder.split(separator: "/").first.map(String.init) ?? remainder
                let childIdentifierPath = "\(containerPath)/\(nextSegment)"
                if !seenNames.contains(nextSegment) {
                    seenNames.insert(nextSegment)
                    if remainder.contains("/") {
                        // Subdirectory entry
                        directChildren.append(FileProviderItem(
                            identifier: NSFileProviderItemIdentifier(childIdentifierPath),
                            parentIdentifier: containerItemIdentifier,
                            filename: nextSegment,
                            contentType: .folder,
                            isDirectory: true
                        ))
                    } else {
                        directChildren.append(self.makeItem(from: entry, domainIdentifier: self.domain.identifier.rawValue))
                    }
                }
            }
        }

        return FileProviderEnumerator(containerItemIdentifier: containerItemIdentifier, items: directChildren)
    }

    public func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        guard let path = archivePath else {
            completionHandler(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil))
            return progress
        }

        let handlerBox = UncheckedSendableBox(completionHandler)
        Task {
            do {
                let entryPath = itemIdentifier.rawValue
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                let extractor = ArchiveExtractor()
                try await extractor.extractSingleFile(
                    archivePath: path,
                    entryPath: entryPath,
                    destinationDir: tempDir.path
                )

                let candidateDirect = tempDir.appendingPathComponent((entryPath as NSString).lastPathComponent)
                let candidateNested = tempDir.appendingPathComponent(entryPath)
                let targetFileURL: URL
                if FileManager.default.fileExists(atPath: candidateDirect.path) {
                    targetFileURL = candidateDirect
                } else if FileManager.default.fileExists(atPath: candidateNested.path) {
                    targetFileURL = candidateNested
                } else if let firstFound = try? FileManager.default.subpathsOfDirectory(atPath: tempDir.path).first {
                    targetFileURL = tempDir.appendingPathComponent(firstFound)
                } else {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: nil)
                }

                let entries = try await self.cache.loadEntries(archivePath: self.archivePath)
                let matchedEntry = entries.first(where: {
                    $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == entryPath
                })

                let item: FileProviderItem
                if let entry = matchedEntry {
                    item = self.makeItem(from: entry, domainIdentifier: self.domain.identifier.rawValue)
                } else {
                    let filename = (entryPath as NSString).lastPathComponent
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: targetFileURL.path)[.size] as? Int64) ?? 0
                    item = FileProviderItem(
                        identifier: itemIdentifier,
                        parentIdentifier: .rootContainer,
                        filename: filename,
                        contentType: UTType(filenameExtension: (entryPath as NSString).pathExtension) ?? .data,
                        documentSize: fileSize
                    )
                }

                progress.completedUnitCount = 100
                handlerBox.value(targetFileURL, item, nil)
            } catch {
                handlerBox.value(nil, nil, error)
            }
        }

        return progress
    }

    // MARK: - Read-Only Mutation Interception

    public func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let readOnlyError = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
            NSLocalizedDescriptionKey: "Archive filesystem is mounted in read-only mode"
        ])
        completionHandler(nil, [], false, readOnlyError)
        return progress
    }

    public func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let readOnlyError = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
            NSLocalizedDescriptionKey: "Modifications are disabled for read-only archives"
        ])
        completionHandler(nil, [], false, readOnlyError)
        return progress
    }

    public func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let readOnlyError = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [
            NSLocalizedDescriptionKey: "Deletion is prohibited in read-only archive mounts"
        ])
        completionHandler(readOnlyError)
        return progress
    }
}
