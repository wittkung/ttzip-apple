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

/// Classification kind inferred from raw magic byte headers.
public enum TTMediaMagicKind: Sendable, Equatable {
    case image(mime: String)
    case video(mime: String)
    case audio(mime: String)
    case pdf
    case archive(mime: String)
    case binary(mime: String)
    case text
    case unknown
}

/// Headless image downsampling loader utilizing hardware-accelerated ImageIO and versioned thumbnail cache.
public enum TTMediaImageLoader {
    /// Loads downsampled thumbnail from a disk URL with strict memory bounds and resource-versioned cache reuse.
    public static func loadThumbnail(from url: URL, maxPixelSize: CGFloat = 2048) -> PlatformImage? {
        #if os(macOS)
        return ImageIOThumbnailCache.shared.cachedOrDownsampledThumbnail(for: url, maxPixelSize: maxPixelSize)
        #else
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return createThumbnail(from: source, maxPixelSize: maxPixelSize)
        #endif
    }

    /// Loads downsampled thumbnail directly from in-memory Data without retaining full uncompressed bitmaps.
    public static func loadThumbnail(from data: Data, maxPixelSize: CGFloat = 2048) -> PlatformImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        return createThumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private static func createThumbnail(from source: CGImageSource, maxPixelSize: CGFloat) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}

/// Dedicated background actor executing bounded concurrent off-main-thread file inspection,
/// cancellation-aware slot acquisition, and generation-fenced format detection.
public actor TTMediaBackgroundDetector {
    public static let shared = TTMediaBackgroundDetector()

    /// Maximum number of concurrent heavy file inspections executing simultaneously.
    public let maxConcurrentDetections: Int

    private var activeCount: Int = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private var sessionGenerations: [String: UInt64] = [:]

    public typealias EPUBAsyncParser = @Sendable (URL) async -> EPUBBookModel?
    private static let _epubParserLock = NSLock()
    nonisolated(unsafe) private static var _epubParser: EPUBAsyncParser?

    public static var epubParser: EPUBAsyncParser? {
        get {
            _epubParserLock.lock()
            defer { _epubParserLock.unlock() }
            return _epubParser
        }
        set {
            _epubParserLock.lock()
            defer { _epubParserLock.unlock() }
            _epubParser = newValue
        }
    }

    public init(maxConcurrentDetections: Int = 4) {
        self.maxConcurrentDetections = max(1, maxConcurrentDetections)
    }

    /// Detects `TTMediaPreviewType` for a disk URL using bounded concurrency off the actor's serial executor.
    /// Cancelling the calling task immediately releases any queued waiter or returns early without blocking subsequent detections.
    public func detect(url: URL) async -> TTMediaPreviewType {
        guard !Task.isCancelled else {
            return .unsupported("Cancelled")
        }
        guard await acquireSlot() else {
            return .unsupported("Cancelled")
        }
        defer {
            releaseSlot()
        }
        let result = await Self.performOffActorDetection(url: url)
        if Task.isCancelled {
            result.releaseEphemeralMediaLease()
            return .unsupported("Cancelled")
        }
        return result
    }

    /// Detects `TTMediaPreviewType` for in-memory Data using bounded concurrency off the actor's serial executor.
    /// Automatically releases any newly staged ephemeral media lease if cancelled before returning.
    public func detect(
        data: Data, suggestedName: String, sourceURL: URL? = nil
    ) async -> TTMediaPreviewType {
        guard !Task.isCancelled else {
            return .unsupported("Cancelled")
        }
        guard await acquireSlot() else {
            return .unsupported("Cancelled")
        }
        defer {
            releaseSlot()
        }
        let result = await Self.performOffActorMemoryDetection(
            data: data, suggestedName: suggestedName, sourceURL: sourceURL
        )
        if Task.isCancelled {
            result.releaseEphemeralMediaLease()
            return .unsupported("Cancelled")
        }
        return result
    }

    /// Detects `TTMediaPreviewType` with monotonic generation fencing per session key.
    /// Returns `nil` if the calling task was cancelled or superseded by a newer request on the same `sessionKey`.
    public func detectLatest(url: URL, sessionKey: String = "default") async -> TTMediaPreviewType? {
        let generation = (sessionGenerations[sessionKey] ?? 0) &+ 1
        sessionGenerations[sessionKey] = generation

        guard !Task.isCancelled else {
            return nil
        }
        guard await acquireSlot() else {
            return nil
        }
        defer {
            releaseSlot()
        }
        guard sessionGenerations[sessionKey] == generation, !Task.isCancelled else {
            return nil
        }

        let result = await Self.performOffActorDetection(url: url)
        guard sessionGenerations[sessionKey] == generation, !Task.isCancelled else {
            result.releaseEphemeralMediaLease()
            return nil
        }
        return result
    }

    /// Detects `TTMediaPreviewType` from in-memory Data with monotonic generation fencing per session key.
    /// Automatically releases any staged ephemeral media lease if cancelled or superseded by a newer generation.
    public func detectLatest(
        data: Data, suggestedName: String, sourceURL: URL? = nil, sessionKey: String = "default"
    ) async -> TTMediaPreviewType? {
        let generation = (sessionGenerations[sessionKey] ?? 0) &+ 1
        sessionGenerations[sessionKey] = generation

        guard !Task.isCancelled else { return nil }
        guard await acquireSlot() else { return nil }
        defer { releaseSlot() }
        guard sessionGenerations[sessionKey] == generation, !Task.isCancelled else { return nil }

        let result = await Self.performOffActorMemoryDetection(
            data: data, suggestedName: suggestedName, sourceURL: sourceURL
        )
        guard sessionGenerations[sessionKey] == generation, !Task.isCancelled else {
            result.releaseEphemeralMediaLease()
            return nil
        }
        return result
    }

    /// Returns the current active detection count for diagnostics and testing.
    public func currentActiveDetections() -> Int {
        activeCount
    }

    // MARK: - Bounded Concurrency Gate

    private func acquireSlot() async -> Bool {
        if Task.isCancelled {
            return false
        }
        if activeCount < maxConcurrentDetections {
            activeCount += 1
            return true
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                if activeCount < maxConcurrentDetections {
                    activeCount += 1
                    continuation.resume(returning: true)
                    return
                }
                waiters.append((id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    private func releaseSlot() {
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: true)
            return
        }
        activeCount = max(0, activeCount - 1)
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let removed = waiters.remove(at: index)
            removed.continuation.resume(returning: false)
        }
    }

    // MARK: - Off-Actor Execution

    nonisolated private static func performOffActorDetection(url: URL) async -> TTMediaPreviewType {
        if Task.isCancelled {
            return .unsupported("Cancelled")
        }
        let ext = TTMediaCapabilityMatrix.cleanExtension(from: url.pathExtension)
        if ext == "epub" {
            let probeData = TTMediaDetector.readInitialSampleData(
                from: url,
                maxBytes: TTMediaDetector.contentProbeBudgetBytes
            )
            if !probeData.isEmpty,
               TTMediaDetector.probeMagicBytes(data: probeData) == .archive(mime: "application/zip"),
               let parser = Self.epubParser,
               let book = await parser(url) {
                return .epubBook(book)
            }
        }

        let computeTask = Task.detached(priority: .userInitiated) { () -> TTMediaPreviewType in
            TTMediaDetector.classifyUnified(source: .disk(url: url), respectCancellation: true)
        }

        return await withTaskCancellationHandler {
            await computeTask.value
        } onCancel: {
            computeTask.cancel()
        }
    }

    nonisolated private static func performOffActorMemoryDetection(
        data: Data, suggestedName: String, sourceURL: URL?
    ) async -> TTMediaPreviewType {
        if Task.isCancelled {
            return .unsupported("Cancelled")
        }
        let computeTask = Task.detached(priority: .userInitiated) { () -> TTMediaPreviewType in
            TTMediaDetector.classifyUnified(
                source: .memory(data: data, suggestedName: suggestedName, sourceURL: sourceURL),
                respectCancellation: true
            )
        }
        return await withTaskCancellationHandler {
            await computeTask.value
        } onCancel: {
            computeTask.cancel()
        }
    }
}

// MARK: - Compatibility Typealiases

public typealias MediaPreviewFactory = TTMediaDetector
public typealias MediaPreviewDetector = TTMediaBackgroundDetector

// MARK: - Compatibility View Factory

extension TTMediaDetector {
    public static var docxExtensions: Set<String> { TTMediaCapabilityMatrix.docxExtensions }
    public static var archiveExtensions: Set<String> { TTMediaCapabilityMatrix.archiveExtensions }
    public static var videoExtensions: Set<String> { TTMediaCapabilityMatrix.videoExtensions }
    public static var nativeVideoExtensions: Set<String> { TTMediaCapabilityMatrix.videoExtensions }
    public static var extendedVideoExtensions: Set<String> { TTMediaCapabilityMatrix.videoExtensions }
    public static var ambiguousExtensions: Set<String> { TTMediaCapabilityMatrix.ambiguousExtensions }
    public static var audioExtensions: Set<String> { TTMediaCapabilityMatrix.audioExtensions }
    public static var nativeAudioExtensions: Set<String> { TTMediaCapabilityMatrix.audioExtensions }
    public static var extendedAudioExtensions: Set<String> { TTMediaCapabilityMatrix.audioExtensions }
    public static var markdownExtensions: Set<String> { TTMediaCapabilityMatrix.markdownExtensions }
    public static var spreadsheetExtensions: Set<String> { TTMediaCapabilityMatrix.spreadsheetExtensions }
    public static var presentationExtensions: Set<String> { TTMediaCapabilityMatrix.presentationExtensions }
    public static var imageExtensions: Set<String> { TTMediaCapabilityMatrix.imageExtensions }
    public static var textExtensions: Set<String> { TTMediaCapabilityMatrix.textExtensions }
    public static var binaryExtensions: Set<String> { TTMediaCapabilityMatrix.binaryExtensions }

    public static func iconName(for fileName: String) -> String {
        TTMediaCapabilityMatrix.iconName(for: fileName)
    }

    @MainActor
    @ViewBuilder
    public static func makePreviewView(
        type: TTMediaPreviewType,
        fileName: String,
        fileURL: URL?,
        isFullScreenActive: Bool = false,
        useMediaKit: Bool = false,
        onSave: ((String) -> Void)? = nil
    ) -> some View {
        TTMediaPreviewFactory.makePreviewView(
            type: type,
            fileName: fileName,
            fileURL: fileURL,
            isFullScreenActive: isFullScreenActive,
            useMediaKit: useMediaKit,
            onSave: onSave
        )
    }

    @MainActor
    public static func makeMediaKitPreview(url: URL, title: String? = nil) -> TTMediaPreview {
        TTMediaPreviewFactory.makeMediaKitPreview(url: url, title: title)
    }

    @MainActor
    public static func makeSpreadsheetView(headers: [String], rows: [[String]]) -> TTSpreadsheetView {
        TTMediaPreviewFactory.makeSpreadsheetView(headers: headers, rows: rows)
    }

    @MainActor
    public static func makeRichDocumentView(markdown: String, title: String? = nil) -> TTRichDocumentView {
        TTMediaPreviewFactory.makeRichDocumentView(markdown: markdown, title: title)
    }

    // MARK: - Archive / In-Memory Image Backing Payload Registry (Group A/C2 Contract)

    private final class ImageBackingPayloadBox: @unchecked Sendable {
        let sourceURL: URL?
        let sourceData: Data?
        let suggestedName: String?

        init(sourceURL: URL?, sourceData: Data?, suggestedName: String?) {
            self.sourceURL = sourceURL
            self.sourceData = sourceData
            self.suggestedName = suggestedName
        }
    }

    private static let imagePayloadLock = NSLock()
    nonisolated(unsafe) private static let imagePayloadTable =
        NSMapTable<PlatformImage, ImageBackingPayloadBox>.weakToStrongObjects()

    /// Associates the backing disk URL or in-memory archive Data with a downsampled thumbnail `PlatformImage`.
    nonisolated public static func registerImageBackingPayload(
        for image: PlatformImage,
        sourceURL: URL?,
        sourceData: Data?,
        suggestedName: String? = nil
    ) {
        imagePayloadLock.lock()
        defer { imagePayloadLock.unlock() }
        let box = ImageBackingPayloadBox(
            sourceURL: sourceURL,
            sourceData: sourceData,
            suggestedName: suggestedName
        )
        imagePayloadTable.setObject(box, forKey: image)
    }

    /// Retrieves any registered backing URL or in-memory Data associated with `image`.
    nonisolated public static func imageBackingPayload(
        for image: PlatformImage
    ) -> (sourceURL: URL?, sourceData: Data?, suggestedName: String?)? {
        imagePayloadLock.lock()
        defer { imagePayloadLock.unlock() }
        guard let box = imagePayloadTable.object(forKey: image) else { return nil }
        return (box.sourceURL, box.sourceData, box.suggestedName)
    }

    /// Resolves a full `TTImagePreviewResource` for `image`, preserving in-memory archive `Data`
    /// for multi-frame animation (GIF/APNG/WebP) and progressive high-resolution zoom resampling.
    nonisolated public static func imagePreviewResource(
        for image: PlatformImage,
        fallbackURL: URL? = nil
    ) -> TTImagePreviewResource {
        if let payload = imageBackingPayload(for: image) {
            return TTImagePreviewResource(
                image: image,
                sourceURL: payload.sourceURL ?? fallbackURL,
                sourceData: payload.sourceData
            )
        }
        return TTImagePreviewResource(image: image, sourceURL: fallbackURL, sourceData: nil)
    }
}

// MARK: - Declarative Magic Signature Table Extension

extension TTMediaDetector {
    internal struct MagicPrefixEntry: Sendable {
        let prefix: [UInt8]
        let kind: TTMediaMagicKind
    }

    internal static let fixedPrefixSignatures: [MagicPrefixEntry] = [
        // Images
        MagicPrefixEntry(prefix: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], kind: .image(mime: "image/png")),
        MagicPrefixEntry(prefix: [0xFF, 0xD8, 0xFF], kind: .image(mime: "image/jpeg")),
        MagicPrefixEntry(prefix: [0x47, 0x49, 0x46, 0x38], kind: .image(mime: "image/gif")),
        MagicPrefixEntry(prefix: [0x49, 0x49, 0x2A, 0x00], kind: .image(mime: "image/tiff")),
        MagicPrefixEntry(prefix: [0x4D, 0x4D, 0x00, 0x2A], kind: .image(mime: "image/tiff")),
        // PDF & Archives
        MagicPrefixEntry(prefix: [0x25, 0x50, 0x44, 0x46], kind: .pdf),
        MagicPrefixEntry(prefix: [0x50, 0x4B, 0x03, 0x04], kind: .archive(mime: "application/zip")),
        MagicPrefixEntry(prefix: [0x50, 0x4B, 0x05, 0x06], kind: .archive(mime: "application/zip")),
        MagicPrefixEntry(prefix: [0x50, 0x4B, 0x07, 0x08], kind: .archive(mime: "application/zip")),
        MagicPrefixEntry(prefix: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], kind: .archive(mime: "application/x-7z-compressed")),
        MagicPrefixEntry(prefix: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], kind: .archive(mime: "application/vnd.rar")),
        MagicPrefixEntry(prefix: [0x1F, 0x8B], kind: .archive(mime: "application/gzip")),
        MagicPrefixEntry(prefix: [0x42, 0x5A, 0x68], kind: .archive(mime: "application/x-bzip2")),
        MagicPrefixEntry(prefix: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], kind: .archive(mime: "application/x-xz")),
        MagicPrefixEntry(prefix: [0x28, 0xB5, 0x2F, 0xFD], kind: .archive(mime: "application/zstd")),
        MagicPrefixEntry(prefix: [0x04, 0x22, 0x4D, 0x18], kind: .archive(mime: "application/x-lz4")),
        MagicPrefixEntry(prefix: [0x4C, 0x5A, 0x49, 0x50], kind: .archive(mime: "application/x-lzip")),
        MagicPrefixEntry(prefix: [0x4C, 0x52, 0x5A, 0x49], kind: .archive(mime: "application/x-lrzip")),
        MagicPrefixEntry(prefix: [0x4D, 0x53, 0x57, 0x49, 0x4D, 0x00, 0x00, 0x00], kind: .archive(mime: "application/x-ms-wim")),
        // Audio Streams (Unambiguous Single-Purpose Formats)
        MagicPrefixEntry(prefix: [0x66, 0x4C, 0x61, 0x43], kind: .audio(mime: "audio/flac")),
        MagicPrefixEntry(prefix: [0x63, 0x61, 0x66, 0x66], kind: .audio(mime: "audio/x-caf")),
        MagicPrefixEntry(prefix: [0x4D, 0x54, 0x68, 0x64], kind: .audio(mime: "audio/midi")),
        MagicPrefixEntry(prefix: [0x2E, 0x73, 0x6E, 0x64], kind: .audio(mime: "audio/basic")),
        MagicPrefixEntry(prefix: [0x23, 0x21, 0x41, 0x4D, 0x52], kind: .audio(mime: "audio/amr")),
        MagicPrefixEntry(prefix: [0x4D, 0x41, 0x43, 0x20], kind: .audio(mime: "audio/ape")),
        MagicPrefixEntry(prefix: [0x77, 0x76, 0x70, 0x6B], kind: .audio(mime: "audio/x-wavpack")),
        MagicPrefixEntry(prefix: [0x54, 0x54, 0x41, 0x31], kind: .audio(mime: "audio/x-tta")),
        MagicPrefixEntry(prefix: [0x4D, 0x50, 0x43, 0x4B], kind: .audio(mime: "audio/x-musepack")),
        MagicPrefixEntry(prefix: [0x4D, 0x50, 0x2B], kind: .audio(mime: "audio/x-musepack")),
        MagicPrefixEntry(prefix: [0x44, 0x53, 0x44, 0x20], kind: .audio(mime: "audio/dsd")),
        MagicPrefixEntry(prefix: [0x46, 0x52, 0x4D, 0x38], kind: .audio(mime: "audio/dsd")),
        MagicPrefixEntry(prefix: Array("Creative Voice File".utf8), kind: .audio(mime: "audio/x-voc")),
        MagicPrefixEntry(prefix: [0x7F, 0xFE, 0x80, 0x01], kind: .audio(mime: "audio/vnd.dts")),
        MagicPrefixEntry(prefix: [0x49, 0x44, 0x33], kind: .audio(mime: "audio/mpeg")),
        // Video Streams (Unambiguous Single-Purpose Formats)
        MagicPrefixEntry(prefix: [0x46, 0x4C, 0x56, 0x01], kind: .video(mime: "video/x-flv")),
        MagicPrefixEntry(prefix: [0x00, 0x00, 0x01, 0xBA], kind: .video(mime: "video/mpeg")),
        MagicPrefixEntry(prefix: [0x00, 0x00, 0x01, 0xB3], kind: .video(mime: "video/mpeg")),
        MagicPrefixEntry(prefix: Array("YUV4MPEG2 ".utf8), kind: .video(mime: "video/x-yuv4mpeg")),
        MagicPrefixEntry(prefix: Array("nut/multimedia container".utf8), kind: .video(mime: "video/x-nut")),
        MagicPrefixEntry(prefix: [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01], kind: .video(mime: "application/mxf")),
        // Native Executables
        MagicPrefixEntry(prefix: [0xFE, 0xED, 0xFA, 0xCE], kind: .binary(mime: "application/x-mach-binary")),
        MagicPrefixEntry(prefix: [0xFE, 0xED, 0xFA, 0xCF], kind: .binary(mime: "application/x-mach-binary")),
        MagicPrefixEntry(prefix: [0xCE, 0xFA, 0xED, 0xFE], kind: .binary(mime: "application/x-mach-binary")),
        MagicPrefixEntry(prefix: [0xCF, 0xFA, 0xED, 0xFE], kind: .binary(mime: "application/x-mach-binary")),
        MagicPrefixEntry(prefix: [0xCA, 0xFE, 0xBA, 0xBE], kind: .binary(mime: "application/x-mach-binary")),
        MagicPrefixEntry(prefix: [0x7F, 0x45, 0x4C, 0x46], kind: .binary(mime: "application/x-elf")),
        MagicPrefixEntry(prefix: [0x00, 0x61, 0x73, 0x6D], kind: .binary(mime: "application/wasm"))
    ]
}

