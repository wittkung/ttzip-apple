// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
@testable import TTMediaKit

final class TTMediaFormatDetectionAndRoutingTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TTMediaFormatRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TTMediaDetector.purgeAllEphemeralMediaFiles()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Capability Matrix Disambiguation (.ts and .dat)

    func testCapabilityMatrixExcludesAmbiguousTSAndDATFromUnconditionalVideo() {
        XCTAssertFalse(TTMediaCapabilityMatrix.isVideo("ts"))
        XCTAssertFalse(TTMediaCapabilityMatrix.isVideo("sample.ts"))
        XCTAssertFalse(TTMediaCapabilityMatrix.isVideo("dat"))
        XCTAssertFalse(TTMediaCapabilityMatrix.isVideo("sample.dat"))

        XCTAssertTrue(TTMediaCapabilityMatrix.isAmbiguous("ts"))
        XCTAssertTrue(TTMediaCapabilityMatrix.isAmbiguous("dat"))
        XCTAssertFalse(TTMediaCapabilityMatrix.isAmbiguous("mp4"))

        let tsDesc = TTMediaCapabilityMatrix.descriptor(for: "sample.ts")
        XCTAssertNotNil(tsDesc)
        XCTAssertEqual(tsDesc?.primaryMode, .sourceCode)
        XCTAssertTrue(tsDesc?.capabilities.contains(.sourceCode) == true)
        XCTAssertTrue(tsDesc?.capabilities.contains(.mediaPlayback) == true)
        XCTAssertEqual(tsDesc?.isEditableSource, true)

        let datDesc = TTMediaCapabilityMatrix.descriptor(for: "sample.dat")
        XCTAssertNotNil(datDesc)
        XCTAssertEqual(datDesc?.primaryMode, .hexBinary)
        XCTAssertEqual(datDesc?.capabilities, [.hexBinary])
        XCTAssertEqual(datDesc?.iconName, "memorychip.fill")

        let resolvedTSCode = TTMediaCapabilityMatrix.resolveDescriptor(
            for: "module.ts",
            magic: .unknown,
            isBinaryContent: false
        )
        XCTAssertEqual(resolvedTSCode, TTMediaCapabilityMatrix.typeScriptSourceDescriptor)

        let resolvedTSVideo = TTMediaCapabilityMatrix.resolveDescriptor(
            for: "stream.ts",
            magic: .video(mime: "video/mp2t"),
            isBinaryContent: true
        )
        XCTAssertEqual(resolvedTSVideo, TTMediaCapabilityMatrix.mpegTSVideoDescriptor)

        let resolvedTSBinary = TTMediaCapabilityMatrix.resolveDescriptor(
            for: "corrupt.ts",
            magic: .unknown,
            isBinaryContent: true
        )
        XCTAssertEqual(resolvedTSBinary?.primaryMode, .hexBinary)
    }

    // MARK: - 2. TypeScript vs MPEG-TS Disambiguation Across All 3 Entry Points

    func testTypeScriptSourceRoutesToTextAndNeverVideoAcrossAllEntryPoints() async throws {
        let tsSamples: [(name: String, source: String)] = [
            (
                "service.ts",
                """
                // Copyright 2026 MetastudyLine. All rights reserved.
                export interface MediaRouteConfig {
                    readonly probeBudgetBytes: number;
                    readonly allowBlindPlayerLaunch: boolean;
                }
                export function createDefaultConfig(): MediaRouteConfig {
                    return { probeBudgetBytes: 8192, allowBlindPlayerLaunch: false };
                }
                """
            ),
            (
                "short.ts",
                "const x = 1;"
            ),
            (
                "single_char.ts",
                "x"
            )
        ]

        for sample in tsSamples {
            let data = Data(sample.source.utf8)
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: data,
                fileName: sample.name
            )
            guard case .text(let decoded) = result else {
                XCTFail("Expected .text for TypeScript file \(sample.name), got \(result)")
                continue
            }
            XCTAssertEqual(decoded, sample.source)

            let fileURL = tempDir.appendingPathComponent("fast_\(sample.name)")
            try data.write(to: fileURL, options: .atomic)
            let fastResult = TTMediaDetector.fastTypeByExtension(url: fileURL)
            if case .video = fastResult {
                XCTFail("fastTypeByExtension must never blindly route TypeScript \(sample.name) to .video")
            }
        }
    }

    func testTypeScriptWithGByteAt188StrideOffsetsStillRoutesToText() async throws {
        // Construct valid UTF-8 TypeScript where 'G' (0x47) appears at offsets 0, 188, and 376.
        var builder = Data()
        let segment = "G" + String(repeating: "a", count: 185) + ";\n"
        XCTAssertEqual(segment.utf8.count, 188)
        builder.append(contentsOf: segment.utf8)
        builder.append(contentsOf: segment.utf8)
        builder.append(contentsOf: segment.utf8)
        XCTAssertEqual(builder[0], 0x47)
        XCTAssertEqual(builder[188], 0x47)
        XCTAssertEqual(builder[376], 0x47)

        XCTAssertEqual(TTMediaDetector.probeMagicBytes(data: builder), .unknown)

        let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
            data: builder,
            fileName: "adversarial_g_stride.ts"
        )
        guard case .text(let text) = result else {
            XCTFail("TypeScript with 'G' at 188-byte stride must route to .text, got \(result)")
            return
        }
        XCTAssertEqual(text.utf8.count, 188 * 3)
    }

    func testMPEGTransportStreamVariantsRouteToVideoAcrossAllEntryPoints() async throws {
        // 1. Standard 188-byte MPEG-TS stride (3 packets)
        var ts188 = Data(repeating: 0xFF, count: 188 * 3)
        for packetIndex in 0..<3 {
            let base = packetIndex * 188
            ts188[base] = 0x47
            ts188[base + 1] = 0x40
            ts188[base + 2] = 0x00
            ts188[base + 3] = 0x10 | UInt8(packetIndex)
            ts188[base + 4] = 0x00
        }

        // 2. BDAV 192-byte M2TS stride (4-byte timecode + 188-byte packet)
        var m2ts192 = Data(repeating: 0xFF, count: 192 * 3)
        for packetIndex in 0..<3 {
            let base = packetIndex * 192
            m2ts192[base] = 0x0E
            m2ts192[base + 1] = 0xBF
            m2ts192[base + 2] = 0x46
            m2ts192[base + 3] = UInt8(packetIndex)
            m2ts192[base + 4] = 0x47
            m2ts192[base + 5] = 0x40
            m2ts192[base + 6] = 0x11
            m2ts192[base + 7] = 0x10
            m2ts192[base + 8] = 0x00
        }

        // 3. Canonical PAT header stream
        var patStream = Data([0x47, 0x40, 0x00, 0x10, 0x00, 0x00, 0xB0, 0x0D])
        patStream.append(Data(repeating: 0x00, count: 512))

        let variants: [(name: String, data: Data)] = [
            ("broadcast_188.ts", ts188),
            ("bluray_192.ts", m2ts192),
            ("bluray_192.m2ts", m2ts192),
            ("pat_stream.ts", patStream)
        ]

        for variant in variants {
            XCTAssertEqual(
                TTMediaDetector.probeMagicBytes(data: variant.data),
                .video(mime: "video/mp2t"),
                "Expected video/mp2t magic for \(variant.name)"
            )
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: variant.data,
                fileName: variant.name
            )
            guard case .video = result else {
                XCTFail("Expected .video for MPEG-TS \(variant.name), got \(result)")
                continue
            }
        }
    }

    // MARK: - 3. Ordinary Binary .dat vs Media .dat Across All 3 Entry Points

    func testOrdinaryBinaryDATRoutesToHexViewerAndNeverVideo() async throws {
        var sequentialBinary = Data( capacity: 256)
        for byte in 0..<256 {
            sequentialBinary.append(UInt8(byte))
        }

        let ordinaryPayloads: [(name: String, data: Data)] = [
            ("sequential.dat", sequentialBinary),
            ("record_table.dat", Data([0x00, 0xFF, 0x10, 0x20, 0x30, 0x40, 0x00, 0x80, 0xDE, 0xAD, 0xBE, 0xEF])),
            ("short_binary.dat", Data([0x00, 0x01, 0x02])),
            ("wasm_module.dat", Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])),
            ("config_plain.dat", Data("version=1\nmode=production\n".utf8))
        ]

        for item in ordinaryPayloads {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: item.data,
                fileName: item.name
            )
            guard case .hexViewer(let sample, _) = result else {
                XCTFail("Ordinary .dat (\(item.name)) must route to .hexViewer, got \(result)")
                continue
            }
            XCTAssertEqual(sample, item.data)

            let fileURL = tempDir.appendingPathComponent("fast_\(item.name)")
            try item.data.write(to: fileURL, options: .atomic)
            let fastResult = TTMediaDetector.fastTypeByExtension(url: fileURL)
            if case .video = fastResult {
                XCTFail("fastTypeByExtension must never route ordinary .dat (\(item.name)) to .video")
            }
        }
    }

    /// Synthetic branch routing test: verifies detector branch paths using minimal valid container + track headers.
    /// Does not claim full stream playability (which is covered separately by real corpus fixtures).
    func testMediaDATWithSufficientContentEvidenceRoutesToMediaBranchLogic() async throws {
        var mpegPSDat = Data([0x00, 0x00, 0x01, 0xBA, 0x21, 0x00, 0x01, 0x00, 0x01, 0x80, 0x00, 0x01, 0x00, 0x00, 0x01, 0xBB])
        mpegPSDat.append(Data(repeating: 0x00, count: 128))

        var vcdCDXADat = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x08, 0x00, 0x00, 0x43, 0x44, 0x58, 0x41])
        vcdCDXADat.append(Data(repeating: 0x00, count: 128))

        let mp4VideoDat = makeSyntheticISOBMFFWithHandler(brand: "isom", handlerType: "vide")

        var mkvVideoDat = Data([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x83, 0x81, 0x01])
        mkvVideoDat.append(Data(repeating: 0x00, count: 64))

        for (name, payload) in [
            ("vcd_mpeg_ps.dat", mpegPSDat),
            ("vcd_riff_cdxa.dat", vcdCDXADat),
            ("mp4_video_stream.dat", mp4VideoDat),
            ("mkv_video_stream.dat", mkvVideoDat)
        ] {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(data: payload, fileName: name)
            guard case .video = result else {
                XCTFail("Media .dat (\(name)) with video track evidence must route to .video, got \(result)")
                continue
            }
        }

        var wavDat = Data([0x52, 0x49, 0x46, 0x46, 0x24, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45])
        wavDat.append(Data(repeating: 0x00, count: 32))
        var mp3Dat = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10])
        mp3Dat.append(Data(repeating: 0x00, count: 32))
        let m4aIsomAudioDat = makeSyntheticISOBMFFWithHandler(brand: "isom", handlerType: "soun")

        for (name, audioData) in [
            ("audio_wave.dat", wavDat),
            ("audio_id3.dat", mp3Dat),
            ("audio_isom.dat", m4aIsomAudioDat)
        ] {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(data: audioData, fileName: name)
            guard case .audio = result else {
                XCTFail("Media .dat (\(name)) with audio track evidence must route to .audio, got \(result)")
                continue
            }
        }
    }

    // MARK: - 4. Shared Container Track Probing (ISOBMFF, Matroska, Ogg, ASF, RealMedia)

    func testSharedContainerISOBMFFAudioOnlyVsVideoTrackProbing() async throws {
        // 1. Bare `ftyp isom` without `moov` track descriptors must NOT default to video.
        var bareIsom = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        bareIsom.append(Data(repeating: 0x00, count: 64))
        XCTAssertEqual(TTMediaDetector.probeMagicBytes(data: bareIsom), .unknown)
        for bareName in ["bare_isom.mp4", "bare_isom.m4a", "bare_isom.dat"] {
            let bareRoute = try await assertConsistentRoutingAcrossThreeEntryPoints(data: bareIsom, fileName: bareName)
            guard case .hexViewer = bareRoute else {
                XCTFail("Bare ftyp isom without tracks (\(bareName)) must degrade to .hexViewer, got \(bareRoute)")
                continue
            }
        }

        // 2. Faststart `ftyp isom` audio-only payload (matching reviewer's 865-byte audio-only.m4a layout:
        //    ftyp(isom) -> free -> mdat -> moov(trak -> mdia -> hdlr(soun) + smhd)) must route to .audio.
        let faststartIsomAudio = makeFaststartIsomAudioOnlyM4APayload()
        XCTAssertEqual(TTMediaDetector.probeMagicBytes(data: faststartIsomAudio), .audio(mime: "audio/mp4"))
        for name in ["audio-only.m4a", "audio-only.mp4", "audio-only.mov", "audio-only.dat"] {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(data: faststartIsomAudio, fileName: name)
            guard case .audio = result else {
                XCTFail("Audio-only ftyp isom (\(name)) must route to .audio across all 3 entry points, got \(result)")
                continue
            }
            let diskURL = tempDir.appendingPathComponent("fast_\(name)")
            try faststartIsomAudio.write(to: diskURL, options: .atomic)
            guard case .audio = TTMediaDetector.fastTypeByExtension(url: diskURL) else {
                XCTFail("fastTypeByExtension must route audio-only ftyp isom (\(name)) to .audio")
                continue
            }
        }

        // 3. Always verify the complete owned audio container; no historical tmp branch.
        let managedRoot = try XCTUnwrap(locatePreviewFixturesRoot(), "Required preview corpus is missing")
        let managedSampleURL = managedRoot.appendingPathComponent("audio/tone.m4a")
        let managedData = try Data(contentsOf: managedSampleURL)
        let managedRoute = try await assertConsistentRoutingAcrossThreeEntryPoints(
            data: managedData,
            fileName: "owned_audio_only.m4a"
        )
        if case .audio = managedRoute {} else {
            XCTFail("Owned audio-only.m4a must route to .audio, got \(managedRoute)")
        }
    }

    func testRealPreviewCorpusSharedContainersAndDisguisedExtensions() async throws {
        guard let fixturesRoot = locatePreviewFixturesRoot() else {
            XCTFail("Preview corpus fixtures directory not found")
            return
        }

        // Real audio-only M4A with non-faststart mdat-before-moov patched to major_brand = isom
        let toneM4AURL = fixturesRoot.appendingPathComponent("audio/tone.m4a")
        var nonFaststartIsomAudio = try Data(contentsOf: toneM4AURL)
        nonFaststartIsomAudio.replaceSubrange(8..<12, with: Data("isom".utf8))
        for disguised in ["nonfast_isom.m4a", "nonfast_isom.mp4", "nonfast_isom.mov", "nonfast_isom.dat"] {
            let route = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: nonFaststartIsomAudio,
                fileName: disguised
            )
            guard case .audio = route else {
                XCTFail("Real non-faststart ftyp isom audio (\(disguised)) must route to .audio, got \(route)")
                continue
            }
        }

        let audioFixtures = [
            "audio/tone.m4a", "audio/tone.m4b", "audio/tone.m4r",
            "audio/tone.wma", "audio/tone.ra", "audio/tone.ogg", "audio/tone.opus",
            "audio/tone.mp3", "audio/tone.wav", "audio/tone.flac"
        ]
        for relPath in audioFixtures {
            let url = fixturesRoot.appendingPathComponent(relPath)
            let data = try Data(contentsOf: url)
            for testName in [url.lastPathComponent, "disguised_\(url.deletingPathExtension().lastPathComponent).mp4"] {
                let route = try await assertConsistentRoutingAcrossThreeEntryPoints(data: data, fileName: testName)
                guard case .audio = route else {
                    XCTFail("Real audio fixture \(relPath) as \(testName) must route to .audio, got \(route)")
                    continue
                }
            }
        }

        let videoFixtures = [
            "video/clip.mp4", "video/clip.m4v", "video/clip.mov", "video/clip.3gp",
            "video/clip.mkv", "video/clip.webm", "video/clip.wmv", "video/clip.asf",
            "video/clip.rm", "video/clip.mpg", "video/clip.ts", "video/clip.m2ts", "video/clip.dat"
        ]
        for relPath in videoFixtures {
            let url = fixturesRoot.appendingPathComponent(relPath)
            let data = try Data(contentsOf: url)
            for testName in [url.lastPathComponent, "disguised_\(url.deletingPathExtension().lastPathComponent).m4a"] {
                let route = try await assertConsistentRoutingAcrossThreeEntryPoints(data: data, fileName: testName)
                guard case .video = route else {
                    XCTFail("Real video fixture \(relPath) as \(testName) must route to .video, got \(route)")
                    continue
                }
            }
        }
        var oggTheora = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02])
        oggTheora.append(Data(repeating: 0x00, count: 22))
        oggTheora.append(Data([0x80, 0x74, 0x68, 0x65, 0x6F, 0x72, 0x61]))
        oggTheora.append(Data(repeating: 0x00, count: 32))
        for testName in ["clip.ogv", "disguised_ogv.ogg", "disguised_ogv.m4a"] {
            let route = try await assertConsistentRoutingAcrossThreeEntryPoints(data: oggTheora, fileName: testName)
            if case .video = route {} else { XCTFail("Ogg Theora (\(testName)) must route to .video, got \(route)") }
        }
    }

    // MARK: - 5. Empty Files, Short Files & Truncated Headers

    func testEmptyFilesExplicitlyDegradeToUnsupportedAcrossAllEntryPoints() async throws {
        let extensions = ["ts", "dat", "mp4", "mp3", "mkv", "wav", "txt", "pdf", "png", "csv", "md", "html", "zip"]

        for ext in extensions {
            let fileName = "empty_file.\(ext)"
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: Data(),
                fileName: fileName
            )
            guard case .unsupported = result else {
                XCTFail("Empty file \(fileName) must degrade to .unsupported, got \(result)")
                continue
            }

            let fileURL = tempDir.appendingPathComponent("fast_\(fileName)")
            try Data().write(to: fileURL, options: .atomic)
            let fastResult = TTMediaDetector.fastTypeByExtension(url: fileURL)
            guard case .unsupported = fastResult else {
                XCTFail("fastTypeByExtension on empty file \(fileName) must return .unsupported, got \(fastResult)")
                continue
            }
        }
    }

    func testShortAndTruncatedBinaryFilesDegradeToHexViewerWithoutLaunchingPlayer() async throws {
        let truncatedCases: [(name: String, data: Data)] = [
            ("truncated_sync.ts", Data([0x47, 0x40, 0x00, 0x10])),
            ("two_byte_bin.ts", Data([0x00, 0x47])),
            ("truncated.mp4", Data([0x00, 0x00, 0x00])),
            ("truncated.mp3", Data([0xFF, 0xFE, 0x00])),
            ("three_byte.dat", Data([0x00, 0xAA, 0x55]))
        ]

        for item in truncatedCases {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: item.data,
                fileName: item.name
            )
            guard case .hexViewer(let bytes, _) = result else {
                XCTFail("Truncated binary \(item.name) must degrade to .hexViewer, got \(result)")
                continue
            }
            XCTAssertEqual(bytes, item.data)
        }
    }

    // MARK: - 6. Disguised Extensions & Unknown Content Degradation

    func testDisguisedExtensionsFollowContentEvidenceAndDegradeUnknownContent() async throws {
        let plainText = "Plain text note disguised with a media or document extension.\n"
        let textData = Data(plainText.utf8)
        for disguisedName in ["fake_video.mp4", "fake_audio.mp3", "fake_mkv.mkv", "fake_doc.pdf", "fake_img.png"] {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: textData,
                fileName: disguisedName
            )
            guard case .text(let decoded) = result else {
                XCTFail("Plain text in \(disguisedName) must degrade to .text, got \(result)")
                continue
            }
            XCTAssertEqual(decoded, plainText)
        }

        let unknownBinary = Data([0x00, 0x89, 0x13, 0x37, 0x00, 0xFA, 0xCE, 0x00, 0x11, 0x22, 0x33, 0x44])
        for disguisedName in ["unknown.mp4", "unknown.mp3", "unknown.ts", "unknown.txt", "unknown.csv", "unknown.md"] {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: unknownBinary,
                fileName: disguisedName
            )
            guard case .hexViewer(let sample, _) = result else {
                XCTFail("Unknown binary in \(disguisedName) must degrade to .hexViewer, got \(result)")
                continue
            }
            XCTAssertEqual(sample, unknownBinary)
        }

        let pdfBytes = Data("%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n".utf8)
        for disguisedName in ["report.mp4", "report.ts", "report.dat"] {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: pdfBytes,
                fileName: disguisedName
            )
            switch result {
            case .pdf, .pdfData:
                break
            default:
                XCTFail("PDF payload in \(disguisedName) must route to .pdf/.pdfData, got \(result)")
            }
        }

        let mp4Bytes = makeSyntheticISOBMFFWithHandler(brand: "mp42", handlerType: "vide")
        for disguisedName in ["disguised_video.txt", "disguised_video.bin", "disguised_video.mp3"] {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: mp4Bytes,
                fileName: disguisedName
            )
            guard case .video = result else {
                XCTFail("MP4 video payload in \(disguisedName) must route to .video, got \(result)")
                continue
            }
        }

        let m4aBytes = makeSyntheticISOBMFFWithHandler(brand: "M4A ", handlerType: "soun")
        for disguisedName in ["voice_track.m4a", "voice_track.mp4", "voice_track.dat"] {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: m4aBytes,
                fileName: disguisedName
            )
            guard case .audio = result else {
                XCTFail("M4A audio payload in \(disguisedName) must route to .audio, got \(result)")
                continue
            }
        }
    }

    // MARK: - 7. Content Probe Read Budget Enforcement

    func testContentProbeEnforcesReadBudgetAndRejectsSignaturesBeyondBudget() async throws {
        let budget = TTMediaDetector.contentProbeBudgetBytes
        XCTAssertEqual(budget, 8 * 1024)

        var beyondBudgetPayload = Data(repeating: 0x00, count: budget + 512)
        beyondBudgetPayload[0] = 0x00
        beyondBudgetPayload[1] = 0x11
        beyondBudgetPayload[2] = 0x22
        beyondBudgetPayload[3] = 0x33

        let lateOffset = budget + 64
        let lateMP4Header: [UInt8] = [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]
        beyondBudgetPayload.replaceSubrange(lateOffset..<(lateOffset + lateMP4Header.count), with: lateMP4Header)

        XCTAssertEqual(TTMediaDetector.probeMagicBytes(data: beyondBudgetPayload), .unknown)

        for fileName in ["late_sig.mp4", "late_sig.ts", "late_sig.dat"] {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: beyondBudgetPayload,
                fileName: fileName
            )
            guard case .hexViewer = result else {
                XCTFail("File \(fileName) with signature past \(budget)-byte budget must degrade to .hexViewer, got \(result)")
                continue
            }
        }
    }

    // MARK: - 8. Real Preview Corpus Fixture Verification (.ts and .dat)

    func testRealPreviewCorpusFixturesForTSAndDAT() async throws {
        guard let fixturesRoot = locatePreviewFixturesRoot() else {
            XCTFail("Preview corpus fixtures directory not found")
            return
        }

        let tsSourceURL = fixturesRoot.appendingPathComponent("text/sample.ts")
        let tsSourceData = try Data(contentsOf: tsSourceURL)
        let tsTextResult = try await assertConsistentRoutingAcrossThreeEntryPoints(
            data: tsSourceData,
            fileName: "sample.ts"
        )
        guard case .text(let code) = tsTextResult else {
            XCTFail("Fixture text/sample.ts must route to .text, got \(tsTextResult)")
            return
        }
        XCTAssertTrue(code.contains("Copyright"))

        let tsVideoURL = fixturesRoot.appendingPathComponent("video/clip.ts")
        let tsVideoData = try Data(contentsOf: tsVideoURL)
        let tsVideoResult = try await assertConsistentRoutingAcrossThreeEntryPoints(
            data: tsVideoData,
            fileName: "clip.ts"
        )
        guard case .video = tsVideoResult else {
            XCTFail("Fixture video/clip.ts must route to .video, got \(tsVideoResult)")
            return
        }

        let binaryDatURL = fixturesRoot.appendingPathComponent("binary/sample.dat")
        let binaryDatData = try Data(contentsOf: binaryDatURL)
        let binaryDatResult = try await assertConsistentRoutingAcrossThreeEntryPoints(
            data: binaryDatData,
            fileName: "sample.dat"
        )
        guard case .hexViewer = binaryDatResult else {
            XCTFail("Fixture binary/sample.dat must route to .hexViewer, got \(binaryDatResult)")
            return
        }

        let videoDatURL = fixturesRoot.appendingPathComponent("video/clip.dat")
        let videoDatData = try Data(contentsOf: videoDatURL)
        let videoDatResult = try await assertConsistentRoutingAcrossThreeEntryPoints(
            data: videoDatData,
            fileName: "clip.dat"
        )
        guard case .video = videoDatResult else {
            XCTFail("Fixture video/clip.dat must route to .video, got \(videoDatResult)")
            return
        }
    }

    // MARK: - 10. Group E & Group C Cross-Group Integration Contracts

    func testMHTMLLaunchBoundaryAndEBookComicCapabilityWiring() async throws {
        let mhtmlMultipart = """
        From: <Saved by Blink>
        MIME-Version: 1.0
        Content-Type: multipart/related; boundary="----MultipartBoundary--xyz"

        ------MultipartBoundary--xyz
        Content-Type: text/html

        <html><body>Archived page</body></html>
        ------MultipartBoundary--xyz--
        """
        for ext in ["mhtml", "mht"] {
            let result = try await assertConsistentRoutingAcrossThreeEntryPoints(
                data: Data(mhtmlMultipart.utf8), fileName: "capture.\(ext)"
            )
            guard case .htmlWeb(let sourceText, _) = result else {
                XCTFail("Multipart .\(ext) must route to dual-mode HTML preview, got \(result)")
                return
            }
            XCTAssertTrue(sourceText.contains("multipart/related"))
        }

        XCTAssertTrue(TTMediaCapabilityMatrix.supportsFullTextEbookReading("book.epub"))
        for ext in ["mobi", "azw", "azw3", "fb2", "ibooks"] {
            XCTAssertTrue(TTMediaCapabilityMatrix.isInspectionOnlyEbook("novel.\(ext)"))
            XCTAssertEqual(TTMediaCapabilityMatrix.descriptor(for: "novel.\(ext)")?.primaryMode, .structuredData)
        }
        for ext in ["cbz", "cbr", "cb7"] {
            XCTAssertTrue(TTMediaCapabilityMatrix.isComicArchive("issue.\(ext)"))
            XCTAssertTrue(TTMediaCapabilityMatrix.isArchive("issue.\(ext)"))
            XCTAssertEqual(TTMediaCapabilityMatrix.descriptor(for: "issue.\(ext)")?.primaryMode, .archiveBrowse)
        }
    }

    // MARK: - Helpers

    private func makeSyntheticISOBMFFWithHandler(brand: String, handlerType: String) -> Data {
        var data = Data([0x00, 0x00, 0x00, 0x18])
        data.append(Data("ftyp".utf8))
        data.append(Data(brand.prefix(4).utf8))
        data.append(Data([0x00, 0x00, 0x02, 0x00]))
        data.append(Data("isommp41".utf8))

        // moov box (40 bytes) containing hdlr box (32 bytes)
        data.append(Data([0x00, 0x00, 0x00, 0x28]))
        data.append(Data("moov".utf8))
        data.append(Data([0x00, 0x00, 0x00, 0x20]))
        data.append(Data("hdlr".utf8))
        data.append(Data(repeating: 0x00, count: 8))
        data.append(Data(handlerType.prefix(4).utf8))
        data.append(Data(repeating: 0x00, count: 12))
        return data
    }

    private func makeFaststartIsomAudioOnlyM4APayload() -> Data {
        var data = Data([
            0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70,
            0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x02, 0x00,
            0x69, 0x73, 0x6F, 0x6D, 0x69, 0x73, 0x6F, 0x32,
            0x6D, 0x70, 0x34, 0x31
        ])
        // free box (8 bytes) + mdat box (38 bytes)
        data.append(Data([0x00, 0x00, 0x00, 0x08, 0x66, 0x72, 0x65, 0x65]))
        data.append(Data([0x00, 0x00, 0x00, 0x26, 0x6D, 0x64, 0x61, 0x74]))
        data.append(Data(repeating: 0x21, count: 30))
        // moov box (56 bytes) with hdlr(soun) + smhd
        data.append(Data([0x00, 0x00, 0x00, 0x38, 0x6D, 0x6F, 0x6F, 0x76]))
        data.append(Data([0x00, 0x00, 0x00, 0x20, 0x68, 0x64, 0x6C, 0x72]))
        data.append(Data(repeating: 0x00, count: 8))
        data.append(Data("soun".utf8))
        data.append(Data(repeating: 0x00, count: 12))
        data.append(Data([0x00, 0x00, 0x00, 0x10, 0x73, 0x6D, 0x68, 0x64]))
        data.append(Data(repeating: 0x00, count: 8))
        return data
    }

    func testCorruptedISOBMFFNonZeroOffsetNearUInt64MaxDoesNotOverflowAcrossEntries() async throws {
        var ftyp = Data([0x00, 0x00, 0x00, 0x18])
        ftyp.append(contentsOf: "ftypisom".utf8)
        ftyp.append(contentsOf: [0x00, 0x00, 0x02, 0x00])
        ftyp.append(contentsOf: "isommp42".utf8)

        var badExtendedBox = Data([0x00, 0x00, 0x00, 0x01])
        badExtendedBox.append(contentsOf: "mdat".utf8)
        var nearMax = (UInt64.max - 7).bigEndian
        withUnsafeBytes(of: &nearMax) { badExtendedBox.append(contentsOf: $0) }
        badExtendedBox.append(Data(repeating: 0xAA, count: 24))

        let inlineCorrupted = ftyp + badExtendedBox
        let inlineRoute = try await assertConsistentRoutingAcrossThreeEntryPoints(
            data: inlineCorrupted,
            fileName: "overflow_inline.mp4"
        )
        guard case .hexViewer = inlineRoute else {
            return XCTFail("Expected corrupted inline ISO BMFF with size64 near UInt64.max to degrade to .hexViewer, got \(inlineRoute)")
        }

        var freeBox = Data([0x00, 0x00, 0x20, 0x08]) // 8,200 bytes (> 8 KiB probe window)
        freeBox.append(contentsOf: "free".utf8)
        freeBox.append(Data(repeating: 0x00, count: 8_192))
        let tailCorrupted = ftyp + freeBox + badExtendedBox
        let tailRoute = try await assertConsistentRoutingAcrossThreeEntryPoints(
            data: tailCorrupted,
            fileName: "overflow_tail.m4a"
        )
        guard case .hexViewer = tailRoute else {
            return XCTFail("Expected corrupted >8KiB ISO BMFF with size64 near UInt64.max to degrade to .hexViewer, got \(tailRoute)")
        }
    }

    private func assertConsistentRoutingAcrossThreeEntryPoints(
        data: Data,
        fileName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> TTMediaPreviewType {
        let fileURL = tempDir.appendingPathComponent("\(UUID().uuidString)_\(fileName)")
        try data.write(to: fileURL, options: .atomic)

        let syncResult = TTMediaDetector.detectType(url: fileURL)
        let asyncResult = await TTMediaDetector.detectTypeAsync(url: fileURL)
        let memoryResult = TTMediaDetector.detectTypeFromMemory(
            data: data,
            suggestedName: fileName,
            sourceURL: fileURL
        )
        defer {
            if case .video(let url) = memoryResult { TTMediaDetector.releaseEphemeralMediaFile(at: url) }
            if case .audio(let url) = memoryResult { TTMediaDetector.releaseEphemeralMediaFile(at: url) }
            if case .quickLook(let url) = memoryResult { TTMediaDetector.releaseEphemeralMediaFile(at: url) }
        }

        let syncKind = normalizedRouteCategory(syncResult)
        let asyncKind = normalizedRouteCategory(asyncResult)
        let memoryKind = normalizedRouteCategory(memoryResult)

        XCTAssertEqual(
            syncKind,
            asyncKind,
            "Sync (\(syncKind)) and Async (\(asyncKind)) routes diverged for \(fileName)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            syncKind,
            memoryKind,
            "Disk (\(syncKind)) and Memory (\(memoryKind)) routes diverged for \(fileName)",
            file: file,
            line: line
        )

        return syncResult
    }

    private func normalizedRouteCategory(_ preview: TTMediaPreviewType) -> String {
        switch preview {
        case .pluginView: return "pluginView"
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        case .pdf, .pdfData: return "pdf"
        case .text(let text): return "text:\(text.count)"
        case .docxDocument: return "docxDocument"
        case .epubBook: return "epubBook"
        case .ebook(let meta): return "ebook:\(meta.formatName)"
        case .hexViewer(let data, _): return "hexViewer:\(data.count)"
        case .markdown(let text, _): return "markdown:\(text.count)"
        case .htmlWeb(let content, _): return "htmlWeb:\(content.count)"
        case .spreadsheetTable(let text, _): return "spreadsheetTable:\(text.count)"
        case .officeSpreadsheet: return "officeSpreadsheet"
        case .officePresentation: return "officePresentation"
        case .quickLook: return "quickLook"
        case .unsupported: return "unsupported"
        }
    }

    private func locatePreviewFixturesRoot() -> URL? {
        if let testSrcDir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] {
            let runfilesCandidates = [
                URL(fileURLWithPath: testSrcDir).appendingPathComponent("_main/infra/ttmedia/Tests/Fixtures/preview"),
                URL(fileURLWithPath: testSrcDir).appendingPathComponent("infra/ttmedia/Tests/Fixtures/preview")
            ]
            for candidate in runfilesCandidates where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = current.appendingPathComponent("Tests/Fixtures/preview")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let directCandidate = current.appendingPathComponent("Fixtures/preview")
            if FileManager.default.fileExists(atPath: directCandidate.path) { return directCandidate }
            current.deleteLastPathComponent()
        }
        return nil
    }
}
