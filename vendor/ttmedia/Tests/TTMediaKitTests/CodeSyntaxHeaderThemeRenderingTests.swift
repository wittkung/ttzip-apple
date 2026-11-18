// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import XCTest
@testable import TTMediaKit

@MainActor
final class CodeSyntaxHeaderThemeRenderingTests: XCTestCase {
    func testDefaultSharedTokenizerUsesTreeSitterASTAcrossSupportedLanguages() async {
        await BackgroundSyntaxTokenizer.shared.setBackend(nil)

        let swiftSource = "struct MyCustomRecord { let item: custom_record }\nlet MAX_ITEMS = 42\n"
        let swiftSpans = await tokenizeFull(swiftSource, ext: "swift")
        XCTAssertEqual(category(of: "MyCustomRecord", in: swiftSource, spans: swiftSpans), .type)
        XCTAssertEqual(category(of: "custom_record", in: swiftSource, spans: swiftSpans), .type)
        XCTAssertNil(category(of: "MAX_ITEMS", in: swiftSource, spans: swiftSpans))

        let rustSource = "pub struct MyCustomRecord { pub item: custom_record }\nlet MAX_ITEMS = 42;\n"
        let rustSpans = await tokenizeFull(rustSource, ext: "rs")
        XCTAssertEqual(category(of: "MyCustomRecord", in: rustSource, spans: rustSpans), .type)
        XCTAssertEqual(category(of: "custom_record", in: rustSource, spans: rustSpans), .type)
        XCTAssertNil(category(of: "MAX_ITEMS", in: rustSource, spans: rustSpans))

        let pySource = "def run(item: custom_record) -> int:\n    MAX_ITEMS = 42\n    return \"ok\"\n"
        let pySpans = await tokenizeFull(pySource, ext: "py")
        XCTAssertEqual(category(of: "custom_record", in: pySource, spans: pySpans), .type)
        XCTAssertNil(category(of: "MAX_ITEMS", in: pySource, spans: pySpans))

        let jsSource = "// header\nfunction runTask() { const MAX_ITEMS = 42; return \"ok\"; }\n"
        let jsSpans = await tokenizeFull(jsSource, ext: "js")
        XCTAssertEqual(category(of: "runTask", in: jsSource, spans: jsSpans), .keyword)
        XCTAssertNil(category(of: "MAX_ITEMS", in: jsSource, spans: jsSpans))

        let tsSource = "interface custom_record { id: number; }\nconst MAX_ITEMS = 42;\n"
        let tsSpans = await tokenizeFull(tsSource, ext: "ts")
        XCTAssertEqual(category(of: "custom_record", in: tsSource, spans: tsSpans), .type)
        XCTAssertNil(category(of: "MAX_ITEMS", in: tsSource, spans: tsSpans))

        let cSource = "struct custom_record { int count; };\nint MAX_ITEMS = 42;\n"
        let cSpans = await tokenizeFull(cSource, ext: "c")
        XCTAssertEqual(category(of: "custom_record", in: cSource, spans: cSpans), .type)
        XCTAssertNil(category(of: "MAX_ITEMS", in: cSource, spans: cSpans))

        let jsonSource = "{\"title\": \"Banner\", \"count\": 42, \"active\": true}"
        let jsonSpans = await tokenizeFull(jsonSource, ext: "json")
        XCTAssertEqual(category(of: "\"Banner\"", in: jsonSource, spans: jsonSpans), .string)
        XCTAssertEqual(category(of: "42", in: jsonSource, spans: jsonSpans), .number)
        XCTAssertEqual(category(of: "true", in: jsonSource, spans: jsonSpans), .keyword)

        let mdSource = "# Banner\n```rust\nlet x = 1;\n```\n"
        let mdSpans = await tokenizeFull(mdSource, ext: "md")
        XCTAssertEqual(category(of: "rust", in: mdSource, spans: mdSpans), .string)
        XCTAssertNil(category(of: "Banner", in: mdSource, spans: mdSpans))

        let htmlSource = "<!-- nav --><section class=\"hero\">Banner</section>"
        let htmlSpans = await tokenizeFull(htmlSource, ext: "html")
        XCTAssertEqual(category(of: "section", in: htmlSource, spans: htmlSpans), .keyword)
        XCTAssertNil(category(of: "Banner", in: htmlSource, spans: htmlSpans))

        let cssSource = "/* theme */ section { width: 100px; content: \"ok\"; }"
        let cssSpans = await tokenizeFull(cssSource, ext: "css")
        XCTAssertEqual(category(of: "section", in: cssSource, spans: cssSpans), .keyword)
        XCTAssertEqual(category(of: "\"ok\"", in: cssSource, spans: cssSpans), .string)
    }

    func testUnsupportedExtensionsAndOversizedInputsFallbackToDefaultLexer() async {
        await BackgroundSyntaxTokenizer.shared.setBackend(nil)

        let fallbackSamples: [(ext: String, source: String, expectedKeyword: String)] = [
            ("sh", "#!/bin/sh\nif [ -n \"$HOME\" ]; then\n  return 0\nfi\n", "if"),
            ("yaml", "# config\nenabled: true\nretries: 3\n", "true"),
            ("toml", "# settings\nenabled = true\nport = 8080\n", "true"),
            ("sql", "-- query\nSELECT 42;\n", "42"),
        ]

        for sample in fallbackSamples {
            let actual = await tokenizeFull(sample.source, ext: sample.ext)
            let expected = BackgroundSyntaxTokenizer.defaultLexer(
                text: sample.source,
                ext: sample.ext,
                maxLength: sample.source.utf16.count
            )
            XCTAssertFalse(actual.isEmpty, "Fallback tokens must not be empty for .\(sample.ext)")
            XCTAssertEqual(actual, expected, "Unsupported extension .\(sample.ext) must fall back to defaultLexer")
        }

        let unit = "let MAX_ITEMS = 42\n"
        let underBoundSpans = await tokenizeFull(unit, ext: "swift")
        XCTAssertNil(category(of: "MAX_ITEMS", in: unit, spans: underBoundSpans))

        let oversizedSwift = String(repeating: unit, count: 7_500)
        XCTAssertGreaterThan(oversizedSwift.utf16.count, 131_072)
        let oversizedSpans = await tokenizeFull(oversizedSwift, ext: "swift")
        let expectedFallback = BackgroundSyntaxTokenizer.defaultLexer(
            text: oversizedSwift,
            ext: "swift",
            maxLength: oversizedSwift.utf16.count
        )
        XCTAssertFalse(oversizedSpans.isEmpty)
        XCTAssertEqual(oversizedSpans, expectedFallback)
    }

    func testMultiByteUTF8EmojiAndCJKProduceExactUTF16NSRangeOffsets() async {
        await BackgroundSyntaxTokenizer.shared.setBackend(nil)

        let source = """
        // 🚀🎉 中文注释与多字节 Emoji 混合前缀 👨👩👧👦
        let greeting = "你好，世界 🌍✨"
        struct MyCustomRecord {
            let payload: custom_record
            let count = 2048
        }
        """
        let nsSource = source as NSString
        let spans = await tokenizeFull(source, ext: "swift")
        XCTAssertFalse(spans.isEmpty)

        for span in spans {
            XCTAssertGreaterThanOrEqual(span.range.location, 0)
            XCTAssertGreaterThan(span.range.length, 0)
            XCTAssertLessThanOrEqual(
                NSMaxRange(span.range),
                nsSource.length,
                "Token span \(span.range) exceeds NSString UTF-16 length \(nsSource.length)"
            )
        }

        XCTAssertEqual(category(of: "\"你好，世界 🌍✨\"", in: source, spans: spans), .string)
        XCTAssertEqual(category(of: "MyCustomRecord", in: source, spans: spans), .type)
        XCTAssertEqual(category(of: "custom_record", in: source, spans: spans), .type)
        XCTAssertEqual(category(of: "2048", in: source, spans: spans), .number)
    }

    func testPriorityPrefixTokenCrossingBoundaryPreservesFullSpanLength() {
        let longComment = "// " + String(repeating: "a", count: 20_000)
        let source = longComment + "\nlet x = 42\n"
        let spans = TreeSitterSyntaxBackend().tokenize(
            text: source,
            fileExtension: "swift",
            maxLength: 16_384
        )
        let commentSpan = spans.first(where: { $0.colorType == .comment })
        XCTAssertNotNil(commentSpan)
        XCTAssertEqual(
            commentSpan?.range,
            NSRange(location: 0, length: (longComment as NSString).length),
            "Comment starting before maxLength must not be truncated at the 16,384 UTF-16 boundary"
        )
    }

    private func tokenizeFull(_ text: String, ext: String) async -> [TokenSpan] {
        await BackgroundSyntaxTokenizer.shared.tokenize(
            text: text,
            ext: ext,
            targetRange: NSRange(location: 0, length: (text as NSString).length)
        )
    }

    private func category(of token: String, in source: String, spans: [TokenSpan]) -> ColorCategory? {
        let target = (source as NSString).range(of: token)
        guard target.location != NSNotFound else { return nil }
        return spans.first(where: { $0.range == target })?.colorType
    }
}
