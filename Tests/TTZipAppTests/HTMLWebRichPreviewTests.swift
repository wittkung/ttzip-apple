// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import AppKit
import WebKit
import TTZipUI
import TTZipPreviewKit
@testable import TTZipCore
@testable import TTZipApp

final class HTMLWebRichPreviewTests: XCTestCase {
    
    private var tempDirURL: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirURL = FileManager.default.temporaryDirectory.appendingPathComponent("HTMLWebPreviewTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        if let url = tempDirURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }
    
    // MARK: - Test 1: Synchronous Format Detection for HTML Extensions
    
    func testHTMLFormatDetectionSync() throws {
        let sampleHTML = "<!DOCTYPE html><html><head><title>Test</title></head><body><h1>Hello World</h1></body></html>"
        let extensions = ["html", "htm", "xhtml", "mhtml"]
        
        for ext in extensions {
            let fileURL = tempDirURL.appendingPathComponent("document.\(ext)")
            try sampleHTML.write(to: fileURL, atomically: true, encoding: .utf8)
            
            let detectedType = MediaPreviewFactory.detectType(url: fileURL)
            switch detectedType {
            case .htmlWeb(let content, let url):
                XCTAssertTrue(content.contains("Hello World"), "Expected HTML content for extension .\(ext)")
                XCTAssertEqual(url, fileURL, "Expected matching file URL for extension .\(ext)")
            default:
                XCTFail("Expected .htmlWeb preview type for extension .\(ext), but got \(detectedType)")
            }
        }
    }
    
    // MARK: - Test 2: Asynchronous Format Detection for HTML Files
    
    func testHTMLFormatDetectionAsync() async throws {
        let sampleHTML = "<html><body><p>Async HTML Content</p></body></html>"
        let fileURL = tempDirURL.appendingPathComponent("index.html")
        try sampleHTML.write(to: fileURL, atomically: true, encoding: .utf8)
        
        let detectedType = await MediaPreviewFactory.detectTypeAsync(url: fileURL)
        switch detectedType {
        case .htmlWeb(let content, let url):
            XCTAssertTrue(content.contains("Async HTML Content"))
            XCTAssertEqual(url, fileURL)
        default:
            XCTFail("Expected .htmlWeb from detectTypeAsync, got \(detectedType)")
        }
    }
    
    // MARK: - Test 3: In-Memory Format Detection (Zero Disk I/O)
    
    func testHTMLFormatDetectionFromMemory() {
        let sampleHTML = "<!DOCTYPE html><html><body><span>In-Memory Web Page</span></body></html>"
        let data = Data(sampleHTML.utf8)
        
        let detectedType = MediaPreviewFactory.detectTypeFromMemory(data: data, suggestedName: "landing.html", sourceURL: nil)
        switch detectedType {
        case .htmlWeb(let content, let url):
            XCTAssertTrue(content.contains("In-Memory Web Page"))
            XCTAssertNil(url)
        default:
            XCTFail("Expected .htmlWeb from in-memory detection, got \(detectedType)")
        }
    }
    
    // MARK: - Test 4: File Icon Name Resolution
    
    func testHTMLIconNameResolution() {
        XCTAssertEqual(MediaPreviewFactory.iconName(for: "index.html"), "globe")
        XCTAssertEqual(MediaPreviewFactory.iconName(for: "page.htm"), "globe")
        XCTAssertEqual(MediaPreviewFactory.iconName(for: "doc.xhtml"), "globe")
        XCTAssertEqual(MediaPreviewFactory.iconName(for: "archive.mhtml"), "globe")
    }
    
    // MARK: - Test 5: Mode Enum and Labels
    
    func testHTMLPreviewModeEnumValues() {
        XCTAssertEqual(HTMLPreviewMode.rendered.rawValue, "网页渲染")
        XCTAssertEqual(HTMLPreviewMode.source.rawValue, "源代码")
        XCTAssertEqual(HTMLPreviewMode.rendered.icon, "globe")
        XCTAssertEqual(HTMLPreviewMode.source.icon, "curlybraces")
        XCTAssertEqual(HTMLPreviewMode.rendered.id, "网页渲染")
    }
    
    // MARK: - Test 6: View Assembly in MediaPreviewFactory
    
    @MainActor
    func testMakePreviewViewForHTMLWeb() throws {
        let sampleHTML = "<html><body><h1>Factory Test</h1></body></html>"
        let fileURL = tempDirURL.appendingPathComponent("view_test.html")
        try sampleHTML.write(to: fileURL, atomically: true, encoding: .utf8)
        
        let previewView = MediaPreviewFactory.makePreviewView(
            type: .htmlWeb(content: sampleHTML, fileURL: fileURL),
            fileName: "view_test.html",
            fileURL: fileURL
        )
        XCTAssertNotNil(previewView, "MediaPreviewFactory.makePreviewView must produce non-nil view for .htmlWeb")
    }
    
    // MARK: - Test 7: Standalone CodeSyntaxPreviewView Adapter
    
    @MainActor
    func testCodeSyntaxPreviewViewInstantiation() {
        let sourceCode = "<p>Hello</p>"
        let codeView = CodeSyntaxPreviewView(content: sourceCode, fileURL: nil, fileName: "test.html")
        XCTAssertNotNil(codeView)
    }
}
