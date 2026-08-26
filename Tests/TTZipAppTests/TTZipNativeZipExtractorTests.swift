// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import Foundation
import zlib
@testable import TTZipPluginKit

final class TTZipNativeZipExtractorTests: XCTestCase {
    
    private var tempDirectory: URL!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TTZipNativeExtractTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }
    
    // MARK: - Test Cases
    
    func testNativeZipExtractionStore() throws {
        let zipData = try buildZipArchive(entries: [
            (path: "LarkSync.ttplugin/Info.plist", content: Data("{\"id\":\"com.ttzip.larksync\"}".utf8), method: 0),
            (path: "LarkSync.ttplugin/Contents/MacOS/plugin", content: Data("binary_executable_data".utf8), method: 0)
        ])
        
        let zipFile = tempDirectory.appendingPathComponent("test_store.zip")
        try zipData.write(to: zipFile)
        
        let stagingDir = tempDirectory.appendingPathComponent("staging_store")
        let extractedBundleURL = try TTZipNativeZipExtractor.extract(archiveURL: zipFile, destinationDirectory: stagingDir)
        
        XCTAssertEqual(extractedBundleURL.lastPathComponent, "LarkSync.ttplugin")
        
        let plistURL = extractedBundleURL.appendingPathComponent("Info.plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL.path))
        let plistContent = try String(contentsOf: plistURL, encoding: .utf8)
        XCTAssertEqual(plistContent, "{\"id\":\"com.ttzip.larksync\"}")
        
        let binURL = extractedBundleURL.appendingPathComponent("Contents/MacOS/plugin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: binURL.path))
    }
    
    func testNativeZipExtractionDeflate() throws {
        let testString = String(repeating: "TTZip High Performance Swift Microkernel Engine Architecture ", count: 100)
        let uncompressedData = Data(testString.utf8)
        
        let zipData = try buildZipArchive(entries: [
            (path: "TestPlugin.ttplugin/README.md", content: uncompressedData, method: 8),
            (path: "TestPlugin.ttplugin/config.json", content: Data("{\"active\":true}".utf8), method: 8)
        ])
        
        let zipFile = tempDirectory.appendingPathComponent("test_deflate.zip")
        try zipData.write(to: zipFile)
        
        let stagingDir = tempDirectory.appendingPathComponent("staging_deflate")
        let bundleURL = try TTZipNativeZipExtractor.extract(archiveURL: zipFile, destinationDirectory: stagingDir)
        
        XCTAssertEqual(bundleURL.lastPathComponent, "TestPlugin.ttplugin")
        let readmeURL = bundleURL.appendingPathComponent("README.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: readmeURL.path))
        let extractedString = try String(contentsOf: readmeURL, encoding: .utf8)
        XCTAssertEqual(extractedString, testString)
    }
    
    func testZipSlipPathTraversalDefense() throws {
        let zipData = try buildZipArchive(entries: [
            (path: "../../../evil_escape.sh", content: Data("rm -rf /".utf8), method: 0),
            (path: "EvilPlugin.ttplugin/Info.plist", content: Data("evil".utf8), method: 0)
        ])
        
        let zipFile = tempDirectory.appendingPathComponent("test_zipslip.zip")
        try zipData.write(to: zipFile)
        
        let stagingDir = tempDirectory.appendingPathComponent("staging_zipslip")
        
        XCTAssertThrowsError(try TTZipNativeZipExtractor.extract(archiveURL: zipFile, destinationDirectory: stagingDir)) { error in
            guard let secErr = error as? TTZipPluginSecurity.SecurityError else {
                XCTFail("Expected TTZipPluginSecurity.SecurityError but got \(error)")
                return
            }
            switch secErr {
            case .zipSlipDetected(let badPath):
                XCTAssertTrue(badPath.contains("evil_escape.sh"))
            default:
                XCTFail("Expected zipSlipDetected but got \(secErr)")
            }
        }
    }
    
    func testNestedPluginDiscovery() throws {
        let zipData = try buildZipArchive(entries: [
            (path: "dist/Nested.ttplugin/Info.plist", content: Data("nested_data".utf8), method: 0)
        ])
        
        let zipFile = tempDirectory.appendingPathComponent("test_nested.zip")
        try zipData.write(to: zipFile)
        
        let stagingDir = tempDirectory.appendingPathComponent("staging_nested")
        let bundleURL = try TTZipNativeZipExtractor.extract(archiveURL: zipFile, destinationDirectory: stagingDir)
        
        XCTAssertEqual(bundleURL.lastPathComponent, "Nested.ttplugin")
    }
    
    func testCorruptArchiveHandling() {
        let garbageData = Data("Not A Valid ZIP Archive Content Here".utf8)
        let corruptFile = tempDirectory.appendingPathComponent("corrupt.zip")
        try? garbageData.write(to: corruptFile)
        
        let stagingDir = tempDirectory.appendingPathComponent("staging_corrupt")
        XCTAssertThrowsError(try TTZipNativeZipExtractor.extract(archiveURL: corruptFile, destinationDirectory: stagingDir))
    }
    
    // MARK: - Test ZIP Generator Helper
    
    private func buildZipArchive(entries: [(path: String, content: Data, method: UInt16)]) throws -> Data {
        var zipData = Data()
        var centralDirectory = Data()
        var localHeaderOffsets: [UInt32] = []
        
        for entry in entries {
            let offset = UInt32(zipData.count)
            localHeaderOffsets.append(offset)
            
            let nameBytes = Array(entry.path.utf8)
            let nameLen = UInt16(nameBytes.count)
            let crc = computeCrc32(data: entry.content)
            
            let compressedPayload: Data
            if entry.method == 8 {
                compressedPayload = try compressDeflate(data: entry.content)
            } else {
                compressedPayload = entry.content
            }
            
            let compSize = UInt32(compressedPayload.count)
            let uncompSize = UInt32(entry.content.count)
            
            // Local Header (30 bytes + name + payload)
            var localHeader = Data()
            localHeader.appendUInt32(0x04034b50)
            localHeader.appendUInt16(20) // version needed
            localHeader.appendUInt16(0)  // flags
            localHeader.appendUInt16(entry.method)
            localHeader.appendUInt16(0)  // mtime
            localHeader.appendUInt16(0)  // mdate
            localHeader.appendUInt32(crc)
            localHeader.appendUInt32(compSize)
            localHeader.appendUInt32(uncompSize)
            localHeader.appendUInt16(nameLen)
            localHeader.appendUInt16(0)  // extra len
            localHeader.append(contentsOf: nameBytes)
            
            zipData.append(localHeader)
            zipData.append(compressedPayload)
            
            // Central Directory Header (46 bytes + name)
            var cdEntry = Data()
            cdEntry.appendUInt32(0x02014b50)
            cdEntry.appendUInt16(0x0314) // made by (UNIX 2.0)
            cdEntry.appendUInt16(20)     // version needed
            cdEntry.appendUInt16(0)      // flags
            cdEntry.appendUInt16(entry.method)
            cdEntry.appendUInt16(0)      // mtime
            cdEntry.appendUInt16(0)      // mdate
            cdEntry.appendUInt32(crc)
            cdEntry.appendUInt32(compSize)
            cdEntry.appendUInt32(uncompSize)
            cdEntry.appendUInt16(nameLen)
            cdEntry.appendUInt16(0)      // extra len
            cdEntry.appendUInt16(0)      // comment len
            cdEntry.appendUInt16(0)      // disk num
            cdEntry.appendUInt16(0)      // internal attr
            cdEntry.appendUInt32(entry.path.hasSuffix("/") ? 0x10 : 0) // external attr
            cdEntry.appendUInt32(offset)
            cdEntry.append(contentsOf: nameBytes)
            
            centralDirectory.append(cdEntry)
        }
        
        let cdOffset = UInt32(zipData.count)
        let cdSize = UInt32(centralDirectory.count)
        zipData.append(centralDirectory)
        
        // End of Central Directory (22 bytes)
        var eocd = Data()
        eocd.appendUInt32(0x06054b50)
        eocd.appendUInt16(0) // disk num
        eocd.appendUInt16(0) // start disk
        eocd.appendUInt16(UInt16(entries.count))
        eocd.appendUInt16(UInt16(entries.count))
        eocd.appendUInt32(cdSize)
        eocd.appendUInt32(cdOffset)
        eocd.appendUInt16(0) // comment len
        
        zipData.append(eocd)
        return zipData
    }
    
    private func computeCrc32(data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(crc32(0, base, uInt(data.count)))
        }
    }
    
    private func compressDeflate(data: Data) throws -> Data {
        var stream = z_stream()
        let initStatus = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw NSError(domain: "TestDeflate", code: Int(initStatus))
        }
        defer { deflateEnd(&stream) }
        
        var output = Data(count: data.count + 1024)
        let outCapacity = output.count
        
        data.withUnsafeBytes { rawIn in
            guard let inBase = rawIn.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(data.count)
            
            output.withUnsafeMutableBytes { rawOut in
                guard let outBase = rawOut.bindMemory(to: Bytef.self).baseAddress else { return }
                stream.next_out = outBase
                stream.avail_out = uInt(outCapacity)
                deflate(&stream, Z_FINISH)
            }
        }
        
        let actualCount = Int(stream.total_out)
        output.removeSubrange(actualCount..<output.count)
        return output
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
    
    mutating func appendUInt32(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
