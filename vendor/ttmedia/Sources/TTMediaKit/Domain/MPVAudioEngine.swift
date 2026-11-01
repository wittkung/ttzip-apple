// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import AVFoundation
import SwiftUI

/// Pure native AVAudioPlayer & in-memory direct audio playback engine.
@MainActor
@Observable
public final class MPVAudioEngine: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    public static let shared = MPVAudioEngine()

    /// Maximum file size eligible for in-memory `Data` fallback when URL stream initialization fails (4 MiB).
    nonisolated public static let maxInMemoryFallbackBytes: Int64 = 4 * 1024 * 1024

    /// Maximum payload size accepted by direct in-memory `load(data:)` calls (64 MiB).
    nonisolated public static let maxDirectDataBytes: Int = 64 * 1024 * 1024

    /// Maximum file size for synchronous main-thread `prepareToPlay()` prebuffering (16 MiB).
    nonisolated public static let maxSynchronousPrepareBytes: Int64 = 16 * 1024 * 1024

    /// Single-frame 60Hz main-thread latency budget (16.0 ms) used to evaluate synchronous preparation stages.
    nonisolated public static let maxMainThreadStageBudgetMs: Double = 16.0

    /// Extensions verified against real audio fixtures in `Tests/Fixtures/preview/audio/` on macOS arm64.
    nonisolated public static let verifiedCorpusFormatSpecs: [String: MPVAudioVerifiedFormatSpec] = [
        "wav": .init(extensionName: "wav", containerFormat: "RIFF WAVE", codecName: "Linear PCM (pcm_s16le)"),
        "mp3": .init(extensionName: "mp3", containerFormat: "MPEG Audio", codecName: "MPEG-1 Layer III"),
        "m4a": .init(extensionName: "m4a", containerFormat: "MPEG-4 Part 14 (M4A)", codecName: "AAC LC"),
        "m4b": .init(extensionName: "m4b", containerFormat: "MPEG-4 Audiobook (M4B)", codecName: "AAC LC"),
        "m4r": .init(extensionName: "m4r", containerFormat: "MPEG-4 Ringtone (M4R)", codecName: "AAC LC"),
        "aac": .init(extensionName: "aac", containerFormat: "ADTS AAC", codecName: "AAC LC"),
        "flac": .init(extensionName: "flac", containerFormat: "FLAC Native", codecName: "FLAC Lossless"),
        "ogg": .init(
            extensionName: "ogg",
            containerFormat: "Ogg Container",
            codecName: "Vorbis",
            playbackVerified: false,
            naturalCompletionVerified: false
        ),
        "oga": .init(
            extensionName: "oga",
            containerFormat: "Ogg Audio",
            codecName: "Vorbis / FLAC",
            playbackVerified: false,
            naturalCompletionVerified: false
        ),
        "opus": .init(
            extensionName: "opus",
            containerFormat: "Ogg Opus",
            codecName: "Opus",
            playbackVerified: false,
            naturalCompletionVerified: false
        ),
        "aiff": .init(extensionName: "aiff", containerFormat: "Audio IFF", codecName: "Linear PCM (pcm_s16be)"),
        "aif": .init(extensionName: "aif", containerFormat: "Audio IFF", codecName: "Linear PCM (pcm_s16be)"),
        "aifc": .init(extensionName: "aifc", containerFormat: "Compressed Audio IFF", codecName: "Linear PCM / IMA4"),
        "caf": .init(extensionName: "caf", containerFormat: "Apple CoreAudio Format", codecName: "Linear PCM"),
        "au": .init(extensionName: "au", containerFormat: "Sun/NeXT AU", codecName: "Linear PCM (pcm_s16be)"),
        "snd": .init(extensionName: "snd", containerFormat: "Sun/NeXT SND", codecName: "Linear PCM (pcm_s16be)"),
        "ac3": .init(extensionName: "ac3", containerFormat: "Dolby Digital AC-3", codecName: "ATSC A/52A (AC-3)"),
        "eac3": .init(extensionName: "eac3", containerFormat: "Dolby Digital Plus", codecName: "ATSC A/52B (E-AC-3)")
    ]

    /// Candidate extensions advertised by macOS CoreAudio that currently lack dedicated corpus fixtures.
    nonisolated public static let unverifiedCandidateCoreAudioExtensions: Set<String> = [
        "adts", "alac", "ec3", "amr", "3gp", "3g2", "w64"
    ]

    /// Extensions verified with real corpus fixtures to pass native `AVAudioPlayer` playback on macOS arm64.
    nonisolated public static var verifiedPlayableCoreAudioExtensions: Set<String> {
        Set(verifiedCorpusFormatSpecs.values.filter(\.playbackVerified).map(\.extensionName))
    }

    /// Union of corpus-verified playable extensions and CoreAudio-advertised candidate extensions.
    nonisolated public static var nativeCoreAudioExtensions: Set<String> {
        verifiedPlayableCoreAudioExtensions.union(unverifiedCandidateCoreAudioExtensions)
    }

    nonisolated public static var verifiedWaveformDecodableExtensions: Set<String> {
        Set(verifiedCorpusFormatSpecs.values.filter(\.waveformExtracted).map(\.extensionName))
    }

    nonisolated public static var waveformOnlyCoreAudioExtensions: Set<String> {
        Set(verifiedCorpusFormatSpecs.values.filter { $0.waveformExtracted && !$0.playbackVerified }.map(\.extensionName))
    }

    public var currentURL: URL?
    public private(set) var currentTime: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var isPlaying: Bool = false
    public private(set) var isBuffering: Bool = false
    public private(set) var volume: Double = 1.0
    public private(set) var playbackSpeed: Double = 1.0
    /// Whole-track acoustic waveform peak envelope extracted from file content (never mutated by live playback level).
    public private(set) var waveformSamples: [Float] = []
    /// Sampling precision mode of the currently loaded waveform (`exhaustiveBucketPeak` vs `windowedSampledEnvelope`).
    public private(set) var waveformSamplingMode: AudioWaveformSamplingMode? = nil
    /// Independent precision and completeness status of the currently loaded waveform (`exhaustiveVerified` vs `sampledOrCompletenessUnverified`).
    public private(set) var waveformPrecisionStatus: AudioWaveformPrecisionStatus? = nil
    /// True only when the container or stream headers authoritatively proved full-stream frame completeness.
    public private(set) var isWaveformCompletenessVerified: Bool = false
    /// True only when every sample across the track was inspected and found below the -80 dBFS silence floor.
    public private(set) var isVerifiedDigitalSilence: Bool = false
    /// Indicates whether background acoustic waveform extraction is currently running for the active track.
    public private(set) var isExtractingWaveform: Bool = false
    /// Real-time playback signal level `[0.0 ... 1.0]` sampled from CoreAudio meters during active playback.
    public private(set) var currentLevel: Float = 0.0
    /// Monotonically increasing token guarding against stale background tasks or old views overwriting newer loads.
    public private(set) var activeLoadGeneration: UInt64 = 0
    /// Identity of the view/session that currently owns this shared audio engine instance.
    public private(set) var activeOwnerSessionID: String? = nil
    public private(set) var metadata: MPVAudioMetadata? = nil
    /// Typed failure reason resolved dynamically through `TTI18n`.
    public private(set) var failureReason: MPVAudioFailureReason? = nil
    /// Raw underlying CoreAudio / NSError diagnostic string preserved for technical inspection.
    public private(set) var diagnosticDetail: String? = nil
    /// Measured main-thread latency metrics for the most recent load/play cycle.
    public private(set) var lastTimingMetrics: MPVAudioLoadTimingMetrics? = nil
    /// Records whether `play()` actually started the hardware output queue for the current track.
    public private(set) var didVerifyPlaybackStart: Bool = false
    /// Records whether `AVAudioPlayerDelegate.audioPlayerDidFinishPlaying(_:successfully:)` fired naturally with `flag == true`.
    public private(set) var didFinishPlayingNaturally: Bool = false
    /// Captured physical resource version of the currently loaded URL for version-consistent window extraction.
    public internal(set) var activeResourceVersion: AudioWaveformResourceVersion? = nil
    /// Stable track-level reference peak (`>= 0.05`) used to normalize local time-window tiles without cross-window jumps.
    public internal(set) var waveformReferencePeak: Float = 1.0
    /// Most recently extracted local high-resolution waveform window tile for the active session.
    public internal(set) var activeWaveformWindowTile: AudioWaveformWindowTile? = nil
    /// Indicates whether a local time-window waveform request is currently running for the active session.
    public internal(set) var isExtractingWaveformWindow: Bool = false
    /// Last local time-window extraction error, if any (independent from whole-track playback failure).
    public internal(set) var lastWaveformWindowError: AudioWaveformWindowError? = nil

    /// Localized status text when the waveform is a sampled result or its completeness is unverified.
    public var waveformPrecisionStatusText: String? {
        guard let status = waveformPrecisionStatus else { return nil }
        switch status {
        case .exhaustiveVerified:
            return nil
        case .sampledOrCompletenessUnverified:
            return AudioPreviewLocalization.text(.completenessUnverifiedBadge)
        }
    }

    public var errorMessage: String? {
        failureReason?.localizedMessage
    }

    public var hasPlaybackError: Bool { failureReason != nil }
    public var isMuted: Bool = false
    public var demuxerCacheProgress: Double = 1.0

    public var codecFormatted: String = "--"
    public var bitrateFormatted: String = "--"
    public var sampleRateFormatted: String = "--"
    public var channelsFormatted: String = "--"

    internal var audioPlayer: AVAudioPlayer?
    private var playbackLoopTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    internal var activeWindowTask: Task<Void, Never>?
    internal var windowPrefetchTask: Task<Void, Never>?
    internal var lastQuantizedWindowStepIndex: Int? = nil
    private var hasRecordedFirstPlayMetric: Bool = false

    public override init() {
        super.init()
    }

    /// Queries playback support classification for a given file extension.
    nonisolated public static func formatSupport(forExtension ext: String) -> MPVAudioFormatSupport {
        let normalized = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        if let spec = verifiedCorpusFormatSpecs[normalized] {
            return .verifiedNativeCoreAudio(spec: spec)
        }
        if unverifiedCandidateCoreAudioExtensions.contains(normalized) {
            return .candidateNativeCoreAudio(extensionName: normalized)
        }
        if normalized == "mid" || normalized == "midi" {
            let extLabel = ".\(normalized)"
            let reason = AudioPreviewLocalization.resolveNonisolated(.midiRequiresSynthesizerFormat, extLabel)
            return .requiresSynthesizer(formatName: "MIDI", reason: reason)
        }
        if let formatName = unsupportedFormatNames[normalized] {
            let extLabel = ".\(normalized)"
            let reason = AudioPreviewLocalization.resolveNonisolated(.unsupportedCodecFormat, formatName, extLabel)
            return .unsupportedCodec(formatName: formatName, reason: reason)
        }
        return .unknown(extensionName: normalized)
    }

    private nonisolated static let unsupportedFormatNames: [String: String] = [
        "wma": "Windows Media Audio (WMA)",
        "wv": "WavPack",
        "tta": "True Audio (TTA)",
        "voc": "Creative Voice (VOC)",
        "ra": "RealAudio",
        "rm": "RealMedia Audio",
        "ape": "Monkey's Audio (APE)",
        "mpc": "Musepack (MPC)",
        "tak": "TAK Lossless",
        "spx": "Speex",
        "dsf": "Direct Stream Digital (DSF)",
        "dff": "DSDIFF Audio",
        "dsd": "Direct Stream Digital (DSD)",
        "mka": "Matroska Audio (MKA)",
        "dts": "DTS Coherent Acoustics",
        "gsm": "GSM Telephony Audio"
    ]

    /// Loads audio directly from in-memory Data within `maxDirectDataBytes` budget.
    @discardableResult
    public func load(data: Data, formatHint: String? = nil, ownerSessionID: String? = nil) -> UInt64 {
        let loadStartNanos = DispatchTime.now().uptimeNanoseconds
        let generation = beginNewLoad(url: nil, ownerSessionID: ownerSessionID)
        guard !data.isEmpty else {
            failLoad(reason: .emptyAudioData, diagnostic: "Data.count == 0")
            return generation
        }
        guard data.count <= Self.maxDirectDataBytes else {
            let formattedSize = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            failLoad(
                reason: .directDataBudgetExceeded(sizeText: formattedSize, budgetText: "64 MB"),
                diagnostic: "Data.count (\(data.count)) > maxDirectDataBytes (\(Self.maxDirectDataBytes))"
            )
            return generation
        }
        if let hint = formatHint, !hint.isEmpty,
           let unsupportedReason = Self.unsupportedFailureReason(forExtension: hint) {
            failLoad(reason: unsupportedReason, diagnostic: "Unsupported format hint: \(hint)")
            return generation
        }

        let initStart = DispatchTime.now().uptimeNanoseconds
        do {
            let player = try Self.makePlayer(from: data, formatHint: formatHint)
            let initMs = Self.elapsedMs(since: initStart)
            configurePlayer(
                player,
                sourceURL: nil,
                sourceData: data,
                fileSize: Int64(data.count),
                generation: generation,
                urlInitMs: initMs,
                fallbackMs: 0,
                usedFallback: false,
                loadStartNanos: loadStartNanos
            )
        } catch {
            let failure = Self.classifyPlaybackFailure(url: nil, formatHint: formatHint, error: error)
            failLoad(reason: failure.reason, diagnostic: failure.diagnostic)
        }
        return generation
    }

    /// Loads audio from a file URL with bounded fallback, measured preparation timing, and verified format diagnostics.
    @discardableResult
    public func load(url: URL, ownerSessionID: String? = nil) -> UInt64 {
        let loadStartNanos = DispatchTime.now().uptimeNanoseconds
        let generation = beginNewLoad(url: url, ownerSessionID: ownerSessionID)
        let ext = url.pathExtension

        guard let fileSize = Self.validatedFileSize(for: url, onFailure: { [weak self] reason, diag in
            self?.failLoad(reason: reason, diagnostic: diag)
        }) else {
            return generation
        }

        if let unsupportedReason = Self.unsupportedFailureReason(forExtension: ext) {
            failLoad(reason: unsupportedReason, diagnostic: "Fast-failed non-native extension .\(ext)")
            return generation
        }

        let initStart = DispatchTime.now().uptimeNanoseconds
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let urlInitMs = Self.elapsedMs(since: initStart)
            configurePlayer(
                player,
                sourceURL: url,
                sourceData: nil,
                fileSize: fileSize,
                generation: generation,
                urlInitMs: urlInitMs,
                fallbackMs: 0,
                usedFallback: false,
                loadStartNanos: loadStartNanos
            )
        } catch {
            let urlInitMs = Self.elapsedMs(since: initStart)
            attemptBoundedDataFallback(
                url: url,
                ext: ext,
                fileSize: fileSize,
                initialError: error,
                generation: generation,
                urlInitMs: urlInitMs,
                loadStartNanos: loadStartNanos
            )
        }
        return generation
    }

    /// Suspends until the active background waveform extraction task finishes or is cancelled.
    public func waitForWaveform() async {
        await waveformTask?.value
    }

    /// Pumps the main RunLoop while waiting for real `AVAudioPlayerDelegate` natural playback completion.
    public func waitForNaturalCompletion(timeoutSeconds: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !didFinishPlayingNaturally && Date() < deadline {
            if hasPlaybackError || audioPlayer == nil {
                break
            }
            pumpRunLoopSlice()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return didFinishPlayingNaturally
    }

    private func pumpRunLoopSlice() {
        _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.015, true)
    }

    private func beginNewLoad(url: URL?, ownerSessionID: String?) -> UInt64 {
        teardownActiveSession()
        activeLoadGeneration &+= 1
        currentURL = url
        activeOwnerSessionID = ownerSessionID
        activeResourceVersion = url.flatMap { AudioWaveformResourceVersion.capture(for: $0) }
        waveformReferencePeak = 1.0
        isBuffering = true
        failureReason = nil
        diagnosticDetail = nil
        lastTimingMetrics = nil
        didVerifyPlaybackStart = false
        didFinishPlayingNaturally = false
        hasRecordedFirstPlayMetric = false
        return activeLoadGeneration
    }

    private func failLoad(reason: MPVAudioFailureReason, diagnostic: String?) {
        waveformTask?.cancel()
        waveformTask = nil
        cancelWaveformWindowTasksInternal()
        isExtractingWaveform = false
        waveformSamples = []
        waveformSamplingMode = nil
        waveformPrecisionStatus = nil
        isWaveformCompletenessVerified = false
        isVerifiedDigitalSilence = false
        currentLevel = 0.0
        isPlaying = false
        isBuffering = false
        duration = 0
        currentTime = 0
        failureReason = reason
        diagnosticDetail = diagnostic
    }

    private func attemptBoundedDataFallback(
        url: URL,
        ext: String,
        fileSize: Int64,
        initialError: any Error,
        generation: UInt64,
        urlInitMs: Double,
        loadStartNanos: UInt64
    ) {
        let baseFailure = Self.classifyPlaybackFailure(url: url, formatHint: ext, error: initialError)
        guard fileSize <= Self.maxInMemoryFallbackBytes else {
            let sizeText = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
            failLoad(
                reason: .fallbackBudgetExceeded(
                    baseReason: baseFailure.reason,
                    sizeText: sizeText,
                    budgetText: "4 MB"
                ),
                diagnostic: baseFailure.diagnostic
            )
            return
        }

        let fallbackStart = DispatchTime.now().uptimeNanoseconds
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
            failLoad(reason: baseFailure.reason, diagnostic: baseFailure.diagnostic)
            return
        }

        do {
            let player = try Self.makePlayer(from: data, formatHint: ext)
            let fallbackMs = Self.elapsedMs(since: fallbackStart)
            configurePlayer(
                player,
                sourceURL: url,
                sourceData: data,
                fileSize: fileSize,
                generation: generation,
                urlInitMs: urlInitMs,
                fallbackMs: fallbackMs,
                usedFallback: true,
                loadStartNanos: loadStartNanos
            )
        } catch {
            let failure = Self.classifyPlaybackFailure(url: url, formatHint: ext, error: error)
            failLoad(reason: failure.reason, diagnostic: failure.diagnostic)
        }
    }

    private static func makePlayer(from data: Data, formatHint: String?) throws -> AVAudioPlayer {
        if let hint = formatHint, !hint.isEmpty {
            if let hintedPlayer = try? AVAudioPlayer(data: data, fileTypeHint: hint) {
                return hintedPlayer
            }
        }
        return try AVAudioPlayer(data: data)
    }

    private static func validatedFileSize(
        for url: URL,
        onFailure: (MPVAudioFailureReason, String) -> Void
    ) -> Int64? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            onFailure(.fileNotFound(fileName: url.lastPathComponent), "ENOENT: \(url.path)")
            return nil
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            ?? ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        guard size > 0 else {
            onFailure(.emptyAudioFile(fileName: url.lastPathComponent), "Zero-byte file: \(url.path)")
            return nil
        }
        return size
    }

    private func configurePlayer(
        _ player: AVAudioPlayer,
        sourceURL: URL?,
        sourceData: Data?,
        fileSize: Int64,
        generation: UInt64,
        urlInitMs: Double,
        fallbackMs: Double,
        usedFallback: Bool,
        loadStartNanos: UInt64
    ) {
        guard player.duration > 0 || player.numberOfChannels > 0 else {
            failLoad(reason: .noPlayableChannelsOrDuration, diagnostic: "duration=0, channels=0")
            return
        }
        player.delegate = self
        player.isMeteringEnabled = true
        player.enableRate = true
        player.volume = isMuted ? 0 : Float(self.volume)
        player.rate = Float(self.playbackSpeed)

        let shouldPrepare = fileSize <= Self.maxSynchronousPrepareBytes
        let prepareStart = DispatchTime.now().uptimeNanoseconds
        let didPrepare = shouldPrepare ? player.prepareToPlay() : false
        let prepareMs = shouldPrepare ? Self.elapsedMs(since: prepareStart) : 0.0
        let totalLoadMs = Self.elapsedMs(since: loadStartNanos)

        self.lastTimingMetrics = MPVAudioLoadTimingMetrics(
            urlInitDurationMs: urlInitMs,
            dataFallbackDurationMs: fallbackMs,
            prepareDurationMs: prepareMs,
            firstPlayDurationMs: 0.0,
            totalLoadDurationMs: totalLoadMs,
            usedDataFallback: usedFallback,
            didPrepareSynchronously: didPrepare,
            fileSizeBytes: fileSize
        )

        self.audioPlayer = player
        self.duration = player.duration
        self.currentTime = 0
        self.currentLevel = 0.0
        self.metadata = MPVAudioMetadata()
        self.channelsFormatted = "\(player.numberOfChannels) ch"
        self.sampleRateFormatted = String(format: "%.1f kHz", player.format.sampleRate / 1000.0)
        if fileSize > 0, player.duration > 0.05 {
            let kbps = Int((Double(fileSize) * 8.0 / player.duration) / 1000.0)
            self.bitrateFormatted = kbps > 0 ? "\(kbps) kbps" : "--"
        } else {
            self.bitrateFormatted = "--"
        }
        let ext = sourceURL?.pathExtension.lowercased() ?? ""
        if let verified = Self.verifiedCorpusFormatSpecs[ext] {
            self.codecFormatted = verified.codecName
        } else {
            self.codecFormatted = ext.isEmpty ? "PCM Audio" : "\(ext.uppercased()) Native Audio"
        }

        self.isBuffering = false
        startWaveformExtraction(url: sourceURL, data: sourceData, generation: generation)
    }

    private func startWaveformExtraction(url: URL?, data: Data?, generation: UInt64) {
        waveformTask?.cancel()
        waveformSamples = []
        waveformSamplingMode = nil
        waveformPrecisionStatus = nil
        isWaveformCompletenessVerified = false
        isVerifiedDigitalSilence = false
        isExtractingWaveform = true

        waveformTask = Task { @MainActor [weak self] in
            var analysis: AudioWaveformAnalysis?
            if let url {
                analysis = await AudioWaveformExtractor.shared.extractWaveformAnalysis(
                    from: url,
                    targetSampleCount: 1600
                )
            }
            if analysis == nil, let data {
                analysis = await AudioWaveformExtractor.shared.extractWaveformAnalysis(
                    from: data,
                    targetSampleCount: 1600
                )
            }
            guard !Task.isCancelled, let self, self.activeLoadGeneration == generation else { return }
            self.applyExtractedWaveformAnalysis(analysis)
        }
    }

    private func applyExtractedWaveformAnalysis(_ analysis: AudioWaveformAnalysis?) {
        waveformSamples = analysis?.peaks ?? []
        waveformSamplingMode = analysis?.samplingMode
        waveformPrecisionStatus = analysis?.precisionStatus
        isWaveformCompletenessVerified = analysis?.isCompletenessVerified ?? false
        isVerifiedDigitalSilence = analysis?.isVerifiedDigitalSilence ?? false
        if let rawMax = analysis?.rawMaxPeak, rawMax > 0 {
            waveformReferencePeak = max(rawMax, AudioWaveformWindowLimits.normalizationReferenceFloor)
        }
        isExtractingWaveform = false
    }

    private func startTimer() {
        playbackLoopTask?.cancel()
        playbackLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, let self, let player = self.audioPlayer else { break }
                self.currentTime = player.currentTime
                self.isPlaying = player.isPlaying

                if player.isPlaying {
                    player.updateMeters()
                    let channels = max(1, player.numberOfChannels)
                    var peakLinear: Float = 0.0
                    for ch in 0..<channels {
                        let power = player.averagePower(forChannel: ch)
                        let linear = pow(10.0, power / 20.0)
                        if linear.isFinite && linear > peakLinear {
                            peakLinear = linear
                        }
                    }
                    self.currentLevel = peakLinear.clamped(to: 0.0...1.0)
                } else {
                    self.currentLevel = 0.0
                    break
                }
            }
        }
    }

    public func play() {
        guard let player = audioPlayer, !hasPlaybackError else { return }
        player.rate = Float(playbackSpeed)
        didFinishPlayingNaturally = false
        let playStart = DispatchTime.now().uptimeNanoseconds
        let started = player.play()
        let playMs = Self.elapsedMs(since: playStart)
        if !hasRecordedFirstPlayMetric, var metrics = lastTimingMetrics {
            metrics.firstPlayDurationMs = playMs
            lastTimingMetrics = metrics
            hasRecordedFirstPlayMetric = true
        }
        if started {
            isPlaying = true
            didVerifyPlaybackStart = true
            startTimer()
        } else {
            isPlaying = false
            currentLevel = 0.0
            failureReason = .outputEngineStartFailed
            diagnosticDetail = "AVAudioPlayer.play() returned false"
        }
    }

    public func pause() {
        playbackLoopTask?.cancel()
        playbackLoopTask = nil
        audioPlayer?.pause()
        isPlaying = false
        currentLevel = 0.0
    }

    public func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    public func seek(to time: Double) {
        guard let player = audioPlayer else { return }
        player.currentTime = max(0, min(duration, time))
        self.currentTime = player.currentTime
    }

    public func seekBy(_ delta: Double) {
        seek(to: currentTime + delta)
    }

    public func stop() {
        activeLoadGeneration &+= 1
        teardownActiveSession()
        currentURL = nil
        activeOwnerSessionID = nil
        activeResourceVersion = nil
    }

    /// Stops playback only if the currently active session matches `url`, `generation`, and `sessionID`.
    /// Prevents an outgoing view A from stopping a newly mounted view B, even when both views inspect the same URL.
    public func stopIfCurrent(
        url: URL,
        generation: UInt64? = nil,
        sessionID: String? = nil
    ) {
        guard let current = currentURL,
              current.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath() else {
            return
        }
        if let generation, activeLoadGeneration != generation {
            return
        }
        if let activeOwner = activeOwnerSessionID {
            guard sessionID == activeOwner else { return }
        } else if sessionID != nil {
            return
        }
        stop()
    }

    internal func cancelWaveformWindowTasksInternal() {
        activeWindowTask?.cancel()
        activeWindowTask = nil
        windowPrefetchTask?.cancel()
        windowPrefetchTask = nil
        isExtractingWaveformWindow = false
        activeWaveformWindowTile = nil
        lastWaveformWindowError = nil
        lastQuantizedWindowStepIndex = nil
    }

    private func teardownActiveSession() {
        let oldURL = currentURL
        let oldSession = activeOwnerSessionID
        playbackLoopTask?.cancel()
        playbackLoopTask = nil
        waveformTask?.cancel()
        waveformTask = nil
        cancelWaveformWindowTasksInternal()
        if let oldSession {
            Task { await AudioWaveformWindowExtractor.shared.cancelRequests(forOwnerSessionID: oldSession) }
        } else if let oldURL {
            Task { await AudioWaveformWindowExtractor.shared.cancelRequests(forURL: oldURL) }
        }
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        isBuffering = false
        isExtractingWaveform = false
        didFinishPlayingNaturally = false
        currentLevel = 0.0
        waveformSamples = []
        waveformSamplingMode = nil
        waveformPrecisionStatus = nil
        isWaveformCompletenessVerified = false
        isVerifiedDigitalSilence = false
        currentTime = 0
        duration = 0
        metadata = nil
        codecFormatted = "--"
        bitrateFormatted = "--"
        sampleRateFormatted = "--"
        channelsFormatted = "--"
    }

    public func setVolume(_ vol: Double) {
        self.volume = max(0, min(1, vol))
        audioPlayer?.volume = isMuted ? 0 : Float(self.volume)
    }

    public func toggleMute() {
        isMuted.toggle()
        audioPlayer?.volume = isMuted ? 0 : Float(self.volume)
    }

    public func setPlaybackSpeed(_ speed: Double) {
        self.playbackSpeed = speed
        audioPlayer?.rate = Float(speed)
    }

    nonisolated private static func unsupportedFailureReason(forExtension ext: String) -> MPVAudioFailureReason? {
        let normalized = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        if normalized == "mid" || normalized == "midi" {
            return .requiresSynthesizer(extensionLabel: ".\(normalized)")
        }
        if let formatName = unsupportedFormatNames[normalized] {
            return .unsupportedCodec(formatName: formatName, extensionLabel: ".\(normalized)")
        }
        return nil
    }

    nonisolated private static func classifyPlaybackFailure(
        url: URL?,
        formatHint: String?,
        error: any Error
    ) -> (reason: MPVAudioFailureReason, diagnostic: String) {
        let ext = (url?.pathExtension ?? formatHint ?? "").lowercased()
        let nsError = error as NSError
        let rawDiag = "\(nsError.domain) (\(nsError.code)): \(error.localizedDescription)"
        if let knownReason = unsupportedFailureReason(forExtension: ext) {
            return (knownReason, rawDiag)
        }

        let label = ext.isEmpty ? "audio" : ".\(ext)"
        switch nsError.code {
        case 1954115647, 1718449215:
            return (.unsupportedStreamFormat(label: label), rawDiag)
        case 1685348671, 1684369471:
            return (.corruptStream(label: label), rawDiag)
        default:
            return (.loadFailed(label: label, underlyingDescription: error.localizedDescription), rawDiag)
        }
    }

    nonisolated private static func elapsedMs(since startNanos: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= startNanos else { return 0.0 }
        return Double(now - startNanos) / 1_000_000.0
    }

    // MARK: - AVAudioPlayerDelegate
    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer.map(ObjectIdentifier.init) == playerID else { return }
            self.playbackLoopTask?.cancel()
            self.playbackLoopTask = nil
            self.isPlaying = false
            self.currentLevel = 0.0
            self.currentTime = self.duration
            self.didFinishPlayingNaturally = flag
        }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let playerID = ObjectIdentifier(player)
        let detail = error?.localizedDescription ?? "AVAudioPlayer decode error callback"
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer.map(ObjectIdentifier.init) == playerID else { return }
            self.playbackLoopTask?.cancel()
            self.playbackLoopTask = nil
            self.isPlaying = false
            self.isBuffering = false
            self.currentLevel = 0.0
            self.failureReason = .playbackDecodeError
            self.diagnosticDetail = detail
        }
    }

    isolated deinit {
        playbackLoopTask?.cancel()
        waveformTask?.cancel()
        activeWindowTask?.cancel()
        windowPrefetchTask?.cancel()
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
