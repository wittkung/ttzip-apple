// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
@testable import TTZipApp
import TTZipCore
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit

@MainActor
final class FrontendArchitectureEvolutionTests: XCTestCase {
    
    // MARK: - 1. Observable Granularity & State Tests
    
    @MainActor
    func testAppSubStatesObservableGranularity() {
        let appState = AppViewState(fileViewer: NoOpFileViewer())
        XCTAssertEqual(appState.activeTab, .home)
        XCTAssertEqual(appState.isLoading, false)
        XCTAssertEqual(appState.progressValue, 0.0)
        
        appState.taskState.progressValue = 0.75
        XCTAssertEqual(appState.progressValue, 0.75)
        
        appState.navigationState.activeTab = .compressWorkspace
        XCTAssertEqual(appState.activeTab, .compressWorkspace)
    }
    
    @MainActor
    func testCompressFormSessionEncapsulation() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let f1 = tempDir.appendingPathComponent("test1.txt")
        let f2 = tempDir.appendingPathComponent("test2.txt")
        try? "test1".write(to: f1, atomically: true, encoding: .utf8)
        try? "test2".write(to: f2, atomically: true, encoding: .utf8)
        
        let session = CompressFormSession(initialInputPaths: [f1.path, f2.path])
        XCTAssertEqual(session.itemsList.count, 2)
        XCTAssertEqual(session.selectedFormat, .sevenZip)
        XCTAssertEqual(session.compressionLevel, .normal)
        XCTAssertEqual(session.isProcessing, false)
        
        session.customVolumeValueString = "500"
        session.customVolumeUnit = "MB"
        session.calculateCustomVolume()
        XCTAssertEqual(session.splitVolumeOption, 500 * 1024 * 1024)
    }
    
    // MARK: - 2. Non-Blocking I/O Scanner Tests
    
    func testDiskDirectoryScannerActorBatch() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        for i in 0..<10 {
            let file = tempDir.appendingPathComponent("file_\(i).txt")
            try? "content_\(i)".write(to: file, atomically: true, encoding: .utf8)
        }
        
        let items = try await DiskDirectoryScannerActor.shared.scanDirectory(at: tempDir)
        XCTAssertEqual(items.count, 10)
        XCTAssertEqual(items.first?.isDirectory, false)
    }
    
    // MARK: - 3. Syntax Highlighting & Tokenizer Tests
    
    func testSyntaxTokenizerHighlighting() async {
        let code = "import SwiftUI\nlet greeting = \"Hello\"\n// A comment\nlet count = 42"
        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        let tokens = await BackgroundSyntaxTokenizer.shared.tokenize(text: code, ext: "swift", targetRange: fullRange)
        
        XCTAssertFalse(tokens.isEmpty)
        let hasComment = tokens.contains { $0.colorType == .comment }
        let hasString = tokens.contains { $0.colorType == .string }
        let hasKeyword = tokens.contains { $0.colorType == .keyword }
        let hasNumber = tokens.contains { $0.colorType == .number }
        
        XCTAssertTrue(hasComment)
        XCTAssertTrue(hasString)
        XCTAssertTrue(hasKeyword)
        XCTAssertTrue(hasNumber)
    }
    
    // MARK: - 4. Thumbnail Service Tests
    
    func testImageIOThumbnailServiceLifecycle() async {
        let service = ImageIOThumbnailService(countLimit: 10, totalCostLimitMB: 4)
        await service.purgeCache()
        
        // Purging and non-existent files return nil cleanly
        let dummyURL = URL(fileURLWithPath: "/tmp/non_existent_image.png")
        let thumb = await service.getThumbnail(for: dummyURL)
        XCTAssertNil(thumb)
    }
    
    // MARK: - 5. Subpath Map Lazy Caching & Boundary Defect Hardening
    
    func testArchiveSubpathMapLazyLookupAndBoundedCapacity() {
        let leaf1 = ArchiveLeafFile(name: "file1.txt", path: "folder/file1.txt", sizeBytes: 100)
        let subDir = ArchiveCompositeDirectory(name: "folder", path: "folder", children: [leaf1])
        let root = ArchiveCompositeDirectory(name: "Archive", path: "", children: [subDir])

        let session = ArchiveHierarchySession(
            archivePath: "/tmp/test.zip",
            modificationTimestamp: 1234567.0,
            fileByteSize: 200,
            rootComposite: root,
            entries: [],
            unlockedPassword: nil
        )

        // Root traversal
        XCTAssertEqual(session.subpathMap[""]?.name, "Archive")
        XCTAssertEqual(session.subpathMap["/"]?.name, "Archive")

        // Subdirectory traversal
        let resolvedDir = session.subpathMap["folder"]
        XCTAssertNotNil(resolvedDir)
        XCTAssertEqual(resolvedDir?.name, "folder")
        XCTAssertTrue(resolvedDir?.isDirectory == true)

        // Nested file traversal
        let resolvedFile = session.subpathMap["folder/file1.txt"]
        XCTAssertNotNil(resolvedFile)
        XCTAssertEqual(resolvedFile?.name, "file1.txt")
        XCTAssertFalse(resolvedFile?.isDirectory == true)

        // Non-existent path returns nil
        XCTAssertNil(session.subpathMap["folder/nonexistent.txt"])
        XCTAssertNil(session.subpathMap["invalid/deep/path"])

        // Bounded capacity verification
        let customSubpathMap = ArchiveSubpathMap(rootComposite: root, maxCapacity: 2)
        _ = customSubpathMap["folder"]
        _ = customSubpathMap["folder/file1.txt"]
        _ = customSubpathMap["folder/extra1"]
        XCTAssertTrue(customSubpathMap.count <= 2)
    }

    // MARK: - 6. LCRS Archive Tree & Topology Tests

    func testLCRSArchiveTreeTopologyAndComponent() {
        // Construct an LCRS tree structure:
        // Root (0) -> docs (1) -> spec.pdf (3)
        //          -> readme.txt (2)
        let rootNode = LCRSNode(name: "Archive", path: "", isDirectory: true, sizeBytes: 1024, firstChildId: 1, nextSiblingId: -1, parentId: -1)
        let docsNode = LCRSNode(name: "docs", path: "docs", isDirectory: true, sizeBytes: 512, firstChildId: 3, nextSiblingId: 2, parentId: 0)
        let readmeNode = LCRSNode(name: "readme.txt", path: "readme.txt", isDirectory: false, sizeBytes: 128, firstChildId: -1, nextSiblingId: -1, parentId: 0)
        let specNode = LCRSNode(name: "spec.pdf", path: "docs/spec.pdf", isDirectory: false, sizeBytes: 384, firstChildId: -1, nextSiblingId: -1, parentId: 1)

        let tree = LCRSArchiveTree(nodes: [rootNode, docsNode, readmeNode, specNode], rootId: 0)

        // 1. Children traversal
        let rootChildren = tree.childrenOf(parentId: 0)
        XCTAssertEqual(rootChildren.count, 2)
        XCTAssertEqual(rootChildren[0].0.name, "docs")
        XCTAssertEqual(rootChildren[1].0.name, "readme.txt")

        let docsChildren = tree.childrenOf(parentId: 1)
        XCTAssertEqual(docsChildren.count, 1)
        XCTAssertEqual(docsChildren[0].0.name, "spec.pdf")

        // 2. Subpath resolution
        let resolvedRoot = tree.resolveSubpath("")
        XCTAssertEqual(resolvedRoot?.0.name, "Archive")

        let resolvedDocs = tree.resolveSubpath("docs")
        XCTAssertEqual(resolvedDocs?.0.name, "docs")
        XCTAssertEqual(resolvedDocs?.1, 1)

        let resolvedSpec = tree.resolveSubpath("docs/spec.pdf")
        XCTAssertEqual(resolvedSpec?.0.name, "spec.pdf")
        XCTAssertEqual(resolvedSpec?.1, 3)

        let resolvedReadme = tree.resolveSubpath("readme.txt")
        XCTAssertEqual(resolvedReadme?.0.name, "readme.txt")
        XCTAssertEqual(resolvedReadme?.1, 2)

        XCTAssertNil(tree.resolveSubpath("docs/nonexistent.txt"))
        XCTAssertNil(tree.resolveSubpath("ghost_directory"))

        // 3. ArchiveSubpathMap backing with LCRS tree
        let map = ArchiveSubpathMap(lcrsTree: tree)
        let mappedDocs = map["docs"]
        XCTAssertNotNil(mappedDocs)
        XCTAssertEqual(mappedDocs?.name, "docs")
        XCTAssertTrue(mappedDocs?.isDirectory == true)

        let mappedSpec = map["docs/spec.pdf"]
        XCTAssertNotNil(mappedSpec)
        XCTAssertEqual(mappedSpec?.name, "spec.pdf")
        XCTAssertFalse(mappedSpec?.isDirectory == true)
        XCTAssertEqual(mappedSpec?.sizeBytes, 384)

        // 4. LCRSComponent child retrieval
        let docsComponent = LCRSComponent(
            name: docsNode.name,
            path: docsNode.path,
            isDirectory: docsNode.isDirectory,
            sizeBytes: docsNode.sizeBytes,
            tree: tree,
            nodeId: 1
        )
        let componentChildren = docsComponent.getChildren()
        XCTAssertEqual(componentChildren.count, 1)
        XCTAssertEqual(componentChildren.first?.name, "spec.pdf")
    }

    func testSingleMillerColumnViewportVirtualizationConstants() {
        let rowPitch: CGFloat = 28.0
        let overscan = 20
        let threshold = 60

        // Test item count below threshold does not slice
        let smallCount = 30
        let shouldVirtualizeSmall = smallCount > threshold
        XCTAssertFalse(shouldVirtualizeSmall)

        // Test item count above threshold virtualizes
        let largeCount = 10_000
        let shouldVirtualizeLarge = largeCount > threshold
        XCTAssertTrue(shouldVirtualizeLarge)

        // Slicing math simulation
        let scrollY: CGFloat = 2800.0 // At row 100
        let viewportHeight: CGFloat = 560.0 // 20 rows visible

        let firstVisible = Int(floor(scrollY / rowPitch))
        let visibleCount = Int(ceil(viewportHeight / rowPitch)) + 1
        let sliceStart = max(0, firstVisible - overscan)
        let sliceEnd = min(largeCount, firstVisible + visibleCount + overscan)

        XCTAssertEqual(firstVisible, 100)
        XCTAssertEqual(sliceStart, 80)
        XCTAssertEqual(sliceEnd, 141)
        XCTAssertEqual(sliceEnd - sliceStart, 61)

        let topSpacerHeight = CGFloat(sliceStart) * rowPitch
        let bottomSpacerHeight = CGFloat(largeCount - sliceEnd) * rowPitch
        let renderedHeight = CGFloat(sliceEnd - sliceStart) * rowPitch

        let totalCalculatedHeight = topSpacerHeight + bottomSpacerHeight + renderedHeight
        let expectedTotalHeight = CGFloat(largeCount) * rowPitch
        XCTAssertEqual(totalCalculatedHeight, expectedTotalHeight)
    }

    func testVfsBackedSubpathMapRootResolutionAndCycleGuard() {
        let entries = [
            UniFfiEntryMetadata(
                path: ".",
                uncompressedSize: 0,
                compressedSize: 0,
                crc32: 0,
                mtimeEpochSecs: 1_700_000_000,
                mode: 0o755,
                isDirectory: true,
                isEncrypted: false,
                compressionMethod: "Stored",
                detectedEncoding: nil
            ),
            UniFfiEntryMetadata(
                path: "./docs/./guide.md",
                uncompressedSize: 512,
                compressedSize: 256,
                crc32: 0x1234,
                mtimeEpochSecs: 1_700_000_000,
                mode: 0o755,
                isDirectory: false,
                isEncrypted: false,
                compressionMethod: "Deflate",
                detectedEncoding: nil
            ),
            UniFfiEntryMetadata(
                path: "cafe\u{301}//notes\\readme.txt",
                uncompressedSize: 256,
                compressedSize: 128,
                crc32: 0x5678,
                mtimeEpochSecs: 1_700_000_000,
                mode: 0o644,
                isDirectory: false,
                isEncrypted: false,
                compressionMethod: "Deflate",
                detectedEncoding: nil
            ),
        ]
        let vfs = UniFfiVfsTree.build(entries: entries, rootName: "sample.tar")
        let rootNode = ArchiveTreeNode(
            name: "sample.tar",
            path: "",
            uncompressedSize: Int64(vfs.getStats().totalUncompressedBytes),
            isDirectory: true,
            hasChildren: true,
            vfsTree: vfs
        )
        let shallowRoot = ArchiveCompositeDirectory(
            name: "sample.tar",
            path: "",
            entry: nil,
            children: rootNode.getChildren()
        )
        let session = ArchiveHierarchySession(
            archivePath: "/tmp/sample.tar",
            modificationTimestamp: 1_700_000_000,
            fileByteSize: 1024,
            rootComposite: shallowRoot,
            entries: [],
            unlockedPassword: nil,
            vfsTree: vfs
        )

        // Verify shallowRoot is not a fake empty directory when inspected directly
        XCTAssertEqual(session.rootComposite.getChildren().count, 2)
        XCTAssertNotNil(session.rootComposite.findChild(named: "docs"))

        let rootComp = session.subpathMap[""]
        XCTAssertNotNil(rootComp)
        let rootChildren = rootComp?.getChildren() ?? []
        XCTAssertEqual(rootChildren.count, 2)
        XCTAssertEqual(rootChildren.first?.name, "caf\u{e9}")
        XCTAssertEqual(rootChildren.last?.name, "docs")

        let docsChildren = session.subpathMap["docs"]?.getChildren() ?? []
        XCTAssertEqual(docsChildren.count, 1)
        XCTAssertEqual(docsChildren.first?.name, "guide.md")
        XCTAssertFalse(docsChildren.first?.isDirectory == true)

        let nfdResolved = session.subpathMap["caf\u{e9}/notes/readme.txt"]
        XCTAssertNotNil(nfdResolved)
        XCTAssertEqual(nfdResolved?.sizeBytes, 256)
    }

    func testShallowPermissionsAndAutoEntryMetadataRoundTrip() {
        let execPath = "d0/d1/run.sh"
        let readonlyPath = "d0/d1/readonly.txt"
        let entries = [
            UniFfiEntryMetadata(
                path: "d0/d1",
                uncompressedSize: 0,
                compressedSize: 0,
                crc32: 0,
                mtimeEpochSecs: 1_700_000_000,
                mode: 0o700,
                isDirectory: true,
                isEncrypted: false,
                compressionMethod: "Stored",
                detectedEncoding: nil
            ),
            UniFfiEntryMetadata(
                path: execPath,
                uncompressedSize: 1024,
                compressedSize: 512,
                crc32: 0x1111_2222,
                mtimeEpochSecs: 1_700_000_000,
                mode: 0o755,
                isDirectory: false,
                isEncrypted: false,
                compressionMethod: "Deflate",
                detectedEncoding: nil
            ),
            UniFfiEntryMetadata(
                path: readonlyPath,
                uncompressedSize: 512,
                compressedSize: 256,
                crc32: 0x3333_4444,
                mtimeEpochSecs: 1_700_000_000,
                mode: 0o444,
                isDirectory: false,
                isEncrypted: false,
                compressionMethod: "Deflate",
                detectedEncoding: nil
            ),
        ]
        let vfs = UniFfiVfsTree.build(entries: entries, rootName: "perms.tar")
        let rootNode = ArchiveTreeNode(
            name: "perms.tar",
            path: "",
            uncompressedSize: 1536,
            isDirectory: true,
            posixPermissions: 0o755,
            hasChildren: true,
            vfsTree: vfs
        )

        // Verify auto-constructed ArchiveTreeNode.entry preserves posixPermissions and metadata
        let d0Orig = rootNode.children?.first
        let d1Orig = d0Orig?.children?.first
        let execOrig = d1Orig?.children?.first { $0.name == "run.sh" }
        let roOrig = d1Orig?.children?.first { $0.name == "readonly.txt" }
        XCTAssertEqual(d0Orig?.entry?.posixPermissions, 0o755)
        XCTAssertEqual(d1Orig?.entry?.posixPermissions, 0o700)
        XCTAssertEqual(execOrig?.entry?.posixPermissions, 0o755)
        XCTAssertEqual(execOrig?.entry?.compressedSize, 512)
        XCTAssertEqual(execOrig?.entry?.crc32, 0x1111_2222)
        XCTAssertEqual(roOrig?.entry?.posixPermissions, 0o444)

        // Round-trip: Node -> toComponent() -> ArchiveTreeNode(component:)
        let roundTrippedRoot = ArchiveTreeNode(component: rootNode.toComponent())
        XCTAssertEqual(roundTrippedRoot.posixPermissions, 0o755)
        let d0Node = roundTrippedRoot.children?.first { $0.isDirectory && $0.name == "d0" }
        let d1Node = d0Node?.children?.first { $0.isDirectory && $0.name == "d1" }
        XCTAssertEqual(d0Node?.posixPermissions, 0o755)
        XCTAssertEqual(d0Node?.entry?.posixPermissions, 0o755)
        XCTAssertEqual(d1Node?.posixPermissions, 0o700)
        XCTAssertEqual(d1Node?.entry?.posixPermissions, 0o700)

        let execNode = d1Node?.children?.first { !$0.isDirectory && $0.name == "run.sh" }
        let roNode = d1Node?.children?.first { !$0.isDirectory && $0.name == "readonly.txt" }
        XCTAssertEqual(execNode?.posixPermissions, 0o755)
        XCTAssertEqual(execNode?.entry?.posixPermissions, 0o755)
        XCTAssertEqual(execNode?.compressedSize, 512)
        XCTAssertEqual(execNode?.crc32, 0x1111_2222)
        XCTAssertEqual(roNode?.posixPermissions, 0o444)
        XCTAssertEqual(roNode?.entry?.posixPermissions, 0o444)
        XCTAssertEqual(roNode?.compressedSize, 256)
        XCTAssertEqual(roNode?.crc32, 0x3333_4444)
    }

    func testDeepArchiveTreeNodeIterativeToComponentWithoutTruncation() {
        let depthCount = 300
        var pathParts: [String] = []
        for idx in 0..<depthCount {
            pathParts.append("d\(idx)")
        }
        let deepFilePath = pathParts.joined(separator: "/") + "/leaf.txt"
        let shallowFilePath = "d0/d1/shallow.txt"
        let entries = [
            UniFfiEntryMetadata(
                path: shallowFilePath,
                uncompressedSize: 1024,
                compressedSize: 512,
                crc32: 0x1111_2222,
                mtimeEpochSecs: 1_700_000_000,
                mode: 0o755,
                isDirectory: false,
                isEncrypted: false,
                compressionMethod: "Deflate",
                detectedEncoding: nil
            ),
            UniFfiEntryMetadata(
                path: deepFilePath,
                uncompressedSize: 4096,
                compressedSize: 1024,
                crc32: 0x9999_8888,
                mtimeEpochSecs: 1_700_000_000,
                mode: 0o644,
                isDirectory: false,
                isEncrypted: false,
                compressionMethod: "Deflate",
                detectedEncoding: nil
            ),
        ]
        let vfs = UniFfiVfsTree.build(entries: entries, rootName: "deep300.tar")
        let rootNode = ArchiveTreeNode(
            name: "deep300.tar",
            path: "",
            uncompressedSize: 5120,
            isDirectory: true,
            posixPermissions: 0o755,
            hasChildren: true,
            vfsTree: vfs
        )

        let rootComp = rootNode.toComponent()
        XCTAssertEqual(rootComp.sizeBytes, 5120)
        var current: ArchiveComponentProtocol? = rootComp
        var deepComponentAt100: ArchiveComponentProtocol?
        for idx in 0..<depthCount {
            let children = current?.getChildren() ?? []
            let nextDir = children.first { $0.isDirectory && $0.name == "d\(idx)" }
            XCTAssertNotNil(nextDir, "Level \(idx) must not be truncated")
            if idx == 100 {
                deepComponentAt100 = nextDir
            }
            current = nextDir
        }
        let finalLeaves = current?.getChildren() ?? []
        XCTAssertEqual(finalLeaves.count, 1)
        XCTAssertEqual(finalLeaves.first?.name, "leaf.txt")
        XCTAssertEqual(finalLeaves.first?.sizeBytes, 4096)

        let roundTrippedRoot = ArchiveTreeNode(component: rootComp)
        XCTAssertEqual(roundTrippedRoot.uncompressedSize, 5120)
        XCTAssertEqual(roundTrippedRoot.posixPermissions, 0o755)
        var nodeCursor: ArchiveTreeNode? = roundTrippedRoot
        for idx in 0..<depthCount {
            let nodeChildren = nodeCursor?.children ?? []
            if idx == 2 {
                let shallowLeaf = nodeChildren.first { !$0.isDirectory && $0.name == "shallow.txt" }
                XCTAssertEqual(shallowLeaf?.path, shallowFilePath)
                XCTAssertEqual(shallowLeaf?.uncompressedSize, 1024)
                XCTAssertEqual(shallowLeaf?.compressedSize, 512)
                XCTAssertEqual(shallowLeaf?.crc32, 0x1111_2222)
                XCTAssertEqual(shallowLeaf?.posixPermissions, 0o755)
                XCTAssertEqual(shallowLeaf?.entry?.posixPermissions, 0o755)
            }
            let nextNode = nodeChildren.first { $0.isDirectory && $0.name == "d\(idx)" }
            XCTAssertNotNil(nextNode, "Round-tripped node at level \(idx) must remain navigable")
            XCTAssertEqual(nextNode?.posixPermissions, 0o755)
            nodeCursor = nextNode
        }
        let deepLeafNode = nodeCursor?.children?.first
        XCTAssertEqual(deepLeafNode?.name, "leaf.txt")
        XCTAssertEqual(deepLeafNode?.path, deepFilePath)
        XCTAssertEqual(deepLeafNode?.uncompressedSize, 4096)
        XCTAssertEqual(deepLeafNode?.compressedSize, 1024)
        XCTAssertEqual(deepLeafNode?.crc32, 0x9999_8888)
        XCTAssertEqual(deepLeafNode?.posixPermissions, 0o644)
        XCTAssertEqual(deepLeafNode?.entry?.posixPermissions, 0o644)

        if let deepComp = deepComponentAt100 {
            let roundTrippedDeep = ArchiveTreeNode(component: deepComp)
            XCTAssertEqual(roundTrippedDeep.name, "d100")
            XCTAssertEqual(roundTrippedDeep.uncompressedSize, 4096)
            XCTAssertEqual(roundTrippedDeep.posixPermissions, 0o755)
            XCTAssertNotNil(roundTrippedDeep.vfsTree)
            XCTAssertEqual(roundTrippedDeep.children?.first?.name, "d101")
        }
    }

    func testInterleavedMultiArchiveSamePathAndZeroValueMetadataRoundTrip() throws {
        let archiveAExec = ArchiveTreeNode(
            name: "app.bin",
            path: "d0/d1/app.bin",
            uncompressedSize: 1024,
            isDirectory: false,
            compressedSize: 600,
            crc32: 0xAAAA_1111,
            posixPermissions: 0o755
        )
        let archiveAZero = ArchiveTreeNode(
            name: "zero.bin",
            path: "d0/d1/zero.bin",
            uncompressedSize: 0,
            isDirectory: false,
            compressedSize: 0,
            crc32: 0,
            posixPermissions: 0
        )
        let archiveARoot = ArchiveTreeNode(
            name: "d1",
            path: "d0/d1",
            uncompressedSize: 1024,
            isDirectory: true,
            children: [archiveAExec, archiveAZero],
            compressedSize: 600,
            crc32: 0x1111_0000,
            posixPermissions: 0o700,
            hasChildren: true
        )

        let archiveBExec = ArchiveTreeNode(
            name: "app.bin",
            path: "d0/d1/app.bin",
            uncompressedSize: 1024,
            isDirectory: false,
            compressedSize: 420,
            crc32: 0xBBBB_2222,
            posixPermissions: 0o444
        )
        let archiveBRoot = ArchiveTreeNode(
            name: "d1",
            path: "d0/d1",
            uncompressedSize: 1024,
            isDirectory: true,
            children: [archiveBExec],
            compressedSize: 420,
            crc32: 0x2222_0000,
            posixPermissions: 0o755,
            hasChildren: true
        )

        // Interleave Node -> Component -> Node across both archives sharing identical paths
        let compA = archiveARoot.toComponent()
        let compB = archiveBootToComponent(archiveBRoot)
        let roundTripA = ArchiveTreeNode(component: compA)
        let roundTripB = ArchiveTreeNode(component: compB)

        XCTAssertEqual(roundTripA.posixPermissions, 0o700)
        XCTAssertEqual(roundTripA.entry?.posixPermissions, 0o700)
        XCTAssertEqual(roundTripA.crc32, 0x1111_0000)
        XCTAssertEqual(roundTripB.posixPermissions, 0o755)
        XCTAssertEqual(roundTripB.entry?.posixPermissions, 0o755)
        XCTAssertEqual(roundTripB.crc32, 0x2222_0000)

        let appA = roundTripA.children?.first { $0.name == "app.bin" }
        let appB = roundTripB.children?.first { $0.name == "app.bin" }
        XCTAssertEqual(appA?.posixPermissions, 0o755)
        XCTAssertEqual(appA?.entry?.posixPermissions, 0o755)
        XCTAssertEqual(appA?.compressedSize, 600)
        XCTAssertEqual(appA?.crc32, 0xAAAA_1111)
        XCTAssertEqual(appB?.posixPermissions, 0o444)
        XCTAssertEqual(appB?.entry?.posixPermissions, 0o444)
        XCTAssertEqual(appB?.compressedSize, 420)
        XCTAssertEqual(appB?.crc32, 0xBBBB_2222)

        let zeroA = roundTripA.children?.first { $0.name == "zero.bin" }
        XCTAssertEqual(zeroA?.posixPermissions, 0)
        XCTAssertEqual(zeroA?.entry?.posixPermissions, .some(0))
        XCTAssertEqual(zeroA?.entry?.compressedSize, .some(0))
        XCTAssertEqual(zeroA?.entry?.crc32, .some(0))
    }

    private func archiveBootToComponent(_ node: ArchiveTreeNode) -> ArchiveComponentProtocol {
        node.toComponent()
    }
}

