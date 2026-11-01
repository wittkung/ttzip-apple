// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import TTI18nCore
import TTI18nUI

// MARK: - Independent V2 Video Playback Localization Keys (TTI18n)

/// Localized vocabulary for V2 video playback presentation badges, silent loading, and status hints.
public enum VideoPlaybackLocaleKey: String, FallbackLocaleKeyProtocol, CaseIterable, Sendable {
    case preparingVideo = "media.video.v2.preparingVideo"
    case formatBadgeSDR = "media.video.v2.formatBadgeSDR"
    case formatBadgeHDR10 = "media.video.v2.formatBadgeHDR10"
    case formatBadgeHLG = "media.video.v2.formatBadgeHLG"
    case formatBadgeDolbyVision = "media.video.v2.formatBadgeDolbyVision"
    case formatBadgeUnknown = "media.video.v2.formatBadgeUnknown"
    case formatBadgeDetectingOutput = "media.video.v2.formatBadgeDetectingOutput"
    case formatBadgeDiagnosticUnconfirmed = "media.video.v2.formatBadgeDiagnosticUnconfirmed"
    case formatBadgeToneMappedFormat = "media.video.v2.formatBadgeToneMappedFormat"

    public func fallbackTranslation(for language: AppLanguage) -> String {
        guard let entry = Self.translations[self] else { return rawKey }
        switch language {
        case .zhHans: return entry.zhHans
        case .zhHant: return entry.zhHant
        default: return entry.en
        }
    }

    private static let translations: [Self: (en: String, zhHans: String, zhHant: String)] = [
        .preparingVideo: (
            "Loading video…",
            "正在加载视频…",
            "正在載入影片…"
        ),
        .formatBadgeSDR: ("SDR", "SDR", "SDR"),
        .formatBadgeHDR10: ("HDR10", "HDR10", "HDR10"),
        .formatBadgeHLG: ("HLG", "HLG", "HLG"),
        .formatBadgeDolbyVision: ("Dolby Vision", "杜比视界", "杜比視界"),
        .formatBadgeUnknown: ("Unknown", "未知动态范围", "未知動態範圍"),
        .formatBadgeDetectingOutput: (
            "Detecting Output",
            "正在检测输出",
            "正在檢測輸出"
        ),
        .formatBadgeDiagnosticUnconfirmed: (
            "Output Unconfirmed",
            "输出未确认",
            "輸出未確認"
        ),
        .formatBadgeToneMappedFormat: (
            "%@ → SDR",
            "%@ → SDR（色调映射）",
            "%@ → SDR（色調映射）"
        )
    ]
}

/// Resolves V2 video presentation vocabulary through the shared `TTI18n` localization state.
@MainActor
public enum VideoPlaybackLocalization {
    public static func text(_ key: VideoPlaybackLocaleKey) -> String {
        LocalizationState.shared.t(key)
    }

    public static func format(_ key: VideoPlaybackLocaleKey, _ args: CVarArg...) -> String {
        let template = LocalizationState.shared.t(key)
        return String(format: template, arguments: args)
    }
}

// MARK: - S1 Video Content Rect Geometry (Contract v1)

/// Computes the actual aspect-fitted video presentation rectangle inside a container viewport,
/// allowing S1 subtitle overlays to scale relative to the real video frame rather than letterbox bars.
///
/// Coordinate Space & Transform Invariant:
/// - Output `CGRect` is always in **player viewport local coordinates** (`0...viewportSize.width`, `0...viewportSize.height`).
/// - `pixelAspectRatio` and `rotationDegrees` (`{0, 90, 180, 270}`) are applied **at most once** when deriving
///   the oriented display size from unrotated coded `rawVideoSize`.
/// - When passing an explicit `videoContentRect` to `SubtitleOverlayView`, it already contains the oriented
///   aspect-fit result and must never be rotated or PAR-scaled a second time.
public enum VideoContentGeometry {
    public static let contractVersion = "v1"

    /// Normalizes arbitrary rotation angles in degrees to `{0, 90, 180, 270}`.
    public static func normalizedRotationDegrees(_ degrees: Int) -> Int {
        let mod = ((degrees % 360) + 360) % 360
        switch mod {
        case 45..<135: return 90
        case 135..<225: return 180
        case 225..<315: return 270
        default: return 0
        }
    }

    /// Extracts normalized clockwise rotation degrees (`{0, 90, 180, 270}`) from an `AVAssetTrack.preferredTransform`.
    public static func rotationDegrees(from preferredTransform: CGAffineTransform) -> Int {
        let radians = atan2(preferredTransform.b, preferredTransform.a)
        let degrees = Int(round(radians * 180.0 / .pi))
        return normalizedRotationDegrees(degrees)
    }

    /// Extracts pixel aspect ratio (`HorizontalSpacing : VerticalSpacing`) from `CMFormatDescription` extensions.
    public static func extractPixelAspectRatio(from formatDescription: CMFormatDescription?) -> CGSize {
        guard let formatDescription,
              let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any],
              let parDict = extensions[kCMFormatDescriptionExtension_PixelAspectRatio] as? [CFString: Any] else {
            return CGSize(width: 1, height: 1)
        }
        let hNum = (parDict[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber)?.doubleValue ?? 1.0
        let vNum = (parDict[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber)?.doubleValue ?? 1.0
        guard hNum.isFinite, vNum.isFinite, hNum > 0, vNum > 0 else {
            return CGSize(width: 1, height: 1)
        }
        return CGSize(width: hNum, height: vNum)
    }

    /// Derives the pixel aspect ratio (`PAR`) from coded pixel dimensions and optional display dimensions.
    public static func pixelAspectRatio(
        pixelWidth: Int,
        pixelHeight: Int,
        displayWidth: Int?,
        displayHeight: Int?
    ) -> CGSize {
        guard pixelWidth > 0, pixelHeight > 0,
              let dw = displayWidth, let dh = displayHeight,
              dw > 0, dh > 0 else {
            return CGSize(width: 1, height: 1)
        }
        if dw == pixelWidth && dh == pixelHeight {
            return CGSize(width: 1, height: 1)
        }
        let num = dw * pixelHeight
        let den = dh * pixelWidth
        let divisor = gcd(num, den)
        return CGSize(
            width: CGFloat(max(1, num / max(1, divisor))),
            height: CGFloat(max(1, den / max(1, divisor)))
        )
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let t = y
            y = x % y
            x = t
        }
        return max(1, x)
    }

    /// Applies `pixelAspectRatio` and `rotationDegrees` (`{0, 90, 180, 270}`) **once** to an unrotated coded `rawVideoSize`.
    public static func orientedDisplaySize(
        rawVideoSize: CGSize,
        pixelAspectRatio: CGSize = CGSize(width: 1, height: 1),
        rotationDegrees: Int = 0
    ) -> CGSize {
        guard rawVideoSize.width.isFinite, rawVideoSize.height.isFinite,
              rawVideoSize.width > 0, rawVideoSize.height > 0 else {
            return .zero
        }
        let parW = (pixelAspectRatio.width.isFinite && pixelAspectRatio.width > 0) ? pixelAspectRatio.width : 1.0
        let parH = (pixelAspectRatio.height.isFinite && pixelAspectRatio.height > 0) ? pixelAspectRatio.height : 1.0
        let parScaledWidth = rawVideoSize.width * (parW / parH)
        let parScaledHeight = rawVideoSize.height
        let rot = normalizedRotationDegrees(rotationDegrees)
        if rot == 90 || rot == 270 {
            return CGSize(width: parScaledHeight, height: parScaledWidth)
        }
        return CGSize(width: parScaledWidth, height: parScaledHeight)
    }

    /// Calculates the aspect-fit (`resizeAspect`) content rectangle in player viewport local coordinates
    /// from unrotated coded `rawVideoSize`, applying `pixelAspectRatio` and `rotationDegrees` once.
    public static func contentRect(
        inside viewportSize: CGSize,
        rawVideoSize: CGSize,
        pixelAspectRatio: CGSize = CGSize(width: 1, height: 1),
        rotationDegrees: Int = 0
    ) -> CGRect {
        let oriented = orientedDisplaySize(
            rawVideoSize: rawVideoSize,
            pixelAspectRatio: pixelAspectRatio,
            rotationDegrees: rotationDegrees
        )
        return contentRect(inside: viewportSize, naturalVideoSize: oriented)
    }

    /// Calculates the aspect-fit (`resizeAspect`) content rectangle for an already-oriented `naturalVideoSize` inside `viewportSize`.
    public static func contentRect(inside viewportSize: CGSize, naturalVideoSize: CGSize) -> CGRect {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return .zero
        }
        guard naturalVideoSize.width > 0, naturalVideoSize.height > 0 else {
            return CGRect(origin: .zero, size: viewportSize)
        }
        let boundingRect = CGRect(origin: .zero, size: viewportSize)
        let fitted = AVMakeRect(aspectRatio: naturalVideoSize, insideRect: boundingRect)
        guard fitted.width.isFinite, fitted.height.isFinite, fitted.width > 0, fitted.height > 0 else {
            return boundingRect
        }
        return fitted
    }

    /// Converts a video sub-rectangle reported in `displayLayer.bounds` space into player viewport local coordinates
    /// (`CGRect(origin: .zero, size: viewportSize)`), flipping Y if the source layer is unflipped.
    public static func convertLayerVideoRectToViewport(
        layerVideoRect: CGRect,
        layerBounds: CGRect,
        viewportSize: CGSize,
        isLayerGeometryFlipped: Bool = true
    ) -> CGRect? {
        guard viewportSize.width > 0, viewportSize.height > 0,
              layerBounds.width > 0, layerBounds.height > 0,
              layerVideoRect.width.isFinite, layerVideoRect.height.isFinite,
              layerVideoRect.width > 0, layerVideoRect.height > 0 else {
            return nil
        }
        let scaleX = viewportSize.width / layerBounds.width
        let scaleY = viewportSize.height / layerBounds.height
        let relX = (layerVideoRect.minX - layerBounds.minX) * scaleX
        let rawRelY = (layerVideoRect.minY - layerBounds.minY) * scaleY
        let scaledW = layerVideoRect.width * scaleX
        let scaledH = layerVideoRect.height * scaleY
        let relY = isLayerGeometryFlipped ? rawRelY : (viewportSize.height - rawRelY - scaledH)
        let viewportBounds = CGRect(origin: .zero, size: viewportSize)
        let converted = CGRect(x: relX, y: relY, width: scaledW, height: scaledH).intersection(viewportBounds)
        guard !converted.isNull, !converted.isEmpty, converted.width > 0, converted.height > 0 else {
            return nil
        }
        return converted
    }

    /// Returns the height of the bottom letterbox bar when the viewport is taller than the video aspect ratio.
    public static func bottomLetterboxInset(inside viewportSize: CGSize, naturalVideoSize: CGSize) -> CGFloat {
        let fitted = contentRect(inside: viewportSize, naturalVideoSize: naturalVideoSize)
        return max(0.0, (viewportSize.height - fitted.height) * 0.5)
    }

    /// Resolves the active subtitle codec or file format identifier for S1 `SubtitleFormatStyleSupport.classify`.
    internal static func resolveActiveSubtitleCodec(
        selectedSubtitleID: String?,
        embeddedSubtitles: [EmbeddedSubtitleTrack],
        catalogSubtitleTracks: [TTMediaSubtitleTrackInfo]
    ) -> String? {
        guard let selectedSubtitleID, selectedSubtitleID != "off", !selectedSubtitleID.isEmpty else {
            return nil
        }
        if selectedSubtitleID.hasPrefix("embedded:") {
            let suffix = String(selectedSubtitleID.dropFirst("embedded:".count))
            if let numericID = Int64(suffix) {
                if let catalogMatch = catalogSubtitleTracks.first(where: {
                    $0.playbackTrackId == numericID || Int64($0.trackIndex) == numericID || $0.containerTrackNumber == numericID
                }) {
                    if !catalogMatch.rawCodecId.isEmpty { return catalogMatch.rawCodecId }
                    if !catalogMatch.codecName.isEmpty { return catalogMatch.codecName }
                    return catalogMatch.codec.rawValue
                }
                if let embeddedMatch = embeddedSubtitles.first(where: { $0.id == numericID }),
                   !embeddedMatch.codec.isEmpty {
                    return embeddedMatch.codec
                }
            }
            return nil
        }
        if let url = URL(string: selectedSubtitleID), !url.pathExtension.isEmpty {
            return "." + url.pathExtension.lowercased()
        }
        let ext = (selectedSubtitleID as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : "." + ext
    }
}

// MARK: - E / V1 Video Format & Dynamic Range Presentation State (Contract v1)

/// Dynamic range classification for video tracks and display output.
public enum VideoDynamicRangeMode: String, Sendable, Codable, Equatable, CaseIterable {
    case sdr = "SDR"
    case hdr10 = "HDR10"
    case hlg = "HLG"
    case dolbyVision = "DoVi"
    case unknown = "Unknown"

    @MainActor
    public var localizedLabel: String {
        switch self {
        case .sdr: return VideoPlaybackLocalization.text(.formatBadgeSDR)
        case .hdr10: return VideoPlaybackLocalization.text(.formatBadgeHDR10)
        case .hlg: return VideoPlaybackLocalization.text(.formatBadgeHLG)
        case .dolbyVision: return VideoPlaybackLocalization.text(.formatBadgeDolbyVision)
        case .unknown: return VideoPlaybackLocalization.text(.formatBadgeUnknown)
        }
    }

    public var isHDR: Bool {
        switch self {
        case .hdr10, .hlg, .dolbyVision: return true
        case .sdr, .unknown: return false
        }
    }
}

/// Lifecycle status of the video rendering output dynamic range observation.
public enum VideoOutputObservationStatus: Sendable, Equatable {
    /// Initial state while playback pipeline or display layer is preparing and has not yet observed output.
    case detecting
    /// Output dynamic range has been confirmed by renderer, sample attachments, color configuration, and screen observation.
    case confirmed(VideoDynamicRangeMode)
    /// Output could not be confirmed or failed; carries an explicit diagnostic reason instead of permanent silent unknown.
    case diagnostic(String)
}

/// Snapshot of the hosting `NSScreen` and window environment where `AVSampleBufferDisplayLayer` is presented.
/// Screen capability is strictly an upper bound (`potentialEDRHeadroom` / `currentEDRHeadroom`), never confirmation of HDR output alone.
public struct VideoHostScreenObservation: Sendable, Equatable {
    public let hasHostWindow: Bool
    public let screenLocalizedName: String?
    public let colorSpaceName: String?
    public let currentEDRHeadroom: CGFloat
    public let potentialEDRHeadroom: CGFloat

    public var screenSupportsEDR: Bool {
        potentialEDRHeadroom > 1.001 || currentEDRHeadroom > 1.001
    }

    public init(
        hasHostWindow: Bool = true,
        screenLocalizedName: String? = nil,
        colorSpaceName: String? = nil,
        currentEDRHeadroom: CGFloat = 1.0,
        potentialEDRHeadroom: CGFloat = 1.0
    ) {
        self.hasHostWindow = hasHostWindow
        self.screenLocalizedName = screenLocalizedName
        self.colorSpaceName = colorSpaceName
        self.currentEDRHeadroom = max(1.0, currentEDRHeadroom)
        self.potentialEDRHeadroom = max(1.0, max(currentEDRHeadroom, potentialEDRHeadroom))
    }
}

/// Structured evidence of native source video stream parameters, colorimetry, and static/dynamic HDR metadata.
/// Missing fields remain `nil` ("Not provided") and never guess SDR or default bit depth.
public struct VideoSourceMetadataEvidence: Sendable, Equatable {
    public static let empty = VideoSourceMetadataEvidence()

    public let rawCodecId: String?
    public let codecProfile: String?
    public let codecLevel: String?
    public let displayWidth: Int?
    public let displayHeight: Int?
    public let frameRateFps: Double?
    public let colorRange: String?
    public let chromaSubsampling: String?
    public let dolbyVisionProfile: Int?
    public let dolbyVisionLevel: Int?
    public let dolbyVisionBLSignalCompatibilityId: Int?
    public let dolbyVisionRPUPresent: Bool?
    public let dolbyVisionELPresent: Bool?
    public let dolbyVisionBLPresent: Bool?
    public let maxCLL: Int?
    public let maxFALL: Int?
    public let masteringDisplayMaxLuminance: Double?
    public let masteringDisplayMinLuminance: Double?

    public init(
        rawCodecId: String? = nil,
        codecProfile: String? = nil,
        codecLevel: String? = nil,
        displayWidth: Int? = nil,
        displayHeight: Int? = nil,
        frameRateFps: Double? = nil,
        colorRange: String? = nil,
        chromaSubsampling: String? = nil,
        dolbyVisionProfile: Int? = nil,
        dolbyVisionLevel: Int? = nil,
        dolbyVisionBLSignalCompatibilityId: Int? = nil,
        dolbyVisionRPUPresent: Bool? = nil,
        dolbyVisionELPresent: Bool? = nil,
        dolbyVisionBLPresent: Bool? = nil,
        maxCLL: Int? = nil,
        maxFALL: Int? = nil,
        masteringDisplayMaxLuminance: Double? = nil,
        masteringDisplayMinLuminance: Double? = nil
    ) {
        self.rawCodecId = rawCodecId
        self.codecProfile = codecProfile
        self.codecLevel = codecLevel
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.frameRateFps = (frameRateFps ?? 0) > 0 ? frameRateFps : nil
        self.colorRange = colorRange
        self.chromaSubsampling = chromaSubsampling
        self.dolbyVisionProfile = dolbyVisionProfile
        self.dolbyVisionLevel = dolbyVisionLevel
        self.dolbyVisionBLSignalCompatibilityId = dolbyVisionBLSignalCompatibilityId
        self.dolbyVisionRPUPresent = dolbyVisionRPUPresent
        self.dolbyVisionELPresent = dolbyVisionELPresent
        self.dolbyVisionBLPresent = dolbyVisionBLPresent
        self.maxCLL = (maxCLL ?? 0) > 0 ? maxCLL : nil
        self.maxFALL = (maxFALL ?? 0) > 0 ? maxFALL : nil
        self.masteringDisplayMaxLuminance = (masteringDisplayMaxLuminance ?? 0) > 0 ? masteringDisplayMaxLuminance : nil
        self.masteringDisplayMinLuminance = (masteringDisplayMinLuminance ?? -1) >= 0 ? masteringDisplayMinLuminance : nil
    }
}

/// Explicit observation of the display environment and confirmed rendering output state.
public struct VideoDisplayOutputObservation: Sendable, Equatable {
    public let screenSupportsEDR: Bool
    public let isHDRPresentationConfirmed: Bool
    public let isToneMappedFallbackConfirmed: Bool
    public let isSDRPresentationConfirmed: Bool
    public let currentEDRHeadroom: CGFloat?
    public let potentialEDRHeadroom: CGFloat?
    public let screenLocalizedName: String?
    public let screenColorSpaceName: String?
    public let rendererName: String
    public let isRendererEDRConfigured: Bool?
    public let hasEnqueuedVideoSample: Bool
    public let sampleTransferFunction: String?
    public let sampleColorPrimaries: String?
    public let sampleYCbCrMatrix: String?
    public let observedSampleDynamicRange: VideoDynamicRangeMode
    public let isDetecting: Bool
    public let diagnosticReason: String?
    public let sessionID: UUID?
    public let playbackGeneration: UInt64?

    public init(
        screenSupportsEDR: Bool,
        isHDRPresentationConfirmed: Bool = false,
        isToneMappedFallbackConfirmed: Bool = false,
        isSDRPresentationConfirmed: Bool = false,
        currentEDRHeadroom: CGFloat? = nil,
        potentialEDRHeadroom: CGFloat? = nil,
        screenLocalizedName: String? = nil,
        screenColorSpaceName: String? = nil,
        rendererName: String = "AVSampleBufferDisplayLayer",
        isRendererEDRConfigured: Bool? = nil,
        hasEnqueuedVideoSample: Bool = false,
        sampleTransferFunction: String? = nil,
        sampleColorPrimaries: String? = nil,
        sampleYCbCrMatrix: String? = nil,
        observedSampleDynamicRange: VideoDynamicRangeMode = .unknown,
        isDetecting: Bool = false,
        diagnosticReason: String? = nil,
        sessionID: UUID? = nil,
        playbackGeneration: UInt64? = nil
    ) {
        self.screenSupportsEDR = screenSupportsEDR
        self.isHDRPresentationConfirmed = isHDRPresentationConfirmed
        self.isToneMappedFallbackConfirmed = isToneMappedFallbackConfirmed
        self.isSDRPresentationConfirmed = isSDRPresentationConfirmed
        self.currentEDRHeadroom = currentEDRHeadroom
        self.potentialEDRHeadroom = potentialEDRHeadroom
        self.screenLocalizedName = screenLocalizedName
        self.screenColorSpaceName = screenColorSpaceName
        self.rendererName = rendererName
        self.isRendererEDRConfigured = isRendererEDRConfigured
        self.hasEnqueuedVideoSample = hasEnqueuedVideoSample
        self.sampleTransferFunction = sampleTransferFunction
        self.sampleColorPrimaries = sampleColorPrimaries
        self.sampleYCbCrMatrix = sampleYCbCrMatrix
        self.observedSampleDynamicRange = observedSampleDynamicRange
        self.isDetecting = isDetecting
        self.diagnosticReason = diagnosticReason
        self.sessionID = sessionID
        self.playbackGeneration = playbackGeneration
    }
}

/// Describes the active video track's format, resolution, source dynamic range, and display output state.
public struct VideoFormatPresentationState: Sendable, Equatable {
    public static let contractVersion = "v1"

    public let codecLabel: String?
    public let width: Int
    public let height: Int
    public let bitDepth: Int?
    public let colorPrimaries: String?
    public let transferFunction: String?
    public let yCbCrMatrix: String?
    public let sourceDynamicRange: VideoDynamicRangeMode
    public let activeOutputDynamicRange: VideoDynamicRangeMode
    public let isToneMappedFallbackToSDR: Bool
    public let outputObservationStatus: VideoOutputObservationStatus
    public let displayObservation: VideoDisplayOutputObservation?
    public let sourceMetadata: VideoSourceMetadataEvidence
    public let badgeText: String
    let explicitBadgeText: String?

    public var dynamicRangeMode: VideoDynamicRangeMode { sourceDynamicRange }
    public var codecName: String { codecLabel ?? "" }
    public var rawCodecId: String? { sourceMetadata.rawCodecId }
    public var codecProfile: String? { sourceMetadata.codecProfile }
    public var codecLevel: String? { sourceMetadata.codecLevel }
    public var displayWidth: Int? { sourceMetadata.displayWidth }
    public var displayHeight: Int? { sourceMetadata.displayHeight }
    public var frameRateFps: Double? { sourceMetadata.frameRateFps }
    public var colorRange: String? { sourceMetadata.colorRange }
    public var chromaSubsampling: String? { sourceMetadata.chromaSubsampling }
    public var dolbyVisionProfile: Int? { sourceMetadata.dolbyVisionProfile }
    public var dolbyVisionLevel: Int? { sourceMetadata.dolbyVisionLevel }
    public var dolbyVisionBLSignalCompatibilityId: Int? { sourceMetadata.dolbyVisionBLSignalCompatibilityId }
    public var dolbyVisionRPUPresent: Bool? { sourceMetadata.dolbyVisionRPUPresent }
    public var dolbyVisionELPresent: Bool? { sourceMetadata.dolbyVisionELPresent }
    public var dolbyVisionBLPresent: Bool? { sourceMetadata.dolbyVisionBLPresent }
    public var maxCLL: Int? { sourceMetadata.maxCLL }
    public var maxFALL: Int? { sourceMetadata.maxFALL }
    public var masteringDisplayMaxLuminance: Double? { sourceMetadata.masteringDisplayMaxLuminance }
    public var masteringDisplayMinLuminance: Double? { sourceMetadata.masteringDisplayMinLuminance }

    public init(
        codecLabel: String? = nil,
        width: Int = 0,
        height: Int = 0,
        bitDepth: Int? = nil,
        colorPrimaries: String? = nil,
        transferFunction: String? = nil,
        yCbCrMatrix: String? = nil,
        sourceDynamicRange: VideoDynamicRangeMode = .unknown,
        activeOutputDynamicRange: VideoDynamicRangeMode? = nil,
        isToneMappedFallbackToSDR: Bool = false,
        outputObservationStatus: VideoOutputObservationStatus? = nil,
        displayObservation: VideoDisplayOutputObservation? = nil,
        sourceMetadata: VideoSourceMetadataEvidence = .empty,
        badgeText: String? = nil
    ) {
        let resolvedOutputDR = activeOutputDynamicRange ?? (isToneMappedFallbackToSDR ? .sdr : .unknown)
        let resolvedStatus: VideoOutputObservationStatus
        if let outputObservationStatus {
            resolvedStatus = outputObservationStatus
        } else if resolvedOutputDR != .unknown {
            resolvedStatus = .confirmed(resolvedOutputDR)
        } else if let reason = displayObservation?.diagnosticReason, !reason.isEmpty {
            resolvedStatus = .diagnostic(reason)
        } else {
            resolvedStatus = .detecting
        }
        self.codecLabel = codecLabel
        self.width = max(0, width)
        self.height = max(0, height)
        self.bitDepth = (bitDepth ?? 0) > 0 ? bitDepth : nil
        self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.sourceDynamicRange = sourceDynamicRange
        self.activeOutputDynamicRange = resolvedOutputDR
        self.isToneMappedFallbackToSDR = isToneMappedFallbackToSDR
        self.outputObservationStatus = resolvedStatus
        self.displayObservation = displayObservation
        self.sourceMetadata = sourceMetadata
        self.explicitBadgeText = badgeText
        self.badgeText = badgeText ?? Self.composeBadgeText(
            codecLabel: codecLabel,
            width: width,
            height: height,
            sourceDynamicRange: sourceDynamicRange,
            activeOutputDynamicRange: resolvedOutputDR,
            isToneMappedFallbackToSDR: isToneMappedFallbackToSDR,
            outputObservationStatus: resolvedStatus
        )
    }

    public init(
        dynamicRangeMode: VideoDynamicRangeMode,
        codecName: String,
        bitDepth: Int? = nil,
        colorPrimaries: String? = nil,
        transferFunction: String? = nil,
        yCbCrMatrix: String? = nil,
        isToneMappedFallbackToSDR: Bool = false,
        activeOutputDynamicRange: VideoDynamicRangeMode? = nil,
        width: Int = 0,
        height: Int = 0
    ) {
        self.init(
            codecLabel: codecName.isEmpty ? nil : codecName,
            width: width,
            height: height,
            bitDepth: bitDepth,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            sourceDynamicRange: dynamicRangeMode,
            activeOutputDynamicRange: activeOutputDynamicRange ?? (isToneMappedFallbackToSDR ? .sdr : .unknown),
            isToneMappedFallbackToSDR: isToneMappedFallbackToSDR
        )
    }

    public var resolutionTierLabel: String? {
        let maxDim = max(width, height)
        let minDim = min(width, height)
        guard maxDim > 0, minDim > 0 else { return nil }
        if maxDim >= 3800 || minDim >= 2100 { return "4K" }
        if maxDim >= 2500 || minDim >= 1400 { return "1440p" }
        if maxDim >= 1900 || minDim >= 1000 { return "1080p" }
        if maxDim >= 1200 || minDim >= 700 { return "720p" }
        return "\(width)×\(height)"
    }
}

// MARK: - F4 / P2 First-Sample Enqueue & Seek Pipeline Telemetry (Contract v1)

/// Captures deterministic timestamps for pipeline-level first video sample enqueue and seek pipeline completion,
/// strictly separating pipeline enqueue from visual presentation on screen (verified by P2 on the candidate bundle).
public struct VideoPlaybackTelemetryMetrics: Sendable, Equatable {
    public static let contractVersion = "v1"

    public private(set) var loadStartedAtUptimeSeconds: Double?
    public private(set) var controllerLoadedAtUptimeSeconds: Double?
    public private(set) var firstVideoSampleEnqueuedAtUptimeSeconds: Double?
    public private(set) var firstVideoSampleEnqueueLatencyMs: Double?
    public private(set) var firstFrameVisualPresentationLatencyMs: Double?
    public private(set) var lastSeekRequestedAtUptimeSeconds: Double?
    public private(set) var lastSeekPipelineCompletedAtUptimeSeconds: Double?
    public private(set) var lastSeekPipelineCompletionLatencyMs: Double?
    public private(set) var lastSeekVisiblePresentationLatencyMs: Double?
    public private(set) var completedSeekCount: Int = 0
    public private(set) var hasEnqueuedFirstVideoSample: Bool = false
    public private(set) var hasVerifiedVisualFirstFramePresentation: Bool = false

    public var firstFrameRenderedAtUptimeSeconds: Double? { firstVideoSampleEnqueuedAtUptimeSeconds }
    public var firstFrameStartupLatencyMs: Double? { firstVideoSampleEnqueueLatencyMs }
    public var hasRenderedFirstVideoFrame: Bool { hasEnqueuedFirstVideoSample }
    public var lastSeekCompletedAtUptimeSeconds: Double? { lastSeekPipelineCompletedAtUptimeSeconds }
    public var lastSeekRecoveryLatencyMs: Double? { lastSeekPipelineCompletionLatencyMs }

    public init() {}

    public mutating func recordLoadStart(at uptimeSeconds: Double = ProcessInfo.processInfo.systemUptime) {
        loadStartedAtUptimeSeconds = uptimeSeconds
        controllerLoadedAtUptimeSeconds = nil
        firstVideoSampleEnqueuedAtUptimeSeconds = nil
        firstVideoSampleEnqueueLatencyMs = nil
        firstFrameVisualPresentationLatencyMs = nil
        hasEnqueuedFirstVideoSample = false
        hasVerifiedVisualFirstFramePresentation = false
    }

    public mutating func recordControllerLoaded(at uptimeSeconds: Double = ProcessInfo.processInfo.systemUptime) {
        controllerLoadedAtUptimeSeconds = uptimeSeconds
    }

    /// Records that the first video `CMSampleBuffer` has been enqueued into `AVSampleBufferDisplayLayer`.
    /// Does not claim visual presentation on screen (`firstFrameVisualPresentationLatencyMs` remains `nil`).
    public mutating func recordFirstVideoSampleEnqueued(at uptimeSeconds: Double = ProcessInfo.processInfo.systemUptime) {
        guard !hasEnqueuedFirstVideoSample else { return }
        hasEnqueuedFirstVideoSample = true
        firstVideoSampleEnqueuedAtUptimeSeconds = uptimeSeconds
        if let start = loadStartedAtUptimeSeconds {
            firstVideoSampleEnqueueLatencyMs = max(0.0, (uptimeSeconds - start) * 1000.0)
        }
    }

    public mutating func recordFirstVideoFrameRendered(at uptimeSeconds: Double = ProcessInfo.processInfo.systemUptime) {
        recordFirstVideoSampleEnqueued(at: uptimeSeconds)
    }

    public mutating func recordSeekRequested(at uptimeSeconds: Double = ProcessInfo.processInfo.systemUptime) {
        lastSeekRequestedAtUptimeSeconds = uptimeSeconds
    }

    /// Records that the seek pipeline has enqueued the target frame (`PTS >= targetSeekTime`) and restored synchronizer rate.
    /// Does not claim visible frame presentation on screen (`lastSeekVisiblePresentationLatencyMs` remains `nil`).
    public mutating func recordSeekPipelineCompleted(at uptimeSeconds: Double = ProcessInfo.processInfo.systemUptime) {
        lastSeekPipelineCompletedAtUptimeSeconds = uptimeSeconds
        completedSeekCount += 1
        if let req = lastSeekRequestedAtUptimeSeconds {
            lastSeekPipelineCompletionLatencyMs = max(0.0, (uptimeSeconds - req) * 1000.0)
        }
    }

    public mutating func recordSeekCompleted(at uptimeSeconds: Double = ProcessInfo.processInfo.systemUptime) {
        recordSeekPipelineCompleted(at: uptimeSeconds)
    }
}

// MARK: - Balanced Viewport Cursor Visibility Controller (Feedback ④)

/// Ensures 1:1 balanced `NSCursor.hide()` and `NSCursor.unhide()` calls scoped strictly to a single
/// video viewport, guaranteeing zero cursor-hide leakage when the mouse leaves, focus changes, or the view disappears.
@MainActor
public final class ViewportCursorVisibilityController {
    public private(set) var isCursorHidden: Bool = false
    public private(set) var hideCallCount: Int = 0
    public private(set) var unhideCallCount: Int = 0

    private let hideAction: @MainActor () -> Void
    private let unhideAction: @MainActor () -> Void

    public init(
        hideAction: @escaping @MainActor () -> Void = { NSCursor.hide() },
        unhideAction: @escaping @MainActor () -> Void = { NSCursor.unhide() }
    ) {
        self.hideAction = hideAction
        self.unhideAction = unhideAction
    }

    /// Applies the desired cursor hidden state with strict 1:1 transition guarding.
    public func applyCursorHidden(_ shouldHide: Bool) {
        if shouldHide {
            guard !isCursorHidden else { return }
            isCursorHidden = true
            hideCallCount += 1
            hideAction()
        } else {
            guard isCursorHidden else { return }
            isCursorHidden = false
            unhideCallCount += 1
            unhideAction()
        }
    }

    /// Unconditionally restores the cursor if currently hidden by this viewport.
    public func forceRestoreCursor() {
        applyCursorHidden(false)
    }
}
