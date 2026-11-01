// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
import TTZipApp
import TTZipUI
@testable import TTZipApp

@MainActor
final class NavigationSessionOwnershipTests: XCTestCase {
    // MARK: - Navigation Session Write Ownership

    func testOnlyStorageTabDirectorySelectionReplacesSlotAndActiveIdentity() throws {
        let nav = NavigationState()
        let initialID = nav.activeSessionID
        nav.openStorageInspectorTab()
        nav.closeTab(id: initialID)
        let storageID = nav.activeSessionID
        let target = URL(fileURLWithPath: "/navigation-owner/storage-target")

        nav.showDirectory(at: target)

        XCTAssertEqual(nav.tabSessions.count, 1)
        XCTAssertEqual(nav.activeTabIndex, 0)
        XCTAssertNotEqual(nav.activeSessionID, storageID)
        XCTAssertEqual(nav.activeSessionID, nav.tabSessions[0].id)
        let active = try XCTUnwrap(nav.activeTabSession)
        XCTAssertEqual(active.id, nav.activeSessionID)
        XCTAssertEqual(active.kind, .directory)
        XCTAssertEqual(active.historyStack.current, target)
        XCTAssertEqual(active.historyStack.backStack, [])
        XCTAssertEqual(nav.currentDirectory, target)
        XCTAssertEqual(nav.activeDirectoryTab?.id, nav.activeSessionID)
        XCTAssertFalse(nav.isStorageInspectorActive)
        XCTAssertFalse(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.activeTab, .home)
    }

    func testToolDirectorySelectionReusesBrowsingSessionAndPreservesToolTabs() throws {
        let nav = NavigationState()
        let first = URL(fileURLWithPath: "/navigation-owner/reuse-first")
        let target = URL(fileURLWithPath: "/navigation-owner/reuse-target")
        nav.showDirectory(at: first)
        let browserID = nav.activeSessionID
        nav.openCompressWorkspaceTab()
        let compression = try XCTUnwrap(nav.activeTabSession)
        nav.openStorageInspectorTab()
        let storage = try XCTUnwrap(nav.activeTabSession)

        nav.showDirectory(at: target)

        XCTAssertEqual(nav.tabSessions.count, 3)
        XCTAssertEqual(nav.activeSessionID, browserID)
        XCTAssertEqual(nav.tabSessions[nav.activeTabIndex].id, browserID)
        XCTAssertEqual(nav.tabSessions.first(where: { $0.id == compression.id }), compression)
        XCTAssertEqual(nav.tabSessions.first(where: { $0.id == storage.id }), storage)
        XCTAssertEqual(nav.activeTabSession?.historyStack.backStack.last, first)
        XCTAssertEqual(nav.currentDirectory, target)
        XCTAssertEqual(nav.activeTab, .home)
    }

    func testDirectorySelectionPreservesIdentityAndTraversableHistory() throws {
        let nav = NavigationState()
        let first = URL(fileURLWithPath: "/navigation-owner/history-first")
        let second = URL(fileURLWithPath: "/navigation-owner/history-second")
        let third = URL(fileURLWithPath: "/navigation-owner/history-third")
        nav.showDirectory(at: first)
        let id = nav.activeSessionID
        let initialHistory = try XCTUnwrap(nav.activeTabSession).historyStack.backStack

        nav.showDirectory(at: second)
        nav.showDirectory(at: third)

        XCTAssertEqual(nav.activeSessionID, id)
        XCTAssertEqual(nav.tabSessions.count, 1)
        XCTAssertEqual(nav.activeTabSession?.historyStack.backStack, initialHistory + [first, second])
        nav.goBack()
        XCTAssertEqual(nav.currentDirectory, second)
        nav.goForward()
        XCTAssertEqual(nav.currentDirectory, third)
        XCTAssertEqual(nav.activeSessionID, id)
        XCTAssertEqual(nav.tabSessions[nav.activeTabIndex].id, id)
    }

    func testCompressionDirectorySelectionReusesBrowserWithoutChangingCompressionSession() throws {
        let nav = NavigationState()
        let browserID = nav.activeSessionID
        nav.openCompressWorkspaceTab()
        let compression = try XCTUnwrap(nav.activeTabSession)
        let target = URL(fileURLWithPath: "/navigation-owner/compression-reuse")

        nav.showDirectory(at: target)

        XCTAssertEqual(nav.activeSessionID, browserID)
        XCTAssertEqual(nav.tabSessions.count, 2)
        XCTAssertEqual(nav.tabSessions.first(where: { $0.id == compression.id }), compression)
        XCTAssertEqual(nav.activeTab, .home)
        XCTAssertFalse(nav.isCompressWorkspaceActive)
        XCTAssertEqual(nav.currentDirectory, target)
    }

    func testCompressionDirectorySelectionReplacesOnlyActiveToolWhenNoBrowserExists() throws {
        let nav = NavigationState()
        let initialID = nav.activeSessionID
        nav.openStorageInspectorTab()
        let storage = try XCTUnwrap(nav.activeTabSession)
        nav.openCompressWorkspaceTab()
        let compressionID = nav.activeSessionID
        nav.closeTab(id: initialID)
        let activeIndex = nav.activeTabIndex
        let target = URL(fileURLWithPath: "/navigation-owner/compression-replacement")

        nav.showDirectory(at: target)

        XCTAssertEqual(nav.tabSessions.count, 2)
        XCTAssertEqual(nav.activeTabIndex, activeIndex)
        XCTAssertEqual(nav.tabSessions.first(where: { $0.id == storage.id }), storage)
        XCTAssertNil(nav.tabSessions.first(where: { $0.id == compressionID }))
        XCTAssertNotEqual(nav.activeSessionID, compressionID)
        XCTAssertEqual(nav.tabSessions[activeIndex].id, nav.activeSessionID)
        XCTAssertEqual(nav.activeTabSession?.kind, .directory)
        XCTAssertEqual(nav.activeTabSession?.historyStack.current, target)
        XCTAssertEqual(nav.activeTab, .home)
    }

    func testToolDirectorySelectionClearsReusedArchiveKindAndPreservesItsIdentity() {
        let nav = NavigationState()
        let browserID = nav.activeSessionID
        nav.setArchiveForActiveTab(path: "/navigation-owner/archive.zip")
        nav.openStorageInspectorTab()
        let target = URL(fileURLWithPath: "/navigation-owner/archive-target")

        nav.showDirectory(at: target)

        XCTAssertEqual(nav.activeSessionID, browserID)
        XCTAssertEqual(nav.activeTabSession?.kind, .directory)
        XCTAssertNil(nav.activeTabSession?.customTitle)
        XCTAssertEqual(nav.currentDirectory, target)
        XCTAssertEqual(nav.activeTab, .home)
    }

    func testStaleIDsAndInvalidIndexesCannotChangeNavigationOwnership() {
        let nav = NavigationState()
        let initialID = nav.activeSessionID
        nav.openStorageInspectorTab()
        nav.closeTab(id: initialID)
        let staleID = nav.activeSessionID
        nav.showDirectory(at: URL(fileURLWithPath: "/navigation-owner/invalid-operations"))
        let sessions = nav.tabSessions
        let activeID = nav.activeSessionID
        let activeIndex = nav.activeTabIndex
        let currentDirectory = nav.currentDirectory

        for id in [staleID, UUID()] {
            nav.switchToTab(id: id)
            nav.closeTab(id: id)
            nav.updateTabURL(id: id, newURL: URL(fileURLWithPath: "/navigation-owner/rejected"))
            nav.setArchive(path: "/navigation-owner/rejected.zip", forTab: id)
            nav.clearArchive(forTab: id)
        }
        for index in [-1, sessions.count, Int.max] {
            nav.switchToTab(at: index)
            nav.closeTab(at: index)
        }

        XCTAssertEqual(nav.tabSessions, sessions)
        XCTAssertEqual(nav.activeSessionID, activeID)
        XCTAssertEqual(nav.activeTabIndex, activeIndex)
        XCTAssertEqual(nav.currentDirectory, currentDirectory)
        XCTAssertEqual(nav.activeTabSession?.id, activeID)
    }
}

extension NavigationSessionOwnershipTests {
    private func archiveLocation(_ archive: URL, subpath: String) throws -> URL {
        var components = try XCTUnwrap(URLComponents(url: archive, resolvingAgainstBaseURL: false))
        components.queryItems = [URLQueryItem(name: "subpath", value: subpath)]
        return try XCTUnwrap(components.url)
    }

    func testArchiveSubpathsHaveDistinctHistoryAndHistorySelection() throws {
        let disk = URL(fileURLWithPath: "/navigation-owner/archives", isDirectory: true)
        let archive = disk.appendingPathComponent("same archive.zip")
        let docs = try archiveLocation(archive, subpath: "docs")
        let deep = try archiveLocation(archive, subpath: "docs/deep")
        var history = WorkspaceHistoryStack(current: disk)
        XCTAssertTrue(history.push(archive))
        XCTAssertTrue(history.push(docs))
        XCTAssertTrue(history.push(deep))
        XCTAssertEqual(history.backStack, [disk, archive, docs])
        XCTAssertEqual(history.goBack(), docs)
        XCTAssertEqual(history.goForward(), deep)
        XCTAssertTrue(history.navigateToHistoryItem(archive))
        XCTAssertEqual(history.current, archive)
        XCTAssertEqual(history.goForward(), docs)
        XCTAssertEqual(history.goForward(), deep)
    }

    func testArchiveGoUpTraversesInternalParentsBeforeLeavingArchive() throws {
        let disk = URL(fileURLWithPath: "/navigation-owner/archives", isDirectory: true)
        let archive = disk.appendingPathComponent("sample.zip")
        let docs = try archiveLocation(archive, subpath: "docs")
        let deep = try archiveLocation(archive, subpath: "docs/deep")
        var history = WorkspaceHistoryStack(current: deep)
        XCTAssertTrue(history.canGoUp)
        XCTAssertEqual(history.goUp(), docs)
        XCTAssertEqual(history.goUp(), archive)
        XCTAssertEqual(history.goUp(), disk)
        var root = WorkspaceHistoryStack(current: URL(fileURLWithPath: "/", isDirectory: true))
        XCTAssertFalse(root.canGoUp)
        XCTAssertNil(root.goUp())
    }

    func testArchiveIdentityDecodesOnceAndKeepsOrdinaryDirectoriesStable() throws {
        let archive = URL(fileURLWithPath: "/navigation-owner/same archive.zip")
        let special = try archiveLocation(archive, subpath: "章节 & notes%2F/literal#?")
        var history = WorkspaceHistoryStack(current: archive)
        XCTAssertTrue(history.push(special))
        XCTAssertEqual(
            URLComponents(url: history.current, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "subpath" })?.value,
            "章节 & notes%2F/literal#?"
        )
        XCTAssertEqual(history.goUp(), try archiveLocation(archive, subpath: "章节 & notes%2F"))
        XCTAssertEqual(history.goUp(), archive)
        XCTAssertFalse(history.push(try archiveLocation(archive, subpath: "")))
        let disk = URL(fileURLWithPath: "/navigation-owner/local", isDirectory: true)
        var folders = WorkspaceHistoryStack(current: disk)
        XCTAssertFalse(folders.push(URL(fileURLWithPath: "/navigation-owner/./local", isDirectory: true)))
        let child = disk.appendingPathComponent("child", isDirectory: true)
        XCTAssertTrue(folders.push(child))
        XCTAssertEqual(folders.goUp(), disk)
        XCTAssertTrue(folders.push(disk.appendingPathComponent("other", isDirectory: true)))
        XCTAssertFalse(folders.canGoForward)
    }

    func testNavigationStatePreservesArchiveSubpathAndTabOwnership() throws {
        let nav = NavigationState()
        let disk = URL(fileURLWithPath: "/navigation-owner/archive-navigation", isDirectory: true)
        nav.showDirectory(at: disk)
        let sessionID = nav.activeSessionID
        let archive = disk.appendingPathComponent("sample.zip")
        let docs = try archiveLocation(archive, subpath: "docs")
        let deep = try archiveLocation(archive, subpath: "docs/deep")
        nav.navigateTo(archive)
        nav.navigateTo(docs)
        nav.navigateTo(deep)
        XCTAssertEqual(nav.currentDirectory, deep)
        XCTAssertEqual(nav.activeTabSession?.historyStack.current, deep)
        XCTAssertEqual(nav.activeSessionID, sessionID)
        nav.goUp()
        XCTAssertEqual(nav.currentDirectory, docs)
        nav.goUp()
        XCTAssertEqual(nav.currentDirectory, archive)
        nav.goUp()
        XCTAssertEqual(nav.currentDirectory, disk)
        nav.goBack()
        XCTAssertEqual(nav.currentDirectory, archive)
        nav.goForward()
        XCTAssertEqual(nav.currentDirectory, disk)
        XCTAssertEqual(nav.activeSessionID, sessionID)
    }
}

extension NavigationSessionOwnershipTests {
    func testHistoryPreservesAuthorityUnknownQueriesFragmentsAndArchiveIdentity() throws {
        let archive = URL(fileURLWithPath: "/navigation-owner/same.zip")
        let remote = try XCTUnwrap(URL(string: "file://server.example/navigation-owner/same.zip"))
        var history = WorkspaceHistoryStack(current: archive)
        XCTAssertTrue(history.push(remote), "A remote authority must not collapse into a local path")
        var one = try XCTUnwrap(URLComponents(url: archive, resolvingAgainstBaseURL: false))
        one.queryItems = [URLQueryItem(name: "view", value: "first")]
        let first = try XCTUnwrap(one.url)
        one.queryItems = [URLQueryItem(name: "view", value: "second")]
        let second = try XCTUnwrap(one.url)
        history = WorkspaceHistoryStack(current: first)
        XCTAssertTrue(history.push(second), "Unknown query values remain part of identity")
        one.queryItems = [URLQueryItem(name: "subpath", value: "docs")]
        one.fragment = "first"
        let firstFragment = try XCTUnwrap(one.url)
        one.fragment = "second"
        history = WorkspaceHistoryStack(current: firstFragment)
        XCTAssertTrue(history.push(try XCTUnwrap(one.url)), "Fragments must not be erased")
        history = WorkspaceHistoryStack(current: try archiveLocation(archive, subpath: "docs"))
        let other = URL(fileURLWithPath: "/navigation-owner/other.zip")
        XCTAssertTrue(history.push(try archiveLocation(other, subpath: "docs")))
        XCTAssertFalse(history.push(try archiveLocation(other, subpath: "docs/")))
        var metadata = try XCTUnwrap(URLComponents(url: other, resolvingAgainstBaseURL: false))
        metadata.queryItems = [URLQueryItem(name: "subpath", value: "docs"), URLQueryItem(name: "view", value: "another")]
        XCTAssertTrue(history.push(try XCTUnwrap(metadata.url)))
    }

    func testHistoryDoesNotResolveDuplicateSubpathsByChoosingTheFirstValue() throws {
        let archive = URL(fileURLWithPath: "/navigation-owner/same.zip")
        var components = try XCTUnwrap(URLComponents(url: archive, resolvingAgainstBaseURL: false))
        components.queryItems = [URLQueryItem(name: "subpath", value: "docs"), URLQueryItem(name: "subpath", value: "other")]
        var history = WorkspaceHistoryStack(current: try XCTUnwrap(components.url))
        XCTAssertFalse(history.canGoUp)
        XCTAssertNil(history.goUp(), "Ambiguous archive navigation must not guess a parent")
        components.queryItems = [URLQueryItem(name: "subpath", value: "docs"), URLQueryItem(name: "subpath", value: "different")]
        XCTAssertTrue(history.push(try XCTUnwrap(components.url)))
        let disk = URL(fileURLWithPath: "/navigation-owner/local", isDirectory: true)
        history = WorkspaceHistoryStack(current: disk)
        XCTAssertFalse(history.push(URL(fileURLWithPath: "/navigation-owner/local")))
    }
}
