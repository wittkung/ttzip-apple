// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import zlib

/// Pure Swift memory-safe ZIP archive extractor with Zip Slip defense and zero external subprocess dependencies.
public enum TTZipNativeZipExtractor: Sendable {
    
    private struct CentralDirectoryEntry: Sendable {
        let compressionMethod: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let crc32: UInt32
        let localHeaderOffset: UInt64
        let filename: String
        let isDirectory: Bool
    }
    
    private struct DataReader {
        let data: Data
        
        func readUInt16(at offset: Int) -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            return data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
            }
        }
        
        func readUInt32(at offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            return data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
            }
        }
        
        func readUInt64(at offset: Int) -> UInt64? {
            guard offset + 8 <= data.count else { return nil }
            return data.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
            }
        }
    }
    
    /// Extracts a ZIP archive safely into a staging root directory and returns the found `.ttplugin` bundle URL.
    @discardableResult
    public static func extract(archiveURL: URL, destinationDirectory: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw TTZipPluginSecurity.SecurityError.fileNotFound(archiveURL)
        }
        
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        
        let fileHandle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? fileHandle.close() }
        
        let fileSize = try fileHandle.seekToEnd()
        guard fileSize >= 22 else {
            throw TTZipPluginSecurity.SecurityError.corruptArchive("File size (\(fileSize) bytes) is too small to be a valid ZIP")
        }
        
        let entries = try parseCentralDirectory(fileHandle: fileHandle, fileSize: fileSize)
        
        for entry in entries {
            guard !entry.filename.isEmpty else { continue }
            
            let destinationURL = try TTZipPluginSecurity.validateSafeDestination(
                entryRelativePath: entry.filename,
                stagingRoot: destinationDirectory
            )
            
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                continue
            }
            
            let parentDir = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            
            // Read local file header to locate exact payload offset
            try fileHandle.seek(toOffset: entry.localHeaderOffset)
            let localHeaderData = fileHandle.readData(ofLength: 30)
            guard localHeaderData.count == 30 else {
                throw TTZipPluginSecurity.SecurityError.corruptArchive("Truncated local file header at offset \(entry.localHeaderOffset)")
            }
            
            let localReader = DataReader(data: localHeaderData)
            guard localReader.readUInt32(at: 0) == 0x04034b50 else {
                throw TTZipPluginSecurity.SecurityError.corruptArchive("Invalid local header signature at offset \(entry.localHeaderOffset)")
            }
            
            let localNameLen = Int(localReader.readUInt16(at: 26) ?? 0)
            let localExtraLen = Int(localReader.readUInt16(at: 28) ?? 0)
            let payloadOffset = entry.localHeaderOffset + 30 + UInt64(localNameLen) + UInt64(localExtraLen)
            
            try fileHandle.seek(toOffset: payloadOffset)
            let compressedData = fileHandle.readData(ofLength: Int(entry.compressedSize))
            guard compressedData.count == Int(entry.compressedSize) else {
                throw TTZipPluginSecurity.SecurityError.corruptArchive("Premature end of payload for entry: \(entry.filename)")
            }
            
            let decompressedData: Data
            switch entry.compressionMethod {
            case 0: // Store (uncompressed)
                decompressedData = compressedData
            case 8: // Deflate
                decompressedData = try decompressDeflate(
                    compressedData: compressedData,
                    expectedSize: Int(entry.uncompressedSize)
                )
            default:
                throw TTZipPluginSecurity.SecurityError.unsupportedCompressionMethod(entry.compressionMethod)
            }
            
            try decompressedData.write(to: destinationURL, options: .atomic)
        }
        
        // Scan for the extracted .ttplugin bundle
        let contents = try FileManager.default.contentsOfDirectory(at: destinationDirectory, includingPropertiesForKeys: nil)
        if let directBundle = contents.first(where: { $0.pathExtension == "ttplugin" }) {
            return directBundle
        }
        
        for item in contents {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                let nested = (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []
                if let nestedBundle = nested.first(where: { $0.pathExtension == "ttplugin" }) {
                    return nestedBundle
                }
            }
        }
        
        throw TTZipPluginSecurity.SecurityError.fileNotFound(destinationDirectory)
    }
    
    // MARK: - Central Directory Parser
    
    private static func parseCentralDirectory(fileHandle: FileHandle, fileSize: UInt64) throws -> [CentralDirectoryEntry] {
        let maxSearchLength = min(fileSize, UInt64(65535 + 22))
        let tailOffset = fileSize - maxSearchLength
        try fileHandle.seek(toOffset: tailOffset)
        let tailData = fileHandle.readData(ofLength: Int(maxSearchLength))
        
        guard let relativeEocdOffset = findEOCDSignature(in: tailData) else {
            throw TTZipPluginSecurity.SecurityError.corruptArchive("End of Central Directory record (EOCD) not found")
        }
        
        let tailReader = DataReader(data: tailData)
        guard let totalEntries16 = tailReader.readUInt16(at: relativeEocdOffset + 10),
              let cdSize32 = tailReader.readUInt32(at: relativeEocdOffset + 12),
              let cdOffset32 = tailReader.readUInt32(at: relativeEocdOffset + 16) else {
            throw TTZipPluginSecurity.SecurityError.corruptArchive("Invalid EOCD record structure")
        }
        
        var totalEntries = UInt64(totalEntries16)
        var cdSize = UInt64(cdSize32)
        var cdOffset = UInt64(cdOffset32)
        
        // Check for Zip64 End of Central Directory Locator
        if relativeEocdOffset >= 20 {
            let locatorOffset = relativeEocdOffset - 20
            if tailReader.readUInt32(at: locatorOffset) == 0x07064b50,
               let zip64EocdOffset = tailReader.readUInt64(at: locatorOffset + 8) {
                try fileHandle.seek(toOffset: zip64EocdOffset)
                let zip64EocdData = fileHandle.readData(ofLength: 56)
                let zip64Reader = DataReader(data: zip64EocdData)
                if zip64Reader.readUInt32(at: 0) == 0x06064b50,
                   let entries64 = zip64Reader.readUInt64(at: 32),
                   let cdSize64 = zip64Reader.readUInt64(at: 40),
                   let cdOffset64 = zip64Reader.readUInt64(at: 48) {
                    totalEntries = entries64
                    cdSize = cdSize64
                    cdOffset = cdOffset64
                }
            }
        }
        
        try fileHandle.seek(toOffset: cdOffset)
        let cdData = fileHandle.readData(ofLength: Int(cdSize))
        guard cdData.count == Int(cdSize) else {
            throw TTZipPluginSecurity.SecurityError.corruptArchive("Truncated Central Directory data")
        }
        
        let cdReader = DataReader(data: cdData)
        var entries: [CentralDirectoryEntry] = []
        var curr = 0
        
        while curr + 46 <= cdData.count && entries.count < Int(totalEntries) {
            guard cdReader.readUInt32(at: curr) == 0x02014b50 else { break }
            
            let versionMadeBy = cdReader.readUInt16(at: curr + 4) ?? 0
            let method = cdReader.readUInt16(at: curr + 10) ?? 0
            let crc = cdReader.readUInt32(at: curr + 16) ?? 0
            var compSize = UInt64(cdReader.readUInt32(at: curr + 20) ?? 0)
            var uncompSize = UInt64(cdReader.readUInt32(at: curr + 24) ?? 0)
            let nameLen = Int(cdReader.readUInt16(at: curr + 28) ?? 0)
            let extraLen = Int(cdReader.readUInt16(at: curr + 30) ?? 0)
            let commentLen = Int(cdReader.readUInt16(at: curr + 32) ?? 0)
            let externalAttr = cdReader.readUInt32(at: curr + 38) ?? 0
            var localOffset = UInt64(cdReader.readUInt32(at: curr + 42) ?? 0)
            
            let nameStart = curr + 46
            guard nameStart + nameLen <= cdData.count else { break }
            let nameBytes = cdData.subdata(in: nameStart..<(nameStart + nameLen))
            let filename = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .ascii) ?? ""
            
            // Parse Zip64 Extra Field (Tag 0x0001)
            let extraStart = nameStart + nameLen
            if extraLen >= 4 && extraStart + extraLen <= cdData.count {
                var extraIdx = extraStart
                while extraIdx + 4 <= extraStart + extraLen {
                    let tag = cdReader.readUInt16(at: extraIdx) ?? 0
                    let size = Int(cdReader.readUInt16(at: extraIdx + 2) ?? 0)
                    extraIdx += 4
                    if tag == 0x0001 {
                        var fieldOffset = extraIdx
                        if uncompSize == 0xFFFFFFFF, fieldOffset + 8 <= extraIdx + size {
                            uncompSize = cdReader.readUInt64(at: fieldOffset) ?? uncompSize
                            fieldOffset += 8
                        }
                        if compSize == 0xFFFFFFFF, fieldOffset + 8 <= extraIdx + size {
                            compSize = cdReader.readUInt64(at: fieldOffset) ?? compSize
                            fieldOffset += 8
                        }
                        if localOffset == 0xFFFFFFFF, fieldOffset + 8 <= extraIdx + size {
                            localOffset = cdReader.readUInt64(at: fieldOffset) ?? localOffset
                            fieldOffset += 8
                        }
                    }
                    extraIdx += size
                }
            }
            
            let isUnixDir = (versionMadeBy >> 8 == 3) && ((externalAttr >> 16) & 0o170000 == 0o040000)
            let isDosDir = (externalAttr & 0x10) != 0
            let isDirectory = filename.hasSuffix("/") || isUnixDir || isDosDir
            
            entries.append(CentralDirectoryEntry(
                compressionMethod: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                crc32: crc,
                localHeaderOffset: localOffset,
                filename: filename,
                isDirectory: isDirectory
            ))
            
            curr += 46 + nameLen + extraLen + commentLen
        }
        
        return entries
    }
    
    private static func findEOCDSignature(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var idx = data.count - 22
        while idx >= 0 {
            if data[idx] == 0x50 && data[idx + 1] == 0x4b && data[idx + 2] == 0x05 && data[idx + 3] == 0x06 {
                return idx
            }
            idx -= 1
        }
        return nil
    }
    
    // MARK: - Raw Deflate Decompression via zlib
    
    private static func decompressDeflate(compressedData: Data, expectedSize: Int) throws -> Data {
        guard !compressedData.isEmpty else { return Data() }
        
        var stream = z_stream()
        // -MAX_WBITS (-15) indicates raw Deflate stream without zlib/gzip headers (RFC 1951)
        let initStatus = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw TTZipPluginSecurity.SecurityError.decompressionFailed("zlib initialization error: \(initStatus)")
        }
        defer { inflateEnd(&stream) }
        
        var decompressedData = Data(capacity: expectedSize > 0 ? expectedSize : 64 * 1024)
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        
        try compressedData.withUnsafeBytes { rawIn in
            guard let inBase = rawIn.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(compressedData.count)
            
            while stream.avail_in > 0 {
                var status: Int32 = Z_OK
                chunk.withUnsafeMutableBytes { rawOut in
                    guard let outBase = rawOut.bindMemory(to: Bytef.self).baseAddress else { return }
                    stream.next_out = outBase
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                }
                
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    decompressedData.append(chunk, count: produced)
                }
                
                if status == Z_STREAM_END {
                    break
                } else if status != Z_OK && status != Z_BUF_ERROR {
                    throw TTZipPluginSecurity.SecurityError.decompressionFailed("zlib inflation error: \(status)")
                }
            }
        }
        
        return decompressedData
    }
}
