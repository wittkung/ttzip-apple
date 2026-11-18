// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Callout styling variants.
public enum DocumentCalloutType: String, Sendable, Equatable, Hashable {
    case info
    case tip
    case warning
    case note
}

/// Structured document primitive blocks with deterministic, collision-free identities.
public enum DocumentBlock: Identifiable, Equatable, Sendable {
    case title(String, subtitle: String? = nil, occurrence: Int = 0)
    case heading(level: Int, text: String, occurrence: Int = 0)
    case paragraph(String, occurrence: Int = 0)
    case quote(String, occurrence: Int = 0)
    case code(language: String?, code: String, occurrence: Int = 0)
    case callout(type: DocumentCalloutType, text: String, occurrence: Int = 0)
    case bullet(String, occurrence: Int = 0)
    case table(headers: [String], rows: [[String]], occurrence: Int = 0)
    case divider(occurrence: Int = 0)

    /// Backward-compatible convenience member for `.divider` without arguments.
    public static var divider: DocumentBlock { .divider(occurrence: 0) }

    public var id: String {
        switch self {
        case .title(let t, let s, let occ):
            return "title-\(Self.fnv1a64("\(t)|\(s ?? "")"))-\(occ)"
        case .heading(let l, let t, let occ):
            return "heading-\(l)-\(Self.fnv1a64(t))-\(occ)"
        case .paragraph(let t, let occ):
            return "p-\(Self.fnv1a64(t))-\(occ)"
        case .quote(let t, let occ):
            return "quote-\(Self.fnv1a64(t))-\(occ)"
        case .code(let lang, let c, let occ):
            return "code-\(lang ?? "")-\(Self.fnv1a64(c))-\(occ)"
        case .callout(let type, let t, let occ):
            return "callout-\(type.rawValue)-\(Self.fnv1a64(t))-\(occ)"
        case .bullet(let t, let occ):
            return "bullet-\(Self.fnv1a64(t))-\(occ)"
        case .table(let headers, let rows, let occ):
            let payload = headers.joined(separator: "\u{1F}") + "\u{1E}" + rows.map { $0.joined(separator: "\u{1F}") }.joined(separator: "\u{1E}")
            return "table-\(Self.fnv1a64(payload))-\(occ)"
        case .divider(let occ):
            return "divider-\(occ)"
        }
    }

    nonisolated internal var baseKey: String {
        switch self {
        case .title(let t, let s, _): return "title:\(t)|\(s ?? "")"
        case .heading(let l, let t, _): return "heading:\(l):\(t)"
        case .paragraph(let t, _): return "p:\(t)"
        case .quote(let t, _): return "quote:\(t)"
        case .code(let lang, let c, _): return "code:\(lang ?? ""):\(c)"
        case .callout(let type, let t, _): return "callout:\(type.rawValue):\(t)"
        case .bullet(let t, _): return "bullet:\(t)"
        case .table(let headers, let rows, _):
            return "table:\(headers.joined(separator: "|")):\(rows.count)"
        case .divider: return "divider"
        }
    }

    nonisolated internal func withOccurrence(_ occ: Int) -> DocumentBlock {
        switch self {
        case .title(let t, let s, _): return .title(t, subtitle: s, occurrence: occ)
        case .heading(let l, let t, _): return .heading(level: l, text: t, occurrence: occ)
        case .paragraph(let t, _): return .paragraph(t, occurrence: occ)
        case .quote(let t, _): return .quote(t, occurrence: occ)
        case .code(let lang, let c, _): return .code(language: lang, code: c, occurrence: occ)
        case .callout(let type, let t, _): return .callout(type: type, text: t, occurrence: occ)
        case .bullet(let t, _): return .bullet(t, occurrence: occ)
        case .table(let h, let r, _): return .table(headers: h, rows: r, occurrence: occ)
        case .divider: return .divider(occurrence: occ)
        }
    }

    nonisolated private static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
