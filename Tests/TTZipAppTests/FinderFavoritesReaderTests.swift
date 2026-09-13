// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp
@testable import TTZipCore

final class FinderFavoritesReaderTests: XCTestCase {
    
    func testFetchFavoritesReturnsNonEmptyList() {
        let result = FinderFavoritesReader.fetchFavoritesResult()
        XCTAssertFalse(result.items.isEmpty, "Favorites list should never be empty due to fallback mechanisms.")
        
        let legacyItems = FinderFavoritesReader.fetchFavorites()
        XCTAssertEqual(result.items.count, legacyItems.count, "Convenience fetchFavorites() should return same items as fetchFavoritesResult().")
        
        for item in result.items {
            XCTAssertFalse(item.id.isEmpty, "Item id must not be empty.")
            XCTAssertFalse(item.name.isEmpty, "Item name must not be empty.")
            XCTAssertFalse(item.path.isEmpty, "Item path must not be empty.")
            XCTAssertFalse(item.systemImage.isEmpty, "Item systemImage must not be empty.")
        }
    }
    
    func testIconMappingForStandardAndCustomNames() {
        let home = NSHomeDirectory()
        
        // Downloads
        let downloadsPath = (home as NSString).appendingPathComponent("Downloads")
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: downloadsPath, name: "Downloads"), "arrow.down.circle.fill")
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: downloadsPath, name: "下载"), "arrow.down.circle.fill")
        
        // Documents
        let docsPath = (home as NSString).appendingPathComponent("Documents")
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: docsPath, name: "Documents"), "doc.text.fill")
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: docsPath, name: "文稿"), "doc.text.fill")
        
        // Desktop
        let desktopPath = (home as NSString).appendingPathComponent("Desktop")
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: desktopPath, name: "Desktop"), "desktopcomputer")
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: desktopPath, name: "桌面"), "desktopcomputer")
        
        // Developer / Code
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: "/dev", name: "dev"), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: "/code/ttzip", name: "ttzip"), "folder.fill")
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: "/code/project", name: "project"), "chevron.left.forwardslash.chevron.right")
        
        // Blog / Writing
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: "/blog", name: "日更"), "text.book.closed.fill")
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: "/notes", name: "blog"), "text.book.closed.fill")
        
        // Cloud
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: "/nextcloud", name: "Nextcloud"), "cloud.fill")
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: "/cloud", name: "Cloud Drive"), "cloud.fill")
        
        // Root / Volumes
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: "/", name: "Macintosh HD"), "internaldrive.fill")
        XCTAssertEqual(FinderFavoritesReader.iconFor(path: "/Volumes/External", name: "USB Drive"), "internaldrive.fill")
    }
    
    func testBookmarkPersistenceAPI() {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
        FinderFavoritesReader.saveSecurityScopedBookmark(for: tempURL)
        FinderFavoritesReader.clearStoredBookmark()
        
        let resultAfterClear = FinderFavoritesReader.fetchFavoritesResult()
        XCTAssertFalse(resultAfterClear.items.isEmpty)
    }
}
