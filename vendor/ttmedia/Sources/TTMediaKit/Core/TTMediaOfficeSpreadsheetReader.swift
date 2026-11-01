// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import zlib

/// Read-only workbook parser for ZIP-backed spreadsheet packages (`.xlsx`, `.xlsm`, `.ods`).
/// Extracts sheet names and cell matrices into `OfficeSpreadsheetWorkbook` without modifying
/// `TTSpreadsheetParser` or permitting in-place writeback.
public enum TTMediaOfficeSpreadsheetReader {
    /// Maximum spreadsheet archive byte size read into memory for workbook parsing (64 MB).
    nonisolated public static let maxArchiveByteBudget: Int = 64 * 1024 * 1024
    /// Maximum decompressed XML part size (32 MB).
    nonisolated public static let maxDecompressedEntryByteBudget: Int = 32 * 1024 * 1024
    /// Maximum rows parsed per sheet (aligned with interactive preview budget + 1 for truncation detection).
    nonisolated public static let maxSheetRows: Int = TTSpreadsheetParser.maxInteractivePreviewRows + 1
    /// Maximum columns materialized per row to prevent sparse repeat bombs.
    nonisolated public static let maxSheetColumns: Int = 512

    // MARK: - Public Entry Points

    nonisolated public static func loadWorkbook(
        from url: URL,
        ext: String? = nil
    ) -> OfficeSpreadsheetWorkbook? {
        let resolvedExt = TTMediaCapabilityMatrix.cleanExtension(from: ext ?? url.pathExtension)
        guard let data = readBoundedArchiveData(from: url) else { return nil }
        return loadWorkbook(data: data, fileName: url.lastPathComponent, fileURL: url, ext: resolvedExt)
    }

    nonisolated public static func loadWorkbook(
        data: Data,
        fileName: String,
        fileURL: URL? = nil,
        ext: String? = nil
    ) -> OfficeSpreadsheetWorkbook? {
        guard data.count >= 22, data.count <= maxArchiveByteBudget else { return nil }
        let resolvedExt = TTMediaCapabilityMatrix.cleanExtension(
            from: ext ?? (fileName as NSString).pathExtension
        )
        guard let entries = ZipPackageReader.parseCentralDirectory(in: data) else { return nil }

        if resolvedExt == "ods" || entries["content.xml"] != nil {
            if let ods = parseODSWorkbook(data: data, entries: entries, fileName: fileName, fileURL: fileURL) {
                return ods
            }
        }
        if resolvedExt == "xlsx" || resolvedExt == "xlsm" || entries["xl/workbook.xml"] != nil {
            if let xlsx = parseXLSXWorkbook(
                data: data,
                entries: entries,
                fileName: fileName,
                fileURL: fileURL,
                resolvedExt: resolvedExt
            ) {
                return xlsx
            }
        }
        return nil
    }

    /// Loads structured worksheet data (including row/column extent and truncation metadata) for a named worksheet.
    nonisolated public static func loadSheet(
        workbook: OfficeSpreadsheetWorkbook,
        sheetName: String
    ) -> TTMediaSheetData? {
        if let active = workbook.activeSheet, active.name == sheetName {
            return active
        }
        let data: Data?
        if let raw = workbook.rawData {
            data = raw
        } else if let url = workbook.fileURL {
            data = readBoundedArchiveData(from: url)
        } else {
            data = nil
        }
        guard let archiveData = data,
              let entries = ZipPackageReader.parseCentralDirectory(in: archiveData) else {
            return nil
        }
        if workbook.format == .ods || entries["content.xml"] != nil,
           let sheet = parseODSSheet(data: archiveData, entries: entries, targetSheetName: sheetName) {
            return sheet
        }
        if let sheet = parseXLSXSheet(data: archiveData, entries: entries, targetSheetName: sheetName) {
            return sheet
        }
        return nil
    }

    /// Loads rows for a specific named worksheet from an `OfficeSpreadsheetWorkbook`.
    nonisolated public static func loadSheetRows(
        workbook: OfficeSpreadsheetWorkbook,
        sheetName: String
    ) -> [[String]]? {
        loadSheet(workbook: workbook, sheetName: sheetName)?.rows
    }

    /// Localized limitation message for binary spreadsheet formats that cannot be rendered inline.
    nonisolated public static func unsupportedSpreadsheetMessage(ext: String) -> String {
        let upper = ext.isEmpty ? "SPREADSHEET" : ext.uppercased()
        let isZh = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        if isZh {
            return "当前表格只读预览支持 XLSX、XLSM、ODS、CSV 与 TSV；暂不支持直接解析 .\(upper) 二进制工作簿。"
        }
        return "Read-only spreadsheet preview supports XLSX, XLSM, ODS, CSV, and TSV; .\(upper) binary workbooks are not supported inline."
    }

    nonisolated private static func readBoundedArchiveData(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxArchiveByteBudget + 1),
              !data.isEmpty,
              data.count <= maxArchiveByteBudget else {
            return nil
        }
        return data
    }

    // MARK: - XLSX Parsing

    nonisolated private static func parseXLSXWorkbook(
        data: Data,
        entries: [String: ZipEntryRecord],
        fileName: String,
        fileURL: URL?,
        resolvedExt: String
    ) -> OfficeSpreadsheetWorkbook? {
        guard let descriptors = resolveXLSXSheetDescriptors(data: data, entries: entries),
              let firstDesc = descriptors.first,
              let sharedStrings = parseXLSXSharedStrings(data: data, entries: entries),
              let activeSheet = loadXLSXSheet(
                  descriptor: firstDesc,
                  sharedStrings: sharedStrings,
                  data: data,
                  entries: entries
              ) else {
            return nil
        }
        let isMacroWorkbook: Bool = if resolvedExt == "xlsm" || entries["xl/vbaProject.bin"] != nil {
            true
        } else if let ctData = ZipPackageReader.extractEntry("[Content_Types].xml", from: data, entries: entries),
                  let ctText = String(data: ctData, encoding: .utf8),
                  ctText.contains("macroEnabled.main+xml") {
            true
        } else {
            OfficeSpreadsheetFormat.resolve(explicitExtension: resolvedExt, fileName: fileName, fileURL: fileURL) == .xlsm
        }
        return OfficeSpreadsheetWorkbook(
            fileName: fileName,
            sheetNames: descriptors.map(\.name),
            activeSheet: activeSheet,
            fileURL: fileURL,
            rawData: fileURL == nil ? data : nil,
            format: isMacroWorkbook ? .xlsm : .xlsx
        )
    }

    nonisolated private static func parseXLSXSheet(
        data: Data, entries: [String: ZipEntryRecord], targetSheetName: String
    ) -> TTMediaSheetData? {
        guard let descriptors = resolveXLSXSheetDescriptors(data: data, entries: entries),
              let desc = descriptors.first(where: { $0.name == targetSheetName }),
              let sharedStrings = parseXLSXSharedStrings(data: data, entries: entries) else {
            return nil
        }
        return loadXLSXSheet(descriptor: desc, sharedStrings: sharedStrings, data: data, entries: entries)
    }

    nonisolated private static func loadXLSXSheet(
        descriptor: (name: String, entryPath: String),
        sharedStrings: [String],
        data: Data,
        entries: [String: ZipEntryRecord]
    ) -> TTMediaSheetData? {
        guard let xmlData = ZipPackageReader.extractEntry(descriptor.entryPath, from: data, entries: entries) else {
            return nil
        }
        return XLSXWorksheetXMLParser.parseSheet(
            from: xmlData,
            name: descriptor.name,
            sharedStrings: sharedStrings
        )
    }

    nonisolated private static func resolveXLSXSheetDescriptors(
        data: Data, entries: [String: ZipEntryRecord]
    ) -> [(name: String, entryPath: String)]? {
        let relMap: [String: String]
        if entries["xl/_rels/workbook.xml.rels"] != nil {
            guard let relData = ZipPackageReader.extractEntry("xl/_rels/workbook.xml.rels", from: data, entries: entries),
                  let parsedRels = XLSXWorkbookMetaParser.parseRelationships(from: relData) else {
                return nil
            }
            relMap = parsedRels
        } else {
            relMap = [:]
        }

        if entries["xl/workbook.xml"] != nil {
            guard let wbData = ZipPackageReader.extractEntry("xl/workbook.xml", from: data, entries: entries),
                  let sheets = XLSXWorkbookMetaParser.parseSheets(from: wbData) else {
                return nil
            }
            let resolved = sheets.enumerated().compactMap { idx, item in
                resolveWorksheetTargetPath(rId: item.rId, index: idx + 1, relMap: relMap, entries: entries)
                    .map { (name: item.name, entryPath: $0) }
            }
            return resolved.count == sheets.count && !resolved.isEmpty ? resolved : nil
        }

        let fallback = entries.keys
            .filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
            .sorted()
            .map { (name: (((($0 as NSString).lastPathComponent) as NSString).deletingPathExtension), entryPath: $0) }
        return fallback.isEmpty ? nil : fallback
    }

    nonisolated private static func resolveWorksheetTargetPath(
        rId: String?, index: Int, relMap: [String: String], entries: [String: ZipEntryRecord]
    ) -> String? {
        if let rId, let target = relMap[rId] {
            let trimmed = target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let normalized = trimmed.hasPrefix("xl/") ? trimmed : "xl/\(trimmed)"
            if entries[normalized] != nil { return normalized }
            if entries[trimmed] != nil { return trimmed }
        }
        let defaultPath = "xl/worksheets/sheet\(index).xml"
        return entries[defaultPath] != nil ? defaultPath : nil
    }

    nonisolated private static func parseXLSXSharedStrings(
        data: Data, entries: [String: ZipEntryRecord]
    ) -> [String]? {
        guard entries["xl/sharedStrings.xml"] != nil else {
            return []
        }
        guard let sstData = ZipPackageReader.extractEntry("xl/sharedStrings.xml", from: data, entries: entries) else {
            return nil
        }
        return XLSXSharedStringsParser.parse(from: sstData)
    }

    // MARK: - ODS Parsing

    nonisolated private static func parseODSWorkbook(
        data: Data, entries: [String: ZipEntryRecord], fileName: String, fileURL: URL?
    ) -> OfficeSpreadsheetWorkbook? {
        guard let contentData = ZipPackageReader.extractEntry("content.xml", from: data, entries: entries),
              let sheets = ODSContentXMLParser.parseTables(from: contentData, targetSheetName: nil),
              let first = sheets.first else {
            return nil
        }
        return OfficeSpreadsheetWorkbook(
            fileName: fileName,
            sheetNames: sheets.map(\.name),
            activeSheet: makeSheetData(from: first),
            fileURL: fileURL,
            rawData: fileURL == nil ? data : nil,
            format: .ods
        )
    }

    nonisolated private static func parseODSSheet(
        data: Data, entries: [String: ZipEntryRecord], targetSheetName: String
    ) -> TTMediaSheetData? {
        guard let contentData = ZipPackageReader.extractEntry("content.xml", from: data, entries: entries),
              let sheets = ODSContentXMLParser.parseTables(from: contentData, targetSheetName: targetSheetName),
              let match = sheets.first(where: { $0.name == targetSheetName }) else {
            return nil
        }
        return makeSheetData(from: match)
    }

    nonisolated private static func makeSheetData(from table: ODSContentXMLParser.ParsedTable) -> TTMediaSheetData {
        TTMediaSheetData(
            name: table.name,
            totalRows: max(table.totalRows, table.rows.count),
            totalColumns: max(table.totalColumns, table.rows.map(\.count).max() ?? 0),
            rows: table.rows
        )
    }
}

public extension TTMediaSheetData {
    /// True when the worksheet's logical row or column extent exceeded `maxSheetRows` / `maxSheetColumns`
    /// and out-of-budget coordinates were truncated without shifting in-budget cells.
    nonisolated var isTruncated: Bool {
        totalRows > rows.count
            || rows.count >= TTMediaOfficeSpreadsheetReader.maxSheetRows
            || totalColumns > TTMediaOfficeSpreadsheetReader.maxSheetColumns
    }
}

public extension OfficeSpreadsheetWorkbook {
    /// True when the active worksheet was truncated by row or column preview budgets.
    nonisolated var isTruncated: Bool {
        activeSheet?.isTruncated ?? false
    }
}

// MARK: - Minimal Bounded ZIP Central Directory & Deflate Reader

private struct ZipEntryRecord: Sendable {
    let compressionMethod: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

private enum ZipPackageReader {
    nonisolated static func parseCentralDirectory(in data: Data) -> [String: ZipEntryRecord]? {
        guard let eocdOffset = findEOCDOffset(in: data) else { return nil }
        let totalEntries = Int(readUInt16LE(data, at: eocdOffset + 10))
        let cdSize = Int(readUInt32LE(data, at: eocdOffset + 12))
        let cdOffset = Int(readUInt32LE(data, at: eocdOffset + 16))
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= data.count else { return nil }

        var entries: [String: ZipEntryRecord] = [:]
        var cursor = cdOffset
        let cdEnd = cdOffset + cdSize
        var parsedCount = 0

        while cursor + 46 <= cdEnd && parsedCount < totalEntries {
            guard readUInt32LE(data, at: cursor) == 0x0201_4B50 else { break }
            let method = readUInt16LE(data, at: cursor + 10)
            let compSize = Int(readUInt32LE(data, at: cursor + 20))
            let uncompSize = Int(readUInt32LE(data, at: cursor + 24))
            let nameLen = Int(readUInt16LE(data, at: cursor + 28))
            let extraLen = Int(readUInt16LE(data, at: cursor + 30))
            let commentLen = Int(readUInt16LE(data, at: cursor + 32))
            let localOffset = Int(readUInt32LE(data, at: cursor + 42))
            let nameStart = cursor + 46
            let nextRecord = nameStart + nameLen + extraLen + commentLen
            guard nextRecord <= cdEnd else { break }

            if let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLen)), encoding: .utf8) {
                entries[name] = ZipEntryRecord(
                    compressionMethod: method,
                    compressedSize: compSize,
                    uncompressedSize: uncompSize,
                    localHeaderOffset: localOffset
                )
            }
            cursor = nextRecord
            parsedCount += 1
        }
        return entries.isEmpty ? nil : entries
    }

    nonisolated static func extractEntry(
        _ path: String,
        from data: Data,
        entries: [String: ZipEntryRecord]
    ) -> Data? {
        guard let entry = entries[path] else { return nil }
        guard entry.uncompressedSize <= TTMediaOfficeSpreadsheetReader.maxDecompressedEntryByteBudget,
              entry.compressedSize >= 0,
              entry.localHeaderOffset >= 0,
              entry.localHeaderOffset + 30 <= data.count else {
            return nil
        }
        let lfh = entry.localHeaderOffset
        guard readUInt32LE(data, at: lfh) == 0x0403_4B50 else { return nil }
        let nameLen = Int(readUInt16LE(data, at: lfh + 26))
        let extraLen = Int(readUInt16LE(data, at: lfh + 28))
        let payloadStart = lfh + 30 + nameLen + extraLen
        let payloadEnd = payloadStart + entry.compressedSize
        guard payloadStart >= 0, payloadEnd <= data.count else { return nil }
        let compressedSlice = data.subdata(in: payloadStart..<payloadEnd)

        if entry.compressionMethod == 0 {
            return compressedSlice
        }
        if entry.compressionMethod == 8 {
            return inflateRawDeflate(
                compressedSlice,
                expectedSize: entry.uncompressedSize,
                maxOutputBytes: TTMediaOfficeSpreadsheetReader.maxDecompressedEntryByteBudget
            )
        }
        return nil
    }

    nonisolated private static func findEOCDOffset(in data: Data) -> Int? {
        let minEOCDSize = 22
        guard data.count >= minEOCDSize else { return nil }
        let maxComment = min(data.count - minEOCDSize, 65_535)
        let startSearch = data.count - minEOCDSize - maxComment
        var offset = data.count - minEOCDSize
        while offset >= startSearch {
            if readUInt32LE(data, at: offset) == 0x0605_4B50 {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    nonisolated private static func inflateRawDeflate(
        _ compressed: Data,
        expectedSize: Int,
        maxOutputBytes: Int
    ) -> Data? {
        if compressed.isEmpty { return expectedSize == 0 ? Data() : nil }
        var stream = z_stream()
        let initStatus = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let initialCap = min(max(expectedSize, 4096), maxOutputBytes)
        var output = Data( capacity: initialCap)
        let chunkSize = 32_768
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        return compressed.withUnsafeBytes { rawBuffer -> Data? in
            guard let basePtr = rawBuffer.bindMemory(to: Bytef.self).baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: basePtr)
            stream.avail_in = uInt(rawBuffer.count)

            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    if output.count + produced > maxOutputBytes { return nil }
                    output.append(chunk, count: produced)
                }
                if status == Z_STREAM_END {
                    return output
                }
                if status != Z_OK || (produced == 0 && stream.avail_in == 0) {
                    return nil
                }
            }
        }
    }

    nonisolated private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    nonisolated private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
