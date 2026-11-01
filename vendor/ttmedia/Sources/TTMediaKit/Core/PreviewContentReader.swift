// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import CoreFoundation
import Darwin

/// Headless content reader service responsible for reading text payloads and inferring text encodings
/// (UTF-8, UTF-16, GB18030, Shift-JIS, Big5, EUC-KR, ISO-Latin-1) completely decoupled from UI or View layers.
public enum TTMediaContentReader {

    /// Maximum text safety budget (50 MB) before refusing full-text decoding to prevent memory exhaustion.
    public static let maxTextBudget: Int64 = 50 * 1024 * 1024

    private static let logger = TTMediaLogger.content

    // MARK: - Encodings

    private static let gb18030Encoding: String.Encoding = {
        let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        return String.Encoding(rawValue: nsEnc)
    }()

    private static let shiftJISEncoding: String.Encoding = {
        let cfEnc = CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        return String.Encoding(rawValue: nsEnc)
    }()

    private static let big5Encoding: String.Encoding = {
        let cfEnc = CFStringEncoding(CFStringEncodings.big5.rawValue)
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        return String.Encoding(rawValue: nsEnc)
    }()

    private static let eucKREncoding: String.Encoding = {
        let cfEnc = CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        return String.Encoding(rawValue: nsEnc)
    }()

    // MARK: - Unicode BOM Descriptor

    private enum UnicodeBOM: Sendable, Equatable {
        case utf8
        case utf16LE
        case utf16BE
        case utf32LE
        case utf32BE

        var headerByteCount: Int {
            switch self {
            case .utf8: return 3
            case .utf16LE, .utf16BE: return 2
            case .utf32LE, .utf32BE: return 4
            }
        }

        var codeUnitWidth: Int {
            switch self {
            case .utf8: return 1
            case .utf16LE, .utf16BE: return 2
            case .utf32LE, .utf32BE: return 4
            }
        }

        var stringEncoding: String.Encoding {
            switch self {
            case .utf8: return .utf8
            case .utf16LE: return .utf16LittleEndian
            case .utf16BE: return .utf16BigEndian
            case .utf32LE: return .utf32LittleEndian
            case .utf32BE: return .utf32BigEndian
            }
        }
    }

    nonisolated private static func detectBOM(in data: Data) -> UnicodeBOM? {
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return .utf32LE
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return .utf32BE
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return .utf8
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return .utf16LE
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return .utf16BE
        }
        return nil
    }

    // MARK: - Reading APIs

    /// Reads text content from a file URL with BOM-aware binary sniffing and streaming hard byte ceiling.
    ///
    /// - Parameters:
    ///   - url: Target file URL to read.
    ///   - maxBudget: Maximum byte limit to safely decode into memory.
    /// - Returns: Decoded text string if content is text-based and within budget, or `nil` otherwise.
    nonisolated public static func readTextContent(from url: URL, maxBudget: Int64 = maxTextBudget) -> String? {
        readTextContent(
            from: url,
            maxBudget: maxBudget,
            chunkSize: 64 * 1024,
            onChunkRead: nil,
            customChunkReader: nil
        )
    }

    /// Internal streaming reader supporting custom chunk sizes, mid-read hooks, and deterministic error injection.
    nonisolated internal static func readTextContent(
        from url: URL,
        maxBudget: Int64 = maxTextBudget,
        chunkSize: Int = 64 * 1024,
        onChunkRead: ((Int) -> Void)? = nil,
        customChunkReader: ((FileHandle, Int) throws -> Data?)? = nil
    ) -> String? {
        guard maxBudget > 0 else { return nil }
        let hardBudget = Int(min(maxBudget, maxTextBudget))
        guard hardBudget > 0 else { return nil }

        guard let fileHandle = openRegularFileHandle(for: url) else { return nil }
        defer { try? fileHandle.close() }

        let readUpToCount: (Int) throws -> Data? = { count in
            if let customChunkReader {
                return try customChunkReader(fileHandle, count)
            }
            return try fileHandle.read(upToCount: count)
        }

        guard let data = readBoundedData(
            readUpToCount: readUpToCount,
            url: url,
            hardBudget: hardBudget,
            chunkSize: chunkSize,
            onChunkRead: onChunkRead
        ) else {
            return nil
        }
        return decodeTextPayload(data: data, allowSampleTruncation: false)
    }

    nonisolated private static func openRegularFileHandle(for url: URL) -> FileHandle? {
        guard url.isFileURL else {
            logger.warning("Attempted to read non-file URL: \(url.absoluteString)")
            return nil
        }
        let fd = url.withUnsafeFileSystemRepresentation { pathPtr -> Int32 in
            guard let pathPtr else { return -1 }
            return Darwin.open(pathPtr, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { return nil }

        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(fd)
            logger.warning("Rejected non-regular file for text reading: \(url.lastPathComponent)")
            return nil
        }

        let currentFlags = Darwin.fcntl(fd, F_GETFL)
        if currentFlags >= 0, (currentFlags & O_NONBLOCK) != 0 {
            _ = Darwin.fcntl(fd, F_SETFL, currentFlags & ~O_NONBLOCK)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    nonisolated private static func readBoundedData(
        readUpToCount: (Int) throws -> Data?,
        url: URL,
        hardBudget: Int,
        chunkSize: Int,
        onChunkRead: ((Int) -> Void)?
    ) -> Data? {
        let stepSize = max(1, min(chunkSize, hardBudget))
        let sniffWindow = min(4096, hardBudget)
        var accumulated = Data()
        var verifiedInitialSample = false

        while accumulated.count < hardBudget {
            let requestCount = nextReadStepSize(
                accumulatedCount: accumulated.count,
                hardBudget: hardBudget,
                stepSize: stepSize
            )
            let chunkOpt: Data?
            do {
                chunkOpt = try readUpToCount(requestCount)
            } catch {
                logger.warning("Read error on \(url.lastPathComponent) after \(accumulated.count) bytes: \(error.localizedDescription)")
                return nil
            }
            guard let chunk = chunkOpt, !chunk.isEmpty else {
                break
            }
            accumulated.append(chunk)
            if !verifiedInitialSample, accumulated.count >= sniffWindow {
                guard !isBinaryPayload(accumulated.prefix(4096)) else { return nil }
                verifiedInitialSample = true
            }
            onChunkRead?(accumulated.count)
        }

        guard !accumulated.isEmpty else { return nil }
        guard verifiedInitialSample || !isBinaryPayload(accumulated.prefix(4096)) else {
            return nil
        }
        guard isWithinBudgetAtEOF(
            readUpToCount: readUpToCount,
            accumulatedCount: accumulated.count,
            hardBudget: hardBudget,
            url: url
        ) else {
            return nil
        }
        return accumulated
    }

    nonisolated private static func nextReadStepSize(
        accumulatedCount: Int,
        hardBudget: Int,
        stepSize: Int
    ) -> Int {
        let remaining = hardBudget - accumulatedCount
        if accumulatedCount == 0, stepSize >= 4096 {
            return min(4096, remaining)
        }
        return min(stepSize, remaining)
    }

    nonisolated private static func isWithinBudgetAtEOF(
        readUpToCount: (Int) throws -> Data?,
        accumulatedCount: Int,
        hardBudget: Int,
        url: URL
    ) -> Bool {
        guard accumulatedCount == hardBudget else { return true }
        do {
            if let overflowProbe = try readUpToCount(1), !overflowProbe.isEmpty {
                logger.warning("File \(url.lastPathComponent) exceeded text safety budget (\(hardBudget)) during read")
                return false
            }
            return true
        } catch {
            logger.warning("Overflow probe read error on \(url.lastPathComponent) at budget \(hardBudget): \(error.localizedDescription)")
            return false
        }
    }

    /// Reads a fast preview text sample up to a specified hard byte limit without loading the entire file.
    nonisolated public static func readTextSample(from url: URL, maxBytes: Int = 64 * 1024) -> String? {
        guard maxBytes > 0 else { return nil }
        let hardLimit = Int(min(Int64(maxBytes), maxTextBudget))
        guard hardLimit > 0 else { return nil }
        guard let fileHandle = openRegularFileHandle(for: url) else { return nil }
        defer { try? fileHandle.close() }

        let sampleOpt: Data?
        do {
            sampleOpt = try fileHandle.read(upToCount: hardLimit)
        } catch {
            logger.warning("Sample read error on \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        guard let sample = sampleOpt, !sample.isEmpty else { return nil }
        guard !isBinaryPayload(sample.prefix(4096)) else {
            return nil
        }
        return decodeTextPayload(data: sample, allowSampleTruncation: true)
    }

    /// Decodes raw data to String using progressive encoding heuristics.
    ///
    /// Evaluates explicit BOM (UTF-8, UTF-16LE/BE, UTF-32LE/BE), standard UTF-8,
    /// East Asian encodings (GB18030, Shift-JIS, Big5, EUC-KR), ASCII, and ISO-Latin-1.
    nonisolated public static func decodeText(data: Data) -> String? {
        guard !data.isEmpty else { return "" }
        guard Int64(data.count) <= maxTextBudget else { return nil }
        guard !isBinaryPayload(data.prefix(4096)) else { return nil }
        return decodeTextPayload(data: data, allowSampleTruncation: false)
    }

    nonisolated private static func decodeTextPayload(data: Data, allowSampleTruncation: Bool) -> String? {
        guard !data.isEmpty else { return "" }

        if let bom = detectBOM(in: data) {
            return decodeBOMTaggedData(data, bom: bom, allowSampleTruncation: allowSampleTruncation)
        }

        if let utf8String = decodeUTF8Data(data, allowSampleTruncation: allowSampleTruncation) {
            return utf8String
        }

        for encoding in [gb18030Encoding, shiftJISEncoding, big5Encoding, eucKREncoding] {
            if let decoded = String(data: data, encoding: encoding), !decoded.isEmpty {
                return decoded
            }
        }

        if let ascii = String(data: data, encoding: .ascii) {
            return ascii
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }

        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func decodeBOMTaggedData(
        _ data: Data,
        bom: UnicodeBOM,
        allowSampleTruncation: Bool
    ) -> String? {
        let body = Data(data.dropFirst(bom.headerByteCount))
        guard !body.isEmpty else { return "" }

        let unitWidth = bom.codeUnitWidth
        if !allowSampleTruncation && (body.count % unitWidth != 0) {
            return nil
        }

        let alignedCount = body.count - (body.count % unitWidth)
        guard alignedCount > 0 else { return nil }
        var alignedBody = body.prefix(alignedCount)

        if bom == .utf8 {
            return decodeUTF8Data(Data(alignedBody), allowSampleTruncation: allowSampleTruncation)
        }

        if allowSampleTruncation && (bom == .utf16LE || bom == .utf16BE) && alignedBody.count >= 2 {
            let lastUnit = readUInt16(from: alignedBody, offset: alignedBody.count - 2, bigEndian: bom == .utf16BE)
            if (0xD800...0xDBFF).contains(lastUnit) {
                alignedBody = alignedBody.dropLast(2)
            }
        }

        return String(data: Data(alignedBody), encoding: bom.stringEncoding)
    }

    nonisolated private static func decodeUTF8Data(_ data: Data, allowSampleTruncation: Bool) -> String? {
        if let direct = String(data: data, encoding: .utf8) {
            return direct
        }
        guard allowSampleTruncation, data.count > 3 else { return nil }
        for trimCount in 1...3 {
            if let trimmed = String(data: data.dropLast(trimCount), encoding: .utf8) {
                return trimmed
            }
        }
        return nil
    }

    // MARK: - Internal Helpers

    nonisolated public static func isBinaryPayload(_ sample: Data) -> Bool {
        guard !sample.isEmpty else { return false }

        if let bom = detectBOM(in: sample) {
            let body = Data(sample.dropFirst(bom.headerByteCount))
            guard !body.isEmpty else { return false }
            switch bom {
            case .utf8:
                return isSingleByteBinary(body)
            case .utf16LE:
                return isUTF16Binary(body, bigEndian: false)
            case .utf16BE:
                return isUTF16Binary(body, bigEndian: true)
            case .utf32LE:
                return isUTF32Binary(body, bigEndian: false)
            case .utf32BE:
                return isUTF32Binary(body, bigEndian: true)
            }
        }

        return isSingleByteBinary(sample)
    }

    nonisolated private static func isSingleByteBinary(_ sample: Data) -> Bool {
        guard !sample.isEmpty else { return false }
        if sample.first == 0 {
            return true
        }
        let nullCount = sample.filter { $0 == 0 }.count
        return Double(nullCount) / Double(sample.count) > 0.01
    }

    nonisolated private static func isUTF16Binary(_ body: Data, bigEndian: Bool) -> Bool {
        let unitCount = body.count / 2
        guard unitCount > 0 else { return true }

        let firstUnit = readUInt16(from: body, offset: 0, bigEndian: bigEndian)
        if firstUnit == 0 {
            return true
        }

        var nullUnits = 0
        var controlUnits = 0
        var index = 0
        while index < unitCount {
            let unit = readUInt16(from: body, offset: index * 2, bigEndian: bigEndian)
            if unit == 0 {
                nullUnits += 1
            } else if isDisallowedControlScalar(UInt32(unit)) {
                controlUnits += 1
            } else if (0xD800...0xDBFF).contains(unit) {
                if index + 1 < unitCount {
                    let nextUnit = readUInt16(from: body, offset: (index + 1) * 2, bigEndian: bigEndian)
                    guard (0xDC00...0xDFFF).contains(nextUnit) else { return true }
                    index += 1
                }
            } else if (0xDC00...0xDFFF).contains(unit) {
                return true
            }
            index += 1
        }

        if Double(nullUnits) / Double(unitCount) > 0.01 {
            return true
        }
        return Double(controlUnits) / Double(unitCount) > 0.10
    }

    nonisolated private static func isUTF32Binary(_ body: Data, bigEndian: Bool) -> Bool {
        let unitCount = body.count / 4
        guard unitCount > 0 else { return true }

        let firstUnit = readUInt32(from: body, offset: 0, bigEndian: bigEndian)
        if firstUnit == 0 {
            return true
        }

        var nullUnits = 0
        var controlUnits = 0
        for index in 0..<unitCount {
            let unit = readUInt32(from: body, offset: index * 4, bigEndian: bigEndian)
            if unit > 0x10FFFF || (0xD800...0xDFFF).contains(unit) {
                return true
            }
            if unit == 0 {
                nullUnits += 1
            } else if isDisallowedControlScalar(unit) {
                controlUnits += 1
            }
        }

        if Double(nullUnits) / Double(unitCount) > 0.01 {
            return true
        }
        return Double(controlUnits) / Double(unitCount) > 0.10
    }

    nonisolated private static func isDisallowedControlScalar(_ scalar: UInt32) -> Bool {
        switch scalar {
        case 0x01...0x08, 0x0E...0x1A, 0x1C...0x1F:
            return true
        default:
            return false
        }
    }

    nonisolated private static func readUInt16(from data: Data, offset: Int, bigEndian: Bool) -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return bigEndian ? ((b0 << 8) | b1) : (b0 | (b1 << 8))
    }

    nonisolated private static func readUInt32(from data: Data, offset: Int, bigEndian: Bool) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        if bigEndian {
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}

// MARK: - Compatibility Typealiases

public typealias PreviewContentReader = TTMediaContentReader
