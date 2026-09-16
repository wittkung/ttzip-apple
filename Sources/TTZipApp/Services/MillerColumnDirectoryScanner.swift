// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

public enum MillerColumnDirectoryScanner {
    public static func loadContentsOf(dirURL: URL) async -> [DiskItemInfo] {
        var isDir: ObjCBool = false
        let path = dirURL.path
        
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return await DiskDirectoryScannerActor.shared.scanDirectory(at: dirURL)
        }
        
        let archivePath = dirURL.path
        let subpath: String
        
        let urlString = dirURL.absoluteString
        if let queryRange = urlString.range(of: "?subpath=") {
            let rawSubpath = String(urlString[queryRange.upperBound...])
            let decoded = rawSubpath.removingPercentEncoding ?? rawSubpath
            subpath = decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
        } else {
            subpath = ""
        }
        
        guard FileManager.default.fileExists(atPath: archivePath) else { return [] }
        
        let targetPassword = ArchivePasswordStore.shared.getPassword(for: archivePath)
        
        let session: ArchiveHierarchySession
        do {
            session = try await ArchiveHierarchySessionCache.shared.getOrFetchSession(
                for: archivePath,
                password: targetPassword,
                autoVaultUnlock: PasswordVaultManager.shared.autoUnlockArchives
            )
        } catch {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: NSNotification.Name("TTZipEncryptedArchivePromptRequired"),
                    object: archivePath
                )
            }
            return [
                DiskItemInfo(
                    virtualName: "Encrypted Archive (Click to enter password)",
                    virtualURL: dirURL,
                    isDirectory: false,
                    isArchive: false,
                    sizeText: "Password Required",
                    rawSizeBytes: 0,
                    kindText: "Password-Protected Archive"
                )
            ]
        }
        
        guard let targetComponent = session.subpathMap[subpath] else {
            return []
        }
        
        let childComponents = targetComponent.getChildren()
        var diskItems: [DiskItemInfo] = []
        diskItems.reserveCapacity(childComponents.count)
        let prefix = subpath.isEmpty ? "" : (subpath.hasSuffix("/") ? subpath : subpath + "/")
        let baseArchiveURL = URL(fileURLWithPath: archivePath)
        let basePrefix = baseArchiveURL.absoluteString + "?subpath="
        
        for child in childComponents {
            let childSubpath = prefix + child.name
            let encodedSubpath = childSubpath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? childSubpath
            let virtualURL = URL(string: basePrefix + encodedSubpath) ?? baseArchiveURL
            
            let isDir = child.isDirectory
            let diskItem: DiskItemInfo
            if isDir {
                diskItem = DiskItemInfo(
                    virtualName: child.name,
                    virtualURL: virtualURL,
                    isDirectory: true,
                    isArchive: false,
                    sizeText: "Folder",
                    rawSizeBytes: child.sizeBytes,
                    kindText: "Archive Folder"
                )
            } else {
                let ext: String
                if let dotIndex = child.name.lastIndex(of: "."), dotIndex != child.name.startIndex {
                    ext = String(child.name[child.name.index(after: dotIndex)...])
                } else {
                    ext = ""
                }
                let sizeText = ByteCountFormatterFlyweight.shared.string(fromByteCount: child.sizeBytes)
                let kind = ext.isEmpty ? "File" : "\(ext.uppercased()) File"
                diskItem = DiskItemInfo(
                    virtualName: child.name,
                    virtualURL: virtualURL,
                    isDirectory: false,
                    isArchive: false,
                    sizeText: sizeText,
                    rawSizeBytes: child.sizeBytes,
                    kindText: kind
                )
            }
            diskItems.append(diskItem)
        }
        
        return diskItems.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
