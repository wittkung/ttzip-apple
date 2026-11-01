// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import XCTest
@testable import TTMediaKit

@MainActor
final class CodeSyntaxHeaderThemeRenderingTests: XCTestCase {
    func testActualHeaderInkFollowsReadingCanvasWithoutRecoloringSibling() throws {
        for appScheme in [ColorScheme.light, .dark] {
            for mode in TTTextReadingBackgroundMode.allCases {
                for width in [560.0, 1200.0] {
                    try assertRenderedHeader(mode: mode, appScheme: appScheme, width: width)
                }
            }
        }
    }

    private func assertRenderedHeader(
        mode: TTTextReadingBackgroundMode, appScheme: ColorScheme, width: CGFloat
    ) throws {
        let darkPaper = mode.effectiveIsDark(isAppDarkAppearance: appScheme == .dark)
        let header = CodeSyntaxHeaderBar(
            isCompact: false, fileName: "fixture.swift", lineCount: 12, byteCount: 128,
            isEdited: false, isWritableFile: false, saveErrorMessage: nil,
            isSavedToastPresented: false, isCopiedToastPresented: false,
            showLineNumbers: .constant(true), readingBackgroundMode: .constant(mode),
            onCopy: {}, onSave: {}
        )
        let content = VStack(alignment: .leading, spacing: 0) {
            header.frame(width: width, height: 40)
                .background(darkPaper ? Color.black : Color.white)
            Text("SIBLING")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.leading, 12)
                .frame(width: width, height: 40, alignment: .leading)
                .background(appScheme == .dark ? Color.black : Color.white)
        }
        .environment(\.colorScheme, appScheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(bitmap.pixelsHigh, 80)
        // The wide fixture's first badge is "Swift": crop only its text, excluding
        // the green symbol, rounded border, picker, metrics, and all action buttons.
        let headerInk = countInk(bitmap, rect: CGRect(x: 36, y: 11, width: 30, height: 18), light: darkPaper)
        let siblingInk = countInk(bitmap, rect: CGRect(x: 12, y: 48, width: 62, height: 24), light: appScheme == .dark)
        let context = "app=\(appScheme), reading=\(mode), width=\(width)"
        XCTAssertGreaterThan(headerInk, 15, "Real header language glyphs lack canvas contrast: \(context)")
        XCTAssertGreaterThan(siblingInk, 40, "Header override escaped to app sibling: \(context)")
    }

    private func countInk(_ bitmap: NSBitmapImageRep, rect: CGRect, light: Bool) -> Int {
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let maximum = max(color.redComponent, max(color.greenComponent, color.blueComponent))
                let minimum = min(color.redComponent, min(color.greenComponent, color.blueComponent))
                let neutral = maximum - minimum < 0.08
                let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                if neutral && (light ? luminance > 0.65 : luminance < 0.4) { count += 1 }
            }
        }
        return count
    }

    func testMarkdownSourceModeFollowsAppColorSchemeAndReadingPreferenceStore() throws {
        let suiteName = "com.metastudyline.ttmedia.r3.md.source.\(UUID().uuidString)"
        let isolatedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        isolatedDefaults.removePersistentDomain(forName: suiteName)
        let isolatedStore = TTTextReadingPreferenceStore(
            defaults: isolatedDefaults,
            storageKey: TTTextReadingBackgroundMode.userDefaultsKey
        )
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 820, height: 520),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
            isolatedDefaults.removePersistentDomain(forName: suiteName)
        }

        for appScheme in [ColorScheme.light, .dark] {
            for mode in TTTextReadingBackgroundMode.allCases {
                try assertMarkdownSourceHostAppearance(
                    in: window,
                    store: isolatedStore,
                    mode: mode,
                    appScheme: appScheme
                )
            }
        }
    }

    private func assertMarkdownSourceHostAppearance(
        in window: NSWindow,
        store: TTTextReadingPreferenceStore,
        mode: TTTextReadingBackgroundMode,
        appScheme: ColorScheme
    ) throws {
        store.mode = mode
        let sampleMarkdown = "Plain lead paragraph before heading\n# Heading\n- item"
        let rootView = MarkdownRichPreviewView(
            initialMarkdown: sampleMarkdown,
            fileName: "README.md",
            isReadOnly: true,
            initialMode: .source,
            readingPreferenceStore: store
        )
        .environment(\.colorScheme, appScheme)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 820, height: 520)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(findFirstSubview(ofType: NSScrollView.self, in: hostingView))
        let textView = try XCTUnwrap(scrollView.documentView as? LargeTextEditorTextView)
        let storage = try XCTUnwrap(textView.textStorage)
        let rulerView = try XCTUnwrap(scrollView.verticalRulerView as? LineNumberRulerView)
        let expectedPalette = TTTextReadingPalette.resolve(
            mode: mode,
            isDarkAppearance: appScheme == .dark
        )

        let fgColor = try XCTUnwrap(
            storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        )
        let fgSRGB = fgColor.usingColorSpace(.sRGB) ?? fgColor
        let bgSRGB = textView.backgroundColor.usingColorSpace(.sRGB) ?? textView.backgroundColor
        let fgLuminance = TTTextReadingPalette.relativeLuminance(of: fgSRGB)
        let context = "scheme=\(appScheme), mode=\(mode.rawValue)"
        print(
            "[R3-MD-SOURCE-HOST] \(context) drawsBG=\(textView.drawsBackground) " +
            "rulerMode=\(rulerView.readingPalette.mode.rawValue) " +
            "rulerDark=\(rulerView.readingPalette.effectiveIsDark) " +
            String(
                format: "fg=(%.3f,%.3f,%.3f,lum=%.3f) bg=(%.3f,%.3f,%.3f,a=%.2f)",
                fgSRGB.redComponent, fgSRGB.greenComponent, fgSRGB.blueComponent, fgLuminance,
                bgSRGB.redComponent, bgSRGB.greenComponent, bgSRGB.blueComponent, bgSRGB.alphaComponent
            )
        )

        XCTAssertEqual(rulerView.readingPalette, expectedPalette, "Ruler palette mismatch: \(context)")
        XCTAssertEqual(scrollView.drawsBackground, expectedPalette.drawsOpaqueBackground, "ScrollView drawsBackground mismatch: \(context)")
        XCTAssertEqual(textView.drawsBackground, expectedPalette.drawsOpaqueBackground, "TextView drawsBackground mismatch: \(context)")
        XCTAssertEqual(textView.backgroundColor, expectedPalette.nsCanvasBackgroundColor, "TextView backgroundColor mismatch: \(context)")
        XCTAssertEqual(textView.insertionPointColor, expectedPalette.nsInsertionPointColor, "Caret color mismatch: \(context)")

        if expectedPalette.drawsOpaqueBackground {
            let contrast = TTTextReadingPalette.contrastRatio(between: fgSRGB, and: bgSRGB)
            XCTAssertGreaterThanOrEqual(contrast, 4.5, "Opaque canvas contrast < 4.5:1 for \(context)")
        } else if appScheme == .light {
            XCTAssertLessThan(fgLuminance, 0.15, "Light fluidTransparent must use dark ink: \(context)")
        } else {
            XCTAssertGreaterThan(fgLuminance, 0.75, "Dark fluidTransparent must use light ink: \(context)")
        }
    }

    private func findFirstSubview<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let matched = root as? T {
            return matched
        }
        for child in root.subviews {
            if let found = findFirstSubview(ofType: type, in: child) {
                return found
            }
        }
        return nil
    }
}
