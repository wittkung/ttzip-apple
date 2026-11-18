// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CoreMedia
import Foundation
import TTI18nCore
import TTI18nUI

// MARK: - Video Format Evidence Localization

/// Localized summaries of source evidence and observed video output.
public enum VideoInteractionLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case sourceFormat = "media.video.v2.sourceFormat"
    case outputFormat = "media.video.v2.outputFormat"
    case outputConfirmedHDR = "media.video.v2.outputConfirmedHDR"
    case outputConfirmedSDRToneMapped = "media.video.v2.outputConfirmedSDRToneMapped"
    case outputConfirmedSDR = "media.video.v2.outputConfirmedSDR"
    case outputUnconfirmed = "media.video.v2.outputUnconfirmed"
    case notProvided = "media.video.v2.notProvided"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let entry = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return entry.zhHans
        case .zhHant: return entry.zhHant
        default: return entry.en
        }
    }

    private static let translations: [Self: (en: String, zhHans: String, zhHant: String)] = [
        .sourceFormat: (
            "Source: %@",
            "源格式: %@",
            "來源格式: %@"
        ),
        .outputFormat: (
            "Output: %@",
            "当前输出: %@",
            "目前輸出: %@"
        ),
        .outputConfirmedHDR: (
            "HDR (EDR Confirmed)",
            "HDR（EDR 已确认）",
            "HDR（EDR 已確認）"
        ),
        .outputConfirmedSDRToneMapped: (
            "SDR (Tone-Mapped)",
            "SDR（已确认色调映射）",
            "SDR（已確認色調映射）"
        ),
        .outputConfirmedSDR: (
            "SDR",
            "SDR",
            "SDR"
        ),
        .outputUnconfirmed: (
            "Unconfirmed",
            "未确认",
            "未確認"
        ),
        .notProvided: (
            "Not provided",
            "未提供",
            "未提供"
        )
    ]
}

/// Resolves shared source and output format summaries.
@MainActor
public enum VideoInteractionLocalization {
    public static func text(_ key: VideoInteractionLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    public static func format(_ key: VideoInteractionLocaleKey, _ args: CVarArg...) -> String {
        let template = LocalizationState.shared.t(key)
        return String(format: template, arguments: args)
    }
}

// MARK: - VideoFormatPresentationState Disaggregated Format & Dynamic Range Extensions

extension VideoFormatPresentationState {
    /// Human-readable description of the video source's dynamic range.
    /// Missing evidence returns localized "Not provided" and never guesses SDR.
    @MainActor
    public var sourceDynamicRangeDescription: String {
        switch sourceDynamicRange {
        case .dolbyVision:
            if let profile = dolbyVisionProfile {
                if let level = dolbyVisionLevel {
                    return "Dolby Vision (Profile \(profile), Level \(level))"
                }
                return "Dolby Vision (Profile \(profile))"
            }
            return "Dolby Vision"
        case .hdr10:
            return "HDR10"
        case .hlg:
            return "HLG"
        case .sdr:
            return "SDR"
        case .unknown:
            return VideoInteractionLocalization.text(.notProvided)
        }
    }

    /// Human-readable description of current presentation output dynamic range.
    @MainActor
    public var outputDynamicRangeDescription: String {
        if isToneMappedFallbackToSDR {
            if sourceDynamicRange.isHDR {
                return "\(sourceDynamicRange.rawValue) → \(VideoInteractionLocalization.text(.outputConfirmedSDRToneMapped))"
            }
            return VideoInteractionLocalization.text(.outputConfirmedSDRToneMapped)
        }
        switch activeOutputDynamicRange {
        case .hdr10, .hlg, .dolbyVision:
            return "\(activeOutputDynamicRange.rawValue) · \(VideoInteractionLocalization.text(.outputConfirmedHDR))"
        case .sdr:
            return VideoInteractionLocalization.text(.outputConfirmedSDR)
        case .unknown:
            switch outputObservationStatus {
            case .detecting:
                return VideoPlaybackLocalization.text(.formatBadgeDetectingOutput)
            case .diagnostic(let reason):
                return "\(VideoInteractionLocalization.text(.outputUnconfirmed))（\(reason)）"
            case .confirmed(let mode):
                return mode != .unknown ? mode.rawValue : VideoInteractionLocalization.text(.outputUnconfirmed)
            }
        }
    }

    /// Disaggregated detailed format summary separating source dynamic range from confirmed display output.
    @MainActor
    public var detailedFormatSummary: String {
        let src = VideoInteractionLocalization.format(.sourceFormat, sourceDynamicRangeDescription)
        let out = VideoInteractionLocalization.format(.outputFormat, outputDynamicRangeDescription)
        if let res = resolutionTierLabel, let codec = codecLabel, !codec.isEmpty {
            let normalizedCodec = Self.normalizeCodecDisplayLabel(codec)
            return "\(res) · \(normalizedCodec) | \(src) | \(out)"
        }
        return "\(src) | \(out)"
    }

    /// Guaranteed non-nil, non-empty short output badge text representing ONLY the currently observed rendering/output dynamic range.
    @MainActor
    public var alwaysAvailableBadgeText: String {
        if let explicitBadgeText, !explicitBadgeText.isEmpty {
            return explicitBadgeText
        }
        return Self.composeBadgeText(
            codecLabel: codecLabel,
            width: width,
            height: height,
            sourceDynamicRange: sourceDynamicRange,
            activeOutputDynamicRange: activeOutputDynamicRange,
            isToneMappedFallbackToSDR: isToneMappedFallbackToSDR,
            outputObservationStatus: outputObservationStatus,
            detectingLabel: VideoPlaybackLocalization.text(.formatBadgeDetectingOutput),
            diagnosticLabel: VideoPlaybackLocalization.text(.formatBadgeDiagnosticUnconfirmed)
        )
    }

    /// Formats source resolution/codec alongside current output with explicit naming (`Source ... | Output ...`).
    @MainActor
    public var namedSourceAndOutputBadgeText: String {
        Self.composeBadgeText(
            codecLabel: codecLabel,
            width: width,
            height: height,
            sourceDynamicRange: sourceDynamicRange,
            activeOutputDynamicRange: activeOutputDynamicRange,
            isToneMappedFallbackToSDR: isToneMappedFallbackToSDR,
            outputObservationStatus: outputObservationStatus,
            includeNamedSourcePrefix: true,
            detectingLabel: VideoPlaybackLocalization.text(.formatBadgeDetectingOutput),
            diagnosticLabel: VideoPlaybackLocalization.text(.formatBadgeDiagnosticUnconfirmed)
        )
    }
}

// MARK: - VideoPlaybackSession Display Rotation & Action Extensions

extension VideoPlaybackSession {
    /// Rotates video presentation clockwise by 90 degrees (presentation-only, source file untouched).
    public func rotateClockwise() {
        userRotationDegrees = VideoContentGeometry.normalizedRotationDegrees(userRotationDegrees + 90)
    }

    /// Rotates video presentation counterclockwise by 90 degrees (presentation-only, source file untouched).
    public func rotateCounterClockwise() {
        userRotationDegrees = VideoContentGeometry.normalizedRotationDegrees(userRotationDegrees + 270)
    }

    /// Rotates video presentation by 180 degrees (presentation-only, source file untouched).
    public func rotate180() {
        userRotationDegrees = VideoContentGeometry.normalizedRotationDegrees(userRotationDegrees + 180)
    }

    /// Resets presentation rotation back to original zero degree orientation.
    public func resetRotation() {
        userRotationDegrees = 0
    }

    /// Toggles play and pause state without triggering any splash HUD overlay.
    public func togglePlayPauseWithoutHUD() {
        guard let activeController else { return }
        activeController.togglePlayPause()
        isPlaying = activeController.userPlaybackIntent || activeController.isPlaying
    }
}
