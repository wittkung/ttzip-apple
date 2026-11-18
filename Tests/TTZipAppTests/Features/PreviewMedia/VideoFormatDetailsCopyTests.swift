// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTMediaKit
import XCTest
@testable import TTZipPreviewKit

final class VideoFormatDetailsCopyTests: XCTestCase {
    @MainActor
    func testVideoFormatDetailsKeepsSourceEvidenceAndOutputRowsSeparate() {
        let source = VideoFormatPresentationState(
            codecLabel: "HEVC", width: 3840, height: 2160, bitDepth: 10,
            colorPrimaries: "BT.2020", transferFunction: "SMPTE ST 2084 (PQ)",
            yCbCrMatrix: "BT.2020", sourceDynamicRange: .hdr10,
            sourceMetadata: VideoSourceMetadataEvidence(
                rawCodecId: "hvc1", codecProfile: "Main 10", frameRateFps: 59.94,
                chromaSubsampling: "4:2:0", maxCLL: 1000,
                masteringDisplayMaxLuminance: 1000, masteringDisplayMinLuminance: 0.005
            )
        )

        let unconfirmed = source.applyingDisplayObservation(.init(
            screenSupportsEDR: false, observedSampleDynamicRange: .hdr10
        )).comparisonSnapshot
        XCTAssertTrue(unconfirmed.sourceSection.codecAndProfileText.contains("HEVC (hvc1) · Main 10"))
        XCTAssertEqual(unconfirmed.sourceSection.resolutionAndFrameRateText, "3840×2160 (4K) · 59.94 fps")
        XCTAssertEqual(unconfirmed.sourceSection.bitDepthAndChromaText, "10-bit · 4:2:0")
        XCTAssertEqual(unconfirmed.sourceSection.colorPrimariesText, "BT.2020")
        XCTAssertEqual(unconfirmed.sourceSection.transferFunctionText, "SMPTE ST 2084 (PQ)")
        XCTAssertEqual(unconfirmed.sourceSection.hdrMetadataText, "Mastering 1000 / 0.0050 nits · MaxCLL 1000 nits")
        XCTAssertTrue(unconfirmed.outputSection.colorMappingText.contains("EDR 未启用 / 输出待确认"))
        XCTAssertEqual(unconfirmed.sourceSection.rows.map(\.id), [
            "codec_profile", "resolution_fps", "bit_depth_chroma", "color_primaries",
            "transfer_function", "ycbcr_matrix", "source_dynamic_range", "hdr_metadata",
        ])
        XCTAssertEqual(unconfirmed.outputSection.rows.map(\.id), [
            "active_output", "color_mapping", "renderer_pipeline", "screen_headroom", "optical_boundary",
        ])
        XCTAssertEqual(unconfirmed.sourceSection.rows.first?.label, TTZipVideoInteractionLocalization.text(.fieldCodecProfile))
        XCTAssertEqual(unconfirmed.outputSection.rows.first?.label, TTZipVideoInteractionLocalization.text(.fieldActiveOutput))

        let toneMapped = source.applyingDisplayObservation(.init(
            screenSupportsEDR: false, isToneMappedFallbackConfirmed: true, observedSampleDynamicRange: .sdr
        )).comparisonSnapshot
        XCTAssertEqual(toneMapped.badgeText, "SDR")
        XCTAssertEqual(toneMapped.sourceSection, unconfirmed.sourceSection)
        XCTAssertTrue(toneMapped.outputSection.colorMappingText.contains("HDR10 → SDR"))

        let hdr = source.applyingDisplayObservation(.init(
            screenSupportsEDR: true, isHDRPresentationConfirmed: true, observedSampleDynamicRange: .hdr10
        )).comparisonSnapshot
        XCTAssertTrue(hdr.outputSection.activeOutputText.contains("EDR 渲染管线已配置"))
        XCTAssertTrue(hdr.outputSection.activeOutputText.contains("硬件光学输出未验证"))
    }

    @MainActor
    func testVideoFormatDetailsDoesNotFillMissingSourceFromKnownSDROutput() {
        let missing = VideoFormatPresentationState(codecLabel: "H.264", width: 1920, height: 1080)
        let observed = missing.applyingDisplayObservation(.init(
            screenSupportsEDR: false, isSDRPresentationConfirmed: true,
            hasEnqueuedVideoSample: true, sampleTransferFunction: "BT.709", observedSampleDynamicRange: .sdr
        )).comparisonSnapshot
        let notProvided = VideoInteractionLocalization.text(.notProvided)
        XCTAssertEqual(observed.badgeText, "SDR")
        XCTAssertEqual(observed.sourceSection.colorPrimariesText, notProvided)
        XCTAssertEqual(observed.sourceSection.transferFunctionText, notProvided)
        XCTAssertEqual(observed.sourceSection.sourceDynamicRangeText, notProvided)
        XCTAssertEqual(observed.sourceSection.hdrMetadataText, notProvided)
        XCTAssertTrue(observed.outputSection.colorMappingText.contains(notProvided))

        let dolbyVision = VideoFormatPresentationState(codecLabel: "AV1", sourceDynamicRange: .dolbyVision)
        let fallback = dolbyVision.applyingDisplayObservation(.init(
            screenSupportsEDR: false, isToneMappedFallbackConfirmed: true, observedSampleDynamicRange: .sdr
        )).comparisonSnapshot
        XCTAssertTrue(fallback.outputSection.colorMappingText.contains("DoVi → SDR"))
    }

    func testVideoDetailsAndRotationCopyKeepsStableKeysAndFallbacks() {
        let rotation = TTZipVideoInteractionLocaleKey.rotateClockwise
        XCTAssertEqual(rotation.rawValue, "media.video.v2.rotateClockwise")
        XCTAssertEqual(rotation.fallbackTranslation(for: .en), "Rotate 90° Clockwise")
        XCTAssertEqual(rotation.fallbackTranslation(for: .zhHans), "顺时针旋转 90°")
        XCTAssertEqual(rotation.fallbackTranslation(for: .zhHant), "順時針旋轉 90°")

        let details = TTZipVideoInteractionLocaleKey.formatDetails
        XCTAssertEqual(details.rawValue, "media.video.v2.formatDetails")
        XCTAssertEqual(details.fallbackTranslation(for: .en), "Source & Output Format")
        XCTAssertEqual(details.fallbackTranslation(for: .zhHans), "源参数与当前输出对照")
        XCTAssertEqual(details.fallbackTranslation(for: .zhHant), "來源參數與目前輸出對照")
    }
}
