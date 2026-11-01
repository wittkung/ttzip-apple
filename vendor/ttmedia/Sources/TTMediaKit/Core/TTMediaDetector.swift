// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CryptoKit
import SwiftUI
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// High-performance universal media detection engine providing bounded content probing,
/// unified format routing across disk and memory entry points, and safe fallback degradation.
public struct TTMediaDetector: Sendable {

    /// Maximum byte budget read from disk or memory when probing format signatures (8 KB).
    public static let contentProbeBudgetBytes: Int = 8 * 1024

    /// Maximum byte sample loaded for hexadecimal binary inspection (64 KB).
    public static let hexSampleBudgetBytes: Int = 64 * 1024

    private static let logger = TTMediaLogger.detector

    // MARK: - Internal Unified Input Source

    internal enum DetectionSource: Sendable {
        case disk(url: URL)
        case memory(data: Data, suggestedName: String, sourceURL: URL?)

        var cleanExtension: String {
            switch self {
            case .disk(let url):
                return TTMediaCapabilityMatrix.cleanExtension(from: url.pathExtension)
            case .memory(_, let suggestedName, let sourceURL):
                let nameExt = (suggestedName as NSString).pathExtension
                if !nameExt.isEmpty { return TTMediaCapabilityMatrix.cleanExtension(from: nameExt) }
                if let urlExt = sourceURL?.pathExtension, !urlExt.isEmpty {
                    return TTMediaCapabilityMatrix.cleanExtension(from: urlExt)
                }
                return TTMediaCapabilityMatrix.cleanExtension(from: suggestedName)
            }
        }

        var associatedURL: URL? {
            switch self {
            case .disk(let url): return url
            case .memory(_, _, let sourceURL): return sourceURL
            }
        }
    }

    // MARK: - Fast Extension & Bounded Header Routing

    nonisolated private static let fastHeaderProbeBudgetBytes = 1024

    /// Rapidly infers initial preview state using extension and a strictly bounded header probe.
    /// Rejects non-fast-routable extensions in memory with zero disk I/O.
    nonisolated public static func fastTypeByExtension(url: URL) -> TTMediaPreviewType {
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: url.pathExtension)
        if TTMediaCapabilityMatrix.isArchive(ext) {
            return archiveContainerUnsupportedType()
        }
        guard TTMediaVersionedDetectionCache.isFastRouteCandidateExtension(ext) else {
            return .unsupported("Loading...")
        }
        if let cached = TTMediaVersionedDetectionCache.shared.lookupFastRoute(for: url) {
            return cached
        }
        let probeData = readInitialSampleData(from: url, maxBytes: fastHeaderProbeBudgetBytes)
        guard !probeData.isEmpty else { return .unsupported("Loading...") }

        let magic = probeMagicBytes(for: .disk(url: url), probeData: probeData)
        if TTMediaCapabilityMatrix.isVideo(ext, magic: magic) { return .video(url) }
        if TTMediaCapabilityMatrix.isAudio(ext, magic: magic) { return .audio(url) }
        if ext == "pdf" && magic == .pdf { return .pdf(url) }
        #if os(macOS)
        let isBinary = isBinaryProbePayload(probeData)
        if isOfficeQuickLookCandidate(ext: ext, magic: magic, probeData: probeData, isBinary: isBinary) {
            return .quickLook(url)
        }
        #endif
        return .unsupported("Loading...")
    }

    // MARK: - Public Detection Entry Points

    /// Detects `TTMediaPreviewType` synchronously for a disk file URL using the unified routing pipeline.
    nonisolated public static func detectType(url: URL) -> TTMediaPreviewType {
        classifyUnified(source: .disk(url: url))
    }

    /// Detects `TTMediaPreviewType` asynchronously on a detached cooperative background actor.
    nonisolated public static func detectTypeAsync(url: URL) async -> TTMediaPreviewType {
        await TTMediaBackgroundDetector.shared.detect(url: url)
    }

    /// Detects `TTMediaPreviewType` directly from in-memory Data using the unified routing pipeline.
    nonisolated public static func detectTypeFromMemory(
        data: Data, suggestedName: String, sourceURL: URL? = nil
    ) -> TTMediaPreviewType {
        classifyUnified(source: .memory(data: data, suggestedName: suggestedName, sourceURL: sourceURL))
    }

    /// Detects `TTMediaPreviewType` asynchronously from in-memory Data on the bounded background detector.
    nonisolated public static func detectTypeFromMemoryAsync(
        data: Data, suggestedName: String, sourceURL: URL? = nil
    ) async -> TTMediaPreviewType {
        await TTMediaBackgroundDetector.shared.detect(
            data: data, suggestedName: suggestedName, sourceURL: sourceURL
        )
    }

    // MARK: - Unified Classification Pipeline

    nonisolated private static func lookupPreclassifiedDiskResult(for source: DetectionSource) -> TTMediaPreviewType? {
        guard case .disk(let url) = source else { return nil }
        if isUnreadableDiskFile(url) {
            return .unsupported("Permission denied: \(url.lastPathComponent)")
        }
        return TTMediaVersionedDetectionCache.shared.lookup(for: url)
    }

    nonisolated internal static func classifyUnified(
        source: DetectionSource, respectCancellation: Bool = false
    ) -> TTMediaPreviewType {
        if respectCancellation && Task.isCancelled { return .unsupported("Cancelled") }
        if let early = lookupPreclassifiedDiskResult(for: source) { return early }
        let ext = source.cleanExtension
        let probeData = readBoundedProbeData(from: source)

        guard !probeData.isEmpty else {
            return emptyPayloadUnsupportedType(for: ext)
        }
        if respectCancellation && Task.isCancelled { return .unsupported("Cancelled") }

        let magic = probeMagicBytes(for: source, probeData: probeData)
        let isBinary = isBinaryProbePayload(probeData)
        let resolved = resolveUnifiedRoute(
            source: source, ext: ext, magic: magic, probeData: probeData, isBinary: isBinary
        )
        if respectCancellation && Task.isCancelled {
            resolved.releaseEphemeralMediaLease()
            return .unsupported("Cancelled")
        }
        if case .disk(let url) = source {
            TTMediaVersionedDetectionCache.shared.store(resolved, for: url)
        }
        return resolved
    }

    nonisolated private static func resolveUnifiedRoute(
        source: DetectionSource, ext: String, magic: TTMediaMagicKind, probeData: Data, isBinary: Bool
    ) -> TTMediaPreviewType {
        if let mediaOrVisual = routeByContentSignature(source: source, ext: ext, magic: magic, isBinary: isBinary) {
            return mediaOrVisual
        }
        if let containerRoute = routeDocumentOrArchiveContainer(
            source: source, ext: ext, magic: magic, probeData: probeData, isBinary: isBinary
        ) {
            return containerRoute
        }
        if !isBinary, let structuredTextRoute = routeStructuredTextFormats(source: source, ext: ext) {
            return structuredTextRoute
        }
        if TTMediaCapabilityMatrix.binaryExtensions.contains(ext) {
            return makeHexViewerFallback(from: source)
        }
        if !isBinary, let plainText = readTextPayload(from: source) {
            return .text(plainText)
        }
        return makeHexViewerFallback(from: source)
    }

    nonisolated private static func routeByContentSignature(
        source: DetectionSource, ext: String, magic: TTMediaMagicKind, isBinary: Bool
    ) -> TTMediaPreviewType? {
        if let visualRoute = routeVisualImageOrVector(source: source, ext: ext, magic: magic, isBinary: isBinary) {
            return visualRoute
        }
        if magic == .pdf { return makePDFPreview(from: source) }
        if TTMediaCapabilityMatrix.isVideo(ext, magic: magic) { return makeMediaPreview(from: source, isVideo: true) }
        if TTMediaCapabilityMatrix.isAudio(ext, magic: magic) { return makeMediaPreview(from: source, isVideo: false) }
        if case .binary = magic { return makeHexViewerFallback(from: source) }
        return nil
    }

    nonisolated private static func routeVisualImageOrVector(
        source: DetectionSource, ext: String, magic: TTMediaMagicKind, isBinary: Bool
    ) -> TTMediaPreviewType? {
        if ext == "svgz" {
            if let decompressedSVG = decompressSVGZPayload(from: source) {
                return .htmlWeb(content: decompressedSVG, fileURL: source.associatedURL)
            }
            return makeHexViewerFallback(from: source)
        }
        if case .image = magic {
            if let image = loadImageThumbnail(from: source) { return .image(image) }
            return makeHexViewerFallback(from: source)
        }
        if ext == "svg" && !isBinary, let svgText = readTextPayload(from: source) {
            return .htmlWeb(content: svgText, fileURL: source.associatedURL)
        }
        if TTMediaCapabilityMatrix.imageExtensions.contains(ext) && isBinary {
            if let image = loadImageThumbnail(from: source) { return .image(image) }
            return makeHexViewerFallback(from: source)
        }
        return nil
    }

    nonisolated private static func routeDocumentOrArchiveContainer(
        source: DetectionSource, ext: String, magic: TTMediaMagicKind, probeData: Data, isBinary: Bool
    ) -> TTMediaPreviewType? {
        if TTMediaCapabilityMatrix.comicArchiveExtensions.contains(ext) && isArchiveMagic(magic) {
            return archiveContainerUnsupportedType()
        }
        if TTMediaCapabilityMatrix.ebookExtensions.contains(ext) && (ext != "fb2" || !isBinary) {
            return makeEBookPreview(from: source, ext: ext)
        }
        if let spreadsheetRoute = routeSpreadsheetContainer(
            source: source, ext: ext, magic: magic, probeData: probeData
        ) {
            return spreadsheetRoute
        }
        if isOfficeQuickLookCandidate(ext: ext, magic: magic, probeData: probeData, isBinary: isBinary) {
            return makeOfficeQuickLookPreview(from: source)
        }
        if TTMediaCapabilityMatrix.isArchive(ext) || isArchiveMagic(magic) {
            return archiveContainerUnsupportedType()
        }
        return nil
    }

    nonisolated private static func routeStructuredTextFormats(
        source: DetectionSource, ext: String
    ) -> TTMediaPreviewType? {
        if TTMediaCapabilityMatrix.isTabularSpreadsheet(ext), let text = readTextPayload(from: source) {
            return .spreadsheetTable(text, source.associatedURL)
        }
        if TTMediaCapabilityMatrix.isMarkdown(ext), let text = readTextPayload(from: source) {
            return .markdown(text, source.associatedURL)
        }
        if TTMediaCapabilityMatrix.htmlWebExtensions.contains(ext), let text = readTextPayload(from: source) {
            return .htmlWeb(content: text, fileURL: source.associatedURL)
        }
        return nil
    }

    // MARK: - Deep Magic Byte Probing (Bounded to contentProbeBudgetBytes)

    /// Probes leading buffer bytes (capped to `contentProbeBudgetBytes`) to detect format signatures deterministically.
    nonisolated public static func probeMagicBytes(data: Data) -> TTMediaMagicKind {
        let sample = Data(data.prefix(contentProbeBudgetBytes))
        let source = DetectionSource.memory(data: data, suggestedName: "", sourceURL: nil)
        return probeMagicBytes(for: source, probeData: sample)
    }

    nonisolated private static func probeMagicBytes(
        for source: DetectionSource,
        probeData: Data
    ) -> TTMediaMagicKind {
        let sample = Data(probeData.prefix(contentProbeBudgetBytes))
        guard sample.count >= 4 else { return .unknown }

        for entry in fixedPrefixSignatures where sample.starts(with: entry.prefix) {
            return entry.kind
        }
        if let riffOrIFF = probeRIFFAndIFFSignature(sample) {
            return riffOrIFF
        }
        if let container = TTMediaCapabilityMatrix.identifySharedContainer(
            in: sample,
            isBinaryPayload: isBinaryProbePayload(sample)
        ) {
            let moovResult = container == .isoBMFF
                ? TTMediaISOBMFFTrackScanner.resolveMoovSample(for: source, initialSample: sample)
                : nil
            return TTMediaCapabilityMatrix.probeSharedContainerTracks(
                container: container,
                sample: sample,
                moovSample: moovResult?.sample,
                isCompleteScan: moovResult?.isCompleteScan ?? true
            )
        }
        if let structural = probeStructuralMediaOrArchiveSignature(sample) {
            return structural
        }
        return .unknown
    }

    nonisolated private static func probeRIFFAndIFFSignature(_ sample: Data) -> TTMediaMagicKind? {
        guard sample.count >= 12 else { return nil }
        let fourCC = sample.subdata(in: 8..<12)

        if sample.starts(with: [0x52, 0x49, 0x46, 0x46]) {
            switch String(bytes: fourCC, encoding: .isoLatin1) {
            case "WEBP": return .image(mime: "image/webp")
            case "WAVE": return .audio(mime: "audio/wav")
            case "AVI ", "AVIX": return .video(mime: "video/x-msvideo")
            case "CDXA": return .video(mime: "video/mpeg")
            default: return nil
            }
        }
        if sample.starts(with: [0x46, 0x4F, 0x52, 0x4D]) {
            let tag = String(bytes: fourCC, encoding: .isoLatin1)
            if tag == "AIFF" || tag == "AIFC" {
                return .audio(mime: "audio/aiff")
            }
        }
        return nil
    }

    nonisolated private static func probeStructuralMediaOrArchiveSignature(_ sample: Data) -> TTMediaMagicKind? {
        if let bitmapOrIcon = probeBMPOrICOHeader(sample) {
            return bitmapOrIcon
        }
        if sample.count >= 262 && sample.subdata(in: 257..<262) == Data([0x75, 0x73, 0x74, 0x61, 0x72]) {
            return .archive(mime: "application/x-tar")
        }
        if sample.starts(with: [0x0B, 0x77]) && isBinaryProbePayload(sample) {
            return .audio(mime: "audio/ac3")
        }
        if let mpegAudio = probeMPEGAudioOrADTSSync(sample) {
            return mpegAudio
        }
        if isMPEGTransportStream(sample) {
            return .video(mime: "video/mp2t")
        }
        return nil
    }

    nonisolated private static func probeBMPOrICOHeader(_ sample: Data) -> TTMediaMagicKind? {
        if sample.count >= 6 && sample.starts(with: [0x00, 0x00, 0x01, 0x00]) && (sample[4] != 0 || sample[5] != 0) {
            return .image(mime: "image/x-icon")
        }
        guard sample.count >= 14, sample[0] == 0x42, sample[1] == 0x4D else {
            return nil
        }
        let reservedZero = sample.subdata(in: 6..<10) == Data([0x00, 0x00, 0x00, 0x00])
        if reservedZero && isBinaryProbePayload(sample) {
            return .image(mime: "image/bmp")
        }
        return nil
    }

    nonisolated private static func probeMPEGAudioOrADTSSync(_ sample: Data) -> TTMediaMagicKind? {
        guard sample[0] == 0xFF else { return nil }
        let b1 = sample[1]
        // Exclude UTF-16LE BOM (FF FE) and raw 0xFFFF padding.
        guard b1 != 0xFE && b1 != 0xFF && (b1 & 0xE0) == 0xE0 else { return nil }

        if b1 == 0xF1 || b1 == 0xF9 {
            return .audio(mime: "audio/aac")
        }

        let versionBits = (b1 >> 3) & 0x03
        let layerBits = (b1 >> 1) & 0x03
        let bitrateIndex = (sample[2] >> 4) & 0x0F
        let sampleRateIndex = (sample[2] >> 2) & 0x03

        guard versionBits != 0x01, layerBits != 0x00, bitrateIndex != 0x0F, sampleRateIndex != 0x03 else {
            return nil
        }
        return .audio(mime: "audio/mpeg")
    }

    nonisolated private static func isMPEGTransportStream(_ sample: Data) -> Bool {
        guard sample.count >= 188, isBinaryProbePayload(sample) else {
            return false
        }
        if sample.starts(with: [0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0]) {
            return true
        }
        return matchesTSStride(sample, initialOffset: 0, stride: 188) ||
            matchesTSStride(sample, initialOffset: 4, stride: 192) ||
            matchesTSStride(sample, initialOffset: 0, stride: 204)
    }

    nonisolated private static func matchesTSStride(_ sample: Data, initialOffset: Int, stride: Int) -> Bool {
        let secondOffset = initialOffset + stride
        guard sample.count >= secondOffset + 2 else {
            return sample.count == stride && isValidTSPacketSync(sample, at: initialOffset)
        }
        guard isValidTSPacketSync(sample, at: initialOffset),
              isValidTSPacketSync(sample, at: secondOffset) else {
            return false
        }
        let thirdOffset = secondOffset + stride
        if sample.count >= thirdOffset + 2 {
            return isValidTSPacketSync(sample, at: thirdOffset)
        }
        return true
    }

    nonisolated private static func isValidTSPacketSync(_ sample: Data, at offset: Int) -> Bool {
        guard offset + 1 < sample.count else { return false }
        return sample[offset] == 0x47 && (sample[offset + 1] & 0x80) == 0
    }

    nonisolated private static func isBinaryProbePayload(_ sample: Data) -> Bool {
        if TTMediaContentReader.isBinaryPayload(sample) {
            return true
        }
        if sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF]) ||
            sample.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return false
        }
        return sample.contains { byte in
            byte == 0x00 || (byte >= 0x01 && byte <= 0x08) ||
                (byte >= 0x0E && byte <= 0x1A) || (byte >= 0x1C && byte <= 0x1F)
        }
    }

    // MARK: - Source Access & Preview Builders

    nonisolated public static func readInitialSampleData(from url: URL, maxBytes: Int = hexSampleBudgetBytes) -> Data {
        guard maxBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maxBytes)) ?? Data()
    }

    nonisolated private static func readBoundedProbeData(from source: DetectionSource) -> Data {
        switch source {
        case .disk(let url): return readInitialSampleData(from: url, maxBytes: contentProbeBudgetBytes)
        case .memory(let data, _, _): return Data(data.prefix(contentProbeBudgetBytes))
        }
    }

    nonisolated private static func readTextPayload(from source: DetectionSource) -> String? {
        switch source {
        case .disk(let url): return TTMediaContentReader.readTextContent(from: url)
        case .memory(let data, _, _):
            return Int64(data.count) <= TTMediaContentReader.maxTextBudget ? TTMediaContentReader.decodeText(data: data) : nil
        }
    }

    nonisolated private static func loadImageThumbnail(from source: DetectionSource) -> PlatformImage? {
        switch source {
        case .disk(let url):
            guard let image = TTMediaImageLoader.loadThumbnail(from: url) else { return nil }
            registerImageBackingPayload(
                for: image, sourceURL: url, sourceData: nil, suggestedName: url.lastPathComponent
            )
            return image
        case .memory(let data, let suggestedName, let sourceURL):
            guard let image = TTMediaImageLoader.loadThumbnail(from: data) else { return nil }
            registerImageBackingPayload(
                for: image, sourceURL: sourceURL, sourceData: data, suggestedName: suggestedName
            )
            return image
        }
    }

    nonisolated private static func decompressSVGZPayload(from source: DetectionSource) -> String? {
        switch source {
        case .disk(let url): return try? SVGZBoundedDecompressor.decompressSVGZ(from: url)
        case .memory(let data, _, _): return try? SVGZBoundedDecompressor.decompressSVGZ(data: data)
        }
    }

    nonisolated private static func makePDFPreview(from source: DetectionSource) -> TTMediaPreviewType {
        switch source {
        case .disk(let url): return .pdf(url)
        case .memory(let data, _, let sourceURL): return .pdfData(data, sourceURL)
        }
    }

    nonisolated private static func makeMediaPreview(from source: DetectionSource, isVideo: Bool) -> TTMediaPreviewType {
        switch source {
        case .disk(let url):
            return isVideo ? .video(url) : .audio(url)
        case .memory(let data, let suggestedName, _):
            guard let fileURL = writeDataToTemporaryFile(data: data, fileName: suggestedName) else {
                let kind = isVideo ? "video" : "audio"
                return .unsupported("Unable to prepare \(kind) file for playback: \(suggestedName)")
            }
            return isVideo ? .video(fileURL) : .audio(fileURL)
        }
    }

    nonisolated private static func makeEBookPreview(from source: DetectionSource, ext: String) -> TTMediaPreviewType {
        let byteCount: Int
        let targetURL: URL
        let title: String
        switch source {
        case .disk(let url):
            byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            targetURL = url
            title = url.deletingPathExtension().lastPathComponent
        case .memory(let data, let suggestedName, let sourceURL):
            byteCount = data.count
            targetURL = sourceURL ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suggestedName)
            title = (suggestedName as NSString).deletingPathExtension
        }
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return .ebook(EBookMetadata(
            url: targetURL, title: title, formatName: ext.uppercased(),
            fileSizeDescription: sizeStr, excerptText: "E-Book publication ready for viewing.", coverImage: nil
        ))
    }

    nonisolated private static func routeSpreadsheetContainer(
        source: DetectionSource, ext: String, magic: TTMediaMagicKind, probeData: Data
    ) -> TTMediaPreviewType? {
        guard TTMediaCapabilityMatrix.isBinarySpreadsheet(ext) else { return nil }
        let isZipPackage = (magic == .archive(mime: "application/zip"))
        let isOLE2Package = probeData.starts(with: [0xD0, 0xCF, 0x11, 0xE0])
        guard isZipPackage || isOLE2Package else { return nil }

        if isZipPackage && (ext == "xlsx" || ext == "xlsm" || ext == "ods") {
            let workbook: OfficeSpreadsheetWorkbook?
            switch source {
            case .disk(let url):
                workbook = TTMediaOfficeSpreadsheetReader.loadWorkbook(from: url, ext: ext)
            case .memory(let data, let suggestedName, let sourceURL):
                workbook = TTMediaOfficeSpreadsheetReader.loadWorkbook(
                    data: data, fileName: suggestedName, fileURL: sourceURL, ext: ext
                )
            }
            if let workbook {
                return .officeSpreadsheet(workbook)
            }
        }
        return .unsupported(TTMediaOfficeSpreadsheetReader.unsupportedSpreadsheetMessage(ext: ext))
    }

    nonisolated private static func isOfficeQuickLookCandidate(
        ext: String, magic: TTMediaMagicKind, probeData: Data, isBinary: Bool
    ) -> Bool {
        let isOfficeExt = TTMediaCapabilityMatrix.docxExtensions.contains(ext) ||
            TTMediaCapabilityMatrix.presentationExtensions.contains(ext)
        guard isOfficeExt else { return false }
        if magic == .archive(mime: "application/zip") || probeData.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) {
            return true
        }
        return ext == "rtf" && !isBinary && probeData.starts(with: [0x7B, 0x5C, 0x72, 0x74, 0x66])
    }

    nonisolated private static func makeOfficeQuickLookPreview(from source: DetectionSource) -> TTMediaPreviewType {
        #if os(macOS)
        switch source {
        case .disk(let url):
            return .quickLook(url)
        case .memory(let data, let suggestedName, let sourceURL):
            if let existingURL = sourceURL, FileManager.default.fileExists(atPath: existingURL.path) {
                return .quickLook(existingURL)
            }
            if let stagedURL = writeDataToTemporaryFile(data: data, fileName: suggestedName) {
                return .quickLook(stagedURL)
            }
            return makeHexViewerFallback(from: source)
        }
        #else
        return makeHexViewerFallback(from: source)
        #endif
    }

    nonisolated private static func makeHexViewerFallback(from source: DetectionSource) -> TTMediaPreviewType {
        let sampleData: Data
        switch source {
        case .disk(let url): sampleData = readInitialSampleData(from: url, maxBytes: hexSampleBudgetBytes)
        case .memory(let data, _, _): sampleData = Data(data.prefix(hexSampleBudgetBytes))
        }
        guard !sampleData.isEmpty else { return emptyPayloadUnsupportedType(for: source.cleanExtension) }
        return .hexViewer(sampleData, source.associatedURL)
    }

    nonisolated private static func isArchiveMagic(_ magic: TTMediaMagicKind) -> Bool {
        if case .archive = magic { return true }
        return false
    }

    nonisolated private static func archiveContainerUnsupportedType() -> TTMediaPreviewType {
        let isZh = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
        let message = isZh
            ? "已加载归档容器，双击或解压以浏览内容。"
            : "Archive container loaded. Open or extract to browse contents."
        return .unsupported(message)
    }

    nonisolated private static func emptyPayloadUnsupportedType(for ext: String) -> TTMediaPreviewType {
        .unsupported("Empty file: \(ext.isEmpty ? "EMPTY" : ext.uppercased())")
    }

    nonisolated private static func isUnreadableDiskFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if !FileManager.default.isReadableFile(atPath: url.path) { return true }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try? handle.close()
            return false
        } catch let error as NSError {
            return isPermissionNSError(error)
        }
    }

    nonisolated private static func isPermissionNSError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EACCES) || error.code == Int(EPERM)) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == Int(EACCES) || underlying.code == Int(EPERM)
        }
        return false
    }

    // MARK: - Ephemeral Media Staging (Group A: In-Memory AVPlayer / QLPreviewView Materialization)
    // Ownership Boundary: `temporaryDirectory/TTMediaEphemeralStorage/media/<content-sha256>/` is owned by `TTMediaDetector`
    // (implemented in `TTMediaBackgroundDetector.swift`) strictly for transient materialization of in-memory `Data` buffers
    // (`AVPlayer` / `QLPreviewView`) with `maxStagedEphemeralFiles = 8`.
    // Archive-extracted preview files are owned separately by `EphemeralPreviewCacheManager` (`TTZipPreviewKit`, F4).
}
