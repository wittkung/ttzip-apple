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
        
        // Verify extension contributions
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
            XCTAssertTrue(
                provider.supportedExtensions.contains(ext),
                "Supported extensions must contain .\(ext)"
            )
            let fileURL = URL(fileURLWithPath: "/tmp/sample_video.\(ext)")
            XCTAssertTrue(
                provider.canPreview(fileURL: fileURL),
                "IINAPreviewProvider must intercept video format .\(ext)"
            )
        }
        
        // Verify non-video formats are not intercepted
        let nonVideoFiles = ["document.pdf", "archive.zip", "picture.png", "source.swift"]
        for nonVideo in nonVideoFiles {
            let url = URL(fileURLWithPath: "/tmp/\(nonVideo)")
            XCTAssertFalse(provider.canPreview(fileURL: url))
        }
        
        // Verify ttzip:// virtual streaming URI parsing
        let virtualStreamURL = URL(string: "ttzip:///Users/test/archive.zip?entry=nested_movie.mkv")!
        XCTAssertTrue(provider.canPreview(fileURL: virtualStreamURL))
        
        let previewView = provider.makePreviewView(fileURL: URL(fileURLWithPath: "/tmp/movie.mkv"))
        XCTAssertNotNil(previewView)
    }
    
    // MARK: - 3. Metal ViewModel, HDR and ASS Subtitle Layout
    
    @MainActor
    func testIINAPlayerViewModelAndSubtitleEngine() {
        let testURL = URL(fileURLWithPath: "/tmp/hdr_movie.mkv")
        let vm = IINAPlayerViewModel(mediaURL: testURL)
        
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.volume, 1.0)
        XCTAssertFalse(vm.isMuted)
        
        // Play / Pause toggle
        vm.togglePlayPause()
        XCTAssertTrue(vm.isPlaying)
        vm.togglePlayPause()
        XCTAssertFalse(vm.isPlaying)
        
        // Precise Seek
        vm.seek(to: 45.0)
        XCTAssertEqual(vm.currentTime, 45.0)
        
        // Skip forward / backward
        vm.skip(seconds: 10.0)
        XCTAssertEqual(vm.currentTime, 55.0)
        vm.skip(seconds: -20.0)
        XCTAssertEqual(vm.currentTime, 35.0)
        
        // Mute toggle
        vm.toggleMute()
        XCTAssertTrue(vm.isMuted)
        vm.toggleMute()
        XCTAssertFalse(vm.isMuted)
        
        // Subtitle Cue Matching
        vm.seek(to: 1.0)
        XCTAssertNotNil(vm.currentSubtitleText)
        XCTAssertTrue(vm.currentSubtitleText?.contains("IINAPlayer") == true)
        
        // Subtitle Tag Stripping
        let subView = IINASubtitleVectorTextView(rawText: "{\\b1}Hello{\\b0} {\\c&H0000FF&}World")
        XCTAssertEqual(subView.cleanText, "Hello World")
    }
    
    // MARK: - 4. Zero-Disk Memory Stream Bridge
    
    func testIINAStreamBridgeMemoryStreaming() throws {
        // Mock VirtualFileStream implementation
        final class MockVirtualFileStream: VirtualFileStreamProtocol, @unchecked Sendable {
            private var data: Data
            private var currentPos: UInt64 = 0
            
            init(data: Data) {
                self.data = data
            }
            
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
            
            func readAll() throws -> Data {
                data
            }
            
            func readExactAt(offset: UInt64, length: UInt32) throws -> Data {
                let start = Int(offset)
                let end = min(start + Int(length), data.count)
                guard start < data.count else { return Data() }
                return data.subdata(in: start..<end)
            }
        }
        
        let samplePayload = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x6D, 0x70, 0x34, 0x32])
        let mockStream = MockVirtualFileStream(data: samplePayload)
        let bridge = IINAStreamBridge(stream: mockStream, mimeType: "video/mp4")
        
        XCTAssertEqual(bridge.size, UInt64(samplePayload.count))
        XCTAssertEqual(bridge.mimeType, "video/mp4")
        
        let readChunk = try bridge.readExact(offset: 0, length: 4)
        XCTAssertEqual(readChunk.count, 4)
        XCTAssertEqual(readChunk, Data([0x00, 0x00, 0x00, 0x18]))
        
        let pos = try bridge.seek(offset: 8)
        XCTAssertEqual(pos, 8)
        XCTAssertEqual(bridge.position, 8)
        
        // Verify Resource Loader custom scheme URL asset creation
        let loader = IINAVirtualStreamResourceLoader(streamBridge: bridge)
        let asset = loader.makeStreamingAsset(originalURL: URL(string: "http://localhost/dummy.mp4")!)
        XCTAssertEqual(asset.url.scheme, "iinavfs")
    }
    
    // MARK: - 5. Marketplace Registration & 1-Click Activation
    
    @MainActor
    func testMarketplaceRegistrationAndActivation() async throws {
        let catalog = TTZipMarketplaceService.defaultCatalog
        XCTAssertTrue(catalog.contains(where: { $0.id == "com.metastudyline.ttzip.plugin.iinaplayer" }))
        
        let iinaMeta = TTZipMarketplaceService.iinaplayerPlugin
        XCTAssertEqual(iinaMeta.name, "IINAPlayer")
        XCTAssertEqual(iinaMeta.displayName, "IINAPlayer 官方全能播放器")
        XCTAssertEqual(iinaMeta.downloadUrl, "builtin://iinaplayer")
        
        // 1-Click Instant Activation
        let installer = TTZipPluginInstaller.shared
        try await installer.install(plugin: iinaMeta, context: TTZipHostContextImpl.shared)
        
        XCTAssertEqual(installer.currentPhase, .installed(pluginId: iinaMeta.id))
        XCTAssertTrue(TTZipPluginRegistry.shared.installedPlugins.contains(where: { $0.manifest.id == iinaMeta.id }))
        XCTAssertFalse(TTZipPluginRegistry.shared.previewProviders.isEmpty)
        
        // Clean up
        await TTZipPluginRegistry.shared.unregister(pluginId: iinaMeta.id)
    }
}
