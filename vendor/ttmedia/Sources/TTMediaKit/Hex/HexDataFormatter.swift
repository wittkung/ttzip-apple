// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Page size options for Hex data viewer pagination.
public enum HexPageSizeOption: Int, CaseIterable, Identifiable, Sendable {
    case oneKilobyte = 1024
    case twoKilobytes = 2048
    case fourKilobytes = 4096
    case eightKilobytes = 8192
    
    public var id: Int { rawValue }
    
    public var displayName: String {
        switch self {
        case .oneKilobyte: return "1 KB (64 lines)"
        case .twoKilobytes: return "2 KB (128 lines)"
        case .fourKilobytes: return "4 KB (256 lines)"
        case .eightKilobytes: return "8 KB (512 lines)"
        }
    }
}

/// Closed byte range model representing inspection boundaries.
public struct HexByteRange: Hashable, Sendable {
    public let start: Int64
    public let end: Int64
    
    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }
    
    public var length: Int64 {
        max(0, end - start)
    }
}

/// Tokenized representation of a single byte with syntax presentation attributes.
public struct HexByteToken: Identifiable, Sendable {
    public let id: Int
    public let byte: UInt8
    public let hexString: String
    public let asciiChar: Character
    public let isPrintable: Bool
    public let isZero: Bool
    
    public init(id: Int, byte: UInt8) {
        self.id = id
        self.byte = byte
        self.hexString = String(format: "%02X", byte)
        if byte >= 32 && byte <= 126 {
            let scalar = UnicodeScalar(byte)
            self.asciiChar = Character(scalar)
            self.isPrintable = true
        } else {
            self.asciiChar = "."
            self.isPrintable = false
        }
        self.isZero = (byte == 0)
    }
}

/// Represents a 16-byte formatted virtual row for virtualized or structured inspection.
public struct HexDataRow: Identifiable, Sendable {
    public let id: Int64
    public let offset: Int64
    public let offsetHex: String
    public let firstHalfTokens: [HexByteToken]
    public let secondHalfTokens: [HexByteToken]
    public let asciiString: String
    
    public init(offset: Int64, bytes: Data) {
        self.id = offset
        self.offset = offset
        self.offsetHex = String(format: "%08X", offset)
        
        var firstHalf: [HexByteToken] = []
        var secondHalf: [HexByteToken] = []
        var ascii = ""
        
        for (index, byte) in bytes.enumerated() {
            let token = HexByteToken(id: Int(offset) + index, byte: byte)
            if index < 8 {
                firstHalf.append(token)
            } else {
                secondHalf.append(token)
            }
            ascii.append(token.asciiChar)
        }
        
        self.firstHalfTokens = firstHalf
        self.secondHalfTokens = secondHalf
        self.asciiString = ascii
    }
}

/// High-throughput formatting utility for hex representations and clipboard export.
public enum HexDataFormattingHelper {
    /// Formats an offset integer to a fixed-width uppercase hexadecimal string.
    public static func formatOffset(_ offset: Int64, width: Int = 8) -> String {
        String(format: "%0\(width)X", offset)
    }
    
    /// Formats current start and end byte offsets into a human-readable range string.
    public static func formatOffsetRange(start: Int64, end: Int64, compact: Bool) -> String {
        if compact {
            return String(format: "0x%06X…", start)
        } else {
            return String(format: "0x%08X – 0x%08X", start, max(0, end - 1))
        }
    }
    
    /// Formats raw byte data into space-separated uppercase hex bytes.
    public static func formatHexBytes(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    /// Formats raw byte data into a continuous hex string.
    public static func formatContinuousHex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }
    
    /// Decodes raw byte data into printable ASCII text, replacing control characters with dots.
    public static func formatASCIIString(_ data: Data) -> String {
        data.map { byte -> String in
            if byte >= 32 && byte <= 126 {
                let scalar = UnicodeScalar(byte)
                return String(scalar)
            } else {
                return "."
            }
        }.joined()
    }
    
    /// Formats raw byte data into a standard C array structure definition.
    public static func formatCArray(_ data: Data, variableName: String = "data", strideCount: Int = 12) -> String {
        let hexList = data.map { String(format: "0x%02X", $0) }
        var result = "const unsigned char \(variableName)[\(data.count)] = {\n"
        for i in stride(from: 0, to: hexList.count, by: strideCount) {
            let chunk = hexList[i..<min(i + strideCount, hexList.count)].joined(separator: ", ")
            result += "    " + chunk + (i + strideCount < hexList.count ? ",\n" : "\n")
        }
        result += "};\n"
        return result
    }
    
    /// Formats a complete 3-column hex dump table with offsets, hex columns, and ASCII text.
    public static func formatFullDumpTable(_ data: Data, startOffset: Int64) -> String {
        var dump = ""
        let count = data.count
        for lineStart in stride(from: 0, to: count, by: 16) {
            let offset = startOffset + Int64(lineStart)
            let lineEnd = min(lineStart + 16, count)
            let chunk = data.subdata(in: lineStart..<lineEnd)
            
            let offsetStr = String(format: "%08X", offset)
            var hex1 = ""
            var hex2 = ""
            var ascii = ""
            
            for (idx, byte) in chunk.enumerated() {
                let hexByte = String(format: "%02X", byte)
                if idx < 8 {
                    hex1 += (hex1.isEmpty ? "" : " ") + hexByte
                } else {
                    hex2 += (hex2.isEmpty ? "" : " ") + hexByte
                }
                if byte >= 32 && byte <= 126 {
                    let scalar = UnicodeScalar(byte)
                    ascii.append(Character(scalar))
                } else {
                    ascii.append(".")
                }
            }
            
            let hex1Padded = hex1.padding(toLength: 23, withPad: " ", startingAt: 0)
            let hex2Padded = hex2.padding(toLength: 23, withPad: " ", startingAt: 0)
            let asciiPadded = ascii.padding(toLength: 16, withPad: " ", startingAt: 0)
            
            dump += "\(offsetStr)  \(hex1Padded)  \(hex2Padded)  |\(asciiPadded)|\n"
        }
        return dump
    }
    
    /// Parses user-entered offset input (hexadecimal or decimal) with boundary clamping.
    public static func parseOffset(from input: String, maxFileSize: Int64) -> Int64 {
        var clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsedOffset: Int64 = 0
        if clean.lowercased().hasPrefix("0x") {
            clean = String(clean.dropFirst(2))
            if let hexVal = Int64(clean, radix: 16) {
                parsedOffset = hexVal
            }
        } else if let decVal = Int64(clean, radix: 10) {
            parsedOffset = decVal
        } else if let hexVal = Int64(clean, radix: 16) {
            parsedOffset = hexVal
        }
        
        let upperLimit = maxFileSize > 0 ? maxFileSize - 1 : 0
        return max(0, min(parsedOffset, upperLimit))
    }
    
    /// Breaks a data chunk into an array of virtual rows for row-by-row rendering.
    public static func generateRows(from data: Data, startOffset: Int64) -> [HexDataRow] {
        var rows: [HexDataRow] = []
        let count = data.count
        for lineStart in stride(from: 0, to: count, by: 16) {
            let offset = startOffset + Int64(lineStart)
            let lineEnd = min(lineStart + 16, count)
            let chunk = data.subdata(in: lineStart..<lineEnd)
            rows.append(HexDataRow(offset: offset, bytes: chunk))
        }
        return rows
    }
}

// MARK: - Byte Count Formatter Cache

/// Thread-safe byte count formatted string provider with caching.
final class ByteCountFormatterCache: @unchecked Sendable {
    static let shared = ByteCountFormatterCache()
    
    private let lock = NSLock()
    private var stringCache: [Int64: String] = [:]
    
    private let formatter: ByteCountFormatter = {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useAll]
        fmt.countStyle = .file
        return fmt
    }()
    
    private let maxCacheSize = 20_000
    
    private init() {}
    
    public func string(fromByteCount bytes: Int64) -> String {
        let targetBytes = max(0, bytes)
        
        lock.lock()
        defer { lock.unlock() }
        if let cached = stringCache[targetBytes] {
            return cached
        }
        
        let formatted = formatter.string(fromByteCount: targetBytes)
        if stringCache.count < maxCacheSize {
            stringCache[targetBytes] = formatted
        }
        return formatted
    }
    
    public static func string(fromByteCount byteCount: Int64) -> String {
        return shared.string(fromByteCount: byteCount)
    }
    
    public func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        stringCache.removeAll(keepingCapacity: false)
    }
}

/// Flyweight alias for cached ByteCountFormatter.
typealias ByteCountFormatterFlyweight = ByteCountFormatterCache
