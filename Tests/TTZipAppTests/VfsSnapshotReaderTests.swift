// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
#if canImport(ttzip_app_coreFFI)
import ttzip_app_coreFFI
#elseif canImport(CTTZipAppCoreBridge)
import CTTZipAppCoreBridge
#endif

@testable import TTZipApp
#if !SWIFT_PACKAGE
#endif

final class VfsSnapshotReaderTests: XCTestCase {

    // MARK: - Legacy 64-Byte CSR Fallback Tests

    private func makeLegacyHeader() -> UnsafeMutableRawPointer {
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 16)
        ptr.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        // Store TT_FEATURE_FLAG_CSR at byte offset 56 to indicate 64B legacy CSR layout
        ptr.storeBytes(of: TTWorkspaceVfsView.featureFlagCSR, toByteOffset: 56, as: UInt32.self)
        return ptr
    }

    func testReadChildrenSlicePerformance() {
        let headerPtr = makeLegacyHeader()
        defer { headerPtr.deallocate() }

        let nodeCount = 50001
        let nodeBytes = nodeCount * 64
        let rawNodes = UnsafeMutableRawPointer.allocate(byteCount: nodeBytes, alignment: 64)
        defer { rawNodes.deallocate() }
        
        rawNodes.initializeMemory(as: UInt8.self, repeating: 0, count: nodeBytes)
        
        // Root node at index 0
        rawNodes.storeBytes(of: UInt32(0), toByteOffset: 0, as: UInt32.self) // parentID
        rawNodes.storeBytes(of: UInt32(1), toByteOffset: 4, as: UInt32.self) // firstChildID
        rawNodes.storeBytes(of: UInt32(50000), toByteOffset: 8, as: UInt32.self) // childCount
        
        let view = TTWorkspaceVfsView(
            header: OpaquePointer(headerPtr),
            nodes: OpaquePointer(rawNodes),
            node_count: UInt64(nodeCount),
            string_arena: nil,
            string_arena_len: 0,
            generation: 1
        )
        
        XCTAssertFalse(view.isCompactFormat)
        XCTAssertTrue(view.isLegacyFormat)
        XCTAssertEqual(view.nodeStride, 64)

        measure {
            let slice = VfsSnapshotReader.readChildrenSlice(of: 0, in: view, offset: 10000, limit: 50)
            XCTAssertEqual(slice.count, 50)
        }
    }
    
    func testZeroCopyStringDecoding() {
        let headerPtr = makeLegacyHeader()
        defer { headerPtr.deallocate() }

        let arenaText = "HelloWorld"
        let arenaPtr = strdup(arenaText)!
        defer { free(arenaPtr) }
        let arenaBytesCount = 10
        
        let nodeBytes = 64 * 2
        let rawNodes = UnsafeMutableRawPointer.allocate(byteCount: nodeBytes, alignment: 64)
        defer { rawNodes.deallocate() }
        rawNodes.initializeMemory(as: UInt8.self, repeating: 0, count: nodeBytes)
        
        rawNodes.storeBytes(of: UInt32(1), toByteOffset: 4, as: UInt32.self) // firstChildID
        rawNodes.storeBytes(of: UInt32(1), toByteOffset: 8, as: UInt32.self) // childCount
        
        rawNodes.storeBytes(of: UInt32(5), toByteOffset: 12 + 64, as: UInt32.self) // nameOffset = 5 ("World")
        rawNodes.storeBytes(of: UInt16(5), toByteOffset: 62 + 64, as: UInt16.self) // nameLen = 5
        
        let view = TTWorkspaceVfsView(
            header: OpaquePointer(headerPtr),
            nodes: OpaquePointer(rawNodes),
            node_count: 2,
            string_arena: UnsafePointer(arenaPtr),
            string_arena_len: UInt64(arenaBytesCount),
            generation: 1
        )
        
        let slice = VfsSnapshotReader.readChildrenSlice(of: 0, in: view, offset: 0, limit: 1)
        XCTAssertEqual(slice.first?.name, "World")
    }
    
    func testSearchIndexSliceRetrieval() {
        let headerPtr = makeLegacyHeader()
        defer { headerPtr.deallocate() }

        let nodeBytes = 64 * 3
        let rawNodes = UnsafeMutableRawPointer.allocate(byteCount: nodeBytes, alignment: 64)
        defer { rawNodes.deallocate() }
        rawNodes.initializeMemory(as: UInt8.self, repeating: 0, count: nodeBytes)
        
        rawNodes.storeBytes(of: UInt64(101), toByteOffset: 48 + 64, as: UInt64.self) // stableID for index 1
        rawNodes.storeBytes(of: UInt64(102), toByteOffset: 48 + 128, as: UInt64.self) // stableID for index 2
        
        let view = TTWorkspaceVfsView(
            header: OpaquePointer(headerPtr),
            nodes: OpaquePointer(rawNodes),
            node_count: 3,
            string_arena: nil,
            string_arena_len: 0,
            generation: 1
        )
        
        let slice = VfsSnapshotReader.readIndexedEntries(indices: [1, 2], in: view, offset: 0, limit: 10)
        XCTAssertEqual(slice.count, 2)
        XCTAssertEqual(slice[0].id, 101)
        XCTAssertEqual(slice[1].id, 102)
    }

    // MARK: - 24-Byte Compact Node Tests

    private func writeCompactNode(
        to rawPtr: UnsafeMutableRawPointer,
        index: Int,
        nameOffset: UInt32,
        nameLen: UInt16,
        flags: UInt16,
        size: UInt64,
        mtime: UInt32,
        dirChildrenIdx: UInt32
    ) {
        let baseOffset = index * 24
        rawPtr.storeBytes(of: nameOffset, toByteOffset: baseOffset + 0, as: UInt32.self)
        rawPtr.storeBytes(of: nameLen, toByteOffset: baseOffset + 4, as: UInt16.self)
        rawPtr.storeBytes(of: flags, toByteOffset: baseOffset + 6, as: UInt16.self)
        rawPtr.storeBytes(of: size, toByteOffset: baseOffset + 8, as: UInt64.self)
        rawPtr.storeBytes(of: mtime, toByteOffset: baseOffset + 16, as: UInt32.self)
        rawPtr.storeBytes(of: dirChildrenIdx, toByteOffset: baseOffset + 20, as: UInt32.self)
    }

    func testCompactNodeGeometryAndReading() {
        let nodeCount = 3
        let rawNodes = UnsafeMutableRawPointer.allocate(byteCount: nodeCount * 24, alignment: 16)
        defer { rawNodes.deallocate() }
        rawNodes.initializeMemory(as: UInt8.self, repeating: 0, count: nodeCount * 24)

        // Node 0: root directory (flags: 0x01 = is_dir)
        writeCompactNode(to: rawNodes, index: 0, nameOffset: 0, nameLen: 4, flags: 0x0001, size: 0, mtime: 1700000000, dirChildrenIdx: 0)
        // Node 1: file (size: 1024)
        writeCompactNode(to: rawNodes, index: 1, nameOffset: 5, nameLen: 9, flags: 0x0000, size: 1024, mtime: 1700000010, dirChildrenIdx: 0)
        // Node 2: encrypted file (flags: 0x04)
        writeCompactNode(to: rawNodes, index: 2, nameOffset: 15, nameLen: 8, flags: 0x0004, size: 2048, mtime: 1700000020, dirChildrenIdx: 0)

        let view = TTWorkspaceVfsView(
            header: nil,
            nodes: OpaquePointer(rawNodes),
            node_count: UInt64(nodeCount),
            string_arena: nil,
            string_arena_len: 0,
            generation: 1
        )

        XCTAssertTrue(view.isCompactFormat)
        XCTAssertFalse(view.isLegacyFormat)
        XCTAssertEqual(view.nodeStride, 24)

        let node0 = view.compactNode(at: 0)
        XCTAssertTrue(node0.isDirectory)
        XCTAssertFalse(node0.isEncrypted)
        XCTAssertEqual(node0.size, 0)
        XCTAssertEqual(node0.dirChildrenIdx, 0)

        let node1 = view.compactNode(at: 1)
        XCTAssertFalse(node1.isDirectory)
        XCTAssertEqual(node1.size, 1024)
        XCTAssertEqual(node1.mtime, 1700000010)

        let node2 = view.compactNode(at: 2)
        XCTAssertTrue(node2.isEncrypted)
        XCTAssertEqual(node2.size, 2048)
        XCTAssertEqual(node2.mtime, 1700000020)
    }

    private func makeArena(string: String) -> (UnsafeMutablePointer<CChar>, Int) {
        let bytes = Array(string.utf8)
        let ptr = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { src in
                ptr.initialize(from: src, count: bytes.count)
            }
        }
        return (ptr, bytes.count)
    }

    func testCompactZeroCopyStringDecoding() {
        let (arenaPtr, arenaCount) = makeArena(string: "root\0hello.txt\0data.bin")
        defer { arenaPtr.deallocate() }

        let nodeCount = 3
        let rawNodes = UnsafeMutableRawPointer.allocate(byteCount: nodeCount * 24, alignment: 16)
        defer { rawNodes.deallocate() }
        rawNodes.initializeMemory(as: UInt8.self, repeating: 0, count: nodeCount * 24)

        writeCompactNode(to: rawNodes, index: 0, nameOffset: 0, nameLen: 4, flags: 0x0001, size: 0, mtime: 1700000000, dirChildrenIdx: 0)
        writeCompactNode(to: rawNodes, index: 1, nameOffset: 5, nameLen: 9, flags: 0x0000, size: 1024, mtime: 1700000010, dirChildrenIdx: 0)
        writeCompactNode(to: rawNodes, index: 2, nameOffset: 15, nameLen: 8, flags: 0x0000, size: 2048, mtime: 1700000020, dirChildrenIdx: 0)

        let view = TTWorkspaceVfsView(
            header: nil,
            nodes: OpaquePointer(rawNodes),
            node_count: UInt64(nodeCount),
            string_arena: UnsafePointer(arenaPtr),
            string_arena_len: UInt64(arenaCount),
            generation: 1
        )

        let node0 = view.compactNode(at: 0)
        let node1 = view.compactNode(at: 1)
        let node2 = view.compactNode(at: 2)

        XCTAssertEqual(VfsSnapshotReader.decodeCompactName(in: view, node: node0), "root")
        XCTAssertEqual(VfsSnapshotReader.decodeCompactName(in: view, node: node1), "hello.txt")
        XCTAssertEqual(VfsSnapshotReader.decodeCompactName(in: view, node: node2), "data.bin")

        let vm1 = VfsSnapshotReader.readCompactNode(at: 1, in: view)
        XCTAssertNotNil(vm1)
        XCTAssertEqual(vm1?.name, "hello.txt")
        XCTAssertEqual(vm1?.uncompressedSize, 1024)
        XCTAssertEqual(vm1?.isDirectory, false)
        XCTAssertEqual(vm1?.modificationDate, Date(timeIntervalSince1970: 1700000010))
    }

    func testCompactChildrenSliceNavigation() {
        let (arenaPtr, arenaCount) = makeArena(string: "root\0hello.txt\0data.bin")
        defer { arenaPtr.deallocate() }

        let nodeCount = 3
        let rawNodes = UnsafeMutableRawPointer.allocate(byteCount: nodeCount * 24, alignment: 16)
        defer { rawNodes.deallocate() }
        rawNodes.initializeMemory(as: UInt8.self, repeating: 0, count: nodeCount * 24)

        writeCompactNode(to: rawNodes, index: 0, nameOffset: 0, nameLen: 4, flags: 0x0001, size: 0, mtime: 1700000000, dirChildrenIdx: 0)
        writeCompactNode(to: rawNodes, index: 1, nameOffset: 5, nameLen: 9, flags: 0x0000, size: 1024, mtime: 1700000010, dirChildrenIdx: 0)
        writeCompactNode(to: rawNodes, index: 2, nameOffset: 15, nameLen: 8, flags: 0x0000, size: 2048, mtime: 1700000020, dirChildrenIdx: 0)

        let view = TTWorkspaceVfsView(
            header: nil,
            nodes: OpaquePointer(rawNodes),
            node_count: UInt64(nodeCount),
            string_arena: UnsafePointer(arenaPtr),
            string_arena_len: UInt64(arenaCount),
            generation: 1
        )

        // Root node has dirChildrenIdx: 0 -> pointing to children [1, 2]
        let dirTable: [[UInt32]] = [[1, 2]]

        let allChildren = VfsSnapshotReader.readChildrenSlice(of: 0, in: view, offset: 0, limit: 10, dirTable: dirTable)
        XCTAssertEqual(allChildren.count, 2)
        XCTAssertEqual(allChildren[0].name, "hello.txt")
        XCTAssertEqual(allChildren[1].name, "data.bin")

        let offsetChildren = VfsSnapshotReader.readChildrenSlice(of: 0, in: view, offset: 1, limit: 1, dirTable: dirTable)
        XCTAssertEqual(offsetChildren.count, 1)
        XCTAssertEqual(offsetChildren[0].name, "data.bin")

        let emptyChildren = VfsSnapshotReader.readChildrenSlice(of: 0, in: view, offset: 2, limit: 5, dirTable: dirTable)
        XCTAssertEqual(emptyChildren.count, 0)
    }

    func testCompactIndexedEntriesRetrieval() {
        let (arenaPtr, arenaCount) = makeArena(string: "root\0hello.txt\0data.bin")
        defer { arenaPtr.deallocate() }

        let nodeCount = 3
        let rawNodes = UnsafeMutableRawPointer.allocate(byteCount: nodeCount * 24, alignment: 16)
        defer { rawNodes.deallocate() }
        rawNodes.initializeMemory(as: UInt8.self, repeating: 0, count: nodeCount * 24)

        writeCompactNode(to: rawNodes, index: 0, nameOffset: 0, nameLen: 4, flags: 0x0001, size: 0, mtime: 1700000000, dirChildrenIdx: 0)
        writeCompactNode(to: rawNodes, index: 1, nameOffset: 5, nameLen: 9, flags: 0x0000, size: 1024, mtime: 1700000010, dirChildrenIdx: 0)
        writeCompactNode(to: rawNodes, index: 2, nameOffset: 15, nameLen: 8, flags: 0x0000, size: 2048, mtime: 1700000020, dirChildrenIdx: 0)

        let view = TTWorkspaceVfsView(
            header: nil,
            nodes: OpaquePointer(rawNodes),
            node_count: UInt64(nodeCount),
            string_arena: UnsafePointer(arenaPtr),
            string_arena_len: UInt64(arenaCount),
            generation: 1
        )

        let indexed = VfsSnapshotReader.readIndexedEntries(indices: [2, 1], in: view, offset: 0, limit: 10)
        XCTAssertEqual(indexed.count, 2)
        XCTAssertEqual(indexed[0].name, "data.bin")
        XCTAssertEqual(indexed[0].id, 2)
        XCTAssertEqual(indexed[1].name, "hello.txt")
        XCTAssertEqual(indexed[1].id, 1)
    }

    @MainActor
    func testCompactDirectMemoryTableViewAdapter() {
        let (arenaPtr, arenaCount) = makeArena(string: "root\0beta.txt\0alpha.bin")
        defer { arenaPtr.deallocate() }

        let nodeCount = 3
        let rawNodes = UnsafeMutableRawPointer.allocate(byteCount: nodeCount * 24, alignment: 16)
        defer { rawNodes.deallocate() }
        rawNodes.initializeMemory(as: UInt8.self, repeating: 0, count: nodeCount * 24)

        // Node 0: root directory
        writeCompactNode(to: rawNodes, index: 0, nameOffset: 0, nameLen: 4, flags: 0x0001, size: 0, mtime: 1700000000, dirChildrenIdx: 0)
        // Node 1: "beta.txt", size 100
        writeCompactNode(to: rawNodes, index: 1, nameOffset: 5, nameLen: 8, flags: 0x0000, size: 100, mtime: 1700000010, dirChildrenIdx: 0)
        // Node 2: "alpha.bin", size 500
        writeCompactNode(to: rawNodes, index: 2, nameOffset: 14, nameLen: 9, flags: 0x0000, size: 500, mtime: 1700000020, dirChildrenIdx: 0)

        let view = TTWorkspaceVfsView(
            header: nil,
            nodes: OpaquePointer(rawNodes),
            node_count: UInt64(nodeCount),
            string_arena: UnsafePointer(arenaPtr),
            string_arena_len: UInt64(arenaCount),
            generation: 1
        )

        let dirTable: [[UInt32]] = [[1, 2]]

        let adapter = NativeArchiveTableViewAdapter(
            compactView: view,
            parentId: 0,
            dirTable: dirTable,
            sortKey: .name,
            sortDirection: .ascending
        )

        XCTAssertEqual(adapter.cachedEntryCount, 2)
        // Ascending by name: alpha.bin (index 2) comes first, beta.txt (index 1) second
        XCTAssertEqual(adapter.compactName(at: 0), "alpha.bin")
        XCTAssertEqual(adapter.compactSize(at: 0), 500)
        XCTAssertFalse(adapter.compactIsDir(at: 0))

        XCTAssertEqual(adapter.compactName(at: 1), "beta.txt")
        XCTAssertEqual(adapter.compactSize(at: 1), 100)

        // Reverse sort by name
        adapter.setSortCriteria(key: .name, direction: .descending)
        XCTAssertEqual(adapter.compactName(at: 0), "beta.txt")
        XCTAssertEqual(adapter.compactName(at: 1), "alpha.bin")

        // Sort by size ascending: 100 (beta.txt) before 500 (alpha.bin)
        adapter.setSortCriteria(key: .size, direction: .ascending)
        XCTAssertEqual(adapter.compactName(at: 0), "beta.txt")
        XCTAssertEqual(adapter.compactSize(at: 0), 100)
        XCTAssertEqual(adapter.compactName(at: 1), "alpha.bin")
        XCTAssertEqual(adapter.compactSize(at: 1), 500)
    }

    func testCompactSlicePerformance() {
        let childCount = 50000
        let totalCount = childCount + 1
        let nodeBytes = totalCount * 24
        let rawNodes = UnsafeMutableRawPointer.allocate(byteCount: nodeBytes, alignment: 16)
        defer { rawNodes.deallocate() }
        rawNodes.initializeMemory(as: UInt8.self, repeating: 0, count: nodeBytes)

        // Root at index 0
        writeCompactNode(to: rawNodes, index: 0, nameOffset: 0, nameLen: 0, flags: 0x0001, size: 0, mtime: 0, dirChildrenIdx: 0)
        let childIndices = (1...UInt32(childCount)).map { $0 }
        let dirTable: [[UInt32]] = [childIndices]

        let view = TTWorkspaceVfsView(
            header: nil,
            nodes: OpaquePointer(rawNodes),
            node_count: UInt64(totalCount),
            string_arena: nil,
            string_arena_len: 0,
            generation: 1
        )

        measure {
            let slice = VfsSnapshotReader.readChildrenSlice(of: 0, in: view, offset: 10000, limit: 50, dirTable: dirTable)
            XCTAssertEqual(slice.count, 50)
        }
    }

    // MARK: - Memory Boundary & Corruption Regression Tests

    func testFeatureFlagNodeFormatParityWithRust() {
        let headerPtr = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 64)
        defer { headerPtr.deallocate() }
        headerPtr.initializeMemory(as: UInt8.self, repeating: 0, count: 128)

        let nilHeaderView = TTWorkspaceVfsView(header: nil)
        XCTAssertTrue(nilHeaderView.isCompactFormat)
        XCTAssertFalse(nilHeaderView.isLegacyFormat)
        XCTAssertEqual(nilHeaderView.nodeStride, 24)

        let cases: [(flags: UInt32, expectedCompact: Bool)] = [
            (0, true),
            (TTWorkspaceVfsView.featureFlagCSR, false),
            (TTWorkspaceVfsView.featureFlagCompactNodes, true),
            (TTWorkspaceVfsView.featureFlagCSR | TTWorkspaceVfsView.featureFlagCompactNodes, true),
            (1 << 5, true),
            (TTWorkspaceVfsView.featureFlagCSR | (1 << 5), false),
            (TTWorkspaceVfsView.featureFlagCompactNodes | (1 << 5), true),
            (TTWorkspaceVfsView.featureFlagCSR | TTWorkspaceVfsView.featureFlagCompactNodes | (1 << 5), true),
            (TTWorkspaceVfsView.featureFlagCSR | (1 << 1) | (1 << 3), false),
        ]

        for (flags, expectedCompact) in cases {
            headerPtr.storeBytes(of: flags, toByteOffset: 56, as: UInt32.self)
            let view = TTWorkspaceVfsView(header: OpaquePointer(headerPtr))
            XCTAssertEqual(view.isCompactFormat, expectedCompact, "flags=0x\(String(flags, radix: 16))")
            XCTAssertEqual(view.isLegacyFormat, !expectedCompact, "flags=0x\(String(flags, radix: 16))")
            XCTAssertEqual(view.nodeStride, expectedCompact ? 24 : 64, "flags=0x\(String(flags, radix: 16))")
        }
    }

    func testStringArenaBoundsAndUInt32WraparoundPrevention() {
        let (arenaPtr, arenaCount) = makeArena(string: "0123456789")
        defer { arenaPtr.deallocate() }
        let arena = UnsafePointer(arenaPtr)
        let arenaLen = UInt64(arenaCount)

        // Exact boundary succeeds; +1 byte past arenaLen and UInt32.max + UInt16.max (widened to
        // UInt64 so 32-bit addition cannot wrap around into a small offset) exceed arenaLen and return "".
        XCTAssertEqual(VfsSnapshotReader.decodeName(arena: arena, arenaLen: arenaLen, offset: 5, len: 5), "56789")
        XCTAssertEqual(VfsSnapshotReader.decodeName(arena: arena, arenaLen: arenaLen, offset: 6, len: 5), "")
        XCTAssertEqual(VfsSnapshotReader.decodeName(arena: arena, arenaLen: arenaLen, offset: .max, len: .max), "")

        // Compact node with out-of-bounds nameOffset + nameLen degrades to "Unknown".
        let rawCompact = UnsafeMutableRawPointer.allocate(byteCount: 2 * 24, alignment: 16)
        defer { rawCompact.deallocate() }
        rawCompact.initializeMemory(as: UInt8.self, repeating: 0, count: 2 * 24)
        writeCompactNode(to: rawCompact, index: 0, nameOffset: 0, nameLen: 4, flags: 0x0001, size: 0, mtime: 0, dirChildrenIdx: 0)
        writeCompactNode(to: rawCompact, index: 1, nameOffset: 8, nameLen: 10, flags: 0x0000, size: 42, mtime: 0, dirChildrenIdx: 0)

        let compactView = TTWorkspaceVfsView(
            header: nil,
            nodes: OpaquePointer(rawCompact),
            node_count: 2,
            string_arena: arena,
            string_arena_len: arenaLen,
            generation: 1
        )
        XCTAssertEqual(VfsSnapshotReader.decodeCompactName(in: compactView, node: compactView.compactNode(at: 1)), "")
        XCTAssertEqual(VfsSnapshotReader.readCompactNode(at: 1, in: compactView)?.name, "Unknown")
        let compactSlice = VfsSnapshotReader.readChildrenSlice(of: 0, in: compactView, offset: 0, limit: 10, dirTable: [[1]])
        XCTAssertEqual(compactSlice.map(\.name), ["Unknown"])
        let compactIndexed = VfsSnapshotReader.readIndexedEntries(indices: [1], in: compactView, offset: 0, limit: 10)
        XCTAssertEqual(compactIndexed.map(\.name), ["Unknown"])
        XCTAssertEqual(VfsSnapshotContext.fallbackSearch(in: compactView, query: "0123", maxResults: 10), [0])

        // CSR node with out-of-bounds nameOffset + nameLen degrades to "Unknown".
        let headerPtr = makeLegacyHeader()
        defer { headerPtr.deallocate() }
        let rawCsr = UnsafeMutableRawPointer.allocate(byteCount: 2 * 64, alignment: 64)
        defer { rawCsr.deallocate() }
        rawCsr.initializeMemory(as: UInt8.self, repeating: 0, count: 2 * 64)
        rawCsr.storeBytes(of: UInt32(1), toByteOffset: 4, as: UInt32.self)
        rawCsr.storeBytes(of: UInt32(1), toByteOffset: 8, as: UInt32.self)
        rawCsr.storeBytes(of: UInt32.max, toByteOffset: 64 + 12, as: UInt32.self)
        rawCsr.storeBytes(of: UInt16(10), toByteOffset: 64 + 62, as: UInt16.self)

        let csrView = TTWorkspaceVfsView(
            header: OpaquePointer(headerPtr),
            nodes: OpaquePointer(rawCsr),
            node_count: 2,
            string_arena: arena,
            string_arena_len: arenaLen,
            generation: 1
        )
        let csrSlice = VfsSnapshotReader.readChildrenSlice(of: 0, in: csrView, offset: 0, limit: 10)
        XCTAssertEqual(csrSlice.map(\.name), ["Unknown"])
        let csrIndexed = VfsSnapshotReader.readIndexedEntries(indices: [1], in: csrView, offset: 0, limit: 10)
        XCTAssertEqual(csrIndexed.map(\.name), ["Unknown"])
        XCTAssertTrue(VfsSnapshotContext.fallbackSearch(in: csrView, query: "5678", maxResults: 10).isEmpty)
    }

    func testCsrChildRangeAndParentBoundsValidation() {
        let headerPtr = makeLegacyHeader()
        defer { headerPtr.deallocate() }

        let rawCsr = UnsafeMutableRawPointer.allocate(byteCount: 3 * 64, alignment: 64)
        defer { rawCsr.deallocate() }
        rawCsr.initializeMemory(as: UInt8.self, repeating: 0, count: 3 * 64)

        // Node 0: firstChildID = 1, childCount = 3 (1 + 3 = 4 > node_count 3 -> out of bounds)
        rawCsr.storeBytes(of: UInt32(1), toByteOffset: 4, as: UInt32.self)
        rawCsr.storeBytes(of: UInt32(3), toByteOffset: 8, as: UInt32.self)
        // Node 1: firstChildID = UInt32.max - 1, childCount = 4 (would wrap in UInt32; widened UInt64 sum > node_count)
        rawCsr.storeBytes(of: UInt32.max - 1, toByteOffset: 64 + 4, as: UInt32.self)
        rawCsr.storeBytes(of: UInt32(4), toByteOffset: 64 + 8, as: UInt32.self)
        // Node 2: firstChildID = UInt32.max (no-children sentinel), childCount = 2
        rawCsr.storeBytes(of: UInt32.max, toByteOffset: 128 + 4, as: UInt32.self)
        rawCsr.storeBytes(of: UInt32(2), toByteOffset: 128 + 8, as: UInt32.self)

        let csrView = TTWorkspaceVfsView(
            header: OpaquePointer(headerPtr),
            nodes: OpaquePointer(rawCsr),
            node_count: 3,
            string_arena: nil,
            string_arena_len: 0,
            generation: 1
        )

        XCTAssertTrue(VfsSnapshotReader.readChildrenSlice(of: 3, in: csrView, offset: 0, limit: 10).isEmpty)
        XCTAssertTrue(VfsSnapshotReader.readChildrenSlice(of: .max, in: csrView, offset: 0, limit: 10).isEmpty)

        XCTAssertTrue(VfsSnapshotReader.readChildrenSlice(of: 0, in: csrView, offset: 0, limit: 10).isEmpty)
        XCTAssertTrue(VfsSnapshotReader.readChildrenSlice(of: 1, in: csrView, offset: 0, limit: 10).isEmpty)
        XCTAssertTrue(VfsSnapshotReader.readChildrenSlice(of: 2, in: csrView, offset: 0, limit: 10).isEmpty)
    }

    func testCompactParentAndPaginationBoundsValidation() {
        let (arenaPtr, arenaCount) = makeArena(string: "root\0a.txt\0b.txt")
        defer { arenaPtr.deallocate() }

        let rawNodes = UnsafeMutableRawPointer.allocate(byteCount: 3 * 24, alignment: 16)
        defer { rawNodes.deallocate() }
        rawNodes.initializeMemory(as: UInt8.self, repeating: 0, count: 3 * 24)
        writeCompactNode(to: rawNodes, index: 0, nameOffset: 0, nameLen: 4, flags: 0x0001, size: 0, mtime: 0, dirChildrenIdx: 0)
        writeCompactNode(to: rawNodes, index: 1, nameOffset: 5, nameLen: 5, flags: 0x0000, size: 10, mtime: 0, dirChildrenIdx: 0)
        writeCompactNode(to: rawNodes, index: 2, nameOffset: 11, nameLen: 5, flags: 0x0000, size: 20, mtime: 0, dirChildrenIdx: 0)

        let view = TTWorkspaceVfsView(
            header: nil,
            nodes: OpaquePointer(rawNodes),
            node_count: 3,
            string_arena: UnsafePointer(arenaPtr),
            string_arena_len: UInt64(arenaCount),
            generation: 1
        )
        let dirTable: [[UInt32]] = [[1, 999, 2]]

        XCTAssertTrue(VfsSnapshotReader.readChildrenSlice(of: 3, in: view, offset: 0, limit: 10, dirTable: dirTable).isEmpty)
        XCTAssertTrue(VfsSnapshotReader.readChildrenSlice(of: .max, in: view, offset: 0, limit: 10, dirTable: dirTable).isEmpty)

        XCTAssertTrue(VfsSnapshotReader.readChildrenSlice(of: 0, in: view, offset: -1, limit: 5, dirTable: dirTable).isEmpty)
        XCTAssertTrue(VfsSnapshotReader.readChildrenSlice(of: 0, in: view, offset: 0, limit: 0, dirTable: dirTable).isEmpty)
        XCTAssertTrue(VfsSnapshotReader.readChildrenSlice(of: 0, in: view, offset: 0, limit: -3, dirTable: dirTable).isEmpty)
        XCTAssertTrue(VfsSnapshotReader.readCompactChildrenSlice(childIndices: [1, 2], in: view, offset: -1, limit: 5).isEmpty)
        XCTAssertTrue(VfsSnapshotReader.readCompactChildrenSlice(childIndices: [1, 2], in: view, offset: 0, limit: 0).isEmpty)
        XCTAssertTrue(VfsSnapshotReader.readIndexedEntries(indices: [1, 2], in: view, offset: -1, limit: 5).isEmpty)
        XCTAssertTrue(VfsSnapshotReader.readIndexedEntries(indices: [1, 2], in: view, offset: 0, limit: -1).isEmpty)

        // Out-of-bounds child IDs (999, UInt32.max) are skipped while limit = Int.max clamps without overflow.
        let validSlice = VfsSnapshotReader.readChildrenSlice(of: 0, in: view, offset: 0, limit: .max, dirTable: dirTable)
        XCTAssertEqual(validSlice.map(\.name), ["a.txt", "b.txt"])
        let validIndexed = VfsSnapshotReader.readIndexedEntries(indices: [2, 999, .max, 1], in: view, offset: 0, limit: .max)
        XCTAssertEqual(validIndexed.map(\.name), ["b.txt", "a.txt"])
    }

    @MainActor
    func testAdapterCorruptStringArenaAndParentBounds() {
        let (arenaPtr, arenaCount) = makeArena(string: "root\0ok.txt")
        defer { arenaPtr.deallocate() }

        let rawNodes = UnsafeMutableRawPointer.allocate(byteCount: 3 * 24, alignment: 16)
        defer { rawNodes.deallocate() }
        rawNodes.initializeMemory(as: UInt8.self, repeating: 0, count: 3 * 24)
        writeCompactNode(to: rawNodes, index: 0, nameOffset: 0, nameLen: 4, flags: 0x0001, size: 0, mtime: 0, dirChildrenIdx: 0)
        writeCompactNode(to: rawNodes, index: 1, nameOffset: 5, nameLen: 6, flags: 0x0000, size: 10, mtime: 1, dirChildrenIdx: 0)
        // Node 2: out-of-bounds nameOffset + nameLen (520 > arenaLen 11)
        writeCompactNode(to: rawNodes, index: 2, nameOffset: 500, nameLen: 20, flags: 0x0000, size: 20, mtime: 2, dirChildrenIdx: 0)

        let view = TTWorkspaceVfsView(
            header: nil,
            nodes: OpaquePointer(rawNodes),
            node_count: 3,
            string_arena: UnsafePointer(arenaPtr),
            string_arena_len: UInt64(arenaCount),
            generation: 1
        )

        let invalidParentAdapter = NativeArchiveTableViewAdapter(
            compactView: view,
            parentId: 99,
            dirTable: [[1, 2]],
            sortKey: .name,
            sortDirection: .ascending
        )
        XCTAssertEqual(invalidParentAdapter.cachedEntryCount, 0)
        XCTAssertNil(invalidParentAdapter.entry(at: 0))

        // Out-of-bounds child index (999) in dirTable is filtered out; out-of-bounds name degrades to "" / "Unknown".
        let adapter = NativeArchiveTableViewAdapter(
            compactView: view,
            parentId: 0,
            dirTable: [[1, 2, 999]],
            sortKey: .name,
            sortDirection: .ascending
        )
        XCTAssertEqual(adapter.cachedEntryCount, 2)
        adapter.setSortCriteria(key: .extension, direction: .ascending)
        XCTAssertNotNil(adapter.entry(at: 0))
        XCTAssertNotNil(adapter.entry(at: 1))
        XCTAssertEqual(adapter.entryIndex(forPath: "ok.txt"), 1)

        adapter.setSearchQuery(query: "ok")
        XCTAssertEqual(adapter.cachedEntryCount, 1)
        XCTAssertEqual(adapter.entry(at: 0)?.name, "ok.txt")
    }
}
