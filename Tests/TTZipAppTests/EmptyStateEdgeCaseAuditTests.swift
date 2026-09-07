// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

@MainActor
final class EmptyStateEdgeCaseAuditTests: XCTestCase {
    
    // MARK: - EmptyFolderPlaceholderView Invariants
    
    func testEmptyFolderPlaceholderViewInstantiation() {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_empty_dir_\(UUID().uuidString)")
        var folderTriggered = false
        var fileTriggered = false
        
        let placeholder = EmptyFolderPlaceholderView(
            dirURL: tempURL,
            onTriggerNewFolder: { _ in folderTriggered = true },
            onTriggerNewFile: { _ in fileTriggered = true }
        )
        
        XCTAssertNotNil(placeholder)
        XCTAssertEqual(placeholder.dirURL, tempURL)
        
        // Trigger action closures
        placeholder.onTriggerNewFolder(tempURL)
        XCTAssertTrue(folderTriggered)
        
        placeholder.onTriggerNewFile(tempURL)
        XCTAssertTrue(fileTriggered)
    }
    
    // MARK: - SingleMillerColumnView Empty State Invariants
    
    func testSingleMillerColumnViewEmptyDirectoryRendering() {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_miller_\(UUID().uuidString)")
        
        // 1. When items is an empty list (empty directory)
        let emptyColumn = SingleMillerColumnView(
            index: 0,
            dirURL: tempURL,
            selectedPath: nil,
            currentSort: .nameAsc,
            items: [],
            currentWidth: 260,
            canGoParent: false,
            isColumnActive: true,
            multiSelectedPaths: [],
            onPrependParent: {},
            onChangeSort: { _ in },
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onSelectItem: { _, _, _, _, _ in },
            onTriggerNewFolder: { _ in },
            onTriggerNewFile: { _ in },
            onRefresh: {},
            onSelectAll: {},
            onWidthChanged: { _ in }
        )
        
        XCTAssertNotNil(emptyColumn.body)
        XCTAssertEqual(emptyColumn.items?.count, 0)
        
        // 2. When items is nil (loading state)
        let loadingColumn = SingleMillerColumnView(
            index: 0,
            dirURL: tempURL,
            selectedPath: nil,
            currentSort: .nameAsc,
            items: nil,
            currentWidth: 260,
            canGoParent: false,
            isColumnActive: true,
            multiSelectedPaths: [],
            onPrependParent: {},
            onChangeSort: { _ in },
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onSelectItem: { _, _, _, _, _ in },
            onTriggerNewFolder: { _ in },
            onTriggerNewFile: { _ in },
            onRefresh: {},
            onSelectAll: {},
            onWidthChanged: { _ in }
        )
        
        XCTAssertNotNil(loadingColumn.body)
        XCTAssertNil(loadingColumn.items)
    }
    
    // MARK: - InspectorColumnView Nil and Empty Selection Invariants
    
    func testInspectorColumnViewNilItemZenPlaceholder() {
        // When no item is selected (item == nil), InspectorColumnView must instantiate safely
        // and display the Zen empty workspace placeholder without crashing or throwing
        let nilInspector = InspectorColumnView(
            item: nil,
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onPreviewFile: { _ in }
        )
        
        XCTAssertNotNil(nilInspector.body)
        XCTAssertNil(nilInspector.item)
        XCTAssertFalse(nilInspector.isVirtualItem)
        XCTAssertNil(nilInspector.effectivePreviewURL)
        XCTAssertNil(nilInspector.effectiveModificationDate)
    }
    
    func testInspectorColumnViewWithEmptyFolder() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_empty_folder_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let itemInfo = DiskItemInfo(url: tempDir)
        XCTAssertTrue(itemInfo.isDirectory)
        
        let folderInspector = InspectorColumnView(
            item: itemInfo,
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onPreviewFile: { _ in }
        )
        
        XCTAssertNotNil(folderInspector.body)
        XCTAssertEqual(folderInspector.item?.path, tempDir.path)
    }
    
    func testInspectorColumnViewWithRegularFile() throws {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_file_\(UUID().uuidString).txt")
        try Data("Hello TTZip".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let itemInfo = DiskItemInfo(url: tempFile)
        XCTAssertFalse(itemInfo.isDirectory)
        
        let fileInspector = InspectorColumnView(
            item: itemInfo,
            onSelectArchive: { _ in },
            onCompressPath: { _ in },
            onPreviewFile: { _ in }
        )
        
        XCTAssertNotNil(fileInspector.body)
        XCTAssertEqual(fileInspector.effectivePreviewURL?.path, tempFile.path)
        XCTAssertNotNil(fileInspector.effectiveModificationDate)
    }
    
    // MARK: - FolderMediaArtboardView Empty Folder Statistics Invariants
    
    func testFolderMediaArtboardViewEmptyDirectoryCalculation() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_artboard_empty_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let itemInfo = DiskItemInfo(url: tempDir)
        let artboard = FolderMediaArtboardView(item: itemInfo, onCompressPath: { _ in })
        
        XCTAssertNotNil(artboard.body)
        
        // Calculate statistics asynchronously via static pure engine
        let (totalSize, subfolders, files, dist) = await FolderMediaArtboardView.calculateFolderStats(at: tempDir.path)
        
        XCTAssertEqual(files, 0)
        XCTAssertEqual(subfolders, 0)
        XCTAssertEqual(totalSize, 0)
        XCTAssertTrue(dist.isEmpty)
    }
}
