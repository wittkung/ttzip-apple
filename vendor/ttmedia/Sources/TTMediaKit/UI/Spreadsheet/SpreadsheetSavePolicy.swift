// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaDemux

/// Errors thrown when a controlled delta save transaction detects a conflict or I/O failure.
public enum TTDeltaSaveConflictError: LocalizedError, Equatable {
    case externalFileModified(URL)
    case transactionFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .externalFileModified(let url):
            return "External file modification detected for \(url.lastPathComponent)"
        case .transactionFailed(let code):
            return "Controlled delta save transaction failed (code \(code))"
        }
    }
}

/// Receipt describing the outcome of a controlled delta save transaction.
public struct TTDeltaSaveReceipt: Sendable, Equatable {
    public let opsCount: Int
    public let usedDeltaPath: Bool

    public init(opsCount: Int, usedDeltaPath: Bool) {
        self.opsCount = opsCount
        self.usedDeltaPath = usedDeltaPath
    }
}

/// Shared controlled text and CSV delta save transaction runner bridging Swift editors to Rust C-ABI.
public enum TTControlledTextSaveTransaction {
    nonisolated public static func commit(
        payload: String,
        expectedBaseline: String?,
        encoding: TTTextSourceEncoding,
        targetURL: URL,
        isCSV: Bool
    ) throws -> TTDeltaSaveReceipt {
        let standardizedURL = targetURL.standardizedFileURL
        let path = standardizedURL.path
        let modifiedLen = payload.utf8.count
        var modifiedBytes = ContiguousArray(payload.utf8)
        modifiedBytes.append(0)
        let hasExpected = expectedBaseline != nil
        let baselineStr = expectedBaseline ?? ""
        let baselineLen = baselineStr.utf8.count
        var baselineBytes = ContiguousArray(baselineStr.utf8)
        baselineBytes.append(0)
        let includeBOM = (encoding == .utf8BOM)
        var opsCount: Int = 0
        var usedDeltaPath: Bool = false

        let status: Int32 = path.withCString { pathPtr in
            modifiedBytes.withUnsafeBufferPointer { modBuf in
                baselineBytes.withUnsafeBufferPointer { baseBuf in
                    ttmedia_delta_commit_file_transaction(
                        pathPtr,
                        hasExpected ? baseBuf.baseAddress : nil,
                        hasExpected ? baselineLen : 0,
                        hasExpected,
                        modBuf.baseAddress,
                        modifiedLen,
                        includeBOM,
                        isCSV,
                        &opsCount,
                        &usedDeltaPath
                    )
                }
            }
        }

        if status == 0 {
            return TTDeltaSaveReceipt(opsCount: opsCount, usedDeltaPath: usedDeltaPath)
        }
        if status == -409 {
            throw TTDeltaSaveConflictError.externalFileModified(standardizedURL)
        }
        throw TTDeltaSaveConflictError.transactionFailed(status)
    }
}

// ADR-042: NSLock-synchronized baseline tracker for SwiftUI View value types across sequential saves.
public final class TTSavedBaselineTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var initialContentBaseline: String
    private var initialDiskBaseline: String
    private var latestSavedBaseline: String? = nil

    public init(
        initialContent: String,
        fileURL: URL? = nil,
        allowsDiskBaselineLoad: Bool = true,
        maxBaselineBytes: Int = TTTextPreviewBytePolicy.maxInteractiveTextUTF8Bytes
    ) {
        self.initialContentBaseline = initialContent
        self.initialDiskBaseline = Self.readBoundedDiskBaseline(
            from: fileURL,
            allowsDiskLoad: allowsDiskBaselineLoad,
            maxBytes: maxBaselineBytes
        ) ?? initialContent
    }

    private static func readBoundedDiskBaseline(
        from fileURL: URL?,
        allowsDiskLoad: Bool,
        maxBytes: Int
    ) -> String? {
        guard allowsDiskLoad,
              maxBytes > 0,
              let url = fileURL,
              url.isFileURL else {
            return nil
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = (attrs[.size] as? NSNumber)?.intValue,
           fileSize > maxBytes {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1),
              data.count <= maxBytes else {
            return nil
        }
        return TTMediaContentReader.decodeText(data: data)
    }

    public func activeBaseline(hasContentOverride: Bool, stateBaseline: String?) -> String {
        if let stateBaseline {
            return stateBaseline
        }
        lock.lock()
        defer { lock.unlock() }
        if let saved = latestSavedBaseline {
            return saved
        }
        return hasContentOverride ? initialContentBaseline : initialDiskBaseline
    }

    public func recordSave(_ newBaseline: String) {
        lock.lock()
        latestSavedBaseline = newBaseline
        initialContentBaseline = newBaseline
        initialDiskBaseline = newBaseline
        lock.unlock()
    }

    public func reset(
        initialContent: String,
        fileURL: URL? = nil,
        allowsDiskBaselineLoad: Bool = true,
        maxBaselineBytes: Int = TTTextPreviewBytePolicy.maxInteractiveTextUTF8Bytes
    ) {
        let diskBaseline = Self.readBoundedDiskBaseline(
            from: fileURL,
            allowsDiskLoad: allowsDiskBaselineLoad,
            maxBytes: maxBaselineBytes
        ) ?? initialContent
        lock.lock()
        latestSavedBaseline = nil
        initialContentBaseline = initialContent
        initialDiskBaseline = diskBaseline
        lock.unlock()
    }
}

/// Policy governing in-place file saving for `SpreadsheetTablePreviewView`.
///
/// Enforces that Office workbooks and derived multi-sheet representations are strictly read-only,
/// and only explicit delimited text sources (`.csv`, `.tsv`, `.tab`) without workbook context
/// may write UTF-8 text back to their source `fileURL`.
public enum SpreadsheetSavePolicy {

    /// File extensions permitted for in-place delimited text overwrite.
    public static let allowedInPlaceSaveExtensions: Set<String> = ["csv", "tsv", "tab"]

    /// Evaluates the detailed edit capability and read-only reason for a spreadsheet preview instance.
    nonisolated public static func evaluateEditCapability(
        fileURL: URL?,
        fileName: String = "",
        workbook: OfficeSpreadsheetWorkbook? = nil,
        hasSheetLoader: Bool = false,
        isPreviewTruncated: Bool = false,
        resourceContext: TTPreviewResourceContext? = nil
    ) -> TTPreviewEditCapability {
        let isDerived = workbook != nil || hasSheetLoader
        if let context = resourceContext {
            return context.effectiveEditCapability(
                isTruncated: isPreviewTruncated,
                isDerived: isDerived,
                allowedExtensions: allowedInPlaceSaveExtensions
            )
        }
        if isDerived {
            return .readOnly(.derivedRepresentation)
        }
        if isPreviewTruncated {
            return .readOnly(.previewTruncated)
        }
        guard let url = fileURL, url.isFileURL else {
            return .readOnly(.missingFileURL)
        }
        if TTPreviewResourceContext.isManagedPreviewStagingURL(url) {
            return .readOnly(.ephemeralStagingPath)
        }
        let urlExtension = cleanExtension(url.pathExtension)
        guard allowedInPlaceSaveExtensions.contains(urlExtension) else {
            return .readOnly(.unsupportedExtension)
        }
        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            let nameExtension = cleanExtension((trimmedName as NSString).pathExtension)
            if !nameExtension.isEmpty && !allowedInPlaceSaveExtensions.contains(nameExtension) {
                return .readOnly(.unsupportedExtension)
            }
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            return .readOnly(.fileSystemReadOnly)
        }
        return .editableInPlace(targetURL: url.standardizedFileURL)
    }

    /// Evaluates whether the spreadsheet preview instance is permitted to overwrite `fileURL` in place.
    nonisolated public static func canSaveInPlace(
        fileURL: URL?,
        fileName: String = "",
        workbook: OfficeSpreadsheetWorkbook? = nil,
        hasSheetLoader: Bool = false,
        isPreviewTruncated: Bool = false,
        resourceContext: TTPreviewResourceContext? = nil
    ) -> Bool {
        if let context = resourceContext {
            return context.validateInPlaceSaveTarget(
                expectedFileURL: fileURL,
                fileName: fileName,
                allowedExtensions: allowedInPlaceSaveExtensions,
                isTruncated: isPreviewTruncated,
                isDerived: workbook != nil || hasSheetLoader
            ) != nil
        }
        return evaluateEditCapability(
            fileURL: fileURL,
            fileName: fileName,
            workbook: workbook,
            hasSheetLoader: hasSheetLoader,
            isPreviewTruncated: isPreviewTruncated,
            resourceContext: nil
        ).isEditableInPlace
    }

    /// Attempts to write `content` via the controlled delta save transaction if `canSaveInPlace` succeeds.
    ///
    /// - Returns: `TTDeltaSaveReceipt` if permitted and committed; `nil` if blocked by policy.
    @discardableResult
    nonisolated public static func saveInPlaceWithDeltaReceipt(
        content: String,
        expectedBaseline: String? = nil,
        fileURL: URL?,
        fileName: String = "",
        workbook: OfficeSpreadsheetWorkbook? = nil,
        hasSheetLoader: Bool = false,
        isPreviewTruncated: Bool = false,
        resourceContext: TTPreviewResourceContext? = nil
    ) throws -> TTDeltaSaveReceipt? {
        guard content.utf8.count <= TTSpreadsheetParser.maxInteractivePreviewUTF8Bytes else {
            return nil
        }
        let targetURL: URL?
        if let context = resourceContext {
            targetURL = context.validateInPlaceSaveTarget(
                expectedFileURL: fileURL,
                fileName: fileName,
                allowedExtensions: allowedInPlaceSaveExtensions,
                isTruncated: isPreviewTruncated,
                isDerived: workbook != nil || hasSheetLoader
            )
        } else {
            targetURL = evaluateEditCapability(
                fileURL: fileURL,
                fileName: fileName,
                workbook: workbook,
                hasSheetLoader: hasSheetLoader,
                isPreviewTruncated: isPreviewTruncated,
                resourceContext: nil
            ).writableTargetURL
        }
        guard let url = targetURL else {
            return nil
        }
        let inspectedEncoding = TTTextSourceInspection.inspect(url: url, fallbackText: content).encoding
        let saveEncoding: TTTextSourceEncoding = (inspectedEncoding == .utf8BOM) ? .utf8BOM : .utf8
        return try TTControlledTextSaveTransaction.commit(
            payload: content,
            expectedBaseline: expectedBaseline,
            encoding: saveEncoding,
            targetURL: url,
            isCSV: true
        )
    }

    /// Attempts to write `content` as UTF-8 to `fileURL` only if `canSaveInPlace` succeeds.
    ///
    /// - Returns: `true` if the write was permitted and succeeded; `false` if blocked by policy.
    @discardableResult
    nonisolated public static func saveInPlace(
        content: String,
        expectedBaseline: String? = nil,
        fileURL: URL?,
        fileName: String = "",
        workbook: OfficeSpreadsheetWorkbook? = nil,
        hasSheetLoader: Bool = false,
        isPreviewTruncated: Bool = false,
        resourceContext: TTPreviewResourceContext? = nil
    ) throws -> Bool {
        try saveInPlaceWithDeltaReceipt(
            content: content,
            expectedBaseline: expectedBaseline,
            fileURL: fileURL,
            fileName: fileName,
            workbook: workbook,
            hasSheetLoader: hasSheetLoader,
            isPreviewTruncated: isPreviewTruncated,
            resourceContext: resourceContext
        ) != nil
    }

    nonisolated private static func cleanExtension(_ rawExtension: String) -> String {
        rawExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}

// MARK: - Precomputed Background Snapshot & Cancellation Pipeline

public struct SpreadsheetComputedTableSnapshot: Sendable {
    public let rows: [[String]]
    public let tableState: SpreadsheetTableState
    public let columnWidths: [Int: CGFloat]
    public let detectedDelimiter: TTSpreadsheetDelimiter
    let actualDelimiter: Character
    public let isTruncated: Bool
    public let hasMoreRows: Bool
}

public enum SpreadsheetBackgroundPipeline {
    nonisolated static func runCancellableDetached<T: Sendable>(
        priority: TaskPriority = .userInitiated,
        operation: @Sendable @escaping () -> T
    ) async -> T {
        let worker = Task.detached(priority: priority, operation: operation)
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    nonisolated static func buildTableSnapshot(
        rows: [[String]],
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        detectedDelimiter: TTSpreadsheetDelimiter,
        actualDelimiter: Character,
        isTruncated: Bool,
        hasMoreRows: Bool
    ) -> SpreadsheetComputedTableSnapshot {
        let state = SpreadsheetTableState(
            parsedRows: rows,
            useFirstRowAsHeader: useFirstRowAsHeader,
            searchQuery: searchQuery
        )
        let widths = SpreadsheetTableLayoutEngine.calculateColumnWidths(
            parsedRows: Array(rows.prefix(200)),
            headerNames: state.headerNames,
            maxColumnCount: state.maxColumnCount
        )
        return SpreadsheetComputedTableSnapshot(
            rows: rows,
            tableState: state,
            columnWidths: widths,
            detectedDelimiter: detectedDelimiter,
            actualDelimiter: actualDelimiter,
            isTruncated: isTruncated,
            hasMoreRows: hasMoreRows
        )
    }

    public nonisolated static func computeFirstScreenSnapshot(
        content: String,
        overrideDelimiter: Character?,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxUTF8Bytes: Int
    ) async -> SpreadsheetComputedTableSnapshot? {
        await runCancellableDetached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil }
            let (bounded, didTruncateBytes) = TTSpreadsheetParser.truncateUTF8Prefix(content, maxBytes: maxUTF8Bytes)
            let detected = TTSpreadsheetParser.detectDelimiter(in: bounded)
            let actualDelim = overrideDelimiter ?? detected.rawValue
            let chunkResult = TTSpreadsheetParser.parsePrefix(text: bounded, delimiter: actualDelim, maxRows: 200)
            guard !Task.isCancelled else { return nil }
            return buildTableSnapshot(
                rows: chunkResult.rows,
                useFirstRowAsHeader: useFirstRowAsHeader,
                searchQuery: searchQuery,
                detectedDelimiter: detected,
                actualDelimiter: actualDelim,
                isTruncated: didTruncateBytes,
                hasMoreRows: chunkResult.isTruncated
            )
        }
    }

    public nonisolated static func computeFullBudgetedSnapshot(
        content: String,
        stage1: SpreadsheetComputedTableSnapshot,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int,
        maxUTF8Bytes: Int
    ) async -> SpreadsheetComputedTableSnapshot? {
        await runCancellableDetached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            let fullResult = TTSpreadsheetParser.parsePrefix(
                text: content,
                delimiter: stage1.actualDelimiter,
                maxRows: maxRows,
                maxUTF8Bytes: maxUTF8Bytes
            )
            guard !Task.isCancelled, !fullResult.rows.isEmpty else { return nil }
            return buildTableSnapshot(
                rows: fullResult.rows,
                useFirstRowAsHeader: useFirstRowAsHeader,
                searchQuery: searchQuery,
                detectedDelimiter: stage1.detectedDelimiter,
                actualDelimiter: stage1.actualDelimiter,
                isTruncated: fullResult.isTruncated,
                hasMoreRows: false
            )
        }
    }

    public nonisolated static func computeWorkbookFirstScreenSnapshot(
        sheet: TTMediaSheetData,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> SpreadsheetComputedTableSnapshot? {
        let sheetRows = sheet.rows
        let sheetTruncated = sheet.isTruncated || sheetRows.count > maxRows
        return await runCancellableDetached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil }
            let firstChunk = Array(sheetRows.prefix(200))
            return buildTableSnapshot(
                rows: firstChunk,
                useFirstRowAsHeader: useFirstRowAsHeader,
                searchQuery: searchQuery,
                detectedDelimiter: .comma,
                actualDelimiter: ",",
                isTruncated: sheetTruncated,
                hasMoreRows: sheetRows.count > firstChunk.count
            )
        }
    }

    public nonisolated static func computeWorkbookFullSnapshot(
        sheet: TTMediaSheetData,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> (snapshot: SpreadsheetComputedTableSnapshot, csv: String)? {
        let sheetRows = sheet.rows
        let sheetTruncated = sheet.isTruncated || sheetRows.count > maxRows
        return await runCancellableDetached(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            let cappedRows = Array(sheetRows.prefix(maxRows))
            let csv = TTSpreadsheetParser.exportToDelimited(rows: cappedRows, delimiter: ",")
            guard !Task.isCancelled else { return nil }
            let snapshot = buildTableSnapshot(
                rows: cappedRows,
                useFirstRowAsHeader: useFirstRowAsHeader,
                searchQuery: searchQuery,
                detectedDelimiter: .comma,
                actualDelimiter: ",",
                isTruncated: sheetTruncated,
                hasMoreRows: false
            )
            return (snapshot, csv)
        }
    }

    public nonisolated static func loadAndComputeSelectedSheet(
        sheetName: String,
        workbook: OfficeSpreadsheetWorkbook,
        sheetDataLoader: (@Sendable (String) async -> TTMediaSheetData?)?,
        sheetLoader: (@Sendable (String) async -> [[String]]?)?,
        useFirstRowAsHeader: Bool,
        searchQuery: String,
        maxRows: Int
    ) async -> (result: SpreadsheetParseResult, state: SpreadsheetTableState, isTruncated: Bool)? {
        let worker = Task.detached(priority: .userInitiated) { () -> (result: SpreadsheetParseResult, state: SpreadsheetTableState, isTruncated: Bool)? in
            guard !Task.isCancelled else { return nil }
            let resolvedSheet: TTMediaSheetData?
            if let dataLoader = sheetDataLoader {
                resolvedSheet = await dataLoader(sheetName)
            } else if let rowLoader = sheetLoader {
                // Legacy rows-only contract: only proves extent from the returned rows and local preview budget.
                // Never secretly re-read or borrow source workbook metadata by row-count matching;
                // whether the external caller pre-truncated its source is unrepresented by `[[String]]`.
                guard let loadedRows = await rowLoader(sheetName) else { return nil }
                resolvedSheet = TTMediaSheetData(
                    name: sheetName,
                    totalRows: loadedRows.count,
                    totalColumns: loadedRows.map(\.count).max() ?? 0,
                    rows: loadedRows
                )
            } else {
                resolvedSheet = TTMediaOfficeSpreadsheetReader.loadSheet(workbook: workbook, sheetName: sheetName)
            }
            guard !Task.isCancelled, let targetSheet = resolvedSheet else { return nil }
            let sheetRows = targetSheet.rows
            let cappedRows = Array(sheetRows.prefix(maxRows))
            let csv = TTSpreadsheetParser.exportToDelimited(rows: cappedRows, delimiter: ",")
            guard !Task.isCancelled else { return nil }
            let state = SpreadsheetTableState(
                parsedRows: cappedRows,
                useFirstRowAsHeader: useFirstRowAsHeader,
                searchQuery: searchQuery
            )
            let widths = SpreadsheetTableLayoutEngine.calculateColumnWidths(
                parsedRows: Array(cappedRows.prefix(200)),
                headerNames: state.headerNames,
                maxColumnCount: state.maxColumnCount
            )
            guard !Task.isCancelled else { return nil }
            let isTruncated = targetSheet.isTruncated || sheetRows.count > maxRows
            return (
                SpreadsheetParseResult(
                    sheetName: sheetName,
                    parsedRows: cappedRows,
                    rawContent: csv,
                    columnWidths: widths
                ),
                state,
                isTruncated
            )
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

