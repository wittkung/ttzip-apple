// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AppKit
import CoreServices
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

public final class FinderFavoritesReader {
    
    private static let bookmarkStorageKey = "TTZipFinderFavoritesBookmarkData"
    
    /// Indicates whether custom Finder favorites were successfully resolved from system SFL or authorized storage.
    public private(set) static var hasResolvedCustomFavorites: Bool = false
    
    /// Fetches user favorites matching the macOS Finder sidebar, with resilient fallback to system standard directories.
    public static func fetchFavorites() -> [FinderFavoriteItem] {
        var results: [FinderFavoriteItem] = []
        var seenPaths = Set<String>()
        let fm = FileManager.default
        
        // 1. Attempt to fetch real macOS Finder favorites (from SFL4/SFL3 or authorized bookmark)
        if let sflFavorites = fetchSFLFavorites(), !sflFavorites.isEmpty {
            hasResolvedCustomFavorites = true
            for item in sflFavorites {
                if seenPaths.insert(item.path).inserted {
                    results.append(item)
                }
            }
        } else {
            hasResolvedCustomFavorites = false
            // Fallback: fetch macOS standard user directories
            let home = NSHomeDirectory()
            let standardPaths: [(String, String)] = [
                ((home as NSString).appendingPathComponent("Downloads"), "arrow.down.circle.fill"),
                ((home as NSString).appendingPathComponent("Documents"), "doc.text.fill"),
                ((home as NSString).appendingPathComponent("Desktop"), "desktopcomputer"),
                (home, "house.fill"),
                ((home as NSString).appendingPathComponent("Pictures"), "photo.fill"),
                ((home as NSString).appendingPathComponent("Movies"), "film.fill"),
                ((home as NSString).appendingPathComponent("Music"), "music.note"),
                ("/Applications", "app.badge")
            ]
            
            for (path, icon) in standardPaths {
                if !seenPaths.contains(path), fm.fileExists(atPath: path) {
                    seenPaths.insert(path)
                    let displayName = fm.displayName(atPath: path)
                    results.append(FinderFavoriteItem(name: displayName, path: path, systemImage: icon))
                }
            }
        }
        
        // 2. Append mounted volumes (e.g., external drives, USB sticks) if not already present
        if let mountedVolumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey, .volumeLocalizedNameKey], options: .skipHiddenVolumes) {
            for volumeURL in mountedVolumes {
                let path = volumeURL.path
                if path == "/System/Volumes/Data" || seenPaths.contains(path) {
                    continue
                }
                
                let isInternal = (try? volumeURL.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) ?? true
                let name = (try? volumeURL.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? volumeURL.lastPathComponent
                
                let icon = isInternal ? "internaldrive.fill" : "externaldrive.fill"
                seenPaths.insert(path)
                results.append(FinderFavoriteItem(name: name, path: path, systemImage: icon))
            }
        }
        
        return results
    }
    
    /// Persists a security-scoped bookmark for the user-selected sharedfilelist directory or file.
    public static func saveSecurityScopedBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkStorageKey)
        } catch {
            // Silently ignore bookmark generation failures
        }
    }
    
    /// Clears any stored security-scoped bookmark.
    public static func clearStoredBookmark() {
        UserDefaults.standard.removeObject(forKey: bookmarkStorageKey)
    }
    
    /// Internal resolution pipeline querying authorized bookmarks first, then direct file paths.
    private static func fetchSFLFavorites() -> [FinderFavoriteItem]? {
        // Option A: Resolve via saved security-scoped bookmark
        if let bookmarkData = UserDefaults.standard.data(forKey: bookmarkStorageKey) {
            var isStale = false
            if let authorizedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let didAccess = authorizedURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        authorizedURL.stopAccessingSecurityScopedResource()
                    }
                }
                if let items = loadAndParseSFL(at: authorizedURL), !items.isEmpty {
                    return items
                }
            }
        }
        
        // Option B: Direct access from ~/Library/Application Support/com.apple.sharedfilelist
        let home = NSHomeDirectory()
        let sflDir = URL(fileURLWithPath: (home as NSString).appendingPathComponent("Library/Application Support/com.apple.sharedfilelist"))
        if let items = loadAndParseSFL(at: sflDir), !items.isEmpty {
            return items
        }
        
        return nil
    }
    
    /// Inspects a directory URL or file URL for .sfl4, .sfl3, or .sfl2 binary plists and parses items.
    private static func loadAndParseSFL(at locationURL: URL) -> [FinderFavoriteItem]? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: locationURL.path, isDirectory: &isDir) else {
            return nil
        }
        
        if isDir.boolValue {
            let candidateNames = [
                "com.apple.LSSharedFileList.FavoriteItems.sfl4",
                "com.apple.LSSharedFileList.FavoriteItems.sfl3",
                "com.apple.LSSharedFileList.FavoriteItems.sfl2"
            ]
            for name in candidateNames {
                let fileURL = locationURL.appendingPathComponent(name)
                if let data = try? Data(contentsOf: fileURL), !data.isEmpty {
                    if let items = parseSFLData(data), !items.isEmpty {
                        return items
                    }
                }
            }
            return nil
        } else {
            if let data = try? Data(contentsOf: locationURL), !data.isEmpty {
                return parseSFLData(data)
            }
            return nil
        }
    }
    
    /// Decodes NSKeyedArchiver binary property list and resolves all valid local directory bookmarks.
    private static func parseSFLData(_ data: Data) -> [FinderFavoriteItem]? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = false
        guard let rootDict = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [String: Any],
              let rawItems = rootDict["items"] as? [[String: Any]],
              !rawItems.isEmpty else {
            unarchiver.finishDecoding()
            return nil
        }
        unarchiver.finishDecoding()
        
        var items: [FinderFavoriteItem] = []
        var seenPaths = Set<String>()
        let fm = FileManager.default
        
        for item in rawItems {
            guard let bookmarkData = item["Bookmark"] as? Data else { continue }
            
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutMounting, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                continue
            }
            
            // Validate that the target exists and is a physical directory (excludes virtual nodes like AirDrop)
            var isTargetDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isTargetDir), isTargetDir.boolValue else {
                continue
            }
            
            let canonicalPath = url.standardizedFileURL.path
            guard seenPaths.insert(canonicalPath).inserted else {
                continue
            }
            
            // Extract display name with priority: CustomItemProperties -> Name -> localizedName -> displayName
            let displayName: String = {
                if let customProps = item["CustomItemProperties"] as? [String: Any],
                   let customName = customProps["com.apple.LSSharedFileList.ItemName"] as? String,
                   !customName.isEmpty {
                    return customName
                }
                if let name = item["Name"] as? String, !name.isEmpty {
                    return name
                }
                if let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName, !localized.isEmpty {
                    return localized
                }
                let fmName = fm.displayName(atPath: canonicalPath)
                return fmName.isEmpty ? url.lastPathComponent : fmName
            }()
            
            let icon = iconFor(path: canonicalPath, name: displayName)
            items.append(FinderFavoriteItem(name: displayName, path: canonicalPath, systemImage: icon))
        }
        
        return items.isEmpty ? nil : items
    }
    
    /// Resolves an appropriate SF Symbol icon based on folder path and name conventions.
    public static func iconFor(path: String, name: String) -> String {
        let home = NSHomeDirectory()
        let lowerName = name.lowercased()
        let lowerPath = path.lowercased()
        
        if path == (home as NSString).appendingPathComponent("Downloads") || lowerName == "downloads" || lowerName == "下载" {
            return "arrow.down.circle.fill"
        } else if path == (home as NSString).appendingPathComponent("Documents") || lowerName == "documents" || lowerName == "文稿" {
            return "doc.text.fill"
        } else if path == (home as NSString).appendingPathComponent("Desktop") || lowerName == "desktop" || lowerName == "桌面" {
            return "desktopcomputer"
        } else if path == home || lowerName == "home" {
            return "house.fill"
        } else if path == (home as NSString).appendingPathComponent("Pictures") || lowerName == "pictures" || lowerName == "图片" {
            return "photo.fill"
        } else if path == (home as NSString).appendingPathComponent("Movies") || lowerName == "movies" || lowerName == "影片" || lowerName == "电影" {
            return "film.fill"
        } else if path == (home as NSString).appendingPathComponent("Music") || lowerName == "music" || lowerName == "音乐" {
            return "music.note"
        } else if path == "/Applications" || lowerName == "applications" || lowerName == "应用程序" {
            return "app.badge"
        } else if path == "/" || lowerPath.hasPrefix("/volumes/") {
            return "internaldrive.fill"
        } else if lowerName.contains("cloud") || lowerPath.contains("cloud") || lowerName.contains("drive") || lowerName.contains("dropbox") || lowerName.contains("nextcloud") {
            return "cloud.fill"
        } else if lowerName.contains("dev") || lowerName.contains("code") || lowerName.contains("git") || lowerName.contains("project") {
            return "chevron.left.forwardslash.chevron.right"
        } else if lowerName.contains("blog") || lowerName.contains("日更") || lowerName.contains("note") || lowerName.contains("writing") || lowerName.contains("文") {
            return "text.book.closed.fill"
        }
        return "folder.fill"
    }
}
