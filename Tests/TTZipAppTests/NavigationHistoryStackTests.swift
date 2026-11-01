// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import AppKit
@testable import TTZipCore
@testable import TTZipApp

@MainActor
final class NavigationHistoryStackTests: XCTestCase {

    func testInitialHistoryState() async throws {
        let root = URL(fileURLWithPath: "/Users/test/Downloads")
        let tab = DirectoryTabItem(url: root)
        
        XCTAssertEqual(tab.history.count, 1)
        XCTAssertEqual(tab.historyIndex, 0)
        XCTAssertFalse(tab.canGoBack)
        XCTAssertFalse(tab.canGoForward)
        XCTAssertTrue(tab.canGoUp)
    }

    func testPushNavigationAndHistoryTraversal() async throws {
        let url1 = URL(fileURLWithPath: "/Users/test/Downloads")
        let url2 = URL(fileURLWithPath: "/Users/test/Documents")
        let url3 = URL(fileURLWithPath: "/Users/test/Documents/code")
        
        var tab = DirectoryTabItem(url: url1)
        
        // Push url2
        tab.pushURL(url2)
        XCTAssertEqual(tab.history.count, 2)
        XCTAssertEqual(tab.historyIndex, 1)
        XCTAssertTrue(tab.canGoBack)
        XCTAssertFalse(tab.canGoForward)
        
        // Push url3
        tab.pushURL(url3)
        XCTAssertEqual(tab.history.count, 3)
        XCTAssertEqual(tab.historyIndex, 2)
        XCTAssertTrue(tab.canGoBack)
        XCTAssertFalse(tab.canGoForward)
        
        // Back to url2
        let back1 = tab.back()
        XCTAssertEqual(back1?.path, url2.path)
        XCTAssertEqual(tab.historyIndex, 1)
        XCTAssertTrue(tab.canGoBack)
        XCTAssertTrue(tab.canGoForward)
        
        // Back to url1
        let back2 = tab.back()
        XCTAssertEqual(back2?.path, url1.path)
        XCTAssertEqual(tab.historyIndex, 0)
        XCTAssertFalse(tab.canGoBack)
        XCTAssertTrue(tab.canGoForward)
        
        // Forward to url2
        let fwd1 = tab.forward()
        XCTAssertEqual(fwd1?.path, url2.path)
        XCTAssertEqual(tab.historyIndex, 1)
        XCTAssertTrue(tab.canGoBack)
        XCTAssertTrue(tab.canGoForward)
    }

    func testHistoryBranchTruncation() async throws {
        let url1 = URL(fileURLWithPath: "/a")
        let url2 = URL(fileURLWithPath: "/b")
        let url3 = URL(fileURLWithPath: "/c")
        let urlBranch = URL(fileURLWithPath: "/d")
        
        var tab = DirectoryTabItem(url: url1)
        tab.pushURL(url2)
        tab.pushURL(url3)
        XCTAssertEqual(tab.historyIndex, 2)
        
        // Step back to /b
        _ = tab.back()
        XCTAssertEqual(tab.historyIndex, 1)
        
        // Branch to /d -> must truncate /c
        tab.pushURL(urlBranch)
        XCTAssertEqual(tab.history.count, 3) // /a, /b, /d
        XCTAssertEqual(tab.historyIndex, 2)
        XCTAssertEqual(tab.url.path, "/d")
        XCTAssertFalse(tab.canGoForward)
        XCTAssertTrue(tab.canGoBack)
        
        let prev = tab.back()
        XCTAssertEqual(prev?.path, "/b")
    }

    func testNavigateUp() async throws {
        let child = URL(fileURLWithPath: "/Users/test/Documents/dev")
        var tab = DirectoryTabItem(url: child)
        
        let parent = tab.up()
        XCTAssertEqual(parent?.path, "/Users/test/Documents")
        XCTAssertEqual(tab.history.count, 2)
        XCTAssertEqual(tab.historyIndex, 1)
    }

    func testNavigationStateFacade() async throws {
        let nav = NavigationState()
        let home = URL(fileURLWithPath: "/Users/test/Downloads")
        nav.currentDirectory = home
        
        let target = URL(fileURLWithPath: "/Users/test/Pictures")
        nav.navigateTo(target)
        XCTAssertEqual(nav.currentDirectory.path, target.path)
        XCTAssertTrue(nav.canGoBack)
        
        nav.goBack()
        XCTAssertEqual(nav.currentDirectory.path, home.path)
        XCTAssertTrue(nav.canGoForward)
        
        nav.goForward()
        XCTAssertEqual(nav.currentDirectory.path, target.path)
    }
}
