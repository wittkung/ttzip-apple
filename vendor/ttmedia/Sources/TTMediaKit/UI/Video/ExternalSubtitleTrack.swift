// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CoreFoundation
import Foundation
import TTMediaDemux
import UniformTypeIdentifiers

internal struct ExternalSubtitleTrack: Sendable, Decodable, Equatable {
    static let supportedExtensions: Set<String> = ["srt", "vtt", "ttml", "dfxp", "ass", "ssa"]
    static let orderedExtensions: [String] = ["srt", "vtt", "ttml", "dfxp", "ass", "ssa"]

    struct Cue: Sendable, Decodable, Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    let cues: [Cue]
    private let maxEndPrefix: [Double]
    private let prevHigherEndIndex: [Int]

    init(cues: [Cue]) {
        let sorted = cues.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        self.cues = sorted
        var prefix = [Double]()
        prefix.reserveCapacity(sorted.count)
        var prevHigher = [Int]()
        prevHigher.reserveCapacity(sorted.count)
        var stack = [Int]()
        var runningMax = -Double.infinity
        for (i, cue) in sorted.enumerated() {
            if cue.end > runningMax {
                runningMax = cue.end
            }
            prefix.append(runningMax)
            while let last = stack.last, sorted[last].end <= cue.end {
                stack.removeLast()
            }
            prevHigher.append(stack.last ?? -1)
            stack.append(i)
        }
        self.maxEndPrefix = prefix
        self.prevHigherEndIndex = prevHigher
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCues = try container.decode([Cue].self, forKey: .cues)
        self.init(cues: decodedCues)
    }

    private enum CodingKeys: String, CodingKey {
        case cues
    }

    /// Resolves active subtitle text at `seconds` (adjusted by `delay`) via $O(\log N)$ binary search
    /// for the `start <= target` upper bound, followed by jump-index collection of still-open overlapping cues.
    func text(at seconds: Double, delay: Double = 0.0) -> String {
        guard !cues.isEmpty else { return "" }
        let target = seconds - delay

        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) >> 1
            if cues[mid].start <= target {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let upperBound = low
        guard upperBound > 0, maxEndPrefix[upperBound - 1] > target else {
            return ""
        }

        var matched: [String] = []
        var idx = upperBound - 1
        while idx >= 0, maxEndPrefix[idx] > target {
            let cue = cues[idx]
            if target < cue.end {
                matched.append(cue.text)
                idx -= 1
            } else {
                idx = prevHigherEndIndex[idx]
            }
        }

        guard !matched.isEmpty else { return "" }
        if matched.count == 1 { return matched[0] }
        return matched.reversed().joined(separator: "\n")
    }

    static func load(from url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
        return try parse(bytes)
    }

    private static func normalizeEncoding(_ bytes: Data) -> Data {
        guard bytes.count <= 4 * 1024 * 1024, !bytes.isEmpty else { return bytes }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            return bytes
        }
        if String(data: bytes, encoding: .utf8) != nil {
            return bytes
        }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let big5 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)
            )
        )
        for encoding in [gb18030, big5, .utf16, .windowsCP1252, .isoLatin1] {
            if let decoded = String(data: bytes, encoding: encoding), !decoded.isEmpty {
                return Data(decoded.utf8)
            }
        }
        return bytes
    }

    static func parse(_ bytes: Data) throws -> Self {
        struct Response: Decodable { let cues: [Cue]?; let error: String? }
        let normalized = normalizeEncoding(bytes)
        let json = normalized.withUnsafeBytes { buffer in
            ttmedia_subtitles_parse(buffer.bindMemory(to: UInt8.self).baseAddress, normalized.count)
        }
        guard let json else { throw CocoaError(.fileReadCorruptFile) }
        defer { ttmedia_subtitles_free(json) }
        let response = try JSONDecoder().decode(Response.self, from: Data(String(cString: json).utf8))
        guard let cues = response.cues else {
            throw NSError(domain: "TTMediaSubtitles", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: response.error ?? "Unable to read subtitles"])
        }
        return Self(cues: cues)
    }
}

