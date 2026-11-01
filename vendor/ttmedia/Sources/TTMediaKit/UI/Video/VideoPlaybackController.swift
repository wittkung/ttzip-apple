// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AVFoundation
import CoreMedia
import Foundation
import TTI18nCore
import TTI18nUI

@MainActor
internal enum VideoPlaybackController {
    case native(AVAssetReaderPlaybackController)
    case worker(AVSampleBufferWorkerPlaybackController)

    var identity: ObjectIdentifier {
        switch self {
        case .native(let controller): ObjectIdentifier(controller)
        case .worker(let controller): ObjectIdentifier(controller)
        }
    }
    var identityDescription: String {
        String(describing: identity)
    }
    var displayLayer: AVSampleBufferDisplayLayer {
        switch self {
        case .native(let c): return c.displayLayer
        case .worker(let c): return c.coordinator.displayLayer
        }
    }
    var synchronizer: AVSampleBufferRenderSynchronizer {
        switch self {
        case .native(let c): return c.synchronizer
        case .worker(let c): return c.coordinator.synchronizer
        }
    }
    var audioRenderer: AVSampleBufferAudioRenderer {
        switch self {
        case .native(let c): return c.audioRenderer
        case .worker(let c): return c.audioPipeline.audioRenderer
        }
    }
    var isPlaying: Bool {
        switch self {
        case .native(let c): return c.isPlaying
        case .worker(let c): return c.isPlaying
        }
    }
    var userPlaybackIntent: Bool {
        switch self {
        case .native(let c): return c.userPlaybackIntent
        case .worker(let c): return c.userPlaybackIntent
        }
    }
    var seekGeneration: UInt64 {
        switch self {
        case .native(let c): return c.seekGeneration
        case .worker(let c): return c.seekGeneration
        }
    }
    var naturalVideoSize: CGSize {
        switch self {
        case .native(let c): return c.naturalSize
        case .worker(let c): return c.naturalVideoSize
        }
    }
    var rawVideoNaturalSize: CGSize? {
        switch self {
        case .native(let c): return c.rawVideoNaturalSize
        case .worker(let c): return c.rawVideoNaturalSize
        }
    }
    var videoPixelAspectRatio: CGSize {
        switch self {
        case .native(let c): return c.videoPixelAspectRatio
        case .worker(let c): return c.videoPixelAspectRatio
        }
    }
    var videoRotationDegrees: Int {
        switch self {
        case .native(let c): return c.videoRotationDegrees
        case .worker(let c): return c.videoRotationDegrees
        }
    }
    var catalogSubtitleTracks: [TTMediaSubtitleTrackInfo] {
        switch self {
        case .native: return []
        case .worker(let c): return c.catalogSubtitleTracks
        }
    }
    var formatPresentationState: VideoFormatPresentationState {
        switch self {
        case .native(let c): return c.formatPresentationState
        case .worker(let c): return c.formatPresentationState
        }
    }
    var duration: CMTime {
        switch self {
        case .native(let c): return c.duration
        case .worker(let c): return c.duration
        }
    }
    var volume: Float {
        switch self {
        case .native(let c): return c.audioRenderer.volume
        case .worker(let c): return c.audioPipeline.audioRenderer.volume
        }
    }
    func setVolume(_ vol: Float) {
        let clamped = max(0.0, min(1.0, vol))
        switch self {
        case .native(let c):
            c.volume = clamped
            c.audioRenderer.volume = clamped
        case .worker(let c):
            c.coordinator.volume = clamped
            c.audioPipeline.audioRenderer.volume = clamped
        }
    }
    var isMuted: Bool {
        switch self {
        case .native(let c): return c.audioRenderer.isMuted
        case .worker(let c): return c.coordinator.isMuted
        }
    }
    func setMuted(_ muted: Bool) {
        switch self {
        case .native(let c):
            c.audioRenderer.isMuted = muted
        case .worker(let c):
            c.coordinator.isMuted = muted
            c.audioPipeline.isMuted = muted
        }
    }
    var playbackRate: Float {
        switch self {
        case .native(let c): return c.playbackRate
        case .worker(let c): return c.coordinator.playbackRate
        }
    }
    func setPlaybackRate(_ rate: Float) {
        switch self {
        case .native(let c): c.playbackRate = rate
        case .worker(let c): c.coordinator.playbackRate = rate
        }
    }
    func togglePlayPause() {
        switch self {
        case .native(let c): c.togglePlayPause()
        case .worker(let c): c.togglePlayPause()
        }
    }
    func stop() {
        switch self {
        case .native(let c): c.stop()
        case .worker(let c): c.teardown()
        }
    }
    func seek(to time: CMTime) {
        switch self {
        case .native(let c):
            c.seek(to: time)
        case .worker(let c):
            c.requestSeek(to: CMTimeGetSeconds(time))
        }
    }
    func setOnTimeUpdate(_ block: @escaping @MainActor (CMTime) -> Void) {
        switch self {
        case .native(let c): c.onTimeUpdate = block
        case .worker(let c): c.onTimeUpdate = block
        }
    }
    func setOnPlaybackEnded(_ block: @escaping @MainActor () -> Void) {
        switch self {
        case .native(let c): c.onPlaybackEnded = block
        case .worker(let c): c.onPlaybackEnded = block
        }
    }
    func setOnError(_ block: @escaping @MainActor (Error) -> Void) {
        switch self {
        case .native(let c): c.onError = block
        case .worker(let c): c.onError = block
        }
    }
    func setOnFirstVideoFrameEnqueued(_ block: @escaping @MainActor (CMTime) -> Void) {
        switch self {
        case .native(let c): c.onFirstVideoFrameEnqueued = block
        case .worker(let c): c.onFirstVideoFrameEnqueued = block
        }
    }
    func setOnSeekCompleted(_ block: @escaping @MainActor (CMTime, UInt64) -> Void) {
        switch self {
        case .native(let c): c.onSeekCompleted = block
        case .worker(let c): c.onSeekCompleted = block
        }
    }
    func setOnFormatPresentationStateChanged(_ block: @escaping @MainActor (VideoFormatPresentationState) -> Void) {
        switch self {
        case .native(let c): c.onFormatPresentationStateChanged = block
        case .worker(let c): c.onFormatPresentationStateChanged = block
        }
    }
    func clearCallbacks() {
        switch self {
        case .native(let c):
            c.onTimeUpdate = nil
            c.onPlaybackEnded = nil
            c.onError = nil
            c.onFirstVideoFrameEnqueued = nil
            c.onSeekCompleted = nil
            c.onFormatPresentationStateChanged = nil
        case .worker(let c):
            c.onTimeUpdate = nil
            c.onPlaybackEnded = nil
            c.onError = nil
            c.onFirstVideoFrameEnqueued = nil
            c.onSeekCompleted = nil
            c.onFormatPresentationStateChanged = nil
        }
    }
}

@MainActor
internal enum VideoPlaybackFaultFormatter {
    static func classifyFatalError(_ error: Error) -> VideoPlaybackFaultCategory {
        if let fatal = error as? AVSampleBufferFatalPlaybackError {
            switch fatal {
            case .workerCrashed:
                return .workerCrashed
            case .containerCorrupted:
                return .containerCorrupted
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && (4097...4099).contains(nsError.code) {
            return .workerCrashed
        }
        let lowered = nsError.localizedDescription.lowercased()
        if lowered.contains("xpc") || lowered.contains("connection interrupted") || lowered.contains("connection invalid") || lowered.contains("worker") {
            return .workerCrashed
        }
        return .containerCorrupted
    }

    static func describeAudioFault(_ fault: AVSampleBufferAudioFault) -> String {
        let codecLabel = (fault.codecName?.isEmpty == false) ? (fault.codecName ?? "unknown") : "unknown"
        switch fault.kind {
        case .unsupportedAudioTrack:
            return String(
                format: LocalizationState.shared.t(PlaybackFaultLocaleKey.unsupportedAudioTrackDetail),
                codecLabel
            )
        case .audioInitializationFailed:
            return String(
                format: LocalizationState.shared.t(PlaybackFaultLocaleKey.audioInitFailedDetail),
                codecLabel
            )
        }
    }

    static func describeFatalPlaybackError(
        _ error: Error,
        category: VideoPlaybackFaultCategory
    ) -> String {
        if let fatal = error as? AVSampleBufferFatalPlaybackError,
           let localized = fatal.errorDescription {
            return localized
        }
        switch category {
        case .workerCrashed:
            let prefix = LocalizationState.shared.t(PlaybackFaultLocaleKey.workerCrashed)
            return "\(prefix) (\(error.localizedDescription))"
        case .containerCorrupted, .unsupportedAudioTrack, .audioInitializationFailed:
            let prefix = LocalizationState.shared.t(PlaybackFaultLocaleKey.containerCorrupted)
            return "\(prefix) (\(error.localizedDescription))"
        }
    }
}

/// Supplemental localized vocabulary for V2 audio fault isolation and playback error feedback.
internal enum PlaybackFaultLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case unsupportedAudioTrack = "media.audio.fault.unsupported_track"
    case unsupportedAudioTrackDetail = "media.audio.fault.unsupported_track.detail"
    case audioInitFailed = "media.audio.fault.init_failed"
    case audioInitFailedDetail = "media.audio.fault.init_failed.detail"
    case containerCorrupted = "media.playback.fault.container_corrupted"
    case workerCrashed = "media.playback.fault.worker_crashed"

    func fallbackTranslation(for language: AppLanguage) -> String {
        guard let values = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return values.zh
        case .zhHant: return values.hant
        default: return values.en
        }
    }

    private static let translations: [Self: (en: String, zh: String, hant: String)] = [
        .unsupportedAudioTrack: (
            "Audio track format is not supported; playing video without audio.",
            "当前音轨格式暂不支持，已静音继续播放视频。",
            "目前音軌格式暫不支援，已靜音繼續播放影片。"
        ),
        .unsupportedAudioTrackDetail: (
            "Unsupported audio track (%@) — playing video without audio.",
            "不支持的音轨格式（%@）— 已静音继续播放视频。",
            "不支援的音軌格式（%@）— 已靜音繼續播放影片。"
        ),
        .audioInitFailed: (
            "Audio decoder could not be initialized; playing video without audio.",
            "音频解码器初始化失败，已静音继续播放视频。",
            "音訊解碼器初始化失敗，已靜音繼續播放影片。"
        ),
        .audioInitFailedDetail: (
            "Audio decoder initialization failed (%@) — playing video without audio.",
            "音频解码器初始化失败（%@）— 已静音继续播放视频。",
            "音訊解碼器初始化失敗（%@）— 已靜音繼續播放影片。"
        ),
        .containerCorrupted: (
            "Media container is corrupted or contains no playable video stream.",
            "媒体容器已损坏或不包含可播放的视频流。",
            "媒體容器已損毀或不包含可播放的視訊串流。"
        ),
        .workerCrashed: (
            "Media decoding service disconnected unexpectedly.",
            "媒体解码服务异常断开。",
            "媒體解碼服務異常中斷。"
        ),
    ]
}

