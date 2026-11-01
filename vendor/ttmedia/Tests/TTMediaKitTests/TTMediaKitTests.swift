// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
@testable import TTMediaKit

final class TTMediaKitTests: XCTestCase {
    func testUmbrellaVersion() {
        XCTAssertEqual(TTMediaKitInfo.version, "1.0.0")
    }

    @MainActor
    func testAVPlayerInitializationAndState() {
        let player = TTMediaAVPlayer()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0.0)
        XCTAssertEqual(player.duration, 0.0)

        // Waveform telemetry injection
        player.updateWaveform(peaks: [0.1, 0.5, 0.9], rms: [0.05, 0.25, 0.45])
        XCTAssertEqual(player.waveformPeaks.count, 3)
        XCTAssertEqual(player.waveformRms.count, 3)
        XCTAssertEqual(player.waveformPeaks[1], 0.5)

        // Stop resets playback
        player.stop()
        XCTAssertFalse(player.isPlaying)
    }

    func testMetalTilePipelineSuccess() throws {
        let pipeline = try MetalTilePipeline()
        let fakeBytes = Data(repeating: 255, count: 64 * 64 * 4)
        let texture = try pipeline.createTileTexture(width: 64, height: 64, rgbaBytes: fakeBytes)

        XCTAssertEqual(texture.width, 64)
        XCTAssertEqual(texture.height, 64)
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)

        // Convenience non-throwing helper
        let optTexture = pipeline.makeTileTexture(width: 32, height: 32, rgbaBytes: Data(repeating: 128, count: 32 * 32 * 4))
        XCTAssertNotNil(optTexture)
        XCTAssertEqual(optTexture?.width, 32)
    }

    func testMetalTilePipelineErrorHandling() throws {
        let pipeline = try MetalTilePipeline()
        let emptyBytes = Data()

        // Zero width should throw textureCreationFailed
        XCTAssertThrowsError(try pipeline.createTileTexture(width: 0, height: 64, rgbaBytes: emptyBytes)) { error in
            guard let pipeErr = error as? MetalPipelineError else {
                XCTFail("Expected MetalPipelineError, got \(error)")
                return
            }
            if case .textureCreationFailed(let w, let h) = pipeErr {
                XCTAssertEqual(w, 0)
                XCTAssertEqual(h, 64)
            } else {
                XCTFail("Expected textureCreationFailed, got \(pipeErr)")
            }
        }

        // Verify localized error descriptions are descriptive
        let deviceErr = MetalPipelineError.deviceUnavailable
        XCTAssertNotNil(deviceErr.errorDescription)
        XCTAssertTrue(deviceErr.errorDescription!.contains("Metal"))

        let shaderErr = MetalPipelineError.shaderLibraryNotFound(underlyingError: "Test bundle not found")
        XCTAssertTrue(shaderErr.errorDescription!.contains("Test bundle not found"))

        let funcErr = MetalPipelineError.functionNotFound(name: "customKernel")
        XCTAssertTrue(funcErr.errorDescription!.contains("customKernel"))
    }

    @MainActor
    func testWaveformViewInitialization() {
        var seekResult: Double?
        let waveform = TTWaveformView(
            waveformPeaks: [0.1, 0.4, 0.8, 0.3, 0.9, 0.2],
            progress: 0.45,
            onSeek: { ratio in
                seekResult = ratio
            }
        )

        XCTAssertEqual(waveform.waveformPeaks.count, 6)
        XCTAssertEqual(waveform.progress, 0.45)
        XCTAssertTrue(waveform.isInteractive)

        waveform.onSeek?(0.75)
        XCTAssertEqual(seekResult, 0.75)
    }

    @MainActor
    func testSpreadsheetViewInitialization() {
        let headers = ["ID", "Name", "Score", "Active"]
        let rows = [
            ["1", "Alice", "98.5", "true"],
            ["2", "Bob", "87.0", "false"],
            ["3", "Charlie", "92.3", "true"]
        ]

        var selectedIndex: Int?
        let sheet = TTSpreadsheetView(
            headers: headers,
            rows: rows,
            onRowSelect: { idx in
                selectedIndex = idx
            }
        )

        XCTAssertEqual(sheet.headers.count, 4)
        XCTAssertEqual(sheet.rows.count, 3)

        sheet.onRowSelect?(1)
        XCTAssertEqual(selectedIndex, 1)

        // Empty spreadsheet initialization
        let emptySheet = TTSpreadsheetView(headers: [], rows: [])
        XCTAssertTrue(emptySheet.headers.isEmpty)
        XCTAssertTrue(emptySheet.rows.isEmpty)
    }

    @MainActor
    func testRichDocumentViewAndMarkdownParser() {
        let sampleMarkdown = """
        # Document Title
        ## Subtitle Section
        This is a paragraph with detailed technical explanations.

        > Architectural invariants must be upheld unconditionally.

        ```swift
        let player = TTMediaAVPlayer()
        player.load(url: url)
        ```

        - Item Alpha
        - Item Beta
        ---
        Final notes paragraph.
        """

        let meta = DocumentMetadata(
            title: "Architecture Spec",
            author: "MetastudyLine CTO",
            date: "2026-09-26",
            wordCount: 42,
            tags: ["Swift", "Metal", "UI"]
        )

        let docView = TTRichDocumentView(markdown: sampleMarkdown, metadata: meta)

        XCTAssertEqual(docView.metadata?.title, "Architecture Spec")
        XCTAssertEqual(docView.metadata?.tags.count, 3)
        XCTAssertFalse(docView.blocks.isEmpty)

        // Verify parsed blocks count and types
        var hasHeading1 = false
        var hasHeading2 = false
        var hasParagraph = false
        var hasQuote = false
        var hasCode = false
        var hasBullet = false
        var hasDivider = false

        for block in docView.blocks {
            switch block {
            case .heading(let level, _, _):
                if level == 1 { hasHeading1 = true }
                if level == 2 { hasHeading2 = true }
            case .paragraph:
                hasParagraph = true
            case .quote:
                hasQuote = true
            case .code(let lang, _, _):
                if lang == "swift" { hasCode = true }
            case .bullet:
                hasBullet = true
            case .divider:
                hasDivider = true
            default:
                break
            }
        }

        XCTAssertTrue(hasHeading1)
        XCTAssertTrue(hasHeading2)
        XCTAssertTrue(hasParagraph)
        XCTAssertTrue(hasQuote)
        XCTAssertTrue(hasCode)
        XCTAssertTrue(hasBullet)
        XCTAssertTrue(hasDivider)

        // Verify GFM table, H1-H6, inline styles, and deterministic collision-free block IDs
        let gfmSample = """
        #### Level 4 Heading
        ###### Level 6 Heading
        Repeated paragraph with **bold**, *italic*, `code`, and [link](https://example.com).
        ---
        | Col A | Col B |
        | :--- | ---: |
        | Val 1 | Escaped \\| Pipe |
        ---
        Repeated paragraph with **bold**, *italic*, `code`, and [link](https://example.com).
        """
        let gfmDocA = TTRichDocumentView(markdown: gfmSample, metadata: nil)
        let gfmDocB = TTRichDocumentView(markdown: gfmSample, metadata: nil)
        XCTAssertEqual(gfmDocA.blocks.map(\.id), gfmDocB.blocks.map(\.id))
        XCTAssertEqual(Set(gfmDocA.blocks.map(\.id)).count, gfmDocA.blocks.count)
        XCTAssertTrue(gfmDocA.blocks.contains {
            if case .table(let headers, let rows, _) = $0 {
                return headers == ["Col A", "Col B"] && rows == [["Val 1", "Escaped | Pipe"]]
            }
            return false
        })
        let renderedInline = String(TTRichDocumentView.renderInlineAttributedString("**bold** and `code`").characters)
        XCTAssertEqual(renderedInline, "bold and code")
    }

    @MainActor
    func testMediaPreviewInstantiation() {
        let audioUrl = URL(fileURLWithPath: "/tmp/sample_audio.wav")
        let previewAudio = TTMediaPreview(url: audioUrl, title: "Test Audio")
        XCTAssertEqual(previewAudio.customTitle, "Test Audio")

        let docUrl = URL(fileURLWithPath: "/tmp/readme.md")
        let previewDoc = TTMediaPreview(url: docUrl)
        XCTAssertNil(previewDoc.customTitle)

        let csvUrl = URL(fileURLWithPath: "/tmp/data.csv")
        let previewCsv = TTMediaPreview(url: csvUrl)
        XCTAssertEqual(previewCsv.url.pathExtension, "csv")

        let videoUrl = URL(fileURLWithPath: "/tmp/sample_video.mp4")
        let previewVideo = TTMediaPreview(url: videoUrl, title: "4K Keynote")
        XCTAssertEqual(previewVideo.customTitle, "4K Keynote")
    }


    // MARK: - Core & Detector Tests

    func testTTMediaPreviewModels() {
        let ebookMeta = EBookMetadata(
            url: URL(fileURLWithPath: "/tmp/book.epub"),
            title: "Test Book",
            formatName: "EPUB",
            fileSizeDescription: "1.2 MB",
            excerptText: "Chapter 1",
            coverImage: nil
        )
        XCTAssertEqual(ebookMeta.title, "Test Book")

        let epubModel = EPUBBookModel(
            url: URL(fileURLWithPath: "/tmp/book.epub"),
            title: "Test Book",
            chapters: [EPUBChapterItem(title: "Intro", fileURL: URL(fileURLWithPath: "/tmp/ch1.xhtml"))],
            extractDir: URL(fileURLWithPath: "/tmp/epub_extracted")
        )
        XCTAssertEqual(epubModel.chapters.count, 1)

        let sheetData = TTMediaSheetData(name: "Sheet1", totalRows: 2, totalColumns: 2, rows: [["A", "B"], ["1", "2"]])
        let workbook = OfficeSpreadsheetWorkbook(fileName: "data.xlsx", sheetNames: ["Sheet1"], activeSheet: sheetData)
        XCTAssertEqual(workbook.sheetNames.first, "Sheet1")
        XCTAssertEqual(workbook.activeSheet?.totalRows, 2)

        let outline = TTMediaOfficeOutline(title: "Deck", slides: [TTMediaOfficeOutlineItem(slideNumber: 1, title: "Title Slide")])
        let presentation = OfficePresentationModel(fileName: "deck.pptx", outline: outline)
        XCTAssertEqual(presentation.outline.slides.count, 1)

        let hexType = TTMediaPreviewType.hexData(Data([0x00, 0x01]))
        if case .hexViewer(let data, _) = hexType {
            XCTAssertEqual(data.count, 2)
        } else {
            XCTFail("Expected .hexViewer")
        }
    }

    func testTTMediaCapabilityMatrix() {
        XCTAssertTrue(TTMediaCapabilityMatrix.isAudio("sample.mp3"))
        XCTAssertTrue(TTMediaCapabilityMatrix.isVideo("sample.mp4"))
        XCTAssertTrue(TTMediaCapabilityMatrix.isImage("sample.png"))
        XCTAssertTrue(TTMediaCapabilityMatrix.isMarkdown("readme.md"))
        XCTAssertTrue(TTMediaCapabilityMatrix.isPdf("doc.pdf"))
        XCTAssertTrue(TTMediaCapabilityMatrix.isEpub("book.epub"))
        XCTAssertTrue(TTMediaCapabilityMatrix.isOffice("slides.pptx"))
        XCTAssertTrue(TTMediaCapabilityMatrix.isSpreadsheet("table.csv"))
        XCTAssertTrue(TTMediaCapabilityMatrix.isCode("main.swift"))
        XCTAssertTrue(TTMediaCapabilityMatrix.isArchive("archive.7z"))
        XCTAssertTrue(TTMediaCapabilityMatrix.isHex("kernel.bin"))

        let desc = TTMediaCapabilityMatrix.descriptor(for: "swift")
        XCTAssertNotNil(desc)
        XCTAssertEqual(desc?.primaryMode, .sourceCode)
        XCTAssertTrue(desc?.capabilities.contains(.sourceCode) == true)
        XCTAssertEqual(TTMediaCapabilityMatrix.iconName(for: "main.swift"), "chevron.left.forwardslash.chevron.right")
    }

    func testTTMediaDetectorMagicBytes() {
        // PNG
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(TTMediaDetector.probeMagicBytes(data: pngHeader), .image(mime: "image/png"))

        // JPEG
        let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertEqual(TTMediaDetector.probeMagicBytes(data: jpegHeader), .image(mime: "image/jpeg"))

        // GIF
        let gifHeader = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        XCTAssertEqual(TTMediaDetector.probeMagicBytes(data: gifHeader), .image(mime: "image/gif"))

        // PDF
        let pdfHeader = Data([0x25, 0x50, 0x44, 0x46, 0x2D])
        XCTAssertEqual(TTMediaDetector.probeMagicBytes(data: pdfHeader), .pdf)

        // ZIP
        let zipHeader = Data([0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(TTMediaDetector.probeMagicBytes(data: zipHeader), .archive(mime: "application/zip"))

        // MP4
        var mp4Header = Data([0x00, 0x00, 0x00, 0x18])
        mp4Header.append(Data([0x66, 0x74, 0x79, 0x70])) // ftyp
        mp4Header.append(Data([0x6D, 0x70, 0x34, 0x32])) // mp42
        XCTAssertEqual(TTMediaDetector.probeMagicBytes(data: mp4Header), .video(mime: "video/mp4"))

        // WAV
        var wavHeader = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00])
        wavHeader.append(Data([0x57, 0x41, 0x56, 0x45]))
        XCTAssertEqual(TTMediaDetector.probeMagicBytes(data: wavHeader), .audio(mime: "audio/wav"))
    }

    func testTTMediaDetectorMemorySniffing() {
        let pdfData = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x35])
        let pdfType = TTMediaDetector.detectTypeFromMemory(data: pdfData, suggestedName: "document.pdf")
        if case .pdfData(let data, _) = pdfType {
            XCTAssertEqual(data.count, pdfData.count)
        } else {
            XCTFail("Expected .pdfData")
        }

        let mdData = "# Title\nContent".data(using: .utf8)!
        let mdType = TTMediaDetector.detectTypeFromMemory(data: mdData, suggestedName: "notes.md")
        if case .markdown(let text, _) = mdType {
            XCTAssertTrue(text.contains("Title"))
        } else {
            XCTFail("Expected .markdown")
        }

        let csvData = "col1,col2\n1,2".data(using: .utf8)!
        let csvType = TTMediaDetector.detectTypeFromMemory(data: csvData, suggestedName: "data.csv")
        if case .spreadsheetTable(let text, _) = csvType {
            XCTAssertTrue(text.contains("col1"))
        } else {
            XCTFail("Expected .spreadsheetTable")
        }
    }

    func testTTMediaLogger() {
        let logger = TTMediaLogger(category: "Test")
        logger.debug("Debug event message")
        logger.info("Info event message")
        logger.warning("Warning event message")
        logger.error("Error event message")
        logger.fault("Fault event message")
    }

    func testTTSecurityScopedResource() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        try? "Test payload".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let manager = TTSecurityScopedResourceManager.shared
        XCTAssertTrue(manager.startAccessing(url: tempURL))
        // Multiple references
        XCTAssertTrue(manager.startAccessing(url: tempURL))
        manager.stopAccessing(url: tempURL)
        manager.stopAccessing(url: tempURL)

        let result = manager.withAccess(to: tempURL) { url in
            (try? String(contentsOf: url)) ?? ""
        }
        XCTAssertEqual(result, "Test payload")
    }

    func testTTMediaContentReader() {
        let utf8Data = "Hello, World! 🚀".data(using: .utf8)!
        XCTAssertEqual(TTMediaContentReader.decodeText(data: utf8Data), "Hello, World! 🚀")

        // UTF-8 with BOM
        var bomData = Data([0xEF, 0xBB, 0xBF])
        bomData.append(utf8Data)
        XCTAssertEqual(TTMediaContentReader.decodeText(data: bomData), "Hello, World! 🚀")

        // Binary check
        let binaryData = Data([0x00, 0xFF, 0xFE, 0x00, 0x12])
        XCTAssertTrue(TTMediaContentReader.isBinaryPayload(binaryData))

        let cleanText = "Plain ASCII text content".data(using: .ascii)!
        XCTAssertFalse(TTMediaContentReader.isBinaryPayload(cleanText))
    }

    @MainActor
    func testP3BTextAndMarkdownEncodingAndArchiveSaveContracts() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("TTMediaP3B_\(UUID().uuidString)", isDirectory: true)
        let diskDir = tempRoot.appendingPathComponent("disk", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("TTZipLRUPreviewCache/s1", isDirectory: true)
        try fm.createDirectory(at: diskDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let cnName = "超长中文文件名_测试编码与只读权限保护_2026年度归档预览报告样本_v1.2.3.txt"
        let utf8URL = diskDir.appendingPathComponent(cnName)
        let utf8Initial = Data("第一行：UTF-8 原始文本\nSecond line\n".utf8)
        try utf8Initial.write(to: utf8URL)

        let diskEditor = CodeTextEditorContainerView(
            initialText: "第一行：UTF-8 原始文本\nSecond line\n",
            fileURL: utf8URL,
            fileName: cnName,
            resourceContext: .diskFile(url: utf8URL, fileName: cnName)
        )
        XCTAssertEqual(diskEditor.sourceEncoding, .utf8)
        XCTAssertEqual(diskEditor.initialByteCount, Int64(utf8Initial.count))
        XCTAssertTrue(diskEditor.canSaveInPlace)
        XCTAssertTrue(diskEditor.saveFile(contentOverride: "修改后 UTF-8\n"))
        XCTAssertEqual(try Data(contentsOf: utf8URL), Data("修改后 UTF-8\n".utf8))

        let stagedURL = stagingDir.appendingPathComponent(cnName)
        try utf8Initial.write(to: stagedURL)
        let archiveCtx = TTPreviewResourceContext.archiveEntry(
            archiveURL: tempRoot.appendingPathComponent("bundle.zip"),
            entryPath: "docs/\(cnName)",
            stagedReadURL: stagedURL,
            fileName: cnName
        )
        let archiveEditor = CodeTextEditorContainerView(
            initialText: "第一行：UTF-8 原始文本\nSecond line\n",
            fileURL: nil,
            fileName: cnName,
            resourceContext: archiveCtx
        )
        XCTAssertFalse(archiveEditor.canSaveInPlace)
        XCTAssertFalse(archiveEditor.isEditorEditable)
        XCTAssertEqual(archiveEditor.initialByteCount, Int64(utf8Initial.count))
        XCTAssertFalse(archiveEditor.saveFile(contentOverride: "Tampered"))
        XCTAssertEqual(try Data(contentsOf: stagedURL), utf8Initial)

        // UTF-16LE & GB18030: authentic raw byte count + read-only non-UTF-8 overwrite protection
        let utf16URL = diskDir.appendingPathComponent("utf16le_中文.txt")
        let utf16Text = "UTF-16LE 编码保护测试\nLine 2\n"
        var utf16Bytes = Data([0xFF, 0xFE])
        utf16Bytes.append(try XCTUnwrap(utf16Text.data(using: .utf16LittleEndian)))
        try utf16Bytes.write(to: utf16URL)
        let utf16Editor = CodeTextEditorContainerView(initialText: utf16Text, fileURL: utf16URL, fileName: "utf16le_中文.txt")
        XCTAssertEqual(utf16Editor.sourceEncoding, .utf16LE)
        XCTAssertEqual(utf16Editor.initialByteCount, Int64(utf16Bytes.count))
        XCTAssertFalse(utf16Editor.canSaveInPlace)
        XCTAssertFalse(utf16Editor.saveFile(contentOverride: "Overwrite UTF-8"))
        XCTAssertEqual(try Data(contentsOf: utf16URL), utf16Bytes)

        let gbEnc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbURL = diskDir.appendingPathComponent("gb18030_中文.md")
        let gbText = "# GB18030 标题\n正文内容测试\n"
        let gbBytes = try XCTUnwrap(gbText.data(using: gbEnc))
        try gbBytes.write(to: gbURL)
        let gbMdView = MarkdownRichPreviewView(initialMarkdown: gbText, fileURL: gbURL, fileName: "gb18030_中文.md")
        XCTAssertEqual(gbMdView.sourceEncoding, .gb18030)
        XCTAssertEqual(gbMdView.displayedByteCount, Int64(gbBytes.count))
        XCTAssertFalse(gbMdView.canSaveInPlace)
        XCTAssertFalse(gbMdView.saveFile(contentOverride: "# Overwrite"))
        XCTAssertEqual(try Data(contentsOf: gbURL), gbBytes)
    }

    func testP3BHexOffsetRangeAndCopyFormattingContracts() {
        let sample = Data((0..<64).map { UInt8($0) })
        XCTAssertEqual(HexDataFormattingHelper.parseOffset(from: "0x20", maxFileSize: 64), 32)
        XCTAssertEqual(HexDataFormattingHelper.parseOffset(from: "1A", maxFileSize: 64), 26)
        XCTAssertEqual(HexDataFormattingHelper.parseOffset(from: "999", maxFileSize: 64), 63)
        XCTAssertEqual(HexDataFormattingHelper.formatOffsetRange(start: 0, end: 64, compact: false), "0x00000000 – 0x0000003F")
        XCTAssertEqual(HexDataFormattingHelper.formatHexBytes(Data([0x00, 0x0A, 0xFF])), "00 0A FF")
        XCTAssertEqual(HexDataFormattingHelper.formatContinuousHex(Data([0x00, 0x0A, 0xFF])), "000AFF")
        XCTAssertEqual(HexDataFormattingHelper.formatASCIIString(Data([0x41, 0x42, 0x00, 0x7E])), "AB.~")
        XCTAssertTrue(HexDataFormattingHelper.formatCArray(Data([0x01, 0xFF])).contains("0x01, 0xFF"))
        let fullDump = HexDataFormattingHelper.formatFullDumpTable(sample, startOffset: 0x100)
        XCTAssertTrue(fullDump.contains("00000100") && fullDump.contains("00000130"))
    }
}


