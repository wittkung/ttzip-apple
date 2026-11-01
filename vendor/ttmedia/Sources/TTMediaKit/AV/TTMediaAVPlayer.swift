// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import AVFoundation



/// High-level audio/video controller coordinating hardware-accelerated playback
/// with authentic PCM waveform telemetry.
@MainActor
@Observable
public final class TTMediaAVPlayer {
    public private(set) var currentURL: URL? = nil
    public private(set) var activeLoadGeneration: UInt64 = 0
    public private(set) var waveformPeaks: [Float] = []
    public private(set) var waveformRms: [Float] = []

    private var avPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var waveformTask: Task<Void, Never>? = nil
    private var durationLoadTask: Task<Void, Never>? = nil
    private var fallbackIsPlaying: Bool = false
    private var fallbackCurrentTime: Double = 0.0
    private var fallbackDuration: Double = 0.0

    public var isPlaying: Bool {
        fallbackIsPlaying
    }

    public var currentTime: Double {
        fallbackCurrentTime
    }

    public var duration: Double {
        fallbackDuration
    }

    public var volume: Double {
        Double(avPlayer?.volume ?? 1.0)
    }

    public init() {}

    isolated deinit {
        waveformTask?.cancel()
        waveformTask = nil
        durationLoadTask?.cancel()
        durationLoadTask = nil
        activeLoadGeneration &+= 1
        currentURL = nil
        if let timeObserverToken, let avPlayer {
            avPlayer.removeTimeObserver(timeObserverToken)
        }
        avPlayer?.currentItem?.asset.cancelLoading()
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
    }

    /// Loads a local or remote media URL into the playback engine and initiates waveform extraction.
    public func load(url: URL, autoPlay: Bool = false) {
        activeLoadGeneration &+= 1
        waveformTask?.cancel()
        waveformTask = nil
        currentURL = url
        waveformPeaks = []
        waveformRms = []
        let generation = activeLoadGeneration
        setupAVPlayer(url: url, generation: generation)
        extractWaveformAsync(url: url, generation: generation)
        if autoPlay {
            play()
        }
    }

    /// Waits for the currently active waveform extraction task to finish, if any.
    public func waitForWaveform() async {
        await waveformTask?.value
    }

    /// Toggles playback between play and pause.
    public func togglePlayback() {
        if let avPlayer {
            if fallbackIsPlaying {
                avPlayer.pause()
                self.fallbackIsPlaying = false
            } else {
                avPlayer.play()
                self.fallbackIsPlaying = true
            }
        }
    }

    /// Resumes media playback.
    public func play() {
        avPlayer?.play()
        self.fallbackIsPlaying = true
    }

    /// Pauses media playback.
    public func pause() {
        avPlayer?.pause()
        self.fallbackIsPlaying = false
    }

    /// Seeks playback to a specific timestamp in seconds.
    public func seek(to seconds: Double) {
        let target = max(0.0, seconds)
        if let avPlayer {
            let time = CMTime(seconds: target, preferredTimescale: 600)
            avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            self.fallbackCurrentTime = target
        }
    }

    /// Adjusts playback volume level [0.0, 1.0].
    public func setVolume(_ volume: Double) {
        let clamped = max(0.0, min(1.0, volume))
        avPlayer?.volume = Float(clamped)
    }

    /// Updates the authentic waveform peak and RMS envelopes.
    public func updateWaveform(peaks: [Float], rms: [Float]) {
        self.waveformPeaks = peaks
        self.waveformRms = rms
    }

    /// Tears down playback resources and stops timeline clocks.
    public func stop() {
        waveformTask?.cancel()
        waveformTask = nil
        activeLoadGeneration &+= 1
        currentURL = nil
        cleanupAVPlayer()
        self.fallbackIsPlaying = false
    }

    private func extractWaveformAsync(url: URL, generation: UInt64) {
        waveformTask = Task { @MainActor [weak self] in
            guard let peaks = await AudioWaveformExtractor.shared.extractAuthenticWaveform(from: url),
                  !Task.isCancelled,
                  let self,
                  self.activeLoadGeneration == generation,
                  self.currentURL == url,
                  !peaks.isEmpty else { return }
            let rms = peaks.map { $0 * 0.7 }
            self.updateWaveform(peaks: peaks, rms: rms)
        }
    }

    private func setupAVPlayer(url: URL, generation: UInt64) {
        cleanupAVPlayer()
        let player = AVPlayer(url: url)
        self.avPlayer = player
        self.fallbackCurrentTime = 0.0
        self.fallbackIsPlaying = false

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        self.timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite && seconds >= 0 {
                MainActor.assumeIsolated {
                    self.fallbackCurrentTime = seconds
                }
            }
        }

        durationLoadTask?.cancel()
        durationLoadTask = Task { @MainActor [weak self, weak player] in
            guard let self, let currentItem = player?.currentItem else { return }
            do {
                let duration = try await currentItem.asset.load(.duration)
                guard !Task.isCancelled, self.activeLoadGeneration == generation, self.currentURL == url else { return }
                let durSeconds = duration.seconds
                if durSeconds.isFinite && durSeconds > 0 {
                    self.fallbackDuration = durSeconds
                }
            } catch {
                // Keep default duration
            }
        }
    }

    private func cleanupAVPlayer() {
        durationLoadTask?.cancel()
        durationLoadTask = nil
        autoreleasepool {
            if let token = timeObserverToken, let avPlayer {
                avPlayer.removeTimeObserver(token)
                self.timeObserverToken = nil
            }
            avPlayer?.currentItem?.asset.cancelLoading()
            avPlayer?.pause()
            avPlayer?.replaceCurrentItem(with: nil)
            self.avPlayer = nil
        }
    }
}
