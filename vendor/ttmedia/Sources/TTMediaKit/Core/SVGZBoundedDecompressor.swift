// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaDemux

/// Typed errors thrown by `SVGZBoundedDecompressor` when validating and decompressing `.svgz` payloads.
public enum SVGZDecompressionError: Error, Equatable, Sendable, LocalizedError {
    case compressedPayloadTooLarge(Int)
    case invalidGzipHeader
    case truncatedStream
    case corruptedPayloadOrChecksumMismatch
    case decompressedSizeLimitExceeded(maxBytes: Int)
    case excessiveExpansionRatio(ratio: Int)
    case invalidUTF8Encoding
    case notValidSVGPayload

    public var errorDescription: String? {
        switch self {
        case .compressedPayloadTooLarge(let bytes):
            return "Compressed SVGZ payload (\(bytes) bytes) exceeds the maximum allowed input size."
        case .invalidGzipHeader:
            return "Invalid RFC 1952 Gzip header in SVGZ payload."
        case .truncatedStream:
            return "Truncated Gzip stream in SVGZ payload."
        case .corruptedPayloadOrChecksumMismatch:
            return "Corrupted Gzip deflate stream or CRC32/ISIZE checksum mismatch in SVGZ payload."
        case .decompressedSizeLimitExceeded(let maxBytes):
            return "Decompressed SVGZ output exceeds the \(maxBytes)-byte safety ceiling."
        case .excessiveExpansionRatio(let ratio):
            return "Decompressed SVGZ expansion ratio (\(ratio):1) exceeds the maximum allowed bomb threshold."
        case .invalidUTF8Encoding:
            return "Decompressed SVGZ payload is not valid UTF-8 text."
        case .notValidSVGPayload:
            return "Decompressed SVGZ payload does not contain a valid <svg> root or element."
        }
    }
}

/// Thin Swift wrapper over the Rust `ttmedia::svgz` bounded Gzip (`.svgz`) decompressor.
public enum SVGZBoundedDecompressor: Sendable {

    /// Default maximum compressed `.svgz` input size (8 MB).
    public static let defaultMaxCompressedBytes: Int = 8 * 1024 * 1024

    /// Default maximum decompressed SVG XML size (16 MB).
    public static let defaultMaxDecompressedBytes: Int = 16 * 1024 * 1024

    /// Default maximum decompressed-to-compressed expansion ratio (100:1).
    public static let defaultMaxExpansionRatio: Int = 100

    /// Minimum decompressed output threshold (64 KB) before enforcing expansion ratio limits.
    public static let expansionRatioCheckMinOutputBytes: Int = 64 * 1024

    /// Streams and decompresses a `.svgz` file from disk via Rust C-ABI within strict resource bounds.
    public static func decompressSVGZ(
        from url: URL,
        maxCompressedBytes: Int = defaultMaxCompressedBytes,
        maxDecompressedBytes: Int = defaultMaxDecompressedBytes,
        maxExpansionRatio: Int = defaultMaxExpansionRatio
    ) throws -> String {
        var outPtr: UnsafeMutablePointer<CChar>?
        var errMetric: Int = 0
        let status = url.path.withCString { cPath in
            ttmedia_svgz_decompress_file(
                cPath,
                max(0, maxCompressedBytes),
                max(1, maxDecompressedBytes),
                max(1, maxExpansionRatio),
                &outPtr,
                &errMetric
            )
        }
        defer {
            if let outPtr {
                ttmedia_svgz_string_free(outPtr)
            }
        }
        return try resolveDecompressionResult(status: status, outPtr: outPtr, errMetric: errMetric)
    }

    /// Decompresses an in-memory `.svgz` Gzip payload via Rust C-ABI within strict resource bounds.
    public static func decompressSVGZ(
        data: Data,
        maxCompressedBytes: Int = defaultMaxCompressedBytes,
        maxDecompressedBytes: Int = defaultMaxDecompressedBytes,
        maxExpansionRatio: Int = defaultMaxExpansionRatio
    ) throws -> String {
        guard !data.isEmpty else {
            throw SVGZDecompressionError.invalidGzipHeader
        }

        var outPtr: UnsafeMutablePointer<CChar>?
        var errMetric: Int = 0
        let status: Int32 = data.withUnsafeBytes { rawBuffer in
            let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return ttmedia_svgz_decompress_bytes(
                base,
                rawBuffer.count,
                max(0, maxCompressedBytes),
                max(1, maxDecompressedBytes),
                max(1, maxExpansionRatio),
                &outPtr,
                &errMetric
            )
        }
        defer {
            if let outPtr {
                ttmedia_svgz_string_free(outPtr)
            }
        }
        return try resolveDecompressionResult(status: status, outPtr: outPtr, errMetric: errMetric)
    }

    private static func resolveDecompressionResult(
        status: Int32,
        outPtr: UnsafeMutablePointer<CChar>?,
        errMetric: Int
    ) throws -> String {
        switch status {
        case TT_MEDIA_SVGZ_OK.rawValue:
            guard let outPtr else {
                throw SVGZDecompressionError.corruptedPayloadOrChecksumMismatch
            }
            return String(cString: outPtr)
        case TT_MEDIA_SVGZ_ERR_COMPRESSED_TOO_LARGE.rawValue:
            throw SVGZDecompressionError.compressedPayloadTooLarge(errMetric)
        case TT_MEDIA_SVGZ_ERR_INVALID_GZIP_HEADER.rawValue:
            throw SVGZDecompressionError.invalidGzipHeader
        case TT_MEDIA_SVGZ_ERR_TRUNCATED_STREAM.rawValue:
            throw SVGZDecompressionError.truncatedStream
        case TT_MEDIA_SVGZ_ERR_CORRUPTED_OR_CHECKSUM.rawValue:
            throw SVGZDecompressionError.corruptedPayloadOrChecksumMismatch
        case TT_MEDIA_SVGZ_ERR_DECOMPRESSED_LIMIT.rawValue:
            throw SVGZDecompressionError.decompressedSizeLimitExceeded(maxBytes: errMetric)
        case TT_MEDIA_SVGZ_ERR_EXCESSIVE_RATIO.rawValue:
            throw SVGZDecompressionError.excessiveExpansionRatio(ratio: errMetric)
        case TT_MEDIA_SVGZ_ERR_INVALID_UTF8.rawValue:
            throw SVGZDecompressionError.invalidUTF8Encoding
        case TT_MEDIA_SVGZ_ERR_NOT_VALID_SVG.rawValue:
            throw SVGZDecompressionError.notValidSVGPayload
        default:
            throw SVGZDecompressionError.corruptedPayloadOrChecksumMismatch
        }
    }
}

// MARK: - MHTML MIME Sniffer & Launch Boundary Guard

/// Structured inspection summary for an RFC 2557 MHTML (`multipart/related`) web archive.
public struct MHTMLInspectionSummary: Equatable, Sendable, Codable {
    public let isMultipartMHTML: Bool
    public let boundary: String?
    public let contentType: String?
    public let subject: String?
    public let snapshotContentLocation: String?
    public let partCountEstimate: Int
    public let recommendedLanguage: String
    public let rawMimeSource: String
    public let renderedHTML: String?

    enum CodingKeys: String, CodingKey {
        case isMultipartMHTML = "is_multipart_mhtml"
        case boundary
        case contentType = "content_type"
        case subject
        case snapshotContentLocation = "snapshot_content_location"
        case partCountEstimate = "part_count_estimate"
        case recommendedLanguage = "recommended_language"
        case rawMimeSource = "raw_mime_source"
        case renderedHTML = "rendered_html"
    }

    public init(
        isMultipartMHTML: Bool,
        boundary: String?,
        contentType: String?,
        subject: String?,
        snapshotContentLocation: String?,
        partCountEstimate: Int,
        recommendedLanguage: String = "mime",
        rawMimeSource: String,
        renderedHTML: String? = nil
    ) {
        self.isMultipartMHTML = isMultipartMHTML
        self.boundary = boundary
        self.contentType = contentType
        self.subject = subject
        self.snapshotContentLocation = snapshotContentLocation
        self.partCountEstimate = partCountEstimate
        self.recommendedLanguage = recommendedLanguage
        self.rawMimeSource = rawMimeSource
        self.renderedHTML = renderedHTML
    }
}

/// Thin Swift wrapper over the Rust `ttmedia::svgz` RFC 2557 MHTML (`multipart/related`) sniffer.
public enum MHTMLMimeBoundaryGuard: Sendable {

    /// Recommended syntax highlighting language identifier when routing MHTML to `.code`.
    public static let mimeLanguageIdentifier = "mime"

    /// Returns `true` if `text` starts with an RFC 2557 MHTML (`multipart/related`) MIME envelope.
    public static func isMultipartMHTML(text: String) -> Bool {
        var utf8 = text
        return utf8.withUTF8 { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return false }
            return ttmedia_mhtml_is_multipart(base, buffer.count)
        }
    }

    /// Returns `true` if `data` starts with an RFC 2557 MHTML (`multipart/related`) MIME envelope.
    public static func isMultipartMHTML(data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return data.withUnsafeBytes { rawBuffer in
            let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return ttmedia_mhtml_is_multipart(base, rawBuffer.count)
        }
    }

    /// Returns `true` if the file at `url` starts with an RFC 2557 MHTML (`multipart/related`) MIME envelope.
    public static func isMultipartMHTML(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return url.path.withCString { cPath in
            ttmedia_mhtml_is_multipart_file(cPath)
        }
    }

    /// Extracts raw MIME source text when `text` is a multipart MHTML archive, or `nil` if it is plain HTML.
    public static func extractRawMimeSource(from text: String, maxBytes: Int = 8 * 1024 * 1024) -> String? {
        inspectMHTMLSource(data: Data(text.utf8), maxBytes: maxBytes)?.rawMimeSource
    }

    /// Extracts raw MIME source text from in-memory `data` when it is a multipart MHTML archive.
    public static func extractRawMimeSource(from data: Data, maxBytes: Int = 8 * 1024 * 1024) -> String? {
        inspectMHTMLSource(data: data, maxBytes: maxBytes)?.rawMimeSource
    }

    /// Inspects an MHTML text payload via Rust C-ABI and returns structured metadata plus raw MIME source.
    public static func inspectMHTMLSource(text: String) -> MHTMLInspectionSummary? {
        inspectMHTMLSource(data: Data(text.utf8), maxBytes: max(1, text.utf8.count))
    }

    /// Inspects an MHTML data payload via Rust C-ABI and returns structured metadata plus raw MIME source.
    public static func inspectMHTMLSource(data: Data, maxBytes: Int = 8 * 1024 * 1024) -> MHTMLInspectionSummary? {
        guard !data.isEmpty else { return nil }
        let cStrPtr: UnsafeMutablePointer<CChar>? = data.withUnsafeBytes { rawBuffer in
            let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress
            return ttmedia_mhtml_extract_summary(base, rawBuffer.count, max(1, maxBytes))
        }
        guard let cStrPtr else { return nil }
        defer {
            ttmedia_svgz_string_free(cStrPtr)
        }
        let jsonString = String(cString: cStrPtr)
        guard let jsonData = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MHTMLInspectionSummary.self, from: jsonData)
    }
}
