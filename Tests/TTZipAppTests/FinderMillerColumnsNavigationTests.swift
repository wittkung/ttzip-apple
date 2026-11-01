// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import TTZipApp
#if !SWIFT_PACKAGE
#endif
@testable import TTZipCore
#if canImport(TTZipAppServices)
#endif
#if canImport(TTZipAppViewModels)
#endif

@MainActor
final class FinderMillerColumnsNavigationTests: XCTestCase {
    
    func testIsNavigableArchiveFolder() {
        // Should return false for document/ebook compound files (keep original document boundary)
        XCTAssertFalse(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "epub", isArchive: true)))
        XCTAssertFalse(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "mobi", isArchive: true)))
        XCTAssertFalse(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "azw3", isArchive: true)))
        XCTAssertFalse(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "fb2", isArchive: true)))
        XCTAssertFalse(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "docx", isArchive: true)))
        XCTAssertFalse(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "pdf", isArchive: true)))
        
        // Should return true for navigable archives including CBZ/CBR/CB7 (.archiveBrowse contract)
        XCTAssertTrue(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "zip", isArchive: true)))
        XCTAssertTrue(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "7z", isArchive: true)))
        XCTAssertTrue(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "tar", isArchive: true)))
        XCTAssertTrue(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "cbz", isArchive: true)))
        XCTAssertTrue(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "cbr", isArchive: true)))
        XCTAssertTrue(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "cb7", isArchive: true)))
        
        // Should return false if not an archive at all
        XCTAssertFalse(FinderMillerColumnsView.isNavigableArchiveFolder(createMockInfo(ext: "txt", isArchive: false)))
    }
    
    func testSelectEPUBDoesNotAppendChildColumn() {
        let initialPaths = [URL(fileURLWithPath: "/tmp")]
        let epubItem = createMockInfo(ext: "epub", isArchive: true)
        
        let nextPaths = FinderMillerColumnsView.nextColumnPaths(
            currentPaths: initialPaths,
            columnIndex: 0,
            item: epubItem
        )
        
        // columnPaths should remain just the root since epub is not navigable
        XCTAssertEqual(nextPaths.count, 1)
        XCTAssertEqual(nextPaths, initialPaths)
    }
    
    func testSelectZIPDoesAppendChildColumn() {
        let initialPaths = [URL(fileURLWithPath: "/tmp")]
        let zipItem = createMockInfo(ext: "zip", isArchive: true)
        
        let nextPaths = FinderMillerColumnsView.nextColumnPaths(
            currentPaths: initialPaths,
            columnIndex: 0,
            item: zipItem
        )
        
        // columnPaths should increase by 1 since zip is navigable
        XCTAssertEqual(nextPaths.count, 2)
        XCTAssertEqual(nextPaths[0], initialPaths[0])
        XCTAssertEqual(nextPaths[1].path, "/tmp/test.zip")
    }

    func testSelectCBZAndCBRDoesAppendChildColumn() {
        let initialPaths = [URL(fileURLWithPath: "/tmp")]
        for ext in ["cbz", "cbr"] {
            let comicArchiveItem = createMockInfo(ext: ext, isArchive: true)
            let nextPaths = FinderMillerColumnsView.nextColumnPaths(
                currentPaths: initialPaths,
                columnIndex: 0,
                item: comicArchiveItem
            )
            XCTAssertEqual(nextPaths.count, 2, "\(ext.uppercased()) should append a child column for archive browsing")
            XCTAssertEqual(nextPaths[0], initialPaths[0])
            XCTAssertEqual(nextPaths[1].path, "/tmp/test.\(ext)")
        }
    }
    
    func testAcceptedArchiveRestoresParentRootAndInternalColumns() throws {
        let projection = makeAcceptedProjection()
        let current = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
            archivePath: projection.archivePath, entrySubpath: "docs/deep"
        ))
        let paths = try XCTUnwrap(FinderMillerColumnsView.restoredArchiveColumnPaths(
            location: current, projection: projection,
            preserving: [URL(fileURLWithPath: "/tmp"), URL(fileURLWithPath: "/tmp/miller-owner")]
        ))
        XCTAssertEqual(paths.count, 5)
        XCTAssertEqual(paths[0].path, "/tmp")
        XCTAssertEqual(paths[1].path, "/tmp/miller-owner")
        XCTAssertEqual(paths.dropFirst(2).map { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "subpath" })?.value
        }, ["", "docs", "docs/deep"])
    }

    func testArchiveRestorationWithoutExistingColumnsKeepsPhysicalParent() throws {
        let projection = makeAcceptedProjection()
        let paths = try XCTUnwrap(FinderMillerColumnsView.restoredArchiveColumnPaths(
            location: URL(fileURLWithPath: projection.archivePath),
            projection: projection, preserving: []
        ))
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0].path, "/tmp/miller-owner")
        XCTAssertEqual(URLComponents(url: paths[1], resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "subpath", value: "")])
    }

    func testArchiveProjectionDoesNotClassifyAnUnacceptedZipByExtension() throws {
        let ordinary = URL(fileURLWithPath: "/tmp/not-accepted.zip")
        XCTAssertNil(FinderMillerColumnsView.restoredArchiveColumnPaths(
            location: ordinary, projection: nil, preserving: []
        ))
        let ambiguous = try XCTUnwrap(URL(string: "file:///tmp/miller-owner/catalog.zip?subpath=docs&subpath=other"))
        XCTAssertNil(FinderMillerColumnsView.restoredArchiveColumnPaths(
            location: ambiguous, projection: makeAcceptedProjection(), preserving: []
        ))
        let remote = try XCTUnwrap(URL(string: "file://server.example/tmp/miller-owner/catalog.zip?subpath=docs"))
        XCTAssertNil(FinderMillerColumnsView.restoredArchiveColumnPaths(
            location: remote, projection: makeAcceptedProjection(), preserving: []
        ))
        for query in ["subpath=../", "subpath=/docs", "subpath=docs//deep", "subpath=docs&extra=1", "subpath=docs#section"] {
            let invalid = try XCTUnwrap(URL(string: "file:///tmp/miller-owner/catalog.zip?" + query))
            XCTAssertNil(FinderMillerColumnsView.restoredArchiveColumnPaths(
                location: invalid, projection: nil, preserving: []
            ), query)
        }
    }

    func testVirtualArchiveFileDoesNotOpenAnotherUnacceptedArchiveColumn() throws {
        let url = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
            archivePath: "/tmp/miller-owner/catalog.zip", entrySubpath: "inner.zip"
        ))
        let item = DiskItemInfo(
            virtualName: "inner.zip", virtualURL: url, isDirectory: false,
            isArchive: true, sizeText: "", rawSizeBytes: 0, kindText: "ZIP"
        )
        let parent = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
            archivePath: "/tmp/miller-owner/catalog.zip", entrySubpath: ""
        ))
        XCTAssertEqual(FinderMillerColumnsView.nextColumnPaths(
            currentPaths: [parent], columnIndex: 0, item: item
        ), [parent])
    }

    func testAcceptedProjectionListsImplicitAndEmptyDirectoriesWithoutArchiveFile() async throws {
        let projection = makeAcceptedProjection()
        let root = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
            archivePath: projection.archivePath, entrySubpath: ""
        ))
        let listed = await MillerColumnDirectoryScanner.loadAcceptedArchiveContents(
            dirURL: root, sortOption: .nameAsc, projection: projection
        )
        let rootItems = try XCTUnwrap(listed)
        XCTAssertEqual(Set(rootItems.map(\.name)), Set(["docs", "empty", "中文&+#?%", "inner.zip"]))
        let special = try XCTUnwrap(rootItems.first(where: { $0.name == "中文&+#?%" }))
        let expected = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
            archivePath: projection.archivePath, entrySubpath: "中文&+#?%"
        ))
        XCTAssertEqual(special.path, expected.absoluteString)
        let children = await MillerColumnDirectoryScanner.loadAcceptedArchiveContents(
            dirURL: expected, sortOption: .nameAsc, projection: projection
        )
        XCTAssertEqual(try XCTUnwrap(children).map(\.name), ["README.md"])
        let empty = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
            archivePath: projection.archivePath, entrySubpath: "empty"
        ))
        let emptyItems = await MillerColumnDirectoryScanner.loadAcceptedArchiveContents(
            dirURL: empty, sortOption: .nameAsc, projection: projection
        )
        XCTAssertEqual(try XCTUnwrap(emptyItems).count, 0)
    }

    func testRestoredSpecialDirectoryUsesExistingVirtualURLIdentity() throws {
        let projection = makeAcceptedProjection()
        let expected = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
            archivePath: projection.archivePath, entrySubpath: "中文&+#?%"
        ))
        let paths = try XCTUnwrap(FinderMillerColumnsView.restoredArchiveColumnPaths(
            location: expected, projection: projection, preserving: []
        ))
        XCTAssertEqual(paths.last?.absoluteString, expected.absoluteString)
    }

    func testSharedArchiveSubpathBoundaryRoundTripsEncodedNamesAndRejectsAmbiguity() throws {
        for (input, expected) in [("", ""), ("docs/deep", "docs/deep"),
                                  ("中文&%#/内目录", "中文&%#/内目录"), ("docs/", "docs")] {
            let location = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
                archivePath: "/tmp/miller-owner/catalog.zip", entrySubpath: input
            ))
            XCTAssertEqual(AcceptedArchiveDirectoryProjection.archiveSubpath(in: location), expected)
        }
        for raw in [
            "file:///tmp/a.zip?subpath=docs&subpath=other",
            "file:///tmp/a.zip?subpath=docs&extra=1",
            "file://server.example/tmp/a.zip?subpath=docs",
            "file:///tmp/a.zip?subpath=docs#section",
            "file:///tmp/a.zip?subpath=../docs",
            "file:///tmp/a.zip?subpath=docs//deep",
            "file:///tmp/a.zip?subpath=docs/./deep",
            "file:///tmp/a.zip?subpath=/docs"
        ] {
            let location = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(AcceptedArchiveDirectoryProjection.archiveSubpath(in: location), raw)
        }
    }

    func testVirtualDragProvidersExposeNamesWithoutFileURLRepresentations() throws {
        for subpath in ["", "docs/manual.pdf"] {
            let location = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
                archivePath: "/tmp/miller-owner/catalog.zip", entrySubpath: subpath
            ))
            let name = subpath.isEmpty ? "catalog.zip" : "manual.pdf"
            let item = DiskItemInfo(
                virtualName: name, virtualURL: location, isDirectory: subpath.isEmpty,
                isArchive: false, sizeText: "", rawSizeBytes: 0, kindText: ""
            )
            let provider = MillerColumnItemRowView.makeDragItemProvider(for: item)
            XCTAssertEqual(provider.suggestedName, name)
            XCTAssertFalse(provider.canLoadObject(ofClass: URL.self), subpath)
            XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), subpath)
        }
    }

    func testPhysicalDragProviderLoadsTheOriginalFileIdentity() async throws {
        let file = URL(fileURLWithPath: "/tmp/miller-owner/notes#draft.txt")
        let item = DiskItemInfo(url: file, isDirectory: false)
        let provider = MillerColumnItemRowView.makeDragItemProvider(for: item)
        XCTAssertTrue(provider.canLoadObject(ofClass: URL.self))
        let loaded: URL = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let value {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }
        XCTAssertEqual(loaded, file)
    }

    func testDropSourceValidationPreservesTheFullURLIdentity() throws {
        for raw in ["file:///tmp/source.txt", "file://localhost/tmp/source.txt", "file:///tmp/notes%23draft.txt"] {
            XCTAssertTrue(MillerColumnItemRowView.isPhysicalDropSource(try XCTUnwrap(URL(string: raw))), raw)
        }
        for raw in [
            "file:///tmp/catalog.zip?subpath=entry.txt", "file:///tmp/catalog.zip?subpath=",
            "file:///tmp/source.txt?", "file:///tmp/source.txt#section",
            "file://server.example/tmp/source.txt", "file://user:secret@localhost/tmp/source.txt",
            "file://localhost:123/tmp/source.txt", "https://example.test/source.txt"
        ] {
            XCTAssertFalse(MillerColumnItemRowView.isPhysicalDropSource(try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testPasteDestinationCannotEscapeAnArchiveIntoItsPhysicalAncestor() throws {
        let parent = URL(fileURLWithPath: "/tmp/miller-owner", isDirectory: true)
        let archive = try XCTUnwrap(AppViewState.makeArchiveEntryVirtualURL(
            archivePath: parent.appendingPathComponent("catalog.zip").path, entrySubpath: "docs"
        ))
        let ancestor = DiskItemInfo(url: URL(fileURLWithPath: "/tmp", isDirectory: true), isDirectory: true)
        XCTAssertNil(FinderMillerColumnsView.physicalPasteDestination(
            ownerLocation: archive, activeColumn: parent, selectedItem: ancestor
        ))
        XCTAssertNil(FinderMillerColumnsView.physicalPasteDestination(
            ownerLocation: parent, activeColumn: archive, selectedItem: nil
        ))
        let virtualSelection = DiskItemInfo(
            virtualName: "docs", virtualURL: archive, isDirectory: true,
            isArchive: false, sizeText: "", rawSizeBytes: 0, kindText: ""
        )
        XCTAssertNil(FinderMillerColumnsView.physicalPasteDestination(
            ownerLocation: parent, activeColumn: parent, selectedItem: virtualSelection
        ))
        XCTAssertEqual(FinderMillerColumnsView.physicalPasteDestination(
            ownerLocation: parent, activeColumn: parent, selectedItem: ancestor
        ), parent)
        let childURL = parent.appendingPathComponent("destination", isDirectory: true)
        let child = DiskItemInfo(url: childURL, isDirectory: true)
        XCTAssertTrue(child.isDirectory, "The model must preserve the supplied directory fact without stat.")
        XCTAssertEqual(FinderMillerColumnsView.physicalPasteDestination(
            ownerLocation: parent, activeColumn: parent, selectedItem: child
        ), childURL)
        XCTAssertEqual(FinderMillerColumnsView.physicalPasteDestination(
            ownerLocation: parent, activeColumn: parent, selectedItem: nil
        ), parent)
    }

    func testExplicitDirectoryFactsAreNotReplacedByDiskClassification() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MillerDirectoryFacts-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("entry.txt")
        let data = Data("directory fact fixture".utf8)
        try data.write(to: file)

        XCTAssertTrue(DiskItemInfo(url: directory).isDirectory)
        XCTAssertFalse(DiskItemInfo(url: file).isDirectory)
        XCTAssertFalse(DiskItemInfo(url: directory, isDirectory: false).isDirectory,
                       "Explicit false must survive even when the current disk item is a directory.")
        XCTAssertTrue(DiskItemInfo(url: file, isDirectory: true).isDirectory,
                      "Explicit true must survive even when the current disk item is a file.")
    }

    func testPhysicalPreviewEntryPreservesTheRealFileSize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MillerPhysicalPreview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        let data = Data("physical preview metadata must retain the real byte count".utf8)
        try data.write(to: file)
        let state = AppViewState(fileViewer: NoOpFileViewer())
        defer { state.prepareForWindowClose() }

        state.previewMediaFile(path: file.path)

        XCTAssertEqual(state.immersiveMediaItem?.url.resolvingSymlinksInPath(), file.resolvingSymlinksInPath())
        XCTAssertEqual(state.immersiveMediaItem?.fileSizeBytes, Int64(data.count))
    }

    func testSingleMillerColumnForwardsRowDoubleClickAndDirectoryArchiveRemainIdempotent() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleColumnDoubleClick-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let txtURL = tempDir.appendingPathComponent("column_row.txt")
        try Data("column test".utf8).write(to: txtURL)
        let subDirURL = tempDir.appendingPathComponent("SubFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: subDirURL, withIntermediateDirectories: true)
        let zipURL = tempDir.appendingPathComponent("sample.zip")
        try Data([0x50, 0x4B, 0x05, 0x06]).write(to: zipURL)

        let txtItem = DiskItemInfo(url: txtURL, isDirectory: false)
        let dirItem = DiskItemInfo(url: subDirURL, isDirectory: true)
        let zipItem = DiskItemInfo(
            path: zipURL.path,
            name: "sample.zip",
            displayName: "sample.zip",
            isDirectory: false,
            isArchive: true,
            sizeText: "4 B",
            rawSizeBytes: 4,
            kindText: "ZIP"
        )

        var activatedItems: [String] = []
        let column = SingleMillerColumnView(
            index: 0,
            dirURL: tempDir,
            selectedPath: nil,
            currentSort: .nameAsc,
            items: [txtItem],
            canGoParent: false,
            multiSelectedPaths: [],
            onPrependParent: {},
            onChangeSort: { _ in },
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onSelectItem: { _, _, _, _, _ in },
            onActivateItem: { item, _, _ in
                activatedItems.append(item.path)
            },
            onTriggerNewFolder: { _ in },
            onTriggerNewFile: { _ in },
            onRefresh: {},
            onSelectAll: {},
            onWidthChanged: { _ in }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: column.frame(width: 260, height: 180))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 180)
        window.contentView = host
        defer {
            NativeContextMenuBridgeView.testSimulatedCurrentEvent = nil
            window.contentView = nil
            window.close()
        }
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        host.layoutSubtreeIfNeeded()

        let bridges = findContextMenuBridges(in: host)
        let rowBridge = try XCTUnwrap(bridges.first, "SingleMillerColumnView must host a NativeContextMenuBridgeView for its row")
        XCTAssertNotNil(rowBridge.onDoubleClick, "SingleMillerColumnView must wire onActivateItem into row's onDoubleClick")

        let rowCenterInWindow = rowBridge.convert(NSPoint(x: rowBridge.bounds.midX, y: rowBridge.bounds.midY), to: nil)
        let doubleDown = try makeMouseEvent(type: .leftMouseDown, location: rowCenterInWindow, clickCount: 2, windowNumber: window.windowNumber)
        NativeContextMenuBridgeView.testSimulatedCurrentEvent = doubleDown
        rowBridge.mouseDown(with: doubleDown)
        XCTAssertEqual(activatedItems, [txtItem.path])

        // Directory and navigable archive double-click must never call FileViewerService.openFile.
        let mockViewer = MockFileViewerHarness()
        let state = AppViewState(fileViewer: mockViewer)
        defer { state.prepareForWindowClose() }
        let dirActivated = await state.activateExplorerItem(dirItem, createAppKitWindow: false)
        XCTAssertFalse(dirActivated, "Directories are navigated in Miller columns, not opened via activateExplorerItem")
        _ = await state.activateExplorerItem(zipItem, createAppKitWindow: false)
        XCTAssertTrue(mockViewer.openedURLs.isEmpty, "Navigable archive double-click must open as Miller folder, never external NSWorkspace")
    }

    // MARK: - Helpers

    func createHarmlessAppBundle(in parentDir: URL, name: String) throws -> URL {
        let appURL = parentDir.appendingPathComponent(name, isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.metastudyline.test.sample</string>
            <key>CFBundleName</key>
            <string>Sample</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try Data(infoPlist.utf8).write(to: contentsURL.appendingPathComponent("Info.plist"))
        return appURL
    }

    private func makeAcceptedProjection() -> AcceptedArchiveDirectoryProjection {
        let entries = [
            ArchiveEntry(path: "docs/deep/README.md", uncompressedSize: 5, isDirectory: false),
            ArchiveEntry(path: "empty/", uncompressedSize: 0, isDirectory: true),
            ArchiveEntry(path: "中文&+#?%/README.md", uncompressedSize: 5, isDirectory: false),
            ArchiveEntry(path: "inner.zip", uncompressedSize: 10, isDirectory: false)
        ]
        return AcceptedArchiveDirectoryProjection(inspection: ArchiveInspectionResult(
            archivePath: "/tmp/miller-owner/catalog.zip", entries: entries,
            treeNode: ArchiveComponentTreeBuilder.buildTree(from: entries),
            securityReport: SecurityReport(
                isSafe: true, suspiciousFileNames: [], hasZipSlipRisk: false,
                detailMessage: "", riskLevel: .safe
            )
        ))
    }


    private func createMockInfo(ext: String, isArchive: Bool) -> DiskItemInfo {
        return DiskItemInfo(
            virtualName: "test.\(ext)",
            virtualURL: URL(fileURLWithPath: "/tmp/test.\(ext)"),
            isDirectory: false,
            isArchive: isArchive,
            sizeText: "10 KB",
            rawSizeBytes: 10240,
            kindText: ext.uppercased()
        )
    }
}
