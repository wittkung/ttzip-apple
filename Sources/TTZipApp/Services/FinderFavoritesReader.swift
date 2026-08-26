// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AppKit
import CoreServices

public final class FinderFavoritesReader {
    
    /// Fetches user favorites matching the macOS Finder sidebar, with resilient fallback to system standard directories.
    public static func fetchFavorites() -> [FinderFavoriteItem] {
        var results: [FinderFavoriteItem] = []
        var seenPaths = Set<String>()
        let fm = FileManager.default
        
        // 1. Fetch macOS standard user directories
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
        
        // 3. Append mounted volumes (e.g., external drives, USB sticks) if not already present
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
        } else if lowerName.contains("cloud") || lowerPath.contains("cloud") || lowerName.contains("drive") || lowerName.contains("dropbox") {
            return "cloud.fill"
        }
        return "folder.fill"
    }
}
