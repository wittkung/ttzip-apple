// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit

public enum MillerColumnDirectoryScanner {
    public static func isAccessDeniedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoPermissionError || nsError.code == 257 || nsError.code == 256 {
                return true
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            if nsError.code == EPERM || nsError.code == EACCES {
                return true
            }
        }
        let desc = error.localizedDescription.lowercased()
        if desc.contains("permission denied") || desc.contains("operation not permitted") || desc.contains("access denied") {
            return true
        }
        return false
    }

    public nonisolated static func loadContentsOf(
        dirURL: URL,
        sortOption: DiskSortOption = .nameAsc,
        scopeID: String? = nil,
        windowID: UUID? = nil,
        bypassCache: Bool = false
    ) async -> [DiskItemInfo] {
        await loadContentsResult(
            dirURL: dirURL,
            sortOption: sortOption,
            scopeID: scopeID,
            windowID: windowID,
            bypassCache: bypassCache
        ) ?? []
    }

    /// Loads and sorts directory or virtual archive contents off the main actor.
    /// Returns `nil` when cancelled or superseded by a newer navigation generation.
    public nonisolated static func loadContentsResult(
        dirURL: URL,
        sortOption: DiskSortOption = .nameAsc,
        scopeID: String? = nil,
        windowID: UUID? = nil,
        bypassCache: Bool = false
    ) async -> [DiskItemInfo]? {
        if Task.isCancelled { return nil }

        let hasVirtualSubpath = dirURL.absoluteString.contains("?subpath=")
        if !hasVirtualSubpath {
            if let diskResult = await loadPhysicalDirectoryIfApplicable(
                dirURL: dirURL,
                sortOption: sortOption,
                scopeID: scopeID,
                bypassCache: bypassCache
            ) {
                return diskResult
            }
            if Task.isCancelled { return nil }
        }

        return await loadVirtualArchiveContents(
            dirURL: dirURL,
            sortOption: sortOption,
            windowID: windowID
        )
    }

    /// Physical-only UI endpoint. A non-directory never falls through to an archive reader.
    public nonisolated static func loadPhysicalContentsResult(
        dirURL: URL,
        sortOption: DiskSortOption = .nameAsc,
        scopeID: String? = nil,
        bypassCache: Bool = false
    ) async -> [DiskItemInfo]? {
        guard !Task.isCancelled, AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(dirURL),
              URLComponents(url: dirURL, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(where: { $0.name == "subpath" }) != true else { return nil }
        let result = await loadPhysicalDirectoryIfApplicable(
            dirURL: dirURL, sortOption: sortOption, scopeID: scopeID, bypassCache: bypassCache
        )
        return Task.isCancelled ? nil : (result ?? [])
    }

    /// Lists an accepted owner catalog; never reads an archive or looks up a credential.
    public nonisolated static func loadAcceptedArchiveContents(
        dirURL: URL,
        sortOption: DiskSortOption,
        projection: AcceptedArchiveDirectoryProjection
    ) async -> [DiskItemInfo]? {
        guard !Task.isCancelled, AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(dirURL),
              dirURL.standardizedFileURL.path == projection.archivePath,
              var components = URLComponents(url: dirURL, resolvingAgainstBaseURL: false) else { return nil }
        if components.percentEncodedQuery == nil {
            components.queryItems = [URLQueryItem(name: "subpath", value: "")]
        }
        guard let location = components.url,
              let subpath = AcceptedArchiveDirectoryProjection.archiveSubpath(in: location) else { return nil }
        guard let directory = projection.subpaths[subpath], directory.isDirectory else { return [] }
        return await mapAndSortVirtualChildren(
            directory.getChildren(), archivePath: projection.archivePath,
            subpath: subpath, sortOption: sortOption
        )
    }

    private struct DirectoryProbeOutcome: Sendable {
        let exists: Bool
        let isDir: Bool
        let permissionDenied: Bool
        let probeError: Error?
    }

    private nonisolated static func probeDirectoryOffMainThread(dirURL: URL) async -> DirectoryProbeOutcome {
        await Task.detached(priority: .userInitiated) {
            let path = dirURL.path
            var isDirObj: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirObj)
            if exists {
                let denied = isDirObj.boolValue && !FileManager.default.isReadableFile(atPath: path)
                return DirectoryProbeOutcome(exists: true, isDir: isDirObj.boolValue, permissionDenied: denied, probeError: nil)
            }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: path)
                let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
                return DirectoryProbeOutcome(exists: true, isDir: isDir, permissionDenied: false, probeError: nil)
            } catch {
                let denied = isAccessDeniedError(error)
                return DirectoryProbeOutcome(exists: false, isDir: denied, permissionDenied: denied, probeError: error)
            }
        }.value
    }

    private nonisolated static func loadPhysicalDirectoryIfApplicable(
        dirURL: URL,
        sortOption: DiskSortOption,
        scopeID: String?,
        bypassCache: Bool
    ) async -> [DiskItemInfo]? {
        let probe = await probeDirectoryOffMainThread(dirURL: dirURL)
        if Task.isCancelled { return nil }

        if probe.permissionDenied {
            return [makeAccessRequiredSentinel(for: dirURL)]
        }

        if probe.exists && probe.isDir {
            do {
                return try await DiskDirectoryScanner.shared.scanDirectory(
                    at: dirURL,
                    sortOption: sortOption,
                    scopeID: scopeID,
                    bypassCache: bypassCache
                )
            } catch is CancellationError {
                return nil
            } catch {
                if Task.isCancelled { return nil }
                let sentinel = isAccessDeniedError(error)
                    ? makeAccessRequiredSentinel(for: dirURL)
                    : makeReadErrorSentinel(for: dirURL, error: error)
                return [sentinel]
            }
        }

        if !probe.exists, let probeError = probe.probeError, dirURL.path.hasPrefix("/Volumes/") {
            return [makeReadErrorSentinel(for: dirURL, error: probeError)]
        }
        return nil
    }

    public nonisolated static func makeAccessRequiredSentinel(for dirURL: URL) -> DiskItemInfo {
        let authURL = URL(string: dirURL.absoluteString + "?subpath=__auth__") ?? dirURL
        return DiskItemInfo(
            virtualName: "Folder Access Required",
            virtualURL: authURL,
            isDirectory: false,
            isArchive: false,
            sizeText: "Permission Required",
            rawSizeBytes: 0,
            kindText: "Access Authorization",
            isEncryptedLockItem: true
        )
    }

    public nonisolated static func makeReadErrorSentinel(for dirURL: URL, error: Error) -> DiskItemInfo {
        let errURL = URL(string: dirURL.absoluteString + "?subpath=__error__") ?? dirURL
        return DiskItemInfo(
            virtualName: "Unable to Read Directory",
            virtualURL: errURL,
            isDirectory: false,
            isArchive: false,
            sizeText: error.localizedDescription,
            rawSizeBytes: 0,
            kindText: "Read Error",
            isEncryptedLockItem: true
        )
    }

    private nonisolated static func parseVirtualSubpath(from urlString: String) -> String {
        guard let queryRange = urlString.range(of: "?subpath=") else { return "" }
        let rawSubpath = String(urlString[queryRange.upperBound...])
        let decoded = rawSubpath.removingPercentEncoding ?? rawSubpath
        return decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
    }

    private nonisolated static func loadVirtualArchiveContents(
        dirURL: URL,
        sortOption: DiskSortOption,
        windowID: UUID?
    ) async -> [DiskItemInfo]? {
        if Task.isCancelled { return nil }

        let archivePath = dirURL.path
        let subpath = parseVirtualSubpath(from: dirURL.absoluteString)

        let archiveExists = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: archivePath)
        }.value
        guard archiveExists, !Task.isCancelled else { return Task.isCancelled ? nil : [] }

        let (targetPassword, autoUnlock) = await MainActor.run {
            (
                ArchivePasswordStore.shared.getPassword(for: archivePath),
                PasswordVaultManager.shared.autoUnlockArchives
            )
        }

        let session: ArchiveHierarchySession
        do {
            session = try await ArchiveHierarchySessionCache.shared.getOrFetchSession(
                for: archivePath,
                password: targetPassword,
                autoVaultUnlock: autoUnlock
            )
        } catch {
            if Task.isCancelled { return nil }
            return [await makeEncryptedArchiveLockSentinel(dirURL: dirURL, archivePath: archivePath, windowID: windowID)]
        }

        guard !Task.isCancelled else { return nil }
        guard let targetComponent = session.subpathMap[subpath] else { return [] }

        let childComponents = targetComponent.getChildren()
        return await mapAndSortVirtualChildren(
            childComponents,
            archivePath: archivePath,
            subpath: subpath,
            sortOption: sortOption
        )
    }

    private nonisolated static func makeEncryptedArchiveLockSentinel(
        dirURL: URL,
        archivePath: String,
        windowID: UUID?
    ) async -> DiskItemInfo {
        let (virtualName, sizeText, kindText) = await MainActor.run {
            var info: [String: Any] = ["operationKind": "browse"]
            if let windowID {
                info["windowID"] = windowID
            }
            NotificationCenter.default.post(
                name: NSNotification.Name("TTZipEncryptedArchivePromptRequired"),
                object: archivePath,
                userInfo: info
            )
            return (
                AppLocalizationState.shared.t(L10n.Explorer.passwordProtectedArchive),
                AppLocalizationState.shared.t(L10n.Errors.passwordRequired),
                AppLocalizationState.shared.t(L10n.Explorer.passwordProtectedArchive)
            )
        }
        return DiskItemInfo(
            virtualName: virtualName,
            virtualURL: dirURL,
            isDirectory: false,
            isArchive: false,
            sizeText: sizeText,
            rawSizeBytes: 0,
            kindText: kindText,
            isEncryptedLockItem: true
        )
    }

    private nonisolated static func mapAndSortVirtualChildren(
        _ childComponents: [any ArchiveComponentProtocol],
        archivePath: String,
        subpath: String,
        sortOption: DiskSortOption
    ) async -> [DiskItemInfo]? {
        let sortOptionRaw = sortOption.rawValue
        return await Task.detached(priority: .userInitiated) {
            if Task.isCancelled { return nil }
            var diskItems: [DiskItemInfo] = []
            diskItems.reserveCapacity(childComponents.count)
            let prefix = subpath.isEmpty ? "" : (subpath.hasSuffix("/") ? subpath : subpath + "/")
            let baseArchiveURL = URL(fileURLWithPath: archivePath)
            let basePrefix = baseArchiveURL.absoluteString + "?subpath="

            for child in childComponents {
                if Task.isCancelled { return nil }
                diskItems.append(
                    makeVirtualChildDiskItem(
                        child,
                        prefix: prefix,
                        basePrefix: basePrefix,
                        baseArchiveURL: baseArchiveURL
                    )
                )
            }
            if Task.isCancelled { return nil }
            let resolvedSort = DiskSortOption(rawValue: sortOptionRaw) ?? .nameAsc
            return DiskItemSorter.sort(diskItems, by: resolvedSort)
        }.value
    }

    private nonisolated static func makeVirtualChildDiskItem(
        _ child: any ArchiveComponentProtocol,
        prefix: String,
        basePrefix: String,
        baseArchiveURL: URL
    ) -> DiskItemInfo {
        let childSubpath = prefix + child.name
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?%")
        let encodedSubpath = childSubpath.addingPercentEncoding(withAllowedCharacters: allowed) ?? childSubpath
        let virtualURL = URL(string: basePrefix + encodedSubpath) ?? baseArchiveURL

        if child.isDirectory {
            return DiskItemInfo(
                virtualName: child.name,
                virtualURL: virtualURL,
                isDirectory: true,
                isArchive: false,
                sizeText: "Folder",
                rawSizeBytes: child.sizeBytes,
                kindText: "Archive Folder"
            )
        }
        let ext: String
        if let dotIndex = child.name.lastIndex(of: "."), dotIndex != child.name.startIndex {
            ext = String(child.name[child.name.index(after: dotIndex)...])
        } else {
            ext = ""
        }
        let sizeText = ByteCountFormatterFlyweight.shared.string(fromByteCount: child.sizeBytes)
        let kind = ext.isEmpty ? "File" : "\(ext.uppercased()) File"
        return DiskItemInfo(
            virtualName: child.name,
            virtualURL: virtualURL,
            isDirectory: false,
            isArchive: false,
            sizeText: sizeText,
            rawSizeBytes: child.sizeBytes,
            kindText: kind
        )
    }
}
