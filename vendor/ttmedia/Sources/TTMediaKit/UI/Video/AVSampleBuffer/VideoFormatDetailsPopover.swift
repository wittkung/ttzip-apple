// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import TTKitDesign

// MARK: - Partitioned Source vs. Output Comparison Snapshot Models

/// Single key-value evidence row inside the video format comparison popover.
public struct VideoFormatDetailRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let value: String
    public let isProvided: Bool

    public init(id: String, label: String, value: String, isProvided: Bool = true) {
        self.id = id
        self.label = label
        self.value = value
        self.isProvided = isProvided
    }
}

/// Evidence-backed source parameters section model.
public struct VideoFormatSourceSectionModel: Equatable, Sendable {
    public let title: String
    public let codecAndProfileText: String
    public let resolutionAndFrameRateText: String
    public let bitDepthAndChromaText: String
    public let colorPrimariesText: String
    public let transferFunctionText: String
    public let matrixAndRangeText: String
    public let sourceDynamicRangeText: String
    public let hdrMetadataText: String
    public let rows: [VideoFormatDetailRow]
}

/// Renderer, sample buffer attachment, color mapping, and screen observation section model.
public struct VideoFormatOutputSectionModel: Equatable, Sendable {
    public let title: String
    public let activeOutputText: String
    public let colorMappingText: String
    public let rendererAndAttachmentText: String
    public let screenCapabilityUpperBoundText: String
    public let opticalBoundaryText: String
    public let rows: [VideoFormatDetailRow]
}

/// Complete partitioned comparison snapshot backing the interactive format popover.
public struct VideoFormatComparisonSnapshot: Equatable, Sendable {
    public let badgeText: String
    public let namedSourceAndOutputBadgeText: String
    public let headerTitle: String
    public let sourceSection: VideoFormatSourceSectionModel
    public let outputSection: VideoFormatOutputSectionModel
}

// MARK: - Snapshot Construction from VideoFormatPresentationState

extension VideoFormatPresentationState {
    /// Builds the partitioned Source vs. Output comparison snapshot from current presentation evidence.
    @MainActor
    public var comparisonSnapshot: VideoFormatComparisonSnapshot {
        let notProvided = VideoInteractionLocalization.text(.notProvided)
        let sourceSection = buildSourceSection(notProvided: notProvided)
        let outputSection = buildOutputSection(notProvided: notProvided)
        return VideoFormatComparisonSnapshot(
            badgeText: alwaysAvailableBadgeText,
            namedSourceAndOutputBadgeText: namedSourceAndOutputBadgeText,
            headerTitle: VideoInteractionLocalization.text(.formatDetails),
            sourceSection: sourceSection,
            outputSection: outputSection
        )
    }

    @MainActor
    private func buildSourceSection(notProvided: String) -> VideoFormatSourceSectionModel {
        let codecRow = formatSourceCodecAndProfile(notProvided: notProvided)
        let dimRow = formatSourceDimensionsAndFrameRate(notProvided: notProvided)
        let bitRow = formatSourceBitDepthAndChroma(notProvided: notProvided)
        let primVal = CMFormatDescriptionMetadataExtractor.humanReadablePrimaries(colorPrimaries)
        let trcVal = CMFormatDescriptionMetadataExtractor.humanReadableTransferFunction(transferFunction)
        let matRow = formatSourceMatrixAndRange(notProvided: notProvided)
        let srcRangeProvided = sourceDynamicRange != .unknown
        let srcRangeVal = sourceDynamicRangeDescription
        let hdrMetaRow = formatSourceHDRMetadata(notProvided: notProvided)

        let rows: [VideoFormatDetailRow] = [
            VideoFormatDetailRow(
                id: "codec_profile",
                label: VideoInteractionLocalization.text(.fieldCodecProfile),
                value: codecRow.text,
                isProvided: codecRow.provided
            ),
            VideoFormatDetailRow(
                id: "resolution_fps",
                label: VideoInteractionLocalization.text(.fieldResolutionFps),
                value: dimRow.text,
                isProvided: dimRow.provided
            ),
            VideoFormatDetailRow(
                id: "bit_depth_chroma",
                label: VideoInteractionLocalization.text(.fieldBitDepthChroma),
                value: bitRow.text,
                isProvided: bitRow.provided
            ),
            VideoFormatDetailRow(
                id: "color_primaries",
                label: VideoInteractionLocalization.text(.fieldColorPrimaries),
                value: primVal ?? notProvided,
                isProvided: primVal != nil
            ),
            VideoFormatDetailRow(
                id: "transfer_function",
                label: VideoInteractionLocalization.text(.fieldTransferFunction),
                value: trcVal ?? notProvided,
                isProvided: trcVal != nil
            ),
            VideoFormatDetailRow(
                id: "ycbcr_matrix",
                label: VideoInteractionLocalization.text(.fieldYCbCrMatrix),
                value: matRow.text,
                isProvided: matRow.provided
            ),
            VideoFormatDetailRow(
                id: "source_dynamic_range",
                label: VideoInteractionLocalization.text(.fieldSourceDynamicRange),
                value: srcRangeVal,
                isProvided: srcRangeProvided
            ),
            VideoFormatDetailRow(
                id: "hdr_metadata",
                label: VideoInteractionLocalization.text(.fieldHDRMetadata),
                value: hdrMetaRow.text,
                isProvided: hdrMetaRow.provided
            )
        ]

        return VideoFormatSourceSectionModel(
            title: VideoInteractionLocalization.text(.sourceSectionTitle),
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
    private func buildOutputSection(notProvided: String) -> VideoFormatOutputSectionModel {
        let activeOutText = formatActiveOutputStatus()
        let mappingText = formatColorMappingExplanation(notProvided: notProvided)
        let rendererText = formatRendererAndAttachments(notProvided: notProvided)
        let screenText = formatScreenCapabilityUpperBound(notProvided: notProvided)
        let boundaryText = VideoInteractionLocalization.text(.opticalBoundaryNote)
        let hasScreenObs = displayObservation?.currentEDRHeadroom != nil
            || displayObservation?.potentialEDRHeadroom != nil
            || displayObservation?.screenLocalizedName != nil

        let rows: [VideoFormatDetailRow] = [
            VideoFormatDetailRow(
                id: "active_output",
                label: VideoInteractionLocalization.text(.fieldActiveOutput),
                value: activeOutText,
                isProvided: activeOutputDynamicRange != .unknown
            ),
            VideoFormatDetailRow(
                id: "color_mapping",
                label: VideoInteractionLocalization.text(.fieldToneMapping),
                value: mappingText
            ),
            VideoFormatDetailRow(
                id: "renderer_pipeline",
                label: VideoInteractionLocalization.text(.fieldRendererPipeline),
                value: rendererText,
                isProvided: displayObservation != nil
            ),
            VideoFormatDetailRow(
                id: "screen_headroom",
                label: VideoInteractionLocalization.text(.fieldScreenHeadroom),
                value: screenText,
                isProvided: hasScreenObs
            ),
            VideoFormatDetailRow(
                id: "optical_boundary",
                label: VideoInteractionLocalization.text(.fieldOpticalBoundary),
                value: boundaryText
            )
        ]

        return VideoFormatOutputSectionModel(
            title: VideoInteractionLocalization.text(.outputSectionTitle),
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

// MARK: - Interactive Format Badge Button & Popover Views

/// Interactive format badge button that displays the short current output dynamic range and opens the comparison popover.
@MainActor
public struct VideoFormatBadgeButton: View {
    public let badgeText: String
    public let isCompact: Bool
    public let state: VideoFormatPresentationState
    @Binding public var isPopoverPresented: Bool
    public let onUserInteraction: () -> Void

    public init(
        badgeText: String,
        isCompact: Bool,
        state: VideoFormatPresentationState,
        isPopoverPresented: Binding<Bool>,
        onUserInteraction: @escaping () -> Void
    ) {
        self.badgeText = badgeText
        self.isCompact = isCompact
        self.state = state
        self._isPopoverPresented = isPopoverPresented
        self.onUserInteraction = onUserInteraction
    }

    public var body: some View {
        Button {
            isPopoverPresented.toggle()
            onUserInteraction()
        } label: {
            Text(badgeText)
                .font(.system(size: isCompact ? 9 : 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.white.opacity(isCompact ? 0.85 : 0.92))
                .padding(.horizontal, isCompact ? 4 : 6)
                .padding(.vertical, isCompact ? 2 : 3)
                .background(Color.white.opacity(0.14), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        Color.white.opacity(isCompact ? 0.14 : 0.20),
                        lineWidth: 0.5
                    )
                )
        }
        .buttonStyle(.plain)
        .background(
            FormatBadgeAppKitButtonBridge(badgeText: badgeText) {
                isPopoverPresented.toggle()
                onUserInteraction()
            }
        )
        .accessibilityIdentifier("video_format_badge_button")
        .accessibilityLabel(VideoInteractionLocalization.text(.formatDetails))
        .accessibilityValue(badgeText)
        .ttButtonHelp(VideoInteractionLocalization.text(.formatDetails))
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            VideoFormatDetailsPopover(state: state)
        }
    }
}

@MainActor
private struct FormatBadgeAppKitButtonBridge: NSViewRepresentable {
    let badgeText: String
    let onPress: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPress: onPress)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = FormatBadgeNSButton(title: badgeText, target: context.coordinator, action: #selector(Coordinator.handlePress))
        button.isBordered = false
        button.alphaValue = 0.01
        button.setAccessibilityIdentifier("video_format_badge_button")
        button.setAccessibilityLabel(VideoInteractionLocalization.text(.formatDetails))
        button.setAccessibilityValue(badgeText)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.onPress = onPress
        nsView.title = badgeText
        nsView.setAccessibilityLabel(VideoInteractionLocalization.text(.formatDetails))
        nsView.setAccessibilityValue(badgeText)
    }

    @MainActor
    final class FormatBadgeNSButton: NSButton {
        override func accessibilityPerformPress() -> Bool {
            _ = sendAction(action, to: target)
            return true
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPress: @MainActor () -> Void
        init(onPress: @escaping @MainActor () -> Void) { self.onPress = onPress }
        @objc func handlePress() { onPress() }
    }
}

/// Partitioned popover presenting native source parameters and observed rendering output.
@MainActor
public struct VideoFormatDetailsPopover: View {
    public let state: VideoFormatPresentationState

    public init(state: VideoFormatPresentationState) {
        self.state = state
    }

    public var body: some View {
        let snapshot = state.comparisonSnapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(snapshot.headerTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(snapshot.namedSourceAndOutputBadgeText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }

            Divider()

            sectionView(
                title: snapshot.sourceSection.title,
                rows: snapshot.sourceSection.rows
            )

            Divider()

            sectionView(
                title: snapshot.outputSection.title,
                rows: snapshot.outputSection.rows
            )
        }
        .padding(14)
        .frame(width: 420)
        .accessibilityIdentifier("video_format_details_popover")
    }

    @ViewBuilder
    private func sectionView(title: String, rows: [VideoFormatDetailRow]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 128, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: 11, weight: row.isProvided ? .medium : .regular, design: .monospaced))
                        .foregroundStyle(row.isProvided ? .primary : .tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
