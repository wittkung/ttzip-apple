// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

// MARK: - XML Parsers for XLSX & ODS

nonisolated func runOfficeXMLParser(_ data: Data, delegate: XMLParserDelegate) -> Bool {
    guard !data.isEmpty else { return false }
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = false
    parser.delegate = delegate
    return parser.parse() && parser.parserError == nil
}

final class XLSXWorkbookMetaParser: NSObject, XMLParserDelegate {
    var sheets: [(name: String, rId: String?)] = []
    var rels: [String: String] = [:]
    private var didCloseWorkbook = false
    private var didCloseRelationships = false

    nonisolated static func parseSheets(from data: Data) -> [(name: String, rId: String?)]? {
        let delegate = XLSXWorkbookMetaParser()
        guard runOfficeXMLParser(data, delegate: delegate), delegate.didCloseWorkbook, !delegate.sheets.isEmpty else {
            return nil
        }
        return delegate.sheets
    }

    nonisolated static func parseRelationships(from data: Data) -> [String: String]? {
        let delegate = XLSXWorkbookMetaParser()
        guard runOfficeXMLParser(data, delegate: delegate), delegate.didCloseRelationships else {
            return nil
        }
        return delegate.rels
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        let local = localXMLName(elementName)
        if local == "sheet" {
            let name = attributeDict["name"] ?? "Sheet\(sheets.count + 1)"
            sheets.append((name: name, rId: attributeDict["r:id"] ?? attributeDict["id"]))
        } else if local == "Relationship", let id = attributeDict["Id"], let target = attributeDict["Target"] {
            rels[id] = target
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let local = localXMLName(elementName)
        if local == "workbook" {
            didCloseWorkbook = true
        } else if local == "Relationships" {
            didCloseRelationships = true
        }
    }
}

final class XLSXSharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var currentSI = ""
    private var inSI = false
    private var inT = false
    private var inRPh = false
    private var didCloseSST = false

    nonisolated static func parse(from data: Data) -> [String]? {
        let delegate = XLSXSharedStringsParser()
        guard runOfficeXMLParser(data, delegate: delegate), delegate.didCloseSST else {
            return nil
        }
        return delegate.strings
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        switch localXMLName(elementName) {
        case "si":
            inSI = true
            currentSI = ""
        case "rPh":
            inRPh = true
        case "t" where inSI && !inRPh:
            inT = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inSI && inT && !inRPh { currentSI.append(string) }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        switch localXMLName(elementName) {
        case "t": inT = false
        case "rPh": inRPh = false
        case "si":
            inSI = false
            strings.append(currentSI)
            currentSI = ""
        case "sst":
            didCloseSST = true
        default: break
        }
    }
}

final class XLSXWorksheetXMLParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var rows: [[String]] = []
    private var currentRowCells: [(col: Int, value: String)] = []
    private var currentRowHasOutOfBudgetValue = false
    private var nextLogicalRowIndex: Int = 0
    private var currentRowIndex: Int = 0
    private var didSetExplicitRowIndex = false
    private var pendingEmptyRows: Int = 0
    private var totalLogicalRows: Int = 0
    private var maxLogicalColumns: Int = 0
    private var nextSequentialCol: Int = 0
    private var currentCellCol: Int = 0
    private var currentCellType: String = ""
    private var currentValueText: String = ""
    private var inValueNode = false
    private var inInlineStr = false
    private var inRPh = false
    private var didSeeSheetData = false
    private var didCloseWorksheet = false

    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

    nonisolated static func parseSheet(from data: Data, name: String, sharedStrings: [String]) -> TTMediaSheetData? {
        let delegate = XLSXWorksheetXMLParser(sharedStrings: sharedStrings)
        guard runOfficeXMLParser(data, delegate: delegate), delegate.didSeeSheetData, delegate.didCloseWorksheet else {
            return nil
        }
        return TTMediaSheetData(
            name: name,
            totalRows: max(delegate.totalLogicalRows, delegate.rows.count),
            totalColumns: max(delegate.maxLogicalColumns, delegate.rows.map(\.count).max() ?? 0),
            rows: delegate.rows
        )
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        switch localXMLName(elementName) {
        case "worksheet", "sheetData":
            didSeeSheetData = true
        case "row":
            startWorksheetRow(attributes: attributeDict)
        case "c":
            startWorksheetCell(attributes: attributeDict)
        case "is": inInlineStr = true
        case "rPh": inRPh = true
        case "v": inValueNode = true
        case "t" where (inInlineStr || currentCellType == "inlineStr") && !inRPh: inValueNode = true
        default: break
        }
    }

    private func startWorksheetRow(attributes: [String: String]) {
        currentRowCells.removeAll(keepingCapacity: true)
        currentRowHasOutOfBudgetValue = false
        nextSequentialCol = 0
        if let rStr = attributes["r"], let rNum = Int(rStr), rNum >= 1 {
            let targetRow = max(nextLogicalRowIndex, min(rNum - 1, 10_000_000))
            pendingEmptyRows += (targetRow - nextLogicalRowIndex)
            currentRowIndex = targetRow
            nextLogicalRowIndex = targetRow + 1
            didSetExplicitRowIndex = true
        } else {
            currentRowIndex = nextLogicalRowIndex
            nextLogicalRowIndex = currentRowIndex + 1
            didSetExplicitRowIndex = false
        }
    }

    private func startWorksheetCell(attributes: [String: String]) {
        currentCellType = attributes["t"] ?? ""
        currentValueText = ""
        let cellRef = attributes["r"]
        if !didSetExplicitRowIndex, let ref = cellRef, let cellRow = parseExcelRowIndex(from: ref), cellRow > currentRowIndex {
            pendingEmptyRows += (cellRow - currentRowIndex)
            currentRowIndex = cellRow
            nextLogicalRowIndex = cellRow + 1
            didSetExplicitRowIndex = true
        }
        currentCellCol = cellRef.flatMap(parseExcelColumnIndex(from:)) ?? nextSequentialCol
        nextSequentialCol = currentCellCol + 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValueNode && !inRPh { currentValueText.append(string) }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        switch localXMLName(elementName) {
        case "v", "t": inValueNode = false
        case "is": inInlineStr = false
        case "rPh": inRPh = false
        case "c": finalizeWorksheetCell()
        case "row": appendCompletedRow()
        case "worksheet": didCloseWorksheet = true
        default: break
        }
    }

    private func finalizeWorksheetCell() {
        let resolved = resolveCellValue(type: currentCellType, rawText: currentValueText)
        guard !resolved.isEmpty, currentCellCol >= 0 else { return }
        maxLogicalColumns = max(maxLogicalColumns, currentCellCol + 1)
        if currentCellCol < TTMediaOfficeSpreadsheetReader.maxSheetColumns {
            currentRowCells.append((col: currentCellCol, value: resolved))
        } else {
            currentRowHasOutOfBudgetValue = true
        }
    }

    private func resolveCellValue(type: String, rawText: String) -> String {
        switch type {
        case "s":
            if let idx = Int(rawText.trimmingCharacters(in: .whitespacesAndNewlines)),
               idx >= 0, idx < sharedStrings.count {
                return sharedStrings[idx]
            }
            return ""
        case "b":
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            return (trimmed == "1" || trimmed.lowercased() == "true") ? "TRUE" : "FALSE"
        default:
            return rawText
        }
    }

    private func appendCompletedRow() {
        let hasNonEmpty = !currentRowCells.isEmpty || currentRowHasOutOfBudgetValue
        guard hasNonEmpty else {
            pendingEmptyRows += 1
            return
        }
        totalLogicalRows = max(totalLogicalRows, currentRowIndex + 1)
        let rowBudget = TTMediaOfficeSpreadsheetReader.maxSheetRows
        if pendingEmptyRows > 0 && rows.count < rowBudget {
            let padCount = min(pendingEmptyRows, rowBudget - rows.count)
            rows.append(contentsOf: repeatElement([], count: padCount))
        }
        pendingEmptyRows = 0
        guard rows.count < rowBudget else { return }
        guard let maxCol = currentRowCells.map(\.col).max() else {
            rows.append([])
            return
        }
        var dense = Array(repeating: "", count: maxCol + 1)
        for item in currentRowCells where item.col >= 0 && item.col <= maxCol {
            dense[item.col] = item.value
        }
        rows.append(dense)
    }
}

final class ODSContentXMLParser: NSObject, XMLParserDelegate {
    struct ParsedTable {
        let name: String
        let rows: [[String]]
        let totalRows: Int
        let totalColumns: Int
    }

    private let targetSheetName: String?
    private var tables: [ParsedTable] = []
    private var tableCounter: Int = 0
    private var inTable = false
    private var currentTableName = ""
    private var currentTableRows: [[String]] = []
    private var currentTableTotalRows: Int = 0
    private var currentTableMaxCols: Int = 0
    private var pendingEmptyRows: Int = 0
    private var currentRowCells: [String] = []
    private var currentColCursor: Int = 0
    private var currentRowMaxNonEmptyCol: Int = -1
    private var currentRowRepeat: Int = 1
    private var inCell = false
    private var currentCellRepeat: Int = 1
    private var currentCellParagraphs: [String] = []
    private var currentParagraphText = ""
    private var currentCellFallbackAttr = ""
    private var inParagraph = false
    private var annotationDepth: Int = 0
    private var didCloseDocumentRoot = false

    init(targetSheetName: String?) { self.targetSheetName = targetSheetName }

    nonisolated static func parseTables(from data: Data, targetSheetName: String?) -> [ParsedTable]? {
        let delegate = ODSContentXMLParser(targetSheetName: targetSheetName)
        guard runOfficeXMLParser(data, delegate: delegate), delegate.didCloseDocumentRoot, !delegate.tables.isEmpty else {
            return nil
        }
        return delegate.tables
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = localXMLName(elementName)
        if local == "table" {
            startTable(attributes: attributeDict)
            return
        }
        guard inTable else { return }
        switch local {
        case "table-row": startRow(attributes: attributeDict)
        case "table-cell", "covered-table-cell": startCell(attributes: attributeDict)
        case "annotation": annotationDepth += 1
        default: startInlineTextElement(local: local, attributes: attributeDict)
        }
    }

    private func startTable(attributes: [String: String]) {
        tableCounter += 1
        let name = attributes["table:name"] ?? attributes["name"] ?? "Sheet\(tableCounter)"
        currentTableName = name
        currentTableRows.removeAll()
        currentTableTotalRows = 0
        currentTableMaxCols = 0
        pendingEmptyRows = 0
        inTable = (targetSheetName == nil || targetSheetName == name)
    }

    private func startRow(attributes: [String: String]) {
        currentRowCells.removeAll(keepingCapacity: true)
        currentColCursor = 0
        currentRowMaxNonEmptyCol = -1
        let rep = Int(attributes["table:number-rows-repeated"] ?? attributes["number-rows-repeated"] ?? "1") ?? 1
        currentRowRepeat = min(max(1, rep), 10_000_000)
    }

    private func startCell(attributes: [String: String]) {
        inCell = true
        let rep = Int(attributes["table:number-columns-repeated"] ?? attributes["number-columns-repeated"] ?? "1") ?? 1
        currentCellRepeat = min(max(1, rep), 1_048_576)
        currentCellParagraphs.removeAll(keepingCapacity: true)
        currentCellFallbackAttr = attributes["office:string-value"]
            ?? attributes["office:value"]
            ?? attributes["office:boolean-value"]
            ?? attributes["office:date-value"]
            ?? attributes["date-value"]
            ?? attributes["office:time-value"]
            ?? attributes["time-value"]
            ?? ""
    }

    private func startInlineTextElement(local: String, attributes: [String: String]) {
        guard inCell, annotationDepth == 0 else { return }
        if local == "p" {
            inParagraph = true
            currentParagraphText = ""
            return
        }
        guard inParagraph else { return }
        switch local {
        case "s":
            let count = Int(attributes["text:c"] ?? attributes["c"] ?? "1") ?? 1
            currentParagraphText.append(String(repeating: " ", count: min(max(1, count), 4096)))
        case "tab": currentParagraphText.append("\t")
        case "line-break": currentParagraphText.append("\n")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTable && inCell && inParagraph && annotationDepth == 0 {
            currentParagraphText.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = localXMLName(elementName)
        if local == "document-content" || local == "document" || local == "spreadsheet" {
            didCloseDocumentRoot = true
            return
        }
        if local == "table" {
            if inTable || targetSheetName == nil {
                tables.append(
                    ParsedTable(
                        name: currentTableName,
                        rows: currentTableRows,
                        totalRows: currentTableTotalRows,
                        totalColumns: currentTableMaxCols
                    )
                )
            }
            inTable = false
            return
        }
        guard inTable else { return }
        switch local {
        case "annotation": annotationDepth = max(0, annotationDepth - 1)
        case "p" where inCell && annotationDepth == 0:
            inParagraph = false
            currentCellParagraphs.append(currentParagraphText)
            currentParagraphText = ""
        case "table-cell", "covered-table-cell": finalizeODSCell()
        case "table-row": finalizeODSRow()
        default: break
        }
    }

    private func finalizeODSCell() {
        inCell = false
        let text = currentCellParagraphs.isEmpty
            ? currentCellFallbackAttr
            : currentCellParagraphs.joined(separator: "\n")
        let startCol = currentColCursor
        let endColExclusive = startCol + currentCellRepeat
        currentColCursor = endColExclusive
        guard !text.isEmpty else { return }
        currentRowMaxNonEmptyCol = max(currentRowMaxNonEmptyCol, endColExclusive - 1)
        currentTableMaxCols = max(currentTableMaxCols, endColExclusive)
        let colBudget = TTMediaOfficeSpreadsheetReader.maxSheetColumns
        guard startCol < colBudget else { return }
        if currentRowCells.count < startCol {
            currentRowCells.append(contentsOf: repeatElement("", count: startCol - currentRowCells.count))
        }
        let inBudgetCount = min(endColExclusive, colBudget) - startCol
        currentRowCells.append(contentsOf: repeatElement(text, count: inBudgetCount))
    }

    private func finalizeODSRow() {
        let hasNonEmpty = !currentRowCells.isEmpty || currentRowMaxNonEmptyCol >= 0
        guard hasNonEmpty else {
            pendingEmptyRows += currentRowRepeat
            return
        }
        currentTableTotalRows += pendingEmptyRows + currentRowRepeat
        let rowBudget = TTMediaOfficeSpreadsheetReader.maxSheetRows
        if pendingEmptyRows > 0 && currentTableRows.count < rowBudget {
            let padCount = min(pendingEmptyRows, rowBudget - currentTableRows.count)
            currentTableRows.append(contentsOf: repeatElement([], count: padCount))
        }
        pendingEmptyRows = 0
        guard currentTableRows.count < rowBudget else { return }
        let repeatTotal = min(currentRowRepeat, rowBudget - currentTableRows.count)
        currentTableRows.append(contentsOf: repeatElement(currentRowCells, count: repeatTotal))
    }
}

nonisolated func localXMLName(_ rawName: String) -> String {
    guard let colon = rawName.lastIndex(of: ":") else { return rawName }
    return String(rawName[rawName.index(after: colon)...])
}

nonisolated func parseExcelColumnIndex(from cellRef: String) -> Int? {
    var col = 0
    var sawLetter = false
    for byte in cellRef.utf8 {
        let upper: UInt8
        if byte >= 65 && byte <= 90 {
            upper = byte
        } else if byte >= 97 && byte <= 122 {
            upper = byte - 32
        } else {
            break
        }
        sawLetter = true
        col = col * 26 + Int(upper - 65 + 1)
        if col > 1_048_576 { return nil }
    }
    return sawLetter ? max(0, col - 1) : nil
}

nonisolated func parseExcelRowIndex(from cellRef: String) -> Int? {
    var row = 0
    var sawDigit = false
    for byte in cellRef.utf8 {
        if byte >= 48 && byte <= 57 {
            sawDigit = true
            row = row * 10 + Int(byte - 48)
            if row > 10_000_000 { return nil }
        } else if sawDigit {
            break
        }
    }
    return (sawDigit && row >= 1) ? (row - 1) : nil
}
