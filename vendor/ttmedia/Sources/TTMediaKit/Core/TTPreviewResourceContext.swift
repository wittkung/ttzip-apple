// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI

/// Identity of an entry inside an archive container.
public struct TTPreviewArchiveEntryIdentity: Sendable, Equatable, Hashable, Codable {
    public let archiveURL: URL
    public let entryPath: String

    nonisolated public var archivePath: String {
        archiveURL.path
    }

    nonisolated public init(archiveURL: URL, entryPath: String) {
        self.archiveURL = archiveURL.standardizedFileURL
        self.entryPath = entryPath
    }

    nonisolated public init(archivePath: String, entryPath: String) {
        self.archiveURL = URL(fileURLWithPath: archivePath).standardizedFileURL
        self.entryPath = entryPath
    }
}

/// Authoritative origin of a previewed resource.
public enum TTPreviewResourceOrigin: Sendable, Equatable, Hashable, Codable {
    /// A standalone file on disk authorized for preview (and in-place editing if policy permits).
    case diskFile(url: URL)
    /// An entry extracted or streamed from an archive container. Never editable in place.
    case archiveEntry(identity: TTPreviewArchiveEntryIdentity, stagedReadURL: URL?)
    /// A derived/transcoded representation (e.g., XLSX workbook, DOCX conversion). Never editable in place.
    case derivedContent(sourceURL: URL?, description: String)
    /// Pure in-memory data without a backing disk file. Never editable in place.
    case inMemory(suggestedName: String)
    /// Unspecified origin. Fail-closed: never automatically grants in-place overwrite permission.
    case unknown(readableURL: URL?)
}

/// Machine-readable reason why a previewed resource is read-only.
public enum TTPreviewReadOnlyReason: String, Sendable, Equatable, Hashable, Codable {
    case archiveEntry
    case derivedContent
    case truncatedPreview
    case inMemoryBuffer
    case unknownOrigin
    case explicitReadOnlyPolicy
    case managedStagingCachePath
    case unwritableDiskFile
    case unsupportedInPlaceFormat
}

/// Evaluated editing capability for a preview session.
public enum TTPreviewEditCapability: Sendable, Equatable, Hashable {
    case readOnly(reason: TTPreviewReadOnlyReason)
    case editableInPlace(targetFileURL: URL)
}

/// Canonical preview resource context carrying origin identity, readable URL, edit permissions, and validated save target.
public struct TTPreviewResourceContext: Sendable, Equatable, Hashable, Codable {
    nonisolated public static let notificationUserInfoKey = "TTPreviewResourceContext"

    private static let managedStagingPathMarkers: [String] = [
        "TTZipLRUPreviewCache",
        "TTMediaEphemeralStorage",
        "TTZipPreviewCache",
        "TTZipArchiveMediaCache",
        "ttzip_previews_",
        "TTZip_QuickLook_",
        "TTZip_Extract_",
        ".ttzip-staging-"
    ]

    public let origin: TTPreviewResourceOrigin
    public let displayFileName: String
    public let allowsEditingWhenAuthorized: Bool
    public let isPreviewTruncated: Bool
    public let isDerivedRepresentation: Bool

    nonisolated public init(
        origin: TTPreviewResourceOrigin,
        displayFileName: String = "",
        allowsEditingWhenAuthorized: Bool = true,
        isPreviewTruncated: Bool = false,
        isDerivedRepresentation: Bool = false
    ) {
        self.origin = origin
        self.displayFileName = displayFileName
        self.allowsEditingWhenAuthorized = allowsEditingWhenAuthorized
        self.isPreviewTruncated = isPreviewTruncated
        self.isDerivedRepresentation = isDerivedRepresentation
    }

    // MARK: - Factory Constructors

    nonisolated public static func diskFile(
        url: URL,
        fileName: String? = nil,
        allowsEditing: Bool = true,
        isTruncated: Bool = false
    ) -> TTPreviewResourceContext {
        let standardized = url.standardizedFileURL
        return TTPreviewResourceContext(
            origin: .diskFile(url: standardized),
            displayFileName: fileName ?? standardized.lastPathComponent,
            allowsEditingWhenAuthorized: allowsEditing,
            isPreviewTruncated: isTruncated,
            isDerivedRepresentation: false
        )
    }

    nonisolated public static func archiveEntry(
        archiveURL: URL,
        entryPath: String,
        stagedReadURL: URL?,
        fileName: String? = nil
    ) -> TTPreviewResourceContext {
        let identity = TTPreviewArchiveEntryIdentity(archiveURL: archiveURL, entryPath: entryPath)
        let resolvedName = fileName ?? (entryPath as NSString).lastPathComponent
        return TTPreviewResourceContext(
            origin: .archiveEntry(identity: identity, stagedReadURL: stagedReadURL?.standardizedFileURL),
            displayFileName: resolvedName,
            allowsEditingWhenAuthorized: false,
            isPreviewTruncated: false,
            isDerivedRepresentation: false
        )
    }

    nonisolated public static func archiveEntry(
        archivePath: String,
        entryPath: String,
        stagedReadURL: URL?,
        fileName: String? = nil
    ) -> TTPreviewResourceContext {
        archiveEntry(
            archiveURL: URL(fileURLWithPath: archivePath),
            entryPath: entryPath,
            stagedReadURL: stagedReadURL,
            fileName: fileName
        )
    }

    nonisolated public static func derived(
        sourceURL: URL? = nil,
        fileName: String = "",
        description: String = "DerivedContent"
    ) -> TTPreviewResourceContext {
        let resolvedName = fileName.isEmpty ? (sourceURL?.lastPathComponent ?? description) : fileName
        return TTPreviewResourceContext(
            origin: .derivedContent(sourceURL: sourceURL?.standardizedFileURL, description: description),
            displayFileName: resolvedName,
            allowsEditingWhenAuthorized: false,
            isPreviewTruncated: false,
            isDerivedRepresentation: true
        )
    }

    nonisolated public static func derivedContent(
        sourceURL: URL? = nil,
        fileName: String = "",
        description: String = "DerivedContent"
    ) -> TTPreviewResourceContext {
        derived(sourceURL: sourceURL, fileName: fileName, description: description)
    }

    nonisolated public static func inMemory(fileName: String) -> TTPreviewResourceContext {
        TTPreviewResourceContext(
            origin: .inMemory(suggestedName: fileName),
            displayFileName: fileName,
            allowsEditingWhenAuthorized: false,
            isPreviewTruncated: false,
            isDerivedRepresentation: false
        )
    }

    nonisolated public static func unknown(
        readableURL: URL? = nil,
        fileName: String = ""
    ) -> TTPreviewResourceContext {
        let resolvedName = fileName.isEmpty ? (readableURL?.lastPathComponent ?? "") : fileName
        return TTPreviewResourceContext(
            origin: .unknown(readableURL: readableURL?.standardizedFileURL),
            displayFileName: resolvedName,
            allowsEditingWhenAuthorized: false,
            isPreviewTruncated: false,
            isDerivedRepresentation: false
        )
    }

    // MARK: - Derived State Modifiers

    nonisolated public func withReadableURL(_ newReadableURL: URL?) -> TTPreviewResourceContext {
        let stdURL = newReadableURL?.standardizedFileURL
        let updatedOrigin: TTPreviewResourceOrigin
        switch origin {
        case .diskFile(let url):
            updatedOrigin = .diskFile(url: stdURL ?? url)
        case .archiveEntry(let identity, _):
            updatedOrigin = .archiveEntry(identity: identity, stagedReadURL: stdURL)
        case .derivedContent(_, let desc):
            updatedOrigin = .derivedContent(sourceURL: stdURL, description: desc)
        case .inMemory(let name):
            updatedOrigin = .inMemory(suggestedName: name)
        case .unknown:
            updatedOrigin = .unknown(readableURL: stdURL)
        }
        return TTPreviewResourceContext(
            origin: updatedOrigin,
            displayFileName: displayFileName,
            allowsEditingWhenAuthorized: allowsEditingWhenAuthorized,
            isPreviewTruncated: isPreviewTruncated,
            isDerivedRepresentation: isDerivedRepresentation
        )
    }

    nonisolated public func withTruncatedPreview(_ truncated: Bool = true) -> TTPreviewResourceContext {
        TTPreviewResourceContext(
            origin: origin,
            displayFileName: displayFileName,
            allowsEditingWhenAuthorized: allowsEditingWhenAuthorized,
            isPreviewTruncated: truncated,
            isDerivedRepresentation: isDerivedRepresentation
        )
    }

    nonisolated public func withDerivedRepresentation(
        _ derived: Bool = true,
        description: String = "DerivedContent"
    ) -> TTPreviewResourceContext {
        let updatedOrigin: TTPreviewResourceOrigin
        if derived {
            if case .archiveEntry = origin {
                updatedOrigin = origin
            } else {
                updatedOrigin = .derivedContent(sourceURL: readableURL, description: description)
            }
        } else {
            updatedOrigin = origin
        }
        return TTPreviewResourceContext(
            origin: updatedOrigin,
            displayFileName: displayFileName,
            allowsEditingWhenAuthorized: derived ? false : allowsEditingWhenAuthorized,
            isPreviewTruncated: isPreviewTruncated,
            isDerivedRepresentation: derived
        )
    }

    nonisolated public func forcingReadOnly() -> TTPreviewResourceContext {
        TTPreviewResourceContext(
            origin: origin,
            displayFileName: displayFileName,
            allowsEditingWhenAuthorized: false,
            isPreviewTruncated: isPreviewTruncated,
            isDerivedRepresentation: isDerivedRepresentation
        )
    }

    // MARK: - Resolved URLs & Permissions

    nonisolated public var readableURL: URL? {
        switch origin {
        case .diskFile(let url):
            return url
        case .archiveEntry(_, let stagedReadURL):
            return stagedReadURL
        case .derivedContent(let sourceURL, _):
            return sourceURL
        case .inMemory:
            return nil
        case .unknown(let readableURL):
            return readableURL
        }
    }

    nonisolated public var originalDiskURL: URL? {
        if case .diskFile(let url) = origin {
            return url.standardizedFileURL
        }
        return nil
    }

    nonisolated public var originalResourceURL: URL? {
        originalDiskURL ?? readableURL
    }

    nonisolated public var archiveEntryIdentity: TTPreviewArchiveEntryIdentity? {
        if case .archiveEntry(let identity, _) = origin {
            return identity
        }
        return nil
    }

    nonisolated public var archiveIdentity: TTPreviewArchiveEntryIdentity? {
        archiveEntryIdentity
    }

    nonisolated public var archiveContainerURL: URL? {
        archiveEntryIdentity?.archiveURL
    }

    nonisolated public var archiveEntryPath: String? {
        archiveEntryIdentity?.entryPath
    }

    nonisolated public var isArchiveEntry: Bool {
        archiveEntryIdentity != nil
    }

    nonisolated public var editCapability: TTPreviewEditCapability {
        evaluateEditCapability(isTruncatedOverride: false, isDerivedOverride: false)
    }

    nonisolated public var isEditableInPlace: Bool {
        if case .editableInPlace = editCapability {
            return true
        }
        return false
    }

    nonisolated public var readOnlyReason: TTPreviewReadOnlyReason? {
        if case .readOnly(let reason) = editCapability {
            return reason
        }
        return nil
    }

    nonisolated public var writableSaveTargetURL: URL? {
        if case .editableInPlace(let targetURL) = editCapability {
            return targetURL
        }
        return nil
    }

    // MARK: - Save-Entry Re-Validation Gate

    nonisolated public func validateInPlaceSaveTarget(
        expectedFileURL: URL? = nil,
        fileName: String = "",
        allowedExtensions: Set<String>? = nil,
        isTruncated: Bool = false,
        isDerived: Bool = false
    ) -> URL? {
        let capability = evaluateEditCapability(
            isTruncatedOverride: isTruncated,
            isDerivedOverride: isDerived
        )
        guard case .editableInPlace(let targetURL) = capability else {
            return nil
        }
        if let expectedFileURL {
            guard expectedFileURL.standardizedFileURL == targetURL.standardizedFileURL else {
                return nil
            }
        }
        if let allowedExtensions {
            guard Self.matchesAllowedExtensions(
                targetURL: targetURL,
                fileName: fileName.isEmpty ? displayFileName : fileName,
                allowedExtensions: allowedExtensions
            ) else {
                return nil
            }
        }
        return targetURL
    }

    nonisolated private func evaluateEditCapability(
        isTruncatedOverride: Bool,
        isDerivedOverride: Bool
    ) -> TTPreviewEditCapability {
        if isPreviewTruncated || isTruncatedOverride {
            return .readOnly(reason: .truncatedPreview)
        }
        if isDerivedRepresentation || isDerivedOverride {
            return .readOnly(reason: .derivedContent)
        }
        switch origin {
        case .archiveEntry:
            return .readOnly(reason: .archiveEntry)
        case .derivedContent:
            return .readOnly(reason: .derivedContent)
        case .inMemory:
            return .readOnly(reason: .inMemoryBuffer)
        case .unknown:
            return .readOnly(reason: .unknownOrigin)
        case .diskFile(let url):
            return evaluateDiskFileCapability(url: url)
        }
    }

    nonisolated private func evaluateDiskFileCapability(url: URL) -> TTPreviewEditCapability {
        guard allowsEditingWhenAuthorized else {
            return .readOnly(reason: .explicitReadOnlyPolicy)
        }
        guard url.isFileURL else {
            return .readOnly(reason: .unwritableDiskFile)
        }
        guard !Self.isManagedPreviewStagingURL(url) else {
            return .readOnly(reason: .managedStagingCachePath)
        }
        let standardized = url.standardizedFileURL
        guard FileManager.default.isWritableFile(atPath: standardized.path) else {
            return .readOnly(reason: .unwritableDiskFile)
        }
        return .editableInPlace(targetFileURL: standardized)
    }

    /// Detects whether `url` points inside a managed preview staging/cache directory or virtual subpath query.
    /// Does NOT classify general `/tmp` or `/var/folders` user files as staging paths.
    nonisolated public static func isManagedPreviewStagingURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if let scheme = url.scheme?.lowercased(), scheme == "ttzip-vfs" {
            return true
        }
        if let query = url.query, query.contains("subpath=") {
            return true
        }
        let path = url.standardizedFileURL.path
        return managedStagingPathMarkers.contains { path.contains($0) }
    }

    nonisolated internal static func matchesAllowedExtensions(
        targetURL: URL,
        fileName: String,
        allowedExtensions: Set<String>
    ) -> Bool {
        let urlExt = cleanExtension(targetURL.pathExtension)
        guard allowedExtensions.contains(urlExt) else { return false }
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let nameExt = cleanExtension((trimmed as NSString).pathExtension)
            if !nameExt.isEmpty && !allowedExtensions.contains(nameExt) {
                return false
            }
        }
        return true
    }

    nonisolated private static func cleanExtension(_ rawExtension: String) -> String {
        rawExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    // MARK: - Notification / UserInfo Serialization

    nonisolated public func toUserInfoDictionary(additional: [String: Any] = [:]) -> [String: Any] {
        var result = additional
        if let encoded = try? JSONEncoder().encode(self) {
            result[Self.notificationUserInfoKey] = encoded
        }
        return result
    }

    nonisolated public static func fromUserInfoDictionary(_ userInfo: [AnyHashable: Any]?) -> TTPreviewResourceContext? {
        guard let userInfo else { return nil }
        if let direct = userInfo[Self.notificationUserInfoKey] as? TTPreviewResourceContext {
            return direct
        }
        if let data = userInfo[Self.notificationUserInfoKey] as? Data {
            return try? JSONDecoder().decode(TTPreviewResourceContext.self, from: data)
        }
        return nil
    }
}

private struct TTPreviewResourceContextEnvironmentKey: EnvironmentKey {
    static let defaultValue: TTPreviewResourceContext = .unknown()
}

public extension EnvironmentValues {
    var previewResourceContext: TTPreviewResourceContext {
        get { self[TTPreviewResourceContextEnvironmentKey.self] }
        set { self[TTPreviewResourceContextEnvironmentKey.self] = newValue }
    }
}

public extension View {
    func previewResourceContext(_ context: TTPreviewResourceContext) -> some View {
        environment(\.previewResourceContext, context)
    }
}
