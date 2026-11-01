// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import CoreMedia
import Foundation
import TTI18nCore
import TTI18nUI

// MARK: - Independent V2 Video Interaction & Rotation Localization Keys (TTI18n)

/// Independent localized vocabulary for V2 video player context menus, display rotation, and format explanations.
public enum VideoInteractionLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case rotationMenu = "media.video.v2.rotationMenu"
    case rotateClockwise = "media.video.v2.rotateClockwise"
    case rotateCounterClockwise = "media.video.v2.rotateCounterClockwise"
    case rotate180 = "media.video.v2.rotate180"
    case resetOrientation = "media.video.v2.resetOrientation"
    case formatDetails = "media.video.v2.formatDetails"
    case sourceFormat = "media.video.v2.sourceFormat"
    case outputFormat = "media.video.v2.outputFormat"
    case outputConfirmedHDR = "media.video.v2.outputConfirmedHDR"
    case outputConfirmedSDRToneMapped = "media.video.v2.outputConfirmedSDRToneMapped"
    case outputConfirmedSDR = "media.video.v2.outputConfirmedSDR"
    case outputUnconfirmed = "media.video.v2.outputUnconfirmed"
    case sourceSectionTitle = "media.video.v2.sourceSectionTitle"
    case outputSectionTitle = "media.video.v2.outputSectionTitle"
    case notProvided = "media.video.v2.notProvided"
    case fieldCodecProfile = "media.video.v2.fieldCodecProfile"
    case fieldResolutionFps = "media.video.v2.fieldResolutionFps"
    case fieldBitDepthChroma = "media.video.v2.fieldBitDepthChroma"
    case fieldColorPrimaries = "media.video.v2.fieldColorPrimaries"
    case fieldTransferFunction = "media.video.v2.fieldTransferFunction"
    case fieldYCbCrMatrix = "media.video.v2.fieldYCbCrMatrix"
    case fieldSourceDynamicRange = "media.video.v2.fieldSourceDynamicRange"
    case fieldHDRMetadata = "media.video.v2.fieldHDRMetadata"
    case fieldActiveOutput = "media.video.v2.fieldActiveOutput"
    case fieldToneMapping = "media.video.v2.fieldToneMapping"
    case fieldRendererPipeline = "media.video.v2.fieldRendererPipeline"
    case fieldScreenHeadroom = "media.video.v2.fieldScreenHeadroom"
    case fieldOpticalBoundary = "media.video.v2.fieldOpticalBoundary"
    case opticalBoundaryNote = "media.video.v2.opticalBoundaryNote"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let entry = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return entry.zhHans
        case .zhHant: return entry.zhHant
        default: return entry.en
        }
    }

    private static let translations: [Self: (en: String, zhHans: String, zhHant: String)] = [
        .rotationMenu: ("Rotate", "旋转", "旋轉"),
        .rotateClockwise: (
            "Rotate 90° Clockwise",
            "顺时针旋转 90°",
            "順時針旋轉 90°"
        ),
        .rotateCounterClockwise: (
            "Rotate 90° Counterclockwise",
            "逆时针旋转 90°",
            "逆時針旋轉 90°"
        ),
        .rotate180: (
            "Rotate 180°",
            "旋转 180°",
            "旋轉 180°"
        ),
        .resetOrientation: (
            "Reset Orientation",
            "恢复原方向",
            "恢復原方向"
        ),
        .formatDetails: (
            "Source & Output Format",
            "源参数与当前输出对照",
            "來源參數與目前輸出對照"
        ),
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
        .sourceSectionTitle: (
            "Source Native Parameters",
            "源参数（视频原生证据）",
            "來源參數（影片原生證據）"
        ),
        .outputSectionTitle: (
            "Current Rendering & Output",
            "当前输出（渲染与屏幕观察）",
            "目前輸出（渲染與螢幕觀察）"
        ),
        .notProvided: (
            "Not provided",
            "未提供",
            "未提供"
        ),
        .fieldCodecProfile: (
            "Codec / Profile",
            "编码 / Profile",
            "編碼 / Profile"
        ),
        .fieldResolutionFps: (
            "Dimensions / Frame Rate",
            "像素尺寸 / 帧率",
            "像素尺寸 / 幀率"
        ),
        .fieldBitDepthChroma: (
            "Bit Depth / Chroma",
            "位深 / 色度采样",
            "位元深度 / 色度取樣"
        ),
        .fieldColorPrimaries: (
            "Color Primaries",
            "原色 (Primaries)",
            "原色 (Primaries)"
        ),
        .fieldTransferFunction: (
            "Transfer Function",
            "传递函数 (Transfer)",
            "傳遞函數 (Transfer)"
        ),
        .fieldYCbCrMatrix: (
            "Matrix / Color Range",
            "矩阵系数 / 色彩范围",
            "矩陣係數 / 色彩範圍"
        ),
        .fieldSourceDynamicRange: (
            "Source Dynamic Range",
            "源动态范围",
            "來源動態範圍"
        ),
        .fieldHDRMetadata: (
            "Static / Dynamic Metadata",
            "静态 / 动态 HDR 元数据",
            "靜態 / 動態 HDR 元數據"
        ),
        .fieldActiveOutput: (
            "Current Output",
            "当前渲染输出",
            "目前渲染輸出"
        ),
        .fieldToneMapping: (
            "Color Mapping",
            "色彩映射状态",
            "色彩映射狀態"
        ),
        .fieldRendererPipeline: (
            "Renderer / Sample Attachments",
            "渲染器与样本附件",
            "渲染器與樣本附件"
        ),
        .fieldScreenHeadroom: (
            "Screen Capability (Upper Bound)",
            "所属屏幕能力上限",
            "所屬螢幕能力上限"
        ),
        .fieldOpticalBoundary: (
            "Hardware Optical Layer Boundary",
            "硬件光学输出层级边界",
            "硬體光學輸出層級邊界"
        ),
        .opticalBoundaryNote: (
            "AVSampleBufferDisplayLayer submits frames and EDR metadata to macOS WindowServer/CoreAnimation. Screen EDR headroom is an upper bound only; physical panel optical output cannot be directly measured in software.",
            "AVSampleBufferDisplayLayer 向 macOS WindowServer/CoreAnimation 提交帧与 EDR 配置；屏幕亮度 Headroom 仅为能力上限，不能单独证明最终光学输出，物理面板最终光学输出不可在软件层直接测量。",
            "AVSampleBufferDisplayLayer 向 macOS WindowServer/CoreAnimation 提交幀與 EDR 配置；螢幕亮度 Headroom 僅為能力上限，不能單獨證明最終光學輸出，物理面板最終光學輸出不可在軟體層直接測量。"
        )
    ]
}

/// Resolves V2 interaction vocabulary through the shared `TTI18n` localization state.
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
