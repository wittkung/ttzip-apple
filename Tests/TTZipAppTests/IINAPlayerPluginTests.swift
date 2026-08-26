// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import TTZipCore
import TTZipPluginKit
@testable import TTZipApp

final class IINAPlayerPluginTests: XCTestCase {
    
    // MARK: - 1. Plugin Lifecycle & Manifest Verification
    
    @MainActor
    func testPluginManifestAndLifecycle() async throws {
        let plugin = IINAPlayerPlugin.shared
        let manifest = plugin.manifest
        
        XCTAssertEqual(manifest.id, "com.metastudyline.ttzip.plugin.iinaplayer")
        XCTAssertEqual(manifest.name, "IINAPlayer")
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.author, "MetaStudyLine & TTZip Team")
        XCTAssertTrue(manifest.permissions.contains(.fileSystemRead))
        XCTAssertTrue(manifest.permissions.contains(.archiveEngine))
        
        let hostContext = TTZipHostContextImpl.shared
        try await plugin.onInitialize(context: hostContext)
        XCTAssertTrue(plugin.isInitialized)
        
        XCTAssertFalse(plugin.previewProviders.isEmpty)
        XCTAssertEqual(plugin.sidebarItem?.id, "iinaplayer.sidebar")
        XCTAssertEqual(plugin.sidebarItem?.badgeText, "HDR")
        XCTAssertFalse(plugin.omnibarCommands.isEmpty)
        XCTAssertFalse(plugin.contextMenuActions.isEmpty)
        
        let workspaceView = plugin.makeWorkspaceView(tabIdentifier: "iinaplayer.workspace")
        XCTAssertNotNil(workspaceView)
        
        let testVideoURL = URL(fileURLWithPath: "/tmp/test.mkv")
        let inspectorView = plugin.makeInspectorView(selectedContext: testVideoURL)
        XCTAssertNotNil(inspectorView)
        
        await plugin.onTerminate()
        XCTAssertFalse(plugin.isInitialized)
    }
    
    // MARK: - 2. Preview Provider Format Interception
    
    @MainActor
    func testPreviewProviderFormatInterception() {
        let provider = IINAPreviewProvider.shared
        let videoExtensions = [
            "mkv", "avi", "webm", "flv", "ts", "m2ts", "wmv", "rmvb", "vob",
            "mp4", "mov", "m4v", "qt", "ogv", "3gp", "divx", "asf"
        ]
        
        for ext in videoExtensions {
            XCTAssertTrue(provider.supportedExtensions.contains(ext))
            let fileURL = URL(fileURLWithPath: "/tmp/sample_video.\(ext)")
            XCTAssertTrue(provider.canPreview(fileURL: fileURL))
        }
        
        let nonVideoFiles = ["document.pdf", "archive.zip", "picture.png", "source.swift"]
        for nonVideo in nonVideoFiles {
            let url = URL(fileURLWithPath: "/tmp/\(nonVideo)")
            XCTAssertFalse(provider.canPreview(fileURL: url))
        }
        
        let virtualStreamURL = URL(string: "ttzip:///Users/test/archive.zip?entry=nested_movie.mkv")!
        XCTAssertTrue(provider.canPreview(fileURL: virtualStreamURL))
        
        let previewView = provider.makePreviewView(fileURL: URL(fileURLWithPath: "/tmp/movie.mkv"))
        XCTAssertNotNil(previewView)
    }
    
    // MARK: - 3. Rust ASS Subtitle AST Parsing & Timeline Query
    
    @MainActor
    func testRustSubtitleASTParsingAndTimelineQuery() throws {
        let assContent = """
        [Script Info]
        Title: Anime Episode 01
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1
        
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:04.50,Default,,0,0,0,,{\\b1}Welcome{\\b0} to {\\i1}TTZip{\\i0} {\\c&H0000FF&}Player!
        Dialogue: 0,0:00:05.00,0:00:08.00,Default,,0,0,0,,Seamless 16-bit Float Metal HDR Output
        """
        
        let script = try parseSubtitleScript(content: assContent, formatName: "ass")
        XCTAssertEqual(script.title, "Anime Episode 01")
        XCTAssertEqual(script.dialogues.count, 2)
        
        let d1 = script.dialogues[0]
        XCTAssertEqual(d1.startMs, 1000)
        XCTAssertEqual(d1.endMs, 4500)
        XCTAssertFalse(d1.spans.isEmpty)
        
        // Query active subtitles at timestamp 2500ms
        let activeAt2500 = findActiveSubtitlesAt(script: script, timestampMs: 2500)
        XCTAssertEqual(activeAt2500.count, 1)
        XCTAssertTrue(activeAt2500[0].plainText.contains("Welcome to TTZip Player!"))
        
        // Query active subtitles at timestamp 6000ms
        let activeAt6000 = findActiveSubtitlesAt(script: script, timestampMs: 6000)
        XCTAssertEqual(activeAt6000.count, 1)
        XCTAssertTrue(activeAt6000[0].plainText.contains("Metal HDR"))
        
        // Out of bounds query at 12000ms
        let activeAt12000 = findActiveSubtitlesAt(script: script, timestampMs: 12000)
        XCTAssertTrue(activeAt12000.isEmpty)
    }
    
    // MARK: - 4. IINARichSubtitleView AttributedString Formatting
    
    @MainActor
    func testRichSubtitleViewAttributedString() {
        let span1 = UniFFISubtitleSpan(
            text: "HDR ",
            bold: true,
            italic: false,
            underline: false,
            strikeout: false,
            primaryColor: UniFFISubtitleColor(r: 255, g: 200, b: 0, a: 255),
            secondaryColor: nil,
            outlineColor: nil,
            shadowColor: nil,
            fontName: "Helvetica",
            fontSize: 24.0,
            position: nil,
            alignment: .bottomCenter
        )
        let span2 = UniFFISubtitleSpan(
            text: "Active",
            bold: false,
            italic: true,
            underline: true,
            strikeout: false,
            primaryColor: UniFFISubtitleColor(r: 0, g: 255, b: 255, a: 255),
            secondaryColor: nil,
            outlineColor: nil,
            shadowColor: nil,
            fontName: "Helvetica",
            fontSize: 24.0,
            position: nil,
            alignment: .bottomCenter
        )
        
        let attr = IINARichSubtitleView.renderAttributedString(spans: [span1, span2], plainText: "HDR Active")
        let plain = String(attr.characters)
        XCTAssertEqual(plain, "HDR Active")
        
        // Alignment Mapping Test
        XCTAssertEqual(UniFFISubtitleAlignment.bottomCenter.swiftUITextAlignment, .center)
        XCTAssertEqual(UniFFISubtitleAlignment.topLeft.swiftUITextAlignment, .leading)
        XCTAssertEqual(UniFFISubtitleAlignment.bottomRight.swiftUITextAlignment, .trailing)
    }
    
    // MARK: - 5. Rust Container Demuxing & Track/Chapter Extraction
    
    @MainActor
    func testRustContainerDemuxing() throws {
        func ebmlBox(id: UInt32, data: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            if id > 0x00FF_FFFF { out.append(contentsOf: withUnsafeBytes(of: id.bigEndian) { Array($0) }) }
            else if id > 0xFFFF { out.append(contentsOf: withUnsafeBytes(of: id.bigEndian) { Array($0)[1...] }) }
            else if id > 0xFF { out.append(contentsOf: withUnsafeBytes(of: id.bigEndian) { Array($0)[2...] }) }
            else { out.append(UInt8(id)) }
            let sz = data.count
            if sz < 0x7F { out.append(0x80 | UInt8(sz)) }
            else { out.append(0x40 | UInt8((sz >> 8) & 0xFF)); out.append(UInt8(sz & 0xFF)) }
            out.append(contentsOf: data)
            return out
        }
        func ebmlStr(id: UInt32, s: String) -> [UInt8] { ebmlBox(id: id, data: Array(s.utf8)) }
        func ebmlUint(id: UInt32, val: UInt64, byteCount: Int) -> [UInt8] {
            let be = withUnsafeBytes(of: val.bigEndian) { Array($0) }
            return ebmlBox(id: id, data: Array(be[(8 - byteCount)...]))
        }
        
        let ebmlHdr = ebmlBox(id: 0x1A45_DFA3, data: ebmlStr(id: 0x4282, s: "matroska"))
        
        var vSub: [UInt8] = []
        vSub.append(contentsOf: ebmlUint(id: 0xB0, val: 3840, byteCount: 2))
        vSub.append(contentsOf: ebmlUint(id: 0xBA, val: 2160, byteCount: 2))
        var vTrack: [UInt8] = []
        vTrack.append(contentsOf: ebmlUint(id: 0xD7, val: 1, byteCount: 1))
        vTrack.append(contentsOf: ebmlUint(id: 0x83, val: 1, byteCount: 1))
        vTrack.append(contentsOf: ebmlStr(id: 0x86, s: "V_MPEGH/ISO/HEVC"))
        vTrack.append(contentsOf: ebmlBox(id: 0xE0, data: vSub))
        let t1 = ebmlBox(id: 0xAE, data: vTrack)
        
        var aTrack: [UInt8] = []
        aTrack.append(contentsOf: ebmlUint(id: 0xD7, val: 2, byteCount: 1))
        aTrack.append(contentsOf: ebmlUint(id: 0x83, val: 2, byteCount: 1))
        aTrack.append(contentsOf: ebmlStr(id: 0x86, s: "A_OPUS"))
        aTrack.append(contentsOf: ebmlStr(id: 0x22B5_9C, s: "jpn"))
        let t2 = ebmlBox(id: 0xAE, data: aTrack)
        
        var trkList: [UInt8] = []
        trkList.append(contentsOf: t1)
        trkList.append(contentsOf: t2)
        let tracks = ebmlBox(id: 0x1654_AE6B, data: trkList)
        
        var c1: [UInt8] = []
        c1.append(contentsOf: ebmlUint(id: 0x91, val: 0, byteCount: 1))
        c1.append(contentsOf: ebmlBox(id: 0x80, data: ebmlStr(id: 0x85, s: "Intro")))
        let chaps = ebmlBox(id: 0x1043_A770, data: ebmlBox(id: 0x45B9, data: ebmlBox(id: 0xB6, data: c1)))
        
        var seg: [UInt8] = []
        seg.append(contentsOf: tracks)
        seg.append(contentsOf: chaps)
        
        var mkvData = ebmlHdr
        mkvData.append(contentsOf: ebmlBox(id: 0x1853_8067, data: seg))
        
        let demuxSummary = try demuxMediaTracks(data: Data(mkvData))
        XCTAssertEqual(demuxSummary.containerFormat, "matroska")
        XCTAssertEqual(demuxSummary.tracks.count, 2)
        
        let videoTrack = demuxSummary.tracks.first { $0.trackType == .video }
        XCTAssertNotNil(videoTrack)
        XCTAssertEqual(videoTrack?.codec, "V_MPEGH/ISO/HEVC")
        XCTAssertEqual(videoTrack?.width, 3840)
        XCTAssertEqual(videoTrack?.height, 2160)
        
        let audioTrack = demuxSummary.tracks.first { $0.trackType == .audio }
        XCTAssertNotNil(audioTrack)
        XCTAssertEqual(audioTrack?.codec, "A_OPUS")
        XCTAssertEqual(audioTrack?.language, "jpn")
        
        XCTAssertFalse(demuxSummary.chapters.isEmpty)
        XCTAssertEqual(demuxSummary.chapters.first?.title, "Intro")
    }
    
    // MARK: - 6. ViewModel Multi-Track, Chapter Navigation & Controls
    
    @MainActor
    func testViewModelTrackSelectionAndChapters() {
        let testURL = URL(fileURLWithPath: "/tmp/movie.mkv")
        let summary = UniFFIMediaDemuxSummary(
            containerFormat: "matroska",
            durationMs: 120_000,
            title: "Demo Movie",
            tracks: [
                UniFFIMediaTrackInfo(trackId: 1, trackType: .video, codec: "hevc", language: "und", title: "Main 4K Video", isDefault: true, channels: nil, sampleRate: nil, width: 3840, height: 2160),
                UniFFIMediaTrackInfo(trackId: 2, trackType: .audio, codec: "flac", language: "jpn", title: "Japanese 5.1", isDefault: true, channels: 6, sampleRate: 48000, width: nil, height: nil),
                UniFFIMediaTrackInfo(trackId: 3, trackType: .audio, codec: "aac", language: "eng", title: "English Stereo", isDefault: false, channels: 2, sampleRate: 44100, width: nil, height: nil),
                UniFFIMediaTrackInfo(trackId: 4, trackType: .subtitle, codec: "ass", language: "eng", title: "English Full ASS", isDefault: true, channels: nil, sampleRate: nil, width: nil, height: nil)
            ],
            chapters: [
                UniFFIMediaChapter(startTimeMs: 0, endTimeMs: 30_000, title: "Opening"),
                UniFFIMediaChapter(startTimeMs: 30_000, endTimeMs: 90_000, title: "Main Story"),
                UniFFIMediaChapter(startTimeMs: 90_000, endTimeMs: 120_000, title: "Ending & Credits")
            ],
            attachments: []
        )
        
        let vm = IINAPlayerViewModel(mediaURL: testURL, demuxSummary: summary)
        
        XCTAssertEqual(vm.duration, 120.0)
        XCTAssertEqual(vm.audioTracks.count, 2)
        XCTAssertEqual(vm.subtitleTracks.count, 1)
        XCTAssertEqual(vm.chapters.count, 3)
        XCTAssertEqual(vm.selectedAudioTrackId, 2)
        XCTAssertEqual(vm.selectedSubtitleTrackId, 4)
        
        // Switch Audio Track
        vm.selectAudioTrack(id: 3)
        XCTAssertEqual(vm.selectedAudioTrackId, 3)
        
        // Jump to Chapter 2
        vm.jumpToChapter(summary.chapters[1])
        XCTAssertEqual(vm.currentTime, 30.0)
        XCTAssertEqual(vm.currentChapter?.title, "Main Story")
        
        // Disable Subtitles
        vm.selectSubtitleTrack(id: nil)
        XCTAssertNil(vm.selectedSubtitleTrackId)
        XCTAssertTrue(vm.activeDialogues.isEmpty)
        
        // Playback Controls
        vm.togglePlayPause()
        XCTAssertTrue(vm.isPlaying)
        vm.togglePlayPause()
        XCTAssertFalse(vm.isPlaying)
        
        vm.skip(seconds: 15.0)
        XCTAssertEqual(vm.currentTime, 45.0)
        
        vm.toggleMute()
        XCTAssertTrue(vm.isMuted)
    }
    
    // MARK: - 7. Zero-Disk Memory Stream Bridge & Custom Loader
    
    @MainActor
    func testIINAStreamBridgeMemoryStreaming() throws {
        func ebmlBox(id: UInt32, data: [UInt8]) -> [UInt8] {
            var out: [UInt8] = []
            if id > 0x00FF_FFFF { out.append(contentsOf: withUnsafeBytes(of: id.bigEndian) { Array($0) }) }
            else if id > 0xFFFF { out.append(contentsOf: withUnsafeBytes(of: id.bigEndian) { Array($0)[1...] }) }
            else if id > 0xFF { out.append(contentsOf: withUnsafeBytes(of: id.bigEndian) { Array($0)[2...] }) }
            else { out.append(UInt8(id)) }
            let sz = data.count
            if sz < 0x7F { out.append(0x80 | UInt8(sz)) }
            else { out.append(0x40 | UInt8((sz >> 8) & 0xFF)); out.append(UInt8(sz & 0xFF)) }
            out.append(contentsOf: data)
            return out
        }
        let ebmlHdr = ebmlBox(id: 0x1A45_DFA3, data: ebmlBox(id: 0x4282, data: Array("matroska".utf8)))
        var mkvData = ebmlHdr
        mkvData.append(contentsOf: ebmlBox(id: 0x1853_8067, data: [0x00, 0x00]))
        
        final class MockVirtualFileStream: VirtualFileStreamProtocol, @unchecked Sendable {
            private var data: Data
            private var currentPos: UInt64 = 0
            
            init(data: Data) { self.data = data }
            func position() -> UInt64 { currentPos }
            func size() -> UInt64 { UInt64(data.count) }
            func seek(offset: UInt64) throws -> UInt64 {
                currentPos = min(offset, UInt64(data.count))
                return currentPos
            }
            func read(maxBytes: UInt32) throws -> Data {
                let available = UInt32(data.count) - UInt32(currentPos)
                let count = min(maxBytes, available)
                let slice = data.subdata(in: Int(currentPos)..<Int(currentPos + UInt64(count)))
                currentPos += UInt64(count)
                return slice
            }
            func readAll() throws -> Data { data }
            func readExactAt(offset: UInt64, length: UInt32) throws -> Data {
                let start = Int(offset)
                let end = min(start + Int(length), data.count)
                guard start < data.count else { return Data() }
                return data.subdata(in: start..<end)
            }
        }
        
        let samplePayload = Data(mkvData)
        let mockStream = MockVirtualFileStream(data: samplePayload)
        let bridge = IINAStreamBridge(stream: mockStream, mimeType: "video/x-matroska")
        
        XCTAssertEqual(bridge.size, UInt64(samplePayload.count))
        XCTAssertEqual(bridge.mimeType, "video/x-matroska")
        
        let readChunk = try bridge.readExact(offset: 0, length: 4)
        XCTAssertEqual(readChunk.count, 4)
        
        let pos = try bridge.seek(offset: 8)
        XCTAssertEqual(pos, 8)
        XCTAssertEqual(bridge.position, 8)
        
        // Demux via stream bridge
        let summary = try bridge.demuxContainer()
        XCTAssertEqual(summary.containerFormat, "matroska")
        XCTAssertEqual(bridge.demuxSummary?.containerFormat, "matroska")
        
        let loader = IINAVirtualStreamResourceLoader(streamBridge: bridge)
        let asset = loader.makeStreamingAsset(originalURL: URL(string: "http://localhost/dummy.mkv")!)
        XCTAssertEqual(asset.url.scheme, "iinavfs")
    }
    
    // MARK: - 8. Marketplace Registration & 1-Click Activation
    
    @MainActor
    func testMarketplaceRegistrationAndActivation() async throws {
        let catalog = TTZipMarketplaceService.defaultCatalog
        XCTAssertTrue(catalog.contains(where: { $0.id == "com.metastudyline.ttzip.plugin.iinaplayer" }))
        
        let iinaMeta = TTZipMarketplaceService.iinaplayerPlugin
        XCTAssertEqual(iinaMeta.name, "IINAPlayer")
        XCTAssertEqual(iinaMeta.displayName, "IINAPlayer 官方全能播放器")
        XCTAssertEqual(iinaMeta.downloadUrl, "builtin://iinaplayer")
        
        let installer = TTZipPluginInstaller.shared
        try await installer.install(plugin: iinaMeta, context: TTZipHostContextImpl.shared)
        
        XCTAssertEqual(installer.currentPhase, .installed(pluginId: iinaMeta.id))
        XCTAssertTrue(TTZipPluginRegistry.shared.installedPlugins.contains(where: { $0.manifest.id == iinaMeta.id }))
        XCTAssertFalse(TTZipPluginRegistry.shared.previewProviders.isEmpty)
        
        await TTZipPluginRegistry.shared.unregister(pluginId: iinaMeta.id)
    }
}
