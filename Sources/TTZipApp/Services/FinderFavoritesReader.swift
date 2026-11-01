// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import CoreServices
import TTZipCore
import TTZipUI
import TTZipPreviewKit

public final class FinderFavoritesReader {
    
    private static let bookmarkStorageKey = "TTZipFinderFavoritesBookmarkData"
    
    public typealias FinderFavoritesResult = FavoritesResult
    
    /// Result of fetching favorites including items and custom status.
    public struct FavoritesResult: Sendable {
        public let items: [FinderFavoriteItem]
        public let hasResolvedCustomFavorites: Bool
        
        public init(items: [FinderFavoriteItem], hasResolvedCustomFavorites: Bool) {
            self.items = items
            self.hasResolvedCustomFavorites = hasResolvedCustomFavorites
        }
    }
    
    /// Returns default standard user favorites immediately for zero-latency initial UI rendering.
    public static func defaultStandardFavorites() -> FavoritesResult {
        let fm = FileManager.default
        let realHome: String = {
            if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
                return fm.string(withFileSystemRepresentation: dir, length: strlen(dir))
            }
            return NSHomeDirectory()
        }()
        
        let standardDirSpecs: [(FileManager.SearchPathDirectory, String, String)] = [
            (.downloadsDirectory, "arrow.down.circle", "Downloads"),
            (.documentDirectory, "doc.text.fill", "Documents"),
            (.desktopDirectory, "desktopcomputer", "Desktop"),
            (.picturesDirectory, "photo.fill", "Pictures"),
            (.moviesDirectory, "film.fill", "Movies"),
            (.musicDirectory, "music.note", "Music")
        ]
        
        var results: [FinderFavoriteItem] = []
        var seenPaths = Set<String>()
        var standardPaths: [(String, String)] = []
        for (_, icon, fallbackSub) in standardDirSpecs {
            let resolved = (realHome as NSString).appendingPathComponent(fallbackSub)
            standardPaths.append((resolved, icon))
        }
        standardPaths.insert((realHome, "house.fill"), at: 3)
        let appPath = fm.urls(for: .applicationDirectory, in: .localDomainMask).first?.path ?? "/Applications"
        standardPaths.append((appPath, "app.badge"))
        
        for (path, icon) in standardPaths {
            if seenPaths.insert(path).inserted {
                let finalName = TTZipPathPresentationService.shared.displayName(for: path)
                results.append(FinderFavoriteItem(name: finalName, path: path, systemImage: icon))
            }
        }
        return FavoritesResult(items: results, hasResolvedCustomFavorites: false)
    }
    
    /// Dedicated POSIX dispatch queue isolated from the Swift Concurrency cooperative thread pool.
    /// Protects cooperative worker threads from kernel blocking I/O on unresponsive SMB/NFS shares.
    private static let sflReaderQueue = DispatchQueue(
        label: "com.metastudyline.ttzip.sfl3-reader",
        qos: .userInitiated
    )

    /// Fetches user favorites asynchronously off the cooperative thread pool.
    public static func fetchFavoritesResult() async -> FavoritesResult {
        await withCheckedContinuation { continuation in
            sflReaderQueue.async {
                let result = fetchFavoritesResultSync()
                continuation.resume(returning: result)
            }
        }
    }
    
    /// Synchronously fetches user favorites matching the macOS Finder sidebar.
    public static func fetchFavoritesResultSync() -> FavoritesResult {
        var results: [FinderFavoriteItem] = []
        var seenPaths = Set<String>()
        let hasResolvedCustom: Bool
        
        // 1. Attempt to fetch real macOS Finder favorites (from SFL4/SFL3/SFL2 or authorized bookmark)
        if let sflFavorites = fetchSFLFavorites(), !sflFavorites.isEmpty {
            hasResolvedCustom = true
            for item in sflFavorites {
                if seenPaths.insert(item.path).inserted {
                    results.append(item)
                }
            }
        } else {
            hasResolvedCustom = false
            return defaultStandardFavorites()
        }
        
        return FavoritesResult(items: results, hasResolvedCustomFavorites: hasResolvedCustom)
    }
    
    /// Synchronous convenience overload matching existing sync call sites.
    public static func fetchFavoritesResult() -> FavoritesResult {
        fetchFavoritesResultSync()
    }
    
    /// Backward-compatible convenience accessor returning just the items list.
    public static func fetchFavorites() -> [FinderFavoriteItem] {
        return fetchFavoritesResultSync().items
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
    
    /// Resolves the directory URL containing macOS sharedfilelist files, if accessible.
    /// Returns the resolved directory URL and whether security-scoped resource access is required.
    public static func resolveSharedFileListDirectory() -> (url: URL, isSecurityScoped: Bool)? {
        if let bookmarkData = UserDefaults.standard.data(forKey: bookmarkStorageKey) {
            var isStale = false
            if let authorizedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: authorizedURL.path, isDirectory: &isDir) {
                    let dirURL = isDir.boolValue ? authorizedURL : authorizedURL.deletingLastPathComponent()
                    return (dirURL, true)
                }
            }
        }
        
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil || NSHomeDirectory().contains("/Containers/")
        if !isSandboxed {
            let realHome: String = {
                if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
                    return FileManager.default.string(withFileSystemRepresentation: dir, length: strlen(dir))
                }
                return NSHomeDirectory()
            }()
            let sflDir = URL(fileURLWithPath: (realHome as NSString).appendingPathComponent("Library/Application Support/com.apple.sharedfilelist"))
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: sflDir.path, isDirectory: &isDir), isDir.boolValue {
                return (sflDir, false)
            }
        }
        
        return nil
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
        
        // Option B: Direct access from real ~/Library/Application Support/com.apple.sharedfilelist
        // In macOS App Sandbox, NSHomeDirectory() points to ~/Library/Containers/<bundle-id>/Data.
        // We avoid probing inside the container where sharedfilelist never exists.
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil || NSHomeDirectory().contains("/Containers/")
        if !isSandboxed {
            let realHome: String = {
                if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
                    return FileManager.default.string(withFileSystemRepresentation: dir, length: strlen(dir))
                }
                return NSHomeDirectory()
            }()
            let sflDir = URL(fileURLWithPath: (realHome as NSString).appendingPathComponent("Library/Application Support/com.apple.sharedfilelist"))
            if let items = loadAndParseSFL(at: sflDir), !items.isEmpty {
                return items
            }
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
        unarchiver.requiresSecureCoding = true
        let allowedClasses: [AnyClass] = [
            NSDictionary.self,
            NSArray.self,
            NSString.self,
            NSData.self,
            NSNumber.self,
            NSDate.self,
            NSURL.self
        ]
        guard let rootDict = unarchiver.decodeObject(of: allowedClasses, forKey: NSKeyedArchiveRootObjectKey) as? [String: Any],
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
            
            // Extract display name with priority: CustomItemProperties -> Standard Directory Localizer -> localizedName -> displayName -> Name fallback
            let displayName: String = {
                if let customProps = item["CustomItemProperties"] as? [String: Any],
                   let customName = customProps["com.apple.LSSharedFileList.ItemName"] as? String,
                   !customName.isEmpty {
                    return customName
                }
                let currentLang = TTZipLocalizationManager.shared.currentLanguage
                if let standardName = standardDirectoryLocalizedName(for: canonicalPath, language: currentLang) {
                    return standardName
                }
                if let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName, !localized.isEmpty {
                    return localized
                }
                let fmName = fm.displayName(atPath: canonicalPath)
                if !fmName.isEmpty && fmName != canonicalPath && fmName != url.lastPathComponent {
                    return fmName
                }
                if let name = item["Name"] as? String, !name.isEmpty, name != "Documents" && name != "Desktop" && name != "Downloads" {
                    return name
                }
                return fmName.isEmpty ? url.lastPathComponent : fmName
            }()
            
            let icon = iconFor(path: canonicalPath, name: displayName)
            items.append(FinderFavoriteItem(name: displayName, path: canonicalPath, systemImage: icon, bookmarkData: bookmarkData))
        }
        
        return items.isEmpty ? nil : items
    }
    
    /// Resolves an appropriate SF Symbol icon based on folder path and name conventions.
    public static func iconFor(path: String, name: String) -> String {
        TTZipPathPresentationService.shared.icon(for: path, isDirectory: true)
    }

    /// Resolves canonical localized names for standard user and system directories
    /// based on the active application language.
    public static func standardDirectoryLocalizedName(for canonicalPath: String, language: AppLanguage) -> String? {
        TTZipPathPresentationService.shared.standardDirectoryLocalizedName(for: canonicalPath, language: language)
    }
}
