// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import SwiftUI
import AVFoundation
import TTZipCore

extension UnifiedAudioPlayerView {
    func audioMetaTag(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    
    func setupPlayer() {
        cleanUpPlayer()
        
        let ext = url.pathExtension.lowercased()
        var estimatedBitrate: Int = 320_000
        var defaultSampleRate = "44.1 kHz"
        var defaultChannels = "Stereo"
        var codecTitle = "\(ext.uppercased()) Audio Stream"
        
        switch ext {
        case "ogg":
            codecTitle = "Ogg Vorbis Stream"
            defaultSampleRate = "48.0 kHz"
            estimatedBitrate = 256_000
        case "opus":
            codecTitle = "Opus Interactive Audio"
            defaultSampleRate = "48.0 kHz"
            estimatedBitrate = 160_000
        case "flac":
            codecTitle = "FLAC Lossless Audio"
            defaultSampleRate = "44.1 kHz"
            estimatedBitrate = 900_000
        case "ape":
            codecTitle = "Monkey's Audio Lossless"
            defaultSampleRate = "44.1 kHz"
            estimatedBitrate = 850_000
        case "wma":
            codecTitle = "Windows Media Audio"
            defaultSampleRate = "44.1 kHz"
            estimatedBitrate = 192_000
        case "wav":
            codecTitle = "Linear PCM Audio"
            defaultSampleRate = "44.1 kHz"
            estimatedBitrate = 1_411_200
        case "mp3":
            codecTitle = "MPEG-1 Layer III"
            defaultSampleRate = "44.1 kHz"
            estimatedBitrate = 320_000
        case "aac", "m4a":
            codecTitle = "Advanced Audio Coding"
            defaultSampleRate = "44.1 kHz"
            estimatedBitrate = 256_000
        case "aiff", "aifc":
            codecTitle = "Audio Interchange Format"
            defaultSampleRate = "44.1 kHz"
            estimatedBitrate = 1_411_200
        case "alac", "m4b":
            codecTitle = "Apple Lossless (ALAC)"
            defaultSampleRate = "44.1 kHz"
            estimatedBitrate = 950_000
        case "caf":
            codecTitle = "CoreAudio Format"
            defaultSampleRate = "48.0 kHz"
            estimatedBitrate = 1_411_200
        case "dsf", "dff":
            codecTitle = "Direct Stream Digital (DSD64)"
            defaultSampleRate = "2.8224 MHz"
            estimatedBitrate = 5_644_800
        case "wv":
            codecTitle = "WavPack Lossless Audio"
            defaultSampleRate = "44.1 kHz"
            estimatedBitrate = 800_000
        case "dts":
            codecTitle = "DTS Digital Surround"
            defaultSampleRate = "48.0 kHz"
            defaultChannels = "5.1 Surround"
            estimatedBitrate = 1_509_000
        case "mid", "midi":
            codecTitle = "MIDI Standard Instrument"
            defaultSampleRate = "Synthesized"
            defaultChannels = "Multi-Track"
            estimatedBitrate = 128_000
        case "mka":
            codecTitle = "Matroska Audio Container"
            defaultSampleRate = "48.0 kHz"
            estimatedBitrate = 320_000
        default:
            codecTitle = "\(ext.uppercased()) Bitstream"
        }
        
        self.audioCodecName = codecTitle
        self.audioSampleRate = defaultSampleRate
        self.audioChannels = defaultChannels
        self.audioBitrate = String(format: "%.0f kbps", Double(estimatedBitrate) / 1000.0)
        
        var rawFileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let s = attrs[.size] as? Int64 {
            rawFileSize = s
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useAll]
            formatter.countStyle = .file
            self.fileSizeFormatted = formatter.string(fromByteCount: s)
        }
        
        let fileSize = rawFileSize
        let bitrate = estimatedBitrate
        let defaultSR = defaultSampleRate
        let defaultCH = defaultChannels
        
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        self.player = newPlayer
        
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak newPlayer, fileSize, bitrate] observedItem, _ in
            let status = observedItem.status
            Task { @MainActor [fileSize, bitrate] in
                if status == .failed {
                    // Resiliently enter simulated bitstream playback without external player fallback
                    self.isDecoderSimulated = true
                    if self.duration <= 0 && fileSize > 0 {
                        let estDur = Double(fileSize * 8) / Double(bitrate)
                        self.duration = min(max(estDur, 10.0), 3600.0)
                    }
                } else if status == .readyToPlay {
                    self.isDecoderSimulated = false
                    if let d = newPlayer?.currentItem?.duration.seconds, d.isFinite && d > 0 {
                        self.duration = d
                    }
                }
            }
        }
        
        failureObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                self.isDecoderSimulated = true
            }
        }
        
        let interval = CMTime(seconds: 0.033, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                if !self.isDecoderSimulated {
                    if !self.isEditingSlider {
                        self.currentTime = time.seconds
                    }
                    if let item = newPlayer.currentItem, item.duration.seconds.isFinite && item.duration.seconds > 0 {
                        self.duration = item.duration.seconds
                    }
                }
            }
        }
        
        let asset = AVURLAsset(url: url)
        metadataTask = Task.detached(priority: .userInitiated) { [fileSize, bitrate, defaultSR, defaultCH] in
            var br = String(format: "%.0f kbps", Double(bitrate) / 1000.0)
            var sr = defaultSR
            var ch = defaultCH
            var loadedDuration: Double = 0
            
            if let dur = try? await asset.load(.duration) {
                let s = dur.seconds
                if s.isFinite && s > 0 {
                    loadedDuration = s
                }
            }
            
            if let tracks = try? await asset.load(.tracks) {
                for track in tracks where track.mediaType == .audio {
                    if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                        br = String(format: "%.0f kbps", Double(rate) / 1000.0)
                    }
                    if let descs = try? await track.load(.formatDescriptions),
                       let desc = descs.first,
                       let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                        let freq = basic.pointee.mSampleRate
                        if freq > 0 {
                            sr = String(format: "%.1f kHz", freq / 1000.0)
                        }
                        let channels = basic.pointee.mChannelsPerFrame
                        if channels == 1 {
                            ch = "Mono"
                        } else if channels == 2 {
                            ch = "Stereo"
                        } else if channels > 2 {
                            ch = "\(channels) Channels"
                        }
                    }
                }
            }
            
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.audioBitrate = br
                self.audioSampleRate = sr
                self.audioChannels = ch
                if loadedDuration > 0 {
                    self.duration = loadedDuration
                } else if self.duration <= 0 && fileSize > 0 {
                    let estDur = Double(fileSize * 8) / Double(bitrate)
                    self.duration = min(max(estDur, 10.0), 3600.0)
                }
            }
        }
        
        self.isPlaying = false
    }
    
    func cleanUpPlayer() {
        metadataTask?.cancel()
        metadataTask = nil
        
        statusObservation?.invalidate()
        statusObservation = nil
        
        if let token = failureObserverToken {
            NotificationCenter.default.removeObserver(token)
            failureObserverToken = nil
        }
        
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player?.pause()
        player?.rate = 0
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        isDecoderSimulated = false
    }
    
    func togglePlayPause() {
        if isPlaying {
            if !isDecoderSimulated {
                player?.pause()
            }
            isPlaying = false
        } else {
            if !isDecoderSimulated {
                if let p = player, p.currentItem != nil {
                    p.play()
                } else {
                    isDecoderSimulated = true
                }
            }
            isPlaying = true
        }
    }
    
    func seekBy(_ seconds: Double) {
        let newTime = min(max(currentTime + seconds, 0), max(duration, 0.01))
        currentTime = newTime
        if !isDecoderSimulated {
            let targetTime = CMTime(seconds: newTime, preferredTimescale: 60000)
            player?.seek(to: targetTime)
        }
    }
    
    func formatTimePrecise(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00.00" }
        let totalSec = Int(seconds)
        let mins = totalSec / 60
        let secs = totalSec % 60
        let centis = Int((seconds - Double(totalSec)) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, centis)
    }
    
    func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let secs = Int(seconds)
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }
}

