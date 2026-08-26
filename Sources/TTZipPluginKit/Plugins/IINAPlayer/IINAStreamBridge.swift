// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import AVFoundation
import TTZipCore

/// Strongly-typed zero-disk IO memory stream bridge for compressed video media.
public final class IINAStreamBridge: @unchecked Sendable {
    private let stream: VirtualFileStreamProtocol
    private let lock = NSLock()
    public let mediaSize: UInt64
    public let mimeType: String
    public private(set) var demuxSummary: UniFFIMediaDemuxSummary?
    
    public init(stream: VirtualFileStreamProtocol, mimeType: String = "video/mp4") {
        self.stream = stream
        self.mediaSize = stream.size()
        self.mimeType = mimeType
    }
    
    /// Factory initializer from a `ttzip://` custom URL scheme.
    public static func open(ttzipURL: URL) throws -> IINAStreamBridge {
        guard let components = URLComponents(url: ttzipURL, resolvingAgainstBaseURL: false) else {
            throw ArchiveError.invalidFormat
        }
        
        let archivePath = ttzipURL.path
        var targetEntry = ""
        var drillPath: [String] = []
        var password: String? = nil
        
        if let queryItems = components.queryItems {
            for item in queryItems {
                switch item.name {
                case "entry":
                    targetEntry = item.value ?? ""
                case "drill":
                    if let val = item.value {
                        drillPath = val.split(separator: ",").map(String.init)
                    }
                case "password":
                    password = item.value
                default:
                    break
                }
            }
        }
        
        if targetEntry.isEmpty {
            targetEntry = ttzipURL.lastPathComponent
        }
        
        let vfs = try openVirtualFileStream(
            archivePath: archivePath,
            drillPath: drillPath,
            targetEntry: targetEntry,
            password: password
        )
        
        let ext = (targetEntry as NSString).pathExtension.lowercased()
        let mime = ArchiveMimeMapper.mimeType(forExtension: ext)
        let bridge = IINAStreamBridge(stream: vfs, mimeType: mime)
        _ = try? bridge.demuxContainer()
        return bridge
    }
    
    /// Demuxes container metadata (tracks, chapters, attachments) via Rust microkernel.
    @discardableResult
    public func demuxContainer(headerByteLimit: UInt32 = 1_048_576) throws -> UniFFIMediaDemuxSummary {
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = demuxSummary {
            return existing
        }
        
        let total = stream.size()
        guard total > 0 else {
            throw ArchiveError.invalidFormat
        }
        let fetchLen = min(UInt32(total), headerByteLimit)
        let sampleData = try stream.readExactAt(offset: 0, length: fetchLen)
        let summary = try demuxMediaTracks(data: sampleData)
        self.demuxSummary = summary
        return summary
    }
    
    /// Extracted media audio tracks.
    public var audioTracks: [UniFFIMediaTrackInfo] {
        lock.lock()
        defer { lock.unlock() }
        return demuxSummary?.tracks.filter { $0.trackType == .audio } ?? []
    }
    
    /// Extracted media video tracks.
    public var videoTracks: [UniFFIMediaTrackInfo] {
        lock.lock()
        defer { lock.unlock() }
        return demuxSummary?.tracks.filter { $0.trackType == .video } ?? []
    }
    
    /// Extracted media subtitle tracks.
    public var subtitleTracks: [UniFFIMediaTrackInfo] {
        lock.lock()
        defer { lock.unlock() }
        return demuxSummary?.tracks.filter { $0.trackType == .subtitle } ?? []
    }
    
    /// Extracted media chapters.
    public var chapters: [UniFFIMediaChapter] {
        lock.lock()
        defer { lock.unlock() }
        return demuxSummary?.chapters ?? []
    }
    
    /// Reads exact byte slice at specified offset in-memory.
    public func readExact(offset: UInt64, length: UInt32) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try stream.readExactAt(offset: offset, length: length)
    }
    
    /// Seeks stream position.
    public func seek(offset: UInt64) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return try stream.seek(offset: offset)
    }
    
    /// Returns total stream size in bytes.
    public var size: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return stream.size()
    }
    
    /// Returns current stream read pointer.
    public var position: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return stream.position()
    }
}

// MARK: - AVAssetResourceLoader Custom Zero-Disk Stream Delegate

public final class IINAVirtualStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public static let customScheme = "iinavfs"
    private let streamBridge: IINAStreamBridge
    private let queue = DispatchQueue(label: "com.metastudyline.ttzip.iinaplayer.loader", qos: .userInitiated)
    
    public init(streamBridge: IINAStreamBridge) {
        self.streamBridge = streamBridge
        super.init()
    }
    
    /// Creates a streaming AVURLAsset bound to this in-memory zero-disk resource loader.
    public func makeStreamingAsset(originalURL: URL) -> AVURLAsset {
        var comps = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        comps.scheme = Self.customScheme
        let customURL = comps.url ?? originalURL
        let asset = AVURLAsset(url: customURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }
    
    // MARK: - AVAssetResourceLoaderDelegate
    
    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let dataRequest = loadingRequest.dataRequest else {
            return false
        }
        
        // 1. Respond to Content Information Request
        if let contentInfo = loadingRequest.contentInformationRequest {
            contentInfo.isByteRangeAccessSupported = true
            contentInfo.contentType = streamBridge.mimeType
            contentInfo.contentLength = Int64(streamBridge.size)
        }
        
        // 2. Fulfill Data Range Request from UniFFI VirtualFileStream
        let requestedOffset = UInt64(dataRequest.requestedOffset)
        let requestedLength = UInt32(dataRequest.requestedLength)
        
        do {
            let data = try streamBridge.readExact(offset: requestedOffset, length: requestedLength)
            dataRequest.respond(with: data)
            loadingRequest.finishLoading()
            return true
        } catch {
            loadingRequest.finishLoading(with: error)
            return false
        }
    }
    
    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Handle cancellation gracefully
    }
}
