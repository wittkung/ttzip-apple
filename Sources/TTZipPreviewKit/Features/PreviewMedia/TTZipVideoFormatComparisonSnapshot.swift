// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTMediaKit

// MARK: - Partitioned Source vs. Output Comparison Snapshot Models

/// A key-value row with the availability of its format evidence.
struct TTZipVideoFormatDetailRow: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
    let isProvided: Bool

    init(id: String, label: String, value: String, isProvided: Bool = true) {
        self.id = id
        self.label = label
        self.value = value
        self.isProvided = isProvided
    }
}

/// Evidence-backed source parameters section model.
struct TTZipVideoFormatSourceSectionModel: Equatable, Sendable {
    let title: String
    let codecAndProfileText: String
    let resolutionAndFrameRateText: String
    let bitDepthAndChromaText: String
    let colorPrimariesText: String
    let transferFunctionText: String
    let matrixAndRangeText: String
    let sourceDynamicRangeText: String
    let hdrMetadataText: String
    let rows: [TTZipVideoFormatDetailRow]
}

/// Renderer, sample buffer attachment, color mapping, and screen observation section model.
struct TTZipVideoFormatOutputSectionModel: Equatable, Sendable {
    let title: String
    let activeOutputText: String
    let colorMappingText: String
    let rendererAndAttachmentText: String
    let screenCapabilityUpperBoundText: String
    let opticalBoundaryText: String
    let rows: [TTZipVideoFormatDetailRow]
}

/// Source format evidence and observed renderer output for comparison.
struct TTZipVideoFormatComparisonSnapshot: Equatable, Sendable {
    let badgeText: String
    let namedSourceAndOutputBadgeText: String
    let headerTitle: String
    let sourceSection: TTZipVideoFormatSourceSectionModel
    let outputSection: TTZipVideoFormatOutputSectionModel
}

// MARK: - Snapshot Construction from VideoFormatPresentationState

extension VideoFormatPresentationState {
    /// Builds the partitioned Source vs. Output comparison snapshot from current presentation evidence.
    @MainActor
    var comparisonSnapshot: TTZipVideoFormatComparisonSnapshot {
        let notProvided = VideoInteractionLocalization.text(.notProvided)
        let sourceSection = buildSourceSection(notProvided: notProvided)
        let outputSection = buildOutputSection(notProvided: notProvided)
        return TTZipVideoFormatComparisonSnapshot(
            badgeText: alwaysAvailableBadgeText,
            namedSourceAndOutputBadgeText: namedSourceAndOutputBadgeText,
            headerTitle: TTZipVideoInteractionLocalization.text(.formatDetails),
            sourceSection: sourceSection,
            outputSection: outputSection
        )
    }

    @MainActor
    private func buildSourceSection(notProvided: String) -> TTZipVideoFormatSourceSectionModel {
        let codecRow = formatSourceCodecAndProfile(notProvided: notProvided)
        let dimRow = formatSourceDimensionsAndFrameRate(notProvided: notProvided)
        let bitRow = formatSourceBitDepthAndChroma(notProvided: notProvided)
        let primVal = CMFormatDescriptionMetadataExtractor.humanReadablePrimaries(colorPrimaries)
        let trcVal = CMFormatDescriptionMetadataExtractor.humanReadableTransferFunction(transferFunction)
        let matRow = formatSourceMatrixAndRange(notProvided: notProvided)
        let srcRangeProvided = sourceDynamicRange != .unknown
        let srcRangeVal = sourceDynamicRangeDescription
        let hdrMetaRow = formatSourceHDRMetadata(notProvided: notProvided)

        let rows: [TTZipVideoFormatDetailRow] = [
            TTZipVideoFormatDetailRow(
                id: "codec_profile",
                label: TTZipVideoInteractionLocalization.text(.fieldCodecProfile),
                value: codecRow.text,
                isProvided: codecRow.provided
            ),
            TTZipVideoFormatDetailRow(
                id: "resolution_fps",
                label: TTZipVideoInteractionLocalization.text(.fieldResolutionFps),
                value: dimRow.text,
                isProvided: dimRow.provided
            ),
            TTZipVideoFormatDetailRow(
                id: "bit_depth_chroma",
                label: TTZipVideoInteractionLocalization.text(.fieldBitDepthChroma),
                value: bitRow.text,
                isProvided: bitRow.provided
            ),
            TTZipVideoFormatDetailRow(
                id: "color_primaries",
                label: TTZipVideoInteractionLocalization.text(.fieldColorPrimaries),
                value: primVal ?? notProvided,
                isProvided: primVal != nil
            ),
            TTZipVideoFormatDetailRow(
                id: "transfer_function",
                label: TTZipVideoInteractionLocalization.text(.fieldTransferFunction),
                value: trcVal ?? notProvided,
                isProvided: trcVal != nil
            ),
            TTZipVideoFormatDetailRow(
                id: "ycbcr_matrix",
                label: TTZipVideoInteractionLocalization.text(.fieldYCbCrMatrix),
                value: matRow.text,
                isProvided: matRow.provided
            ),
            TTZipVideoFormatDetailRow(
                id: "source_dynamic_range",
                label: TTZipVideoInteractionLocalization.text(.fieldSourceDynamicRange),
                value: srcRangeVal,
                isProvided: srcRangeProvided
            ),
            TTZipVideoFormatDetailRow(
                id: "hdr_metadata",
                label: TTZipVideoInteractionLocalization.text(.fieldHDRMetadata),
                value: hdrMetaRow.text,
                isProvided: hdrMetaRow.provided
            )
        ]

        return TTZipVideoFormatSourceSectionModel(
            title: TTZipVideoInteractionLocalization.text(.sourceSectionTitle),
            codecAndProfileText: codecRow.text,
            resolutionAndFrameRateText: dimRow.text,
            bitDepthAndChromaText: bitRow.text,
            colorPrimariesText: primVal ?? notProvided,
            transferFunctionText: trcVal ?? notProvided,
            matrixAndRangeText: matRow.text,
            sourceDynamicRangeText: srcRangeVal,
            hdrMetadataText: hdrMetaRow.text,
            rows: rows
        )
    }

    @MainActor
    private func buildOutputSection(notProvided: String) -> TTZipVideoFormatOutputSectionModel {
        let activeOutText = formatActiveOutputStatus()
        let mappingText = formatColorMappingExplanation(notProvided: notProvided)
        let rendererText = formatRendererAndAttachments(notProvided: notProvided)
        let screenText = formatScreenCapabilityUpperBound(notProvided: notProvided)
        let boundaryText = TTZipVideoInteractionLocalization.text(.opticalBoundaryNote)
        let hasScreenObs = displayObservation?.currentEDRHeadroom != nil
            || displayObservation?.potentialEDRHeadroom != nil
            || displayObservation?.screenLocalizedName != nil

        let rows: [TTZipVideoFormatDetailRow] = [
            TTZipVideoFormatDetailRow(
                id: "active_output",
                label: TTZipVideoInteractionLocalization.text(.fieldActiveOutput),
                value: activeOutText,
                isProvided: activeOutputDynamicRange != .unknown
            ),
            TTZipVideoFormatDetailRow(
                id: "color_mapping",
                label: TTZipVideoInteractionLocalization.text(.fieldToneMapping),
                value: mappingText
            ),
            TTZipVideoFormatDetailRow(
                id: "renderer_pipeline",
                label: TTZipVideoInteractionLocalization.text(.fieldRendererPipeline),
                value: rendererText,
                isProvided: displayObservation != nil
            ),
            TTZipVideoFormatDetailRow(
                id: "screen_headroom",
                label: TTZipVideoInteractionLocalization.text(.fieldScreenHeadroom),
                value: screenText,
                isProvided: hasScreenObs
            ),
            TTZipVideoFormatDetailRow(
                id: "optical_boundary",
                label: TTZipVideoInteractionLocalization.text(.fieldOpticalBoundary),
                value: boundaryText
            )
        ]

        return TTZipVideoFormatOutputSectionModel(
            title: TTZipVideoInteractionLocalization.text(.outputSectionTitle),
            activeOutputText: activeOutText,
            colorMappingText: mappingText,
            rendererAndAttachmentText: rendererText,
            screenCapabilityUpperBoundText: screenText,
            opticalBoundaryText: boundaryText,
            rows: rows
        )
    }
}

// MARK: - Field Formatting Helpers

extension VideoFormatPresentationState {
    private func nonEmptyOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func formatSourceCodecAndProfile(notProvided: String) -> (text: String, provided: Bool) {
        var parts: [String] = []
        if let rawCodec = nonEmptyOrNil(codecLabel) {
            let normalized = Self.normalizeCodecDisplayLabel(rawCodec)
            if let fourCC = nonEmptyOrNil(rawCodecId),
               normalized.caseInsensitiveCompare(fourCC) != .orderedSame {
                parts.append("\(normalized) (\(fourCC))")
            } else if normalized.caseInsensitiveCompare(rawCodec) != .orderedSame {
                parts.append("\(normalized) (\(rawCodec))")
            } else {
                parts.append(normalized)
            }
        }
        if let profile = nonEmptyOrNil(codecProfile) {
            parts.append(profile)
        }
        if let level = nonEmptyOrNil(codecLevel) {
            parts.append("Level \(level)")
        }
        guard !parts.isEmpty else { return (notProvided, false) }
        return (parts.joined(separator: " · "), true)
    }

    private func formatSourceDimensionsAndFrameRate(notProvided: String) -> (text: String, provided: Bool) {
        var parts: [String] = []
        if width > 0, height > 0 {
            var dim = "\(width)×\(height)"
            if let tier = resolutionTierLabel {
                dim += " (\(tier))"
            }
            if let dw = displayWidth,
               let dh = displayHeight,
               dw > 0, dh > 0, (dw != width || dh != height) {
                dim += " [Display \(dw)×\(dh)]"
            }
            parts.append(dim)
        }
        if let fps = frameRateFps, fps > 0 {
            let formattedFps = abs(fps.rounded() - fps) < 0.01
                ? String(format: "%.0f fps", fps)
                : String(format: "%.2f fps", fps)
            parts.append(formattedFps)
        }
        guard !parts.isEmpty else { return (notProvided, false) }
        return (parts.joined(separator: " · "), true)
    }

    private func formatSourceBitDepthAndChroma(notProvided: String) -> (text: String, provided: Bool) {
        var parts: [String] = []
        if let depth = bitDepth, depth > 0 {
            parts.append("\(depth)-bit")
        }
        if let chroma = nonEmptyOrNil(chromaSubsampling) {
            parts.append(chroma)
        }
        guard !parts.isEmpty else { return (notProvided, false) }
        return (parts.joined(separator: " · "), true)
    }

    private func formatSourceMatrixAndRange(notProvided: String) -> (text: String, provided: Bool) {
        var parts: [String] = []
        if let matrix = CMFormatDescriptionMetadataExtractor.humanReadableMatrix(yCbCrMatrix) {
            parts.append(matrix)
        }
        if let range = nonEmptyOrNil(colorRange) {
            parts.append(range)
        }
        guard !parts.isEmpty else { return (notProvided, false) }
        return (parts.joined(separator: " · "), true)
    }

    private func formatSourceHDRMetadata(notProvided: String) -> (text: String, provided: Bool) {
        var parts: [String] = []
        if let maxLum = masteringDisplayMaxLuminance {
            let minStr = masteringDisplayMinLuminance.map { String(format: "%.4f", $0) } ?? "?"
            parts.append(String(format: "Mastering %.0f / %@ nits", maxLum, minStr))
        }
        if let cll = maxCLL, cll > 0 {
            parts.append("MaxCLL \(cll) nits")
        }
        if let fall = maxFALL, fall > 0 {
            parts.append("MaxFALL \(fall) nits")
        }
        appendDolbyVisionMetadataParts(into: &parts)
        guard !parts.isEmpty else { return (notProvided, false) }
        return (parts.joined(separator: " · "), true)
    }

    private func appendDolbyVisionMetadataParts(into parts: inout [String]) {
        if let profile = dolbyVisionProfile {
            var dv = "DoVi P\(profile)"
            if let level = dolbyVisionLevel { dv += ".L\(level)" }
            if let compat = dolbyVisionBLSignalCompatibilityId {
                dv += " (BL Compat \(compat))"
            }
            parts.append(dv)
        }
        var layers: [String] = []
        if dolbyVisionBLPresent == true { layers.append("BL") }
        if dolbyVisionELPresent == true { layers.append("EL") }
        if dolbyVisionRPUPresent == true { layers.append("RPU") }
        if !layers.isEmpty {
            parts.append("Layers: \(layers.joined(separator: "+"))")
        }
    }

    @MainActor
    private func formatActiveOutputStatus() -> String {
        switch outputObservationStatus {
        case .confirmed(let mode) where mode != .unknown:
            if mode.isHDR {
                return "\(outputDynamicRangeDescription)（样本已提交 · EDR 渲染管线已配置，硬件光学输出未验证）"
            }
            return "\(outputDynamicRangeDescription)（可显示样本已提交 · 渲染管线已配置）"
        case .detecting:
            if let reason = nonEmptyOrNil(displayObservation?.diagnosticReason) {
                return "\(VideoPlaybackLocalization.text(.formatBadgeDetectingOutput))（\(reason)）"
            }
            return VideoPlaybackLocalization.text(.formatBadgeDetectingOutput)
        case .diagnostic(let reason):
            return "\(VideoInteractionLocalization.text(.outputUnconfirmed))（\(reason)）"
        case .confirmed:
            return outputDynamicRangeDescription
        }
    }

    @MainActor
    private func formatColorMappingExplanation(notProvided: String) -> String {
        if isToneMappedFallbackToSDR {
            return formatToneMappedExplanation()
        }
        if activeOutputDynamicRange.isHDR {
            return formatConfirmedHDRMappingExplanation()
        }
        if activeOutputDynamicRange == .sdr {
            return formatConfirmedSDRMappingExplanation(notProvided: notProvided)
        }
        return formatUnconfirmedMappingExplanation(notProvided: notProvided)
    }

    private func formatToneMappedExplanation() -> String {
        let srcLabel = sourceDynamicRange.isHDR ? sourceDynamicRange.rawValue : "HDR"
        let evidence = nonEmptyOrNil(displayObservation?.diagnosticReason)
            ?? "已由输出样本传递函数或显式色调映射转换确认"
        return "\(srcLabel) → SDR（源为 \(srcLabel)，当前输出已确认色调映射为 SDR；依据：\(evidence)）"
    }

    @MainActor
    private func formatConfirmedHDRMappingExplanation() -> String {
        if sourceDynamicRange == .dolbyVision && activeOutputDynamicRange != .dolbyVision {
            return "\(sourceDynamicRangeDescription) → \(activeOutputDynamicRange.rawValue)（源为 Dolby Vision，渲染管线按 \(activeOutputDynamicRange.rawValue) EDR 传递函数配置；不借源标记自动声称 Dolby Vision 输出，光学输出未验证）"
        }
        return "\(sourceDynamicRangeDescription) → \(activeOutputDynamicRange.rawValue)（EDR 渲染管线已配置，硬件最终光学输出未直接测量）"
    }

    private func formatConfirmedSDRMappingExplanation(notProvided: String) -> String {
        if sourceDynamicRange == .sdr {
            return "SDR → SDR（样本携带明确 SDR 传递函数，标准动态范围直出）"
        }
        let sampleTF = displayObservation?.sampleTransferFunction ?? "BT.709"
        return "源动态范围\(notProvided) → 入队样本携带明确 SDR 传递函数（\(sampleTF)），按 SDR 输出"
    }

    @MainActor
    private func formatUnconfirmedMappingExplanation(notProvided: String) -> String {
        switch outputObservationStatus {
        case .detecting:
            if let reason = nonEmptyOrNil(displayObservation?.diagnosticReason) {
                return "\(VideoPlaybackLocalization.text(.formatBadgeDetectingOutput))（\(reason)）"
            }
            return VideoPlaybackLocalization.text(.formatBadgeDetectingOutput)
        case .diagnostic(let reason):
            return reason.contains("EDR 未启用") ? reason : "输出待确认（\(reason)）"
        case .confirmed:
            return notProvided
        }
    }

    private func formatRendererAndAttachments(notProvided: String) -> String {
        guard let obs = displayObservation else {
            return notProvided
        }
        let edrFlag = (obs.isRendererEDRConfigured == true) ? "EDR=ON" : "EDR=OFF"
        let readyFlag: String
        if !obs.hasEnqueuedVideoSample {
            readyFlag = "Pending"
        } else if obs.isDetecting {
            readyFlag = "Enqueued-AwaitingTimebaseOrPreroll"
        } else {
            readyFlag = "Submitted-PipelineConfigured"
        }
        let hasAttachments = obs.sampleTransferFunction != nil
            || obs.sampleColorPrimaries != nil
            || obs.sampleYCbCrMatrix != nil
        let attachFlag = hasAttachments ? "Attachments=Present" : "Attachments=None"
        var summary = "\(obs.rendererName) (\(edrFlag), \(readyFlag), \(attachFlag))"
        if let tf = nonEmptyOrNil(obs.sampleTransferFunction) {
            summary += " · TRC=\(tf)"
        }
        if let prim = nonEmptyOrNil(obs.sampleColorPrimaries) {
            summary += " · Primaries=\(prim)"
        }
        return summary
    }

    private func formatScreenCapabilityUpperBound(notProvided: String) -> String {
        guard let obs = displayObservation,
              obs.currentEDRHeadroom != nil || obs.potentialEDRHeadroom != nil || obs.screenLocalizedName != nil else {
            return notProvided
        }
        let name = nonEmptyOrNil(obs.screenLocalizedName) ?? "Display"
        let cur = String(format: "%.2fx", obs.currentEDRHeadroom ?? 1.0)
        let maxPot = String(format: "%.2fx", obs.potentialEDRHeadroom ?? 1.0)
        return "\(name) · 当前可用 EDR Headroom \(cur) / 潜在上限 \(maxPot)（上限不等于实际 HDR 输出确认）"
    }
}
