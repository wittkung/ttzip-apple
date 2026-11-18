// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AppKit
import CryptoKit
@preconcurrency import PDFKit
import TTI18nCore
import TTI18nUI

/// Localized diagnostics reported by the PDF loader.
public enum PDFPreviewLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case loadFailedCorruptOrEmpty = "media.pdf.loadFailedCorruptOrEmpty"
    case incorrectPassword = "media.pdf.incorrectPassword"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .loadFailedCorruptOrEmpty: (
            "The PDF file is damaged, empty, or cannot be opened.",
            "PDF 文件已损坏、为空或无法打开。",
            "PDF 檔案已損毀、為空或無法打開。"
        ),
        .incorrectPassword: ("Incorrect password. Please try again.", "密码错误，请重试。", "密碼錯誤，請重試。"),
    ]
}

/// Resolves loader diagnostics through the shared `TTI18n` localization state.
@MainActor
public enum PDFPreviewLocalization {
    public static func text(_ key: PDFPreviewLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }
}

// MARK: - Content-Aware Input Identity

/// Content-aware identity for PDF preview inputs.
///
/// Combines standardized file URL, disk resource version metadata (`st_dev`, `st_ino`,
/// `st_size`, `st_mtimespec`), and a bounded SHA-256 content digest so both in-memory
/// equal-length `Data` mutations and on-disk atomic replacements / same-path equal-length
/// overwrites always produce a distinct identity across loader, thumbnail cache, and worker pools.
public struct PDFPreviewInputIdentity: Equatable, Hashable, Sendable {
    public let standardizedURL: String?
    public let dataByteCount: Int?
    public let dataSHA256: [UInt8]?
    public let diskResourceVersion: String?
    public let contentDigest: String
    public let cacheKey: String
    public var cacheKeyPrefix: String { cacheKey }

    nonisolated public init(
        url: URL?,
        data: Data?,
        maxDigestBytes: Int = PDFPreviewLoader.maxReadBudgetBytes
    ) {
        let normalizedURL = url?.standardizedFileURL.absoluteString
        self.standardizedURL = normalizedURL
        if let raw = data {
            let digestBytes = Array(SHA256.hash(data: raw))
            let hex = digestBytes.map { String(format: "%02x", $0) }.joined()
            self.dataByteCount = raw.count
            self.dataSHA256 = digestBytes
            self.diskResourceVersion = nil
            self.contentDigest = hex
            self.cacheKey = "\(normalizedURL ?? "memory")#\(raw.count)#\(hex)"
        } else if let validURL = url, validURL.isFileURL {
            let snapshot = Self.computeDiskSnapshot(for: validURL, maxBytes: maxDigestBytes)
            self.dataByteCount = snapshot.byteCount
            self.dataSHA256 = snapshot.sha256Bytes
            self.diskResourceVersion = snapshot.versionTag
            self.contentDigest = snapshot.digestTag
            self.cacheKey = "\(normalizedURL ?? "file")#\(snapshot.digestTag)"
        } else {
            self.dataByteCount = nil
            self.dataSHA256 = nil
            self.diskResourceVersion = nil
            self.contentDigest = normalizedURL ?? "empty"
            self.cacheKey = normalizedURL ?? "empty"
        }
    }

    private struct DiskSnapshot {
        let byteCount: Int?
        let sha256Bytes: [UInt8]?
        let versionTag: String
        let digestTag: String
    }

    nonisolated private static func computeDiskSnapshot(for fileURL: URL, maxBytes: Int) -> DiskSnapshot {
        let path = fileURL.standardizedFileURL.path
        var st = stat()
        let hasStat = stat(path, &st) == 0
        let versionTag: String
        if hasStat {
            versionTag = "d\(st.st_dev)-i\(st.st_ino)-s\(st.st_size)-m\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        } else {
            versionTag = "missing"
        }
        guard hasStat, st.st_size >= 0, let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return DiskSnapshot(byteCount: nil, sha256Bytes: nil, versionTag: versionTag, digestTag: versionTag)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalRead = 0
        let budget = max(maxBytes, 1)
        while totalRead < budget {
            let toRead = min(65_536, budget - totalRead)
            guard let chunk = try? handle.read(upToCount: toRead), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            totalRead += chunk.count
        }
        let digestBytes = Array(hasher.finalize())
        let hex = digestBytes.map { String(format: "%02x", $0) }.joined()
        return DiskSnapshot(
            byteCount: Int(st.st_size),
            sha256Bytes: digestBytes,
            versionTag: versionTag,
            digestTag: "\(versionTag)#\(totalRead)#\(hex)"
        )
    }
}

// MARK: - PDF Layout Modes

public enum PDFLayoutMode: String, CaseIterable, Identifiable, Sendable {
    case singleFullWidth = "Single Page"
    case twoPages = "Two Pages"
    case threePages = "Three Pages"
    
    public var id: String { rawValue }
}

public final class InteractivePDFView: PDFView {
    public override func magnify(with event: NSEvent) {
        if self.autoScales {
            self.autoScales = false
        }
        let currentScale = self.scaleFactor
        let newScale = currentScale * (1.0 + event.magnification)
        self.scaleFactor = min(max(newScale, minScaleFactor), maxScaleFactor)
    }
    
    public override func smartMagnify(with event: NSEvent) {
        if self.autoScales || abs(self.scaleFactor - 1.0) < 0.2 {
            self.autoScales = false
            self.scaleFactor = 2.5
        } else {
            self.autoScales = true
        }
    }
}

// MARK: - Thumbnail Pixel Budget Sizing

extension PDFThumbnailRenderCoordinator {
    /// Clamps a requested display size and backing scale factor to the strict per-card pixel budget (`<= 420x560`).
    nonisolated public static func budgetedPixelSize(
        for displayPointSize: CGSize,
        scaleFactor: CGFloat = 2.0,
        pageAspectRatio: CGFloat = 0.75
    ) -> CGSize {
        let resolvedScale = min(max(scaleFactor, 1.0), 3.0)
        let baseWidth = displayPointSize.width > 1 ? displayPointSize.width : defaultCardPointSize.width
        let baseHeight = displayPointSize.height > 1 ? displayPointSize.height : defaultCardPointSize.height
        var pixelWidth = baseWidth * resolvedScale
        var pixelHeight = baseHeight * resolvedScale

        if pageAspectRatio > 0.05 {
            let heightFromAspect = pixelWidth / pageAspectRatio
            if heightFromAspect <= pixelHeight {
                pixelHeight = heightFromAspect
            } else {
                pixelWidth = pixelHeight * pageAspectRatio
            }
        }

        let widthRatio = maxPixelWidth / max(pixelWidth, 1)
        let heightRatio = maxPixelHeight / max(pixelHeight, 1)
        let clampScale = min(1.0, min(widthRatio, heightRatio))
        pixelWidth = floor(pixelWidth * clampScale)
        pixelHeight = floor(pixelHeight * clampScale)

        let area = pixelWidth * pixelHeight
        if area > maxPixelArea, area > 0 {
            let areaScale = sqrt(maxPixelArea / area)
            pixelWidth = floor(pixelWidth * areaScale)
            pixelHeight = floor(pixelHeight * areaScale)
        }

        return CGSize(
            width: max(16, min(pixelWidth, maxPixelWidth)),
            height: max(16, min(pixelHeight, maxPixelHeight))
        )
    }

    nonisolated public static func thumbnailCacheKey(
        identityKey: String,
        zeroBasedPageIndex: Int,
        pixelSize: CGSize
    ) -> String {
        "\(identityKey)#p\(zeroBasedPageIndex)#\(Int(pixelSize.width.rounded()))x\(Int(pixelSize.height.rounded()))"
    }
}

// MARK: - Budgeted Stream Reading & Detached PDF Load Helpers

extension PDFPreviewLoader {
    struct TransferablePDFDocumentBox: @unchecked Sendable {
        let document: PDFDocument?
        let loadMs: Double
        let parseMs: Double
    }

    nonisolated public static func loadBudgetedDocument(
        url: URL?,
        data: Data?,
        maxBytes: Int = maxReadBudgetBytes,
        onBeforeStreamReadChunk: (@Sendable () -> Void)? = nil
    ) -> PDFDocument? {
        loadBudgetedDocumentTimed(
            url: url,
            data: data,
            maxBytes: maxBytes,
            onBeforeStreamReadChunk: onBeforeStreamReadChunk
        ).document
    }

    nonisolated static func loadBudgetedDocumentTimed(
        url: URL?,
        data: Data?,
        maxBytes: Int,
        onBeforeStreamReadChunk: (@Sendable () -> Void)?
    ) -> (document: PDFDocument?, loadMs: Double, parseMs: Double) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard !Task.isCancelled, maxBytes > 0 else { return (nil, 0, 0) }
        let resolvedData: Data?
        if let raw = data {
            guard raw.count <= maxBytes, !Task.isCancelled else { return (nil, 0, 0) }
            resolvedData = raw
        } else if let validURL = url {
            resolvedData = readBoundedStreamData(
                from: validURL,
                maxBytes: maxBytes,
                onBeforeStreamReadChunk: onBeforeStreamReadChunk
            )
        } else {
            resolvedData = nil
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        let loadMs = Double(t1 &- t0) / 1_000_000.0
        guard let boundedData = resolvedData, !Task.isCancelled else { return (nil, loadMs, 0) }
        let doc = PDFDocument(data: boundedData)
        let t2 = DispatchTime.now().uptimeNanoseconds
        let parseMs = Double(t2 &- t1) / 1_000_000.0
        return (Task.isCancelled ? nil : doc, loadMs, parseMs)
    }

    nonisolated public static func readBoundedStreamData(
        from url: URL,
        maxBytes: Int = maxReadBudgetBytes,
        onBeforeStreamReadChunk: (@Sendable () -> Void)? = nil
    ) -> Data? {
        guard !Task.isCancelled, maxBytes > 0 else { return nil }
        if url.isFileURL {
            return readBoundedLocalFileData(from: url, maxBytes: maxBytes, onBeforeStreamReadChunk: onBeforeStreamReadChunk)
        }
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        onBeforeStreamReadChunk?()
        let chunkSize = min(max(maxBytes + 1, 4096), 65_536)
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var accumulated = Data()

        while !Task.isCancelled {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead < 0 { return nil }
            if bytesRead == 0 { break }
            if accumulated.count + bytesRead > maxBytes { return nil }
            accumulated.append(buffer, count: bytesRead)
        }
        guard !Task.isCancelled, !accumulated.isEmpty else { return nil }
        return accumulated
    }

    nonisolated private static func readBoundedLocalFileData(
        from fileURL: URL,
        maxBytes: Int,
        onBeforeStreamReadChunk: (@Sendable () -> Void)?
    ) -> Data? {
        var st = stat()
        if stat(fileURL.standardizedFileURL.path, &st) == 0 {
            guard st.st_size >= 0, st.st_size <= maxBytes else { return nil }
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }

        onBeforeStreamReadChunk?()
        let chunkSize = min(max(maxBytes + 1, 4096), 65_536)
        var accumulated = Data()
        do {
            while !Task.isCancelled {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                if accumulated.count + chunk.count > maxBytes { return nil }
                accumulated.append(chunk)
            }
        } catch {
            return nil
        }
        guard !Task.isCancelled, !accumulated.isEmpty else { return nil }
        return accumulated
    }

    nonisolated public static func runDetachedBudgetedLoad(
        url: URL?,
        data: Data?,
        maxBytes: Int = maxReadBudgetBytes,
        priority: TaskPriority = .userInitiated,
        onBeforeStreamReadChunk: (@Sendable () -> Void)? = nil
    ) async -> PDFDocument? {
        await runDetachedBudgetedLoadTimed(
            url: url,
            data: data,
            maxBytes: maxBytes,
            priority: priority,
            onBeforeStreamReadChunk: onBeforeStreamReadChunk
        ).document
    }

    nonisolated static func runDetachedBudgetedLoadTimed(
        url: URL?,
        data: Data?,
        maxBytes: Int,
        priority: TaskPriority = .userInitiated,
        onBeforeStreamReadChunk: (@Sendable () -> Void)? = nil
    ) async -> TransferablePDFDocumentBox {
        guard !Task.isCancelled else { return TransferablePDFDocumentBox(document: nil, loadMs: 0, parseMs: 0) }
        let worker = Task.detached(priority: priority) {
            let timed = loadBudgetedDocumentTimed(
                url: url,
                data: data,
                maxBytes: maxBytes,
                onBeforeStreamReadChunk: onBeforeStreamReadChunk
            )
            return TransferablePDFDocumentBox(document: timed.document, loadMs: timed.loadMs, parseMs: timed.parseMs)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

