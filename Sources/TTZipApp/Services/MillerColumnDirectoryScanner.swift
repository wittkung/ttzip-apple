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
        
        let archivePath: String
        let subpath: String
        
        if let components = URLComponents(url: dirURL, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems,
           let subItem = queryItems.first(where: { $0.name == "subpath" })?.value {
            archivePath = dirURL.path
            subpath = subItem.hasSuffix("/") ? String(subItem.dropLast()) : subItem
        } else {
            archivePath = dirURL.path
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
        
        for child in childComponents {
            let childSubpath = prefix + child.name
            var comp = URLComponents(url: URL(fileURLWithPath: archivePath), resolvingAgainstBaseURL: false)!
            comp.queryItems = [URLQueryItem(name: "subpath", value: childSubpath)]
            let virtualURL = comp.url ?? URL(fileURLWithPath: archivePath)
            
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
                let ext = (child.name as NSString).pathExtension
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
