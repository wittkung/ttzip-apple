// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import CoreMedia
import Foundation
import TTI18nCore

// MARK: - VideoFormatPresentationState Output Observation & Source Evidence Extensions

extension VideoFormatPresentationState {
    /// Returns an updated presentation state reflecting an explicit display and renderer output observation.
    /// Never claims HDR output or SDR tone-mapping from codec name or screen capability alone without renderer confirmation.
    public func applyingDisplayObservation(_ observation: VideoDisplayOutputObservation?) -> VideoFormatPresentationState {
        guard let observation else {
            return VideoFormatPresentationState(
                codecLabel: codecLabel,
                width: width,
                height: height,
                bitDepth: bitDepth,
                colorPrimaries: colorPrimaries,
                transferFunction: transferFunction,
                yCbCrMatrix: yCbCrMatrix,
                sourceDynamicRange: sourceDynamicRange,
                activeOutputDynamicRange: .unknown,
                isToneMappedFallbackToSDR: false,
                outputObservationStatus: .detecting,
                displayObservation: nil,
                sourceMetadata: sourceMetadata,
                badgeText: explicitBadgeText
            )
        }
        if observation.isDetecting {
            return VideoFormatPresentationState(
                codecLabel: codecLabel,
                width: width,
                height: height,
                bitDepth: bitDepth,
                colorPrimaries: colorPrimaries,
                transferFunction: transferFunction,
                yCbCrMatrix: yCbCrMatrix,
                sourceDynamicRange: sourceDynamicRange,
                activeOutputDynamicRange: .unknown,
                isToneMappedFallbackToSDR: false,
                outputObservationStatus: .detecting,
                displayObservation: observation,
                sourceMetadata: sourceMetadata,
                badgeText: explicitBadgeText
            )
        }
        let evaluation = Self.resolveOutputFromObservation(
            sourceDynamicRange: sourceDynamicRange,
            observation: observation
        )
        return VideoFormatPresentationState(
            codecLabel: codecLabel,
            width: width,
            height: height,
            bitDepth: bitDepth,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            sourceDynamicRange: sourceDynamicRange,
            activeOutputDynamicRange: evaluation.output,
            isToneMappedFallbackToSDR: evaluation.toneMapped,
            outputObservationStatus: evaluation.status,
            displayObservation: observation,
            sourceMetadata: sourceMetadata,
            badgeText: explicitBadgeText
        )
    }

    /// Transitions output observation into an explicit diagnostic state without fabricating SDR or HDR output.
    public func applyingDiagnosticFailure(_ reason: String) -> VideoFormatPresentationState {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedReason = trimmed.isEmpty ? "渲染输出状态未能确认" : trimmed
        return VideoFormatPresentationState(
            codecLabel: codecLabel,
            width: width,
            height: height,
            bitDepth: bitDepth,
            colorPrimaries: colorPrimaries,
            transferFunction: transferFunction,
            yCbCrMatrix: yCbCrMatrix,
            sourceDynamicRange: sourceDynamicRange,
            activeOutputDynamicRange: .unknown,
            isToneMappedFallbackToSDR: false,
            outputObservationStatus: .diagnostic(resolvedReason),
            displayObservation: displayObservation,
            sourceMetadata: sourceMetadata,
            badgeText: explicitBadgeText
        )
    }

    private static func resolveOutputFromObservation(
        sourceDynamicRange: VideoDynamicRangeMode,
        observation: VideoDisplayOutputObservation
    ) -> (output: VideoDynamicRangeMode, toneMapped: Bool, status: VideoOutputObservationStatus) {
        if observation.isToneMappedFallbackConfirmed && !observation.observedSampleDynamicRange.isHDR {
            return (.sdr, true, .confirmed(.sdr))
        }
        if observation.screenSupportsEDR && observation.isHDRPresentationConfirmed {
            let confirmedHDRMode = resolveConfirmedHDROutputMode(
                sourceDynamicRange: sourceDynamicRange,
                observedSampleDynamicRange: observation.observedSampleDynamicRange
            )
            if confirmedHDRMode.isHDR {
                return (confirmedHDRMode, false, .confirmed(confirmedHDRMode))
            }
            let doviReason = observation.diagnosticReason
                ?? "源为 Dolby Vision，但未观测到渲染样本传递函数或 Dolby Vision 管线确认，不自动声称 Dolby Vision 输出"
            return (.unknown, false, .diagnostic(doviReason))
        }
        if observation.isSDRPresentationConfirmed && !observation.observedSampleDynamicRange.isHDR {
            return (.sdr, false, .confirmed(.sdr))
        }
        let reason = observation.diagnosticReason ?? defaultUnconfirmedReason(
            sourceDynamicRange: sourceDynamicRange,
            observation: observation
        )
        return (.unknown, false, .diagnostic(reason))
    }

    private static func resolveConfirmedHDROutputMode(
        sourceDynamicRange: VideoDynamicRangeMode,
        observedSampleDynamicRange: VideoDynamicRangeMode
    ) -> VideoDynamicRangeMode {
        if observedSampleDynamicRange.isHDR {
            return observedSampleDynamicRange
        }
        // Never borrow source Dolby Vision to automatically claim Dolby Vision output when sample transfer is unobserved.
        if sourceDynamicRange == .hdr10 || sourceDynamicRange == .hlg {
            return sourceDynamicRange
        }
        return .unknown
    }

    private static func defaultUnconfirmedReason(
        sourceDynamicRange: VideoDynamicRangeMode,
        observation: VideoDisplayOutputObservation
    ) -> String {
        if sourceDynamicRange.isHDR || observation.observedSampleDynamicRange.isHDR {
            return observation.screenSupportsEDR
                ? "宿主屏幕支持 EDR 上限，但渲染器尚未确认 HDR 样本帧激活输出"
                : "EDR 未启用 / 输出待确认：宿主屏幕未启用 EDR，且未观测到显式 SDR 色调映射转换"
        }
        if observation.observedSampleDynamicRange == .unknown {
            return "入队样本缺少明确传递函数（Transfer Function），无法确认 SDR 或 HDR 输出"
        }
        return "渲染器尚未确认当前样本帧呈现与输出状态"
    }

    private static func hasExplicitDynamicRangeEvidence(_ track: TTMediaVideoTrackInfo) -> Bool {
        if track.rawDynamicRange?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if track.colorMetadata.transferCharacteristics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        if track.dolbyVisionProfile != nil {
            return true
        }
        if let priv = track.codecPrivateFormat?.lowercased(), ["dvcc", "dvvc", "dvwc"].contains(priv) {
            return true
        }
        return ["dvh1", "dvhe", "dav1", "dva1"].contains(track.rawCodecId.lowercased())
    }

    private static func mapWorkerDynamicRange(_ range: TTMediaDynamicRange) -> VideoDynamicRangeMode {
        switch range {
        case .sdr: return .sdr
        case .hdr10, .hdr10Plus: return .hdr10
        case .hlg: return .hlg
        case .dolbyVision: return .dolbyVision
        case .unknown: return .unknown
        }
    }

    internal static func fromWorkerVideoTrack(_ track: TTMediaVideoTrackInfo) -> VideoFormatPresentationState {
        let mode: VideoDynamicRangeMode = hasExplicitDynamicRangeEvidence(track)
            ? mapWorkerDynamicRange(track.dynamicRange)
            : .unknown
        let rawLabel = track.codecName.isEmpty ? (track.codec?.rawValue ?? "") : track.codecName
        let label = rawLabel.uppercased()
        let validBitDepth = (track.bitDepth ?? 0) > 0 ? track.bitDepth : nil
        let rawCodec = track.rawCodecId.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = VideoSourceMetadataEvidence(
            rawCodecId: rawCodec.isEmpty ? nil : rawCodec,
            codecProfile: track.codecProfile,
            codecLevel: track.codecLevel,
            displayWidth: track.displayWidth,
            displayHeight: track.displayHeight,
            frameRateFps: track.frameRateFps,
            colorRange: track.colorMetadata.colorRange,
            chromaSubsampling: track.colorMetadata.chromaSubsampling,
            dolbyVisionProfile: track.dolbyVisionProfile,
            dolbyVisionLevel: track.dolbyVisionLevel,
            dolbyVisionBLSignalCompatibilityId: track.dolbyVisionBLSignalCompatibilityId,
            dolbyVisionRPUPresent: track.dolbyVisionRPUPresent,
            dolbyVisionELPresent: track.dolbyVisionELPresent,
            dolbyVisionBLPresent: track.dolbyVisionBLPresent,
            maxCLL: track.maxCLL,
            maxFALL: track.maxFALL,
            masteringDisplayMaxLuminance: track.masteringDisplayMaxLuminance,
            masteringDisplayMinLuminance: track.masteringDisplayMinLuminance
        )
        return VideoFormatPresentationState(
            codecLabel: label.isEmpty ? nil : label,
            width: track.pixelWidth > 0 ? track.pixelWidth : track.width,
            height: track.pixelHeight > 0 ? track.pixelHeight : track.height,
            bitDepth: validBitDepth,
            colorPrimaries: track.colorMetadata.colorPrimaries,
            transferFunction: track.colorMetadata.transferCharacteristics,
            yCbCrMatrix: track.colorMetadata.matrixCoefficients,
            sourceDynamicRange: mode,
            activeOutputDynamicRange: .unknown,
            isToneMappedFallbackToSDR: false,
            outputObservationStatus: .detecting,
            sourceMetadata: metadata
        )
    }

    /// Composes the short control-bar badge representing ONLY the currently observed rendering/output dynamic range
    /// (or explicit named source/output summary when `includeNamedSourcePrefix == true`).
    /// Never falls back to `sourceDynamicRange` when `activeOutputDynamicRange == .unknown`.
    public static func composeBadgeText(
        codecLabel: String? = nil,
        width: Int = 0,
        height: Int = 0,
        sourceDynamicRange: VideoDynamicRangeMode = .unknown,
        activeOutputDynamicRange: VideoDynamicRangeMode,
        isToneMappedFallbackToSDR: Bool = false,
        outputObservationStatus: VideoOutputObservationStatus? = nil,
        includeNamedSourcePrefix: Bool = false,
        sourcePrefixLabel: String = "源",
        outputPrefixLabel: String = "输出",
        detectingLabel: String = VideoPlaybackLocaleKey.formatBadgeDetectingOutput.fallbackTranslation(for: .zhHans),
        diagnosticLabel: String = VideoPlaybackLocaleKey.formatBadgeDiagnosticUnconfirmed.fallbackTranslation(for: .zhHans),
        unknownLabel: String? = nil
    ) -> String {
        let outputToken = resolveShortOutputToken(
            activeOutputDynamicRange: activeOutputDynamicRange,
            outputObservationStatus: outputObservationStatus,
            detectingLabel: detectingLabel,
            diagnosticLabel: diagnosticLabel,
            unknownLabel: unknownLabel
        )
        guard includeNamedSourcePrefix else {
            return outputToken
        }
        return composeNamedSourceAndOutputText(
            codecLabel: codecLabel,
            width: width,
            height: height,
            sourceDynamicRange: sourceDynamicRange,
            outputToken: outputToken,
            sourcePrefixLabel: sourcePrefixLabel,
            outputPrefixLabel: outputPrefixLabel
        )
    }

    private static func resolveShortOutputToken(
        activeOutputDynamicRange: VideoDynamicRangeMode,
        outputObservationStatus: VideoOutputObservationStatus?,
        detectingLabel: String,
        diagnosticLabel: String,
        unknownLabel: String?
    ) -> String {
        if activeOutputDynamicRange != .unknown {
            return activeOutputDynamicRange.rawValue
        }
        if let unknownLabel {
            return unknownLabel
        }
        switch outputObservationStatus ?? .detecting {
        case .detecting:
            return detectingLabel
        case .diagnostic:
            return diagnosticLabel
        case .confirmed(let mode):
            return mode != .unknown ? mode.rawValue : detectingLabel
        }
    }

    private static func composeNamedSourceAndOutputText(
        codecLabel: String?,
        width: Int,
        height: Int,
        sourceDynamicRange: VideoDynamicRangeMode,
        outputToken: String,
        sourcePrefixLabel: String,
        outputPrefixLabel: String
    ) -> String {
        var sourceParts: [String] = []
        if let tier = resolutionTierString(width: width, height: height) {
            sourceParts.append(tier)
        }
        if let codecLabel, !codecLabel.isEmpty {
            sourceParts.append(normalizeCodecDisplayLabel(codecLabel))
        }
        if sourceParts.isEmpty && sourceDynamicRange != .unknown {
            sourceParts.append(sourceDynamicRange.rawValue)
        }
        if sourceParts.isEmpty {
            return "\(outputPrefixLabel) \(outputToken)"
        }
        return "\(sourcePrefixLabel) \(sourceParts.joined(separator: " · ")) | \(outputPrefixLabel) \(outputToken)"
    }

    private static func resolutionTierString(width: Int, height: Int) -> String? {
        let maxDim = max(width, height)
        let minDim = min(width, height)
        if maxDim >= 3800 || minDim >= 2100 { return "4K" }
        if maxDim >= 2500 || minDim >= 1400 { return "1440p" }
        if maxDim >= 1900 || minDim >= 1000 { return "1080p" }
        if maxDim >= 1200 || minDim >= 700 { return "720p" }
        if width > 0 && height > 0 { return "\(width)×\(height)" }
        return nil
    }

    public static func normalizeCodecDisplayLabel(_ raw: String) -> String {
        let upper = raw.uppercased()
        if upper.contains("HEVC") || upper.contains("H265") || upper.contains("HVC1") || upper.contains("HEV1") {
            return "HEVC"
        }
        if upper.contains("AVC") || upper.contains("H264") || upper.contains("AVC1") {
            return "H.264"
        }
        if upper.contains("AV1") || upper.contains("AV01") {
            return "AV1"
        }
        if upper.contains("VP9") || upper.contains("VP09") {
            return "VP9"
        }
        if upper.contains("PRORES") {
            return "ProRes"
        }
        return raw.uppercased()
    }

    /// Resolves source dynamic range strictly from explicit CoreMedia format description extensions or verified metadata hints.
    /// Never guesses `.sdr` when transfer function and Dolby Vision configuration evidence are absent.
    public static func detectDynamicRange(
        formatDescription: CMFormatDescription?,
        rawCodecName: String? = nil,
        transferFunctionHint: String? = nil
    ) -> VideoDynamicRangeMode {
        if isDolbyVisionFormat(formatDescription: formatDescription, rawCodecName: rawCodecName) {
            return .dolbyVision
        }
        if let formatDescription,
           let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any],
           let tf = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
           !tf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return classifyTransferFunction(tf)
        }
        if let hint = transferFunctionHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            return classifyTransferFunction(hint)
        }
        return .unknown
    }

    private static func isDolbyVisionFormat(
        formatDescription: CMFormatDescription?,
        rawCodecName: String?
    ) -> Bool {
        if let raw = rawCodecName?.uppercased() {
            let doviTokens = ["DOVI", "DVHE", "DVH1", "DOLBY", "DAV1", "DVA1"]
            if doviTokens.contains(where: { raw.contains($0) }) { return true }
        }
        guard let formatDescription else { return false }
        let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
        let doviSubTypes: Set<FourCharCode> = [0x64766831, 0x64766865, 0x64766131]
        if doviSubTypes.contains(subType) { return true }
        guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any] else {
            return false
        }
        let doviBoxKeys: [CFString] = [
            "DolbyVisionConfigurationBox" as CFString,
            "dvcC" as CFString,
            "dvvC" as CFString
        ]
        if doviBoxKeys.contains(where: { extensions[$0] != nil }) { return true }
        if let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any] {
            if atoms["dvcC"] != nil || atoms["dvvC"] != nil || atoms["dvwC"] != nil { return true }
        }
        return false
    }

    internal static func classifyTransferFunction(_ tf: String) -> VideoDynamicRangeMode {
        let upper = tf.uppercased()
        if upper.contains("2084") || upper.contains("PQ") {
            return .hdr10
        }
        if upper.contains("HLG") || upper.contains("2100_HLG") || upper.contains("ARIB_STD_B67") || upper.contains("ARIB-STD-B67") {
            return .hlg
        }
        if upper.contains("709") || upper.contains("240M") || upper.contains("SRGB") || upper.contains("GAMMA") || upper.contains("601") {
            return .sdr
        }
        return .unknown
    }

    public static func resolve(
        codecLabel: String? = nil,
        rawCodecName: String? = nil,
        width: Int,
        height: Int,
        bitDepth: Int? = nil,
        formatDescription: CMFormatDescription?,
        transferFunctionHint: String? = nil,
        frameRateFps: Double? = nil,
        displayObservation: VideoDisplayOutputObservation? = nil
    ) -> VideoFormatPresentationState {
        let extracted = CMFormatDescriptionMetadataExtractor.extractPresentationState(
            from: formatDescription,
            width: width,
            height: height,
            frameRateFps: frameRateFps,
            explicitCodecLabel: codecLabel ?? rawCodecName,
            explicitBitDepth: bitDepth,
            transferFunctionHint: transferFunctionHint
        )
        return extracted.applyingDisplayObservation(displayObservation)
    }
}

// MARK: - CoreMedia Format Description & Bitstream Metadata Extractor

public enum CMFormatDescriptionMetadataExtractor {
    public static func extractPresentationState(
        from formatDesc: CMFormatDescription?,
        width: Int = 0,
        height: Int = 0,
        displayWidth: Int? = nil,
        displayHeight: Int? = nil,
        frameRateFps: Double? = nil,
        explicitCodecLabel: String? = nil,
        explicitBitDepth: Int? = nil,
        transferFunctionHint: String? = nil
    ) -> VideoFormatPresentationState {
        guard let formatDesc else {
            return makeFallbackPresentationState(
                width: width,
                height: height,
                displayWidth: displayWidth,
                displayHeight: displayHeight,
                frameRateFps: frameRateFps,
                explicitCodecLabel: explicitCodecLabel,
                explicitBitDepth: explicitBitDepth,
                transferFunctionHint: transferFunctionHint
            )
        }
        let subType = CMFormatDescriptionGetMediaSubType(formatDesc)
        let fourCC = fourCharCodeString(subType)
        let resolvedCodecLabel = explicitCodecLabel ?? codecLabel(for: subType, fourCC: fourCC)
        let ext = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any]
        let rawPrimaries = ext?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let rawTransfer = (ext?[kCMFormatDescriptionExtension_TransferFunction as String] as? String) ?? transferFunctionHint
        let rawMatrix = ext?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        let atoms = ext?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any]
        let bitstreamInfo = parseCodecConfigurationAtoms(atoms: atoms)
        let resolvedBitDepth = explicitBitDepth ?? parseExplicitBitDepth(from: ext) ?? bitstreamInfo.bitDepth
        let dovi = parseDolbyVisionConfiguration(from: ext, atoms: atoms)
        let dynamicRange: VideoDynamicRangeMode = dovi.profile != nil
            ? .dolbyVision
            : VideoFormatPresentationState.detectDynamicRange(
                formatDescription: formatDesc,
                rawCodecName: fourCC ?? resolvedCodecLabel,
                transferFunctionHint: rawTransfer
            )
        let dims = CMVideoFormatDescriptionGetDimensions(formatDesc)
        let metadata = buildSourceEvidence(
            fourCC: fourCC,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            frameRateFps: frameRateFps,
            ext: ext,
            atoms: atoms,
            bitstreamInfo: bitstreamInfo,
            dovi: dovi
        )
        return VideoFormatPresentationState(
            codecLabel: resolvedCodecLabel,
            width: width > 0 ? width : Int(dims.width),
            height: height > 0 ? height : Int(dims.height),
            bitDepth: resolvedBitDepth,
            colorPrimaries: humanReadablePrimaries(rawPrimaries),
            transferFunction: humanReadableTransferFunction(rawTransfer),
            yCbCrMatrix: humanReadableMatrix(rawMatrix),
            sourceDynamicRange: dynamicRange,
            activeOutputDynamicRange: .unknown,
            isToneMappedFallbackToSDR: false,
            outputObservationStatus: .detecting,
            sourceMetadata: metadata
        )
    }

    private static func makeFallbackPresentationState(
        width: Int,
        height: Int,
        displayWidth: Int?,
        displayHeight: Int?,
        frameRateFps: Double?,
        explicitCodecLabel: String?,
        explicitBitDepth: Int?,
        transferFunctionHint: String?
    ) -> VideoFormatPresentationState {
        let fallbackDR = VideoFormatPresentationState.detectDynamicRange(
            formatDescription: nil,
            rawCodecName: explicitCodecLabel,
            transferFunctionHint: transferFunctionHint
        )
        return VideoFormatPresentationState(
            codecLabel: explicitCodecLabel,
            width: width,
            height: height,
            bitDepth: explicitBitDepth,
            transferFunction: transferFunctionHint,
            sourceDynamicRange: fallbackDR,
            sourceMetadata: VideoSourceMetadataEvidence(
                displayWidth: displayWidth,
                displayHeight: displayHeight,
                frameRateFps: frameRateFps
            )
        )
    }

    private static func buildSourceEvidence(
        fourCC: String?,
        displayWidth: Int?,
        displayHeight: Int?,
        frameRateFps: Double?,
        ext: [String: Any]?,
        atoms: [String: Any]?,
        bitstreamInfo: (profile: String?, level: String?, chromaSubsampling: String?, bitDepth: Int?),
        dovi: (profile: Int?, level: Int?, blCompatibilityId: Int?, rpuPresent: Bool?, elPresent: Bool?, blPresent: Bool?)
    ) -> VideoSourceMetadataEvidence {
        let mdcv = parseMasteringDisplayColorVolume(from: ext, atoms: atoms)
        let clli = parseContentLightLevelInfo(from: ext, atoms: atoms)
        return VideoSourceMetadataEvidence(
            rawCodecId: fourCC,
            codecProfile: bitstreamInfo.profile,
            codecLevel: bitstreamInfo.level,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            frameRateFps: frameRateFps,
            colorRange: parseColorRange(from: ext),
            chromaSubsampling: bitstreamInfo.chromaSubsampling,
            dolbyVisionProfile: dovi.profile,
            dolbyVisionLevel: dovi.level,
            dolbyVisionBLSignalCompatibilityId: dovi.blCompatibilityId,
            dolbyVisionRPUPresent: dovi.rpuPresent,
            dolbyVisionELPresent: dovi.elPresent,
            dolbyVisionBLPresent: dovi.blPresent,
            maxCLL: clli.maxCLL,
            maxFALL: clli.maxFALL,
            masteringDisplayMaxLuminance: mdcv.maxLuminance,
            masteringDisplayMinLuminance: mdcv.minLuminance
        )
    }

    public static func humanReadablePrimaries(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        if upper.contains("2020") { return "BT.2020" }
        if upper.contains("709") { return "BT.709" }
        if upper.contains("P3") { return "Display P3 / DCI-P3" }
        if upper.contains("601") || upper.contains("SMPTE_C") { return "BT.601" }
        return trimmed
    }

    public static func humanReadableTransferFunction(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        if upper.contains("2084") || upper.contains("PQ") { return "SMPTE ST 2084 (PQ)" }
        if upper.contains("HLG") || upper.contains("2100") || upper.contains("B67") { return "ITU-R BT.2100 HLG" }
        if upper.contains("709") { return "ITU-R BT.709" }
        if upper.contains("SRGB") { return "sRGB" }
        if upper.contains("240M") { return "SMPTE 240M" }
        return trimmed
    }

    public static func humanReadableMatrix(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        if upper.contains("2020_C") || upper.contains("2020C") { return "BT.2020 constant" }
        if upper.contains("2020") { return "BT.2020 non-constant" }
        if upper.contains("709") { return "BT.709" }
        if upper.contains("601") { return "BT.601" }
        return trimmed
    }

    private static func codecLabel(for subType: FourCharCode, fourCC: String?) -> String {
        switch subType {
        case kCMVideoCodecType_H264: return "H264"
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha, 0x64766831, 0x64766865: return "HEVC"
        case kCMVideoCodecType_AV1, 0x64617631, 0x64766131: return "AV1"
        case kCMVideoCodecType_VP9: return "VP9"
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes4444: return "ProRes"
        default: return fourCC ?? "VIDEO"
        }
    }

    private static func fourCharCodeString(_ code: FourCharCode) -> String? {
        guard code != 0 else { return nil }
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
    }

    private static func parseColorRange(from ext: [String: Any]?) -> String? {
        guard let ext else { return nil }
        if let full = ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool {
            return full ? "Full (PC)" : "Video (Limited)"
        }
        return nil
    }

    private static func parseExplicitBitDepth(from ext: [String: Any]?) -> Int? {
        guard let ext else { return nil }
        if let bpc = (ext["BitsPerComponent"] as? NSNumber)?.intValue, bpc > 0 { return bpc }
        if let depth = (ext[kCMFormatDescriptionExtension_Depth as String] as? NSNumber)?.intValue {
            if depth == 8 || depth == 10 || depth == 12 || depth == 16 { return depth }
        }
        return nil
    }

    private static func parseCodecConfigurationAtoms(
        atoms: [String: Any]?
    ) -> (profile: String?, level: String?, chromaSubsampling: String?, bitDepth: Int?) {
        guard let atoms else { return (nil, nil, nil, nil) }
        if let hvcC = atoms["hvcC"] as? Data, hvcC.count >= 22 {
            return parseHVCCAtom(hvcC)
        }
        if let avcC = atoms["avcC"] as? Data, avcC.count >= 4 {
            return parseAVCCAtom(avcC)
        }
        return (nil, nil, nil, nil)
    }

    private static func parseHVCCAtom(
        _ hvcC: Data
    ) -> (profile: String?, level: String?, chromaSubsampling: String?, bitDepth: Int?) {
        let profileIdc = Int(hvcC[1] & 0x1F)
        let levelIdc = Int(hvcC[12])
        let chromaIdc = Int(hvcC[16] & 0x03)
        let bitDepthLuma = Int(hvcC[17] & 0x07) + 8
        let profileMap: [Int: String] = [
            1: "Main", 2: "Main 10", 3: "Main Still Picture", 4: "Range Extensions"
        ]
        let chromaMap: [Int: String] = [1: "4:2:0", 2: "4:2:2", 3: "4:4:4"]
        let profile = profileMap[profileIdc] ?? "Profile \(profileIdc)"
        let level = levelIdc > 0 ? String(format: "%.1f", Double(levelIdc) / 30.0) : nil
        return (profile, level, chromaMap[chromaIdc], bitDepthLuma >= 8 ? bitDepthLuma : nil)
    }

    private static func parseAVCCAtom(
        _ avcC: Data
    ) -> (profile: String?, level: String?, chromaSubsampling: String?, bitDepth: Int?) {
        let profileIdc = Int(avcC[1])
        let levelIdc = Int(avcC[3])
        let profileMap: [Int: String] = [
            66: "Baseline", 77: "Main", 88: "Extended",
            100: "High", 110: "High 10", 122: "High 4:2:2", 244: "High 4:4:4"
        ]
        let profile = profileMap[profileIdc] ?? "Profile \(profileIdc)"
        let level = levelIdc > 0 ? String(format: "%.1f", Double(levelIdc) / 10.0) : nil
        return (profile, level, nil, profileIdc == 110 ? 10 : nil)
    }

    private static func parseMasteringDisplayColorVolume(
        from ext: [String: Any]?,
        atoms: [String: Any]?
    ) -> (maxLuminance: Double?, minLuminance: Double?) {
        let data = (ext?[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] as? Data)
            ?? (atoms?["mdcv"] as? Data) ?? (atoms?["SmDm"] as? Data)
        guard let data, data.count >= 24 else { return (nil, nil) }
        let maxRaw = UInt32(data[16]) << 24 | UInt32(data[17]) << 16 | UInt32(data[18]) << 8 | UInt32(data[19])
        let minRaw = UInt32(data[20]) << 24 | UInt32(data[21]) << 16 | UInt32(data[22]) << 8 | UInt32(data[23])
        let maxNits = Double(maxRaw) / 10000.0
        let minNits = Double(minRaw) / 10000.0
        return (maxNits > 0 ? maxNits : nil, minNits >= 0 ? minNits : nil)
    }

    private static func parseContentLightLevelInfo(
        from ext: [String: Any]?,
        atoms: [String: Any]?
    ) -> (maxCLL: Int?, maxFALL: Int?) {
        let data = (ext?[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] as? Data)
            ?? (atoms?["clli"] as? Data) ?? (atoms?["CoLL"] as? Data)
        guard let data, data.count >= 4 else { return (nil, nil) }
        let cll = Int(UInt16(data[0]) << 8 | UInt16(data[1]))
        let fall = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
        return (cll > 0 ? cll : nil, fall > 0 ? fall : nil)
    }

    private static func parseDolbyVisionConfiguration(
        from ext: [String: Any]?,
        atoms: [String: Any]?
    ) -> (profile: Int?, level: Int?, blCompatibilityId: Int?, rpuPresent: Bool?, elPresent: Bool?, blPresent: Bool?) {
        let data = (ext?["DolbyVisionConfigurationBox"] as? Data)
            ?? (ext?["dvcC"] as? Data) ?? (ext?["dvvC"] as? Data)
            ?? (atoms?["dvcC"] as? Data) ?? (atoms?["dvvC"] as? Data) ?? (atoms?["dvwC"] as? Data)
        guard let data, data.count >= 5 else { return (nil, nil, nil, nil, nil, nil) }
        let profile = Int((data[2] >> 1) & 0x7F)
        let level = Int(((data[2] & 0x01) << 5) | ((data[3] >> 3) & 0x1F))
        let rpu = (data[3] & 0x04) != 0
        let el = (data[3] & 0x02) != 0
        let bl = (data[3] & 0x01) != 0
        let compatId = Int((data[4] >> 4) & 0x0F)
        return (profile, level, compatId, rpu, el, bl)
    }

    /// Maps container/bitstream color primaries token to CoreMedia `CFString` constant.
    public static func mapColorPrimariesToCoreMedia(_ raw: String?) -> CFString? {
        guard let upper = raw?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines), !upper.isEmpty else {
            return nil
        }
        if upper.contains("2020") { return kCMFormatDescriptionColorPrimaries_ITU_R_2020 }
        if upper.contains("P3") || upper.contains("DCI") { return kCMFormatDescriptionColorPrimaries_DCI_P3 }
        if upper.contains("709") { return kCMFormatDescriptionColorPrimaries_ITU_R_709_2 }
        if upper.contains("601") || upper.contains("SMPTE_C") { return kCMFormatDescriptionColorPrimaries_SMPTE_C }
        return raw as CFString?
    }

    /// Maps container/bitstream transfer characteristics token to CoreMedia `CFString` constant.
    public static func mapTransferFunctionToCoreMedia(_ raw: String?) -> CFString? {
        guard let upper = raw?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines), !upper.isEmpty else {
            return nil
        }
        if upper.contains("2084") || upper.contains("PQ") {
            return kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
        }
        if upper.contains("HLG") || upper.contains("2100") || upper.contains("B67") {
            return kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
        }
        if upper.contains("709") || upper.contains("601") {
            return kCMFormatDescriptionTransferFunction_ITU_R_709_2
        }
        if upper.contains("240M") {
            return kCMFormatDescriptionTransferFunction_SMPTE_240M_1995
        }
        return raw as CFString?
    }

    /// Maps container/bitstream YCbCr matrix token to CoreMedia `CFString` constant.
    public static func mapYCbCrMatrixToCoreMedia(_ raw: String?) -> CFString? {
        guard let upper = raw?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines), !upper.isEmpty else {
            return nil
        }
        if upper.contains("2020") { return kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 }
        if upper.contains("709") { return kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 }
        if upper.contains("601") { return kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 }
        if upper.contains("240M") { return kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995 }
        return raw as CFString?
    }
}
