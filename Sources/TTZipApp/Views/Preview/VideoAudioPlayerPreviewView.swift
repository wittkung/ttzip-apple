// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AVFoundation
import AVKit
import TTZipCore

/// Shared video player state store integrating Rust demuxing and AVFoundation hardware playback.
@MainActor
public final class SharedVideoPlayerStore: ObservableObject {
    @Published public var player: AVPlayer?
    @Published public var currentURL: URL?
    @Published public var isPlaying: Bool = false
    @Published public var currentTime: Double = 0
    @Published public var duration: Double = 0
    @Published public var isMuted: Bool = false
    @Published public var hasPlaybackError: Bool = false
    @Published public var hasDecoderLimitation: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var demuxSummary: UniFfiMediaDemuxSummary? = nil
    
    private var timeObserverToken: Any?
    private var statusObservation: NSKeyValueObservation?
    private var failureNotificationToken: Any?
    
    public init() {}
    
    public func setup(url: URL) {
        if currentURL == url, let p = player {
            if !hasPlaybackError && p.rate == 0 && isPlaying {
                p.play()
            }
            return
        }
        
        cleanUp()
        
        self.currentURL = url
        self.isPlaying = false
        self.hasPlaybackError = false
        self.hasDecoderLimitation = false
        self.errorMessage = nil
        
        // 1. Asynchronously extract tracks, chapters, and container metadata via Rust microkernel
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            let headerData = (try? handle.read(upToCount: 2 * 1024 * 1024)) ?? Data()
            if !headerData.isEmpty {
                let summary = try? demuxMediaTracks(data: headerData)
                await MainActor.run { [weak self] in
                    guard let self = self, self.currentURL == url else { return }
                    self.demuxSummary = summary
                    if self.duration == 0, let durMs = summary?.durationMs, durMs > 0 {
                        self.duration = Double(durMs) / 1000.0
                    }
                }
            }
        }
        
        // 2. Initialize native AVPlayer hardware accelerated playback pipeline
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        self.player = newPlayer
        
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self = self, self.currentURL == url else { return }
                switch observedItem.status {
                case .readyToPlay:
                    let d = CMTimeGetSeconds(observedItem.duration)
                    if d.isFinite && d > 0 {
                        self.duration = d
                    }
                    self.hasPlaybackError = false
                case .failed:
                    self.hasDecoderLimitation = true
                    self.errorMessage = observedItem.error?.localizedDescription ?? "Hardware decoder unavailable for this container/stream."
                default:
                    break
                }
            }
        }
        
        failureNotificationToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notif in
            let errorDesc = (notif.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                guard let self = self, self.currentURL == url else { return }
                self.hasDecoderLimitation = true
                if let errorDesc = errorDesc {
                    self.errorMessage = errorDesc
                }
            }
        }
        
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self = self else { return }
                let secs = CMTimeGetSeconds(time)
                if secs.isFinite && secs >= 0 {
                    self.currentTime = secs
                }
                if let currentItem = newPlayer.currentItem {
                    let d = CMTimeGetSeconds(currentItem.duration)
                    if d.isFinite && d > 0 {
                        self.duration = d
                    }
                }
            }
        }
    }
    
    public func togglePlayPause() {
        guard let p = player, !hasPlaybackError else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
        } else {
            p.play()
            isPlaying = true
        }
    }
    
    public func seek(to seconds: Double) {
        guard !hasPlaybackError else { return }
        currentTime = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }
    
    public func seekBy(_ seconds: Double) {
        guard !hasPlaybackError else { return }
        let maxDur = duration > 0 ? duration : 36000
        let target = min(max(currentTime + seconds, 0), maxDur)
        seek(to: target)
    }
    
    public func cleanUp() {
        if let obs = timeObserverToken, let p = player {
            p.removeTimeObserver(obs)
            timeObserverToken = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        if let token = failureNotificationToken {
            NotificationCenter.default.removeObserver(token)
            failureNotificationToken = nil
        }
        player?.pause()
        player?.rate = 0
        player?.replaceCurrentItem(with: nil)
        player = nil
        currentURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        hasPlaybackError = false
        hasDecoderLimitation = false
        errorMessage = nil
        demuxSummary = nil
    }
}
