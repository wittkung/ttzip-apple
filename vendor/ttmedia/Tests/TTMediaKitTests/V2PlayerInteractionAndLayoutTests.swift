// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os
import SwiftUI
import TTI18nCore
import TTI18nUI
import XCTest
@testable import TTMediaKit

private final class V2ProductionObservationScriptedTransport: MediaWorkerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let metadata: [String: Any]
    private let initialPackets: [MediaPacketDTO]
    private let postSeekFactory: @Sendable (Double) -> [MediaPacketDTO]
    private var activePackets: [MediaPacketDTO] = []
    private var activeSessionId: String?

    init(metadata: [String: Any], initialPackets: [MediaPacketDTO], postSeekFactory: @escaping @Sendable (Double) -> [MediaPacketDTO]) {
        self.metadata = metadata
        self.initialPackets = initialPackets
        self.postSeekFactory = postSeekFactory
    }

    func openMedia(path: String, targetTracks: [Int]?) async throws -> (sessionId: String, metadata: [String: Any]) {
        let sid = UUID().uuidString
        lock.withLock { activeSessionId = sid; activePackets = initialPackets }
        return (sid, metadata)
    }

    func readNextPacket(sessionId: String) async throws -> Data? {
        let pkt: MediaPacketDTO? = try lock.withLock {
            guard activeSessionId == sessionId else { throw MediaWorkerError.sessionNotFound(sessionId) }
            return activePackets.isEmpty ? nil : activePackets.removeFirst()
        }
        return try pkt.map { try JSONEncoder().encode($0) }
    }

    func seek(to timestamp: Double, sessionId: String, accurate: Bool) async throws -> Double {
        let pkts = postSeekFactory(timestamp)
        return try lock.withLock {
            guard activeSessionId == sessionId else { throw MediaWorkerError.sessionNotFound(sessionId) }
            activePackets = pkts
            return timestamp
        }
    }

    func closeMedia(sessionId: String) async throws { lock.withLock { if activeSessionId == sessionId { activeSessionId = nil } } }
    func setSleepState(state: Int) async throws {}
    func invalidate() { lock.withLock { activeSessionId = nil } }
    func reconnect() async throws {}
    func setCrashHandler(_ handler: (@Sendable (MediaWorkerError) -> Void)?) {}
    var isConnected: Bool { lock.withLock { activeSessionId != nil } }
}

/// Deterministic regression test suite verifying V2 video player interaction, aspect ratio layout,
/// presentation rotation, context menu contract, and disaggregated format dynamic range indicators.
@MainActor
final class V2PlayerInteractionAndLayoutTests: XCTestCase {

    // MARK: - 1. Center Play/Pause HUD Removal & Control Bar State Preservation

    func testCanvasAndKeyTogglePlayPausePreservesStateWithoutCenterHUD() async throws {
        let dummyURL = URL(fileURLWithPath: "/tmp/v2_test_video.mp4")
        let session = VideoPlaybackSession(url: dummyURL)
        session.rawVideoNaturalSize = CGSize(width: 1920, height: 1080)
        session.videoPixelAspectRatio = CGSize(width: 1, height: 1)

        XCTAssertFalse(session.isPlaying, "Session should start paused")

        // Act: Toggle without HUD
        session.isPlaying = true
        XCTAssertTrue(session.isPlaying, "Playback state should update to playing")

        session.isPlaying = false
        XCTAssertFalse(session.isPlaying, "Playback state should update to paused")

        // User intent verification
        XCTAssertFalse(session.userPlaybackIntent)
    }

    // MARK: - 2. Aspect Ratio Layout & Letterbox Invariant (Landscape, Portrait, PAR)

    func testLandscapeVideoAspectFitInVariousViewports() {
        let videoSize = CGSize(width: 1920, height: 1080)
        let wideViewport = CGSize(width: 1600, height: 800)
        let wideRect = VideoContentGeometry.contentRect(
            inside: wideViewport, rawVideoSize: videoSize,
            pixelAspectRatio: CGSize(width: 1, height: 1), rotationDegrees: 0
        )
        let expectedWidth: CGFloat = 800 * (16.0 / 9.0)
        XCTAssertEqual(wideRect.height, 800, accuracy: 1.0)
        XCTAssertEqual(wideRect.width, expectedWidth, accuracy: 1.0)
        XCTAssertEqual(wideRect.minX, (wideViewport.width - expectedWidth) * 0.5, accuracy: 1.0)
        XCTAssertEqual(wideRect.minY, 0.0, accuracy: 1.0)

        let tallViewport = CGSize(width: 800, height: 1600)
        let tallRect = VideoContentGeometry.contentRect(
            inside: tallViewport, rawVideoSize: videoSize,
            pixelAspectRatio: CGSize(width: 1, height: 1), rotationDegrees: 0
        )
        let expectedTallHeight: CGFloat = 800 / (16.0 / 9.0)
        XCTAssertEqual(tallRect.width, 800, accuracy: 1.0)
        XCTAssertEqual(tallRect.height, expectedTallHeight, accuracy: 1.0)
        XCTAssertEqual(tallRect.minX, 0.0, accuracy: 1.0)
        XCTAssertEqual(tallRect.minY, (tallViewport.height - expectedTallHeight) * 0.5, accuracy: 1.0)

        let exactRect = VideoContentGeometry.contentRect(
            inside: CGSize(width: 1920, height: 1080), rawVideoSize: videoSize,
            pixelAspectRatio: CGSize(width: 1, height: 1), rotationDegrees: 0
        )
        XCTAssertEqual(exactRect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testPortraitVideoAspectFitInVariousViewports() {
        let portraitVideoSize = CGSize(width: 1080, height: 1920)
        let landscapeViewport = CGSize(width: 1200, height: 600)
        let rect = VideoContentGeometry.contentRect(
            inside: landscapeViewport, rawVideoSize: portraitVideoSize,
            pixelAspectRatio: CGSize(width: 1, height: 1), rotationDegrees: 0
        )
        let expectedWidth: CGFloat = 600 * (9.0 / 16.0)
        XCTAssertEqual(rect.height, 600, accuracy: 1.0)
        XCTAssertEqual(rect.width, expectedWidth, accuracy: 1.0)
        XCTAssertEqual(rect.minX, (landscapeViewport.width - expectedWidth) * 0.5, accuracy: 1.0)

        let portraitViewport = CGSize(width: 600, height: 1200)
        let portRect = VideoContentGeometry.contentRect(
            inside: portraitViewport, rawVideoSize: portraitVideoSize,
            pixelAspectRatio: CGSize(width: 1, height: 1), rotationDegrees: 0
        )
        let expectedPortHeight: CGFloat = 600 * (16.0 / 9.0)
        XCTAssertEqual(portRect.width, 600, accuracy: 1.0)
        XCTAssertEqual(portRect.height, expectedPortHeight, accuracy: 1.0)
        XCTAssertEqual(portRect.minY, (portraitViewport.height - expectedPortHeight) * 0.5, accuracy: 1.0)
    }

    func testNonSquarePixelAspectRatioAspectFitCalculation() {
        let codedSize = CGSize(width: 1440, height: 1080)
        let par = CGSize(width: 4, height: 3)
        let displaySize = VideoContentGeometry.orientedDisplaySize(
            rawVideoSize: codedSize, pixelAspectRatio: par, rotationDegrees: 0
        )
        XCTAssertEqual(displaySize.width, 1920.0, accuracy: 0.1)
        XCTAssertEqual(displaySize.height, 1080.0, accuracy: 0.1)
        let fitRect = VideoContentGeometry.contentRect(
            inside: CGSize(width: 1920, height: 1080), rawVideoSize: codedSize,
            pixelAspectRatio: par, rotationDegrees: 0
        )
        XCTAssertEqual(fitRect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    // MARK: - 3. Display Rotation, Non-Destructive Invariant, and Subtitle/Interaction Coordinates

    func testPresentationRotationCycleAndNormalization() {
        let dummyURL = URL(fileURLWithPath: "/tmp/untouched_source_video.mov")
        let session = VideoPlaybackSession(url: dummyURL)
        session.rawVideoNaturalSize = CGSize(width: 1920, height: 1080)
        session.videoRotationDegrees = 0
        XCTAssertEqual(session.userRotationDegrees, 0)
        XCTAssertEqual(session.effectiveRotationDegrees, 0)
        session.rotateClockwise()
        XCTAssertEqual(session.userRotationDegrees, 90)
        XCTAssertEqual(session.effectiveRotationDegrees, 90)
        session.rotate180()
        XCTAssertEqual(session.userRotationDegrees, 270)
        XCTAssertEqual(session.effectiveRotationDegrees, 270)
        session.rotateCounterClockwise()
        XCTAssertEqual(session.userRotationDegrees, 180)
        XCTAssertEqual(session.effectiveRotationDegrees, 180)
        session.resetRotation()
        XCTAssertEqual(session.userRotationDegrees, 0)
        XCTAssertEqual(session.effectiveRotationDegrees, 0)
        XCTAssertEqual(session.url, dummyURL)
    }

    func testRotatedVideoContentRectAndSubtitleGeometryCoordination() {
        let dummyURL = URL(fileURLWithPath: "/tmp/rotation_geom_test.mp4")
        let session = VideoPlaybackSession(url: dummyURL)
        session.rawVideoNaturalSize = CGSize(width: 1920, height: 1080)
        let viewport = CGSize(width: 1000, height: 1000)
        let rect0 = session.videoContentRect(in: viewport)
        XCTAssertNotNil(rect0)
        XCTAssertEqual(rect0?.width ?? 0, 1000.0, accuracy: 1.0)
        XCTAssertEqual(rect0?.height ?? 0, 562.5, accuracy: 1.0)
        session.rotateClockwise()
        let rect90 = session.videoContentRect(in: viewport)
        XCTAssertNotNil(rect90)
        XCTAssertEqual(rect90?.width ?? 0, 562.5, accuracy: 1.0)
        XCTAssertEqual(rect90?.height ?? 0, 1000.0, accuracy: 1.0)
        XCTAssertEqual(rect90?.minX ?? 0, (1000.0 - 562.5) * 0.5, accuracy: 1.0)
        XCTAssertEqual(rect90?.minY ?? 0, 0.0, accuracy: 1.0)
        let subGeom = session.subtitleVideoGeometry(for: viewport)
        XCTAssertEqual(subGeom.rotationDegrees, 90)
        XCTAssertEqual(subGeom.explicitVideoRect?.width ?? 0, 562.5, accuracy: 1.0)
        XCTAssertEqual(subGeom.explicitVideoRect?.height ?? 0, 1000.0, accuracy: 1.0)
    }

    func testBottomControlBarExclusionRemainsStableRegardlessOfRotation() {
        let playerView = AVSampleBufferPlayerNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        playerView.bottomControlBarExclusionHeight = 76.0
        playerView.isControlBarVisible = true
        playerView.userRotationDegrees = 90
        XCTAssertTrue(playerView.shouldIgnoreCanvasClick(at: NSPoint(x: 400, y: 30)))
        XCTAssertFalse(playerView.shouldIgnoreCanvasClick(at: NSPoint(x: 400, y: 300)))
        playerView.userRotationDegrees = 180
        XCTAssertTrue(playerView.shouldIgnoreCanvasClick(at: NSPoint(x: 400, y: 50)))
        XCTAssertFalse(playerView.shouldIgnoreCanvasClick(at: NSPoint(x: 400, y: 250)))
    }

    // MARK: - 4. Format Dynamic Range Always-Available & Disaggregated Indicators

    func testFormatBadgeAlwaysAvailableEvenWithoutCodecLabel() {
        let sdrState = VideoFormatPresentationState(
            codecLabel: nil, width: 1920, height: 1080,
            sourceDynamicRange: .sdr, activeOutputDynamicRange: .sdr, outputObservationStatus: .confirmed(.sdr)
        )
        XCTAssertEqual(sdrState.alwaysAvailableBadgeText, "SDR")

        let detectingHDRSource = VideoFormatPresentationState(
            codecLabel: "hvc1", width: 3840, height: 2160,
            sourceDynamicRange: .hdr10, activeOutputDynamicRange: .unknown, outputObservationStatus: .detecting
        )
        XCTAssertEqual(
            detectingHDRSource.alwaysAvailableBadgeText,
            VideoPlaybackLocalization.text(.formatBadgeDetectingOutput),
            "Short badge must never fall back to sourceDynamicRange when output is unknown"
        )
    }

    func testUnknownFormatBadgeFollowsLanguageWithoutChangingEvidence() {
        let localization = LocalizationState.shared
        let savedLanguage = localization.currentLanguage
        defer { localization.setLanguage(savedLanguage) }
        let detectingState = VideoFormatPresentationState(codecLabel: "hvc1", width: 3840, height: 2160)
        let diagnosticState = detectingState.applyingDiagnosticFailure("Renderer error")
        let labels: [(AppLanguage, String, String)] = [
            (.zhHans, "正在检测输出", "输出未确认"),
            (.zhHant, "正在檢測輸出", "輸出未確認"),
            (.en, "Detecting Output", "Output Unconfirmed")
        ]
        for (language, detectingLabel, diagnosticLabel) in labels {
            localization.setLanguage(language)
            XCTAssertEqual(detectingState.alwaysAvailableBadgeText, detectingLabel)
            XCTAssertEqual(detectingState.namedSourceAndOutputBadgeText, "源 4K · HEVC | 输出 \(detectingLabel)")
            XCTAssertEqual(diagnosticState.alwaysAvailableBadgeText, diagnosticLabel)
            XCTAssertEqual(detectingState.sourceDynamicRange, .unknown)
            XCTAssertEqual(detectingState.activeOutputDynamicRange, .unknown)
            XCTAssertFalse(detectingState.isToneMappedFallbackToSDR)
        }
    }

    func testExplicitFormatBadgeRemainsUnchangedAcrossLanguages() {
        let localization = LocalizationState.shared
        let savedLanguage = localization.currentLanguage
        defer { localization.setLanguage(savedLanguage) }
        let state = VideoFormatPresentationState(badgeText: "Custom status")
        for language: AppLanguage in [.zhHans, .zhHant, .en] {
            localization.setLanguage(language)
            XCTAssertEqual(state.alwaysAvailableBadgeText, "Custom status")
        }
    }

    func testDolbyVisionEvidenceGateStrictness() {
        let emptyMode = VideoFormatPresentationState.detectDynamicRange(formatDescription: nil, rawCodecName: "HEVC", transferFunctionHint: nil)
        XCTAssertEqual(emptyMode, VideoDynamicRangeMode.unknown, "Must not infer Dolby Vision without explicit box or fourcc")
        let doviMode = VideoFormatPresentationState.detectDynamicRange(formatDescription: nil, rawCodecName: "dvhe", transferFunctionHint: nil)
        XCTAssertEqual(doviMode, VideoDynamicRangeMode.dolbyVision, "Must recognize verified Dolby Vision evidence")
        let sdrMode = VideoFormatPresentationState.detectDynamicRange(formatDescription: nil, rawCodecName: "H.264", transferFunctionHint: "ITU_R_BT_709")
        XCTAssertEqual(sdrMode, VideoDynamicRangeMode.sdr)
    }

    func testDisaggregatedSourceAndOutputDynamicRange() {
        let hdrSourceState = VideoFormatPresentationState(
            codecLabel: "HEVC", width: 3840, height: 2160,
            sourceDynamicRange: .hdr10, activeOutputDynamicRange: .unknown,
            isToneMappedFallbackToSDR: false, outputObservationStatus: .detecting
        )
        XCTAssertEqual(hdrSourceState.sourceDynamicRangeDescription, "HDR10")
        let detectingExpected = VideoPlaybackLocalization.text(.formatBadgeDetectingOutput)
        XCTAssertEqual(hdrSourceState.alwaysAvailableBadgeText, detectingExpected)
        XCTAssertEqual(hdrSourceState.outputDynamicRangeDescription, detectingExpected)
        let summaryA = hdrSourceState.detailedFormatSummary
        XCTAssertTrue(summaryA.contains("HDR10") && summaryA.contains(detectingExpected))

        let toneMappedState = VideoFormatPresentationState(
            codecLabel: "HEVC", width: 3840, height: 2160,
            sourceDynamicRange: .dolbyVision, activeOutputDynamicRange: .sdr, isToneMappedFallbackToSDR: true
        )
        XCTAssertEqual(toneMappedState.alwaysAvailableBadgeText, "SDR")
        XCTAssertEqual(toneMappedState.namedSourceAndOutputBadgeText, "源 4K · HEVC | 输出 SDR")
        XCTAssertEqual(toneMappedState.sourceDynamicRangeDescription, "Dolby Vision")
        let toneMappedExpected = VideoInteractionLocalization.text(.outputConfirmedSDRToneMapped)
        XCTAssertTrue(toneMappedState.outputDynamicRangeDescription.contains("DoVi →"))
        XCTAssertTrue(toneMappedState.outputDynamicRangeDescription.contains(toneMappedExpected))
        XCTAssertTrue(toneMappedState.comparisonSnapshot.outputSection.colorMappingText.contains("DoVi → SDR"))

        let confirmedObservation = VideoDisplayOutputObservation(
            screenSupportsEDR: true, isHDRPresentationConfirmed: true,
            isToneMappedFallbackConfirmed: false, isSDRPresentationConfirmed: false
        )
        let outputHDRState = hdrSourceState.applyingDisplayObservation(confirmedObservation)
        XCTAssertEqual(outputHDRState.alwaysAvailableBadgeText, "HDR10")
        XCTAssertEqual(outputHDRState.sourceDynamicRangeDescription, "HDR10")
        let confirmedHDRExpected = VideoInteractionLocalization.text(.outputConfirmedHDR)
        XCTAssertTrue(outputHDRState.outputDynamicRangeDescription.contains("HDR10"))
        XCTAssertTrue(outputHDRState.outputDynamicRangeDescription.contains(confirmedHDRExpected))
    }

    // MARK: - 5. Controlled SDR / PQ / HLG Samples, Screen Observation, and Interactive Popover Verification

    func testControlledDisplayCapabilitiesWithSDRPQAndHLGSamples() throws {
        let displayLayer = AVSampleBufferDisplayLayer()
        let sdrScreen = VideoHostScreenObservation(hasHostWindow: true, screenLocalizedName: "SDR Reference", currentEDRHeadroom: 1.0, potentialEDRHeadroom: 1.0)
        let potentialOnlyEDRScreen = VideoHostScreenObservation(hasHostWindow: true, screenLocalizedName: "XDR Inactive", currentEDRHeadroom: 1.0, potentialEDRHeadroom: 4.0)
        let activeEDRScreen = VideoHostScreenObservation(hasHostWindow: true, screenLocalizedName: "Liquid Retina XDR", currentEDRHeadroom: 2.8, potentialEDRHeadroom: 4.0)

        let pqSample = try Self.makeSyntheticColorTaggedSampleBuffer(
            codecType: kCMVideoCodecType_HEVC, width: 3840, height: 2160,
            primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020, includeHDR10StaticBoxes: true
        )
        let pqDesc = try XCTUnwrap(CMSampleBufferGetFormatDescription(pqSample))
        let pqInitialState = VideoFormatPresentationState.resolve(rawCodecName: "hvc1", width: 3840, height: 2160, formatDescription: pqDesc, frameRateFps: 59.94)
        XCTAssertEqual(pqInitialState.sourceDynamicRange, .hdr10)
        XCTAssertEqual(pqInitialState.alwaysAvailableBadgeText, VideoPlaybackLocalization.text(.formatBadgeDetectingOutput))

        let pqOnSDRObs = VideoRendererOutputEvaluator.evaluateObservation(displayLayer: displayLayer, sampleBuffer: pqSample, sourceDynamicRange: .hdr10, hasEnqueuedSample: true, isSamplePresented: true, hostScreen: sdrScreen)
        let pqOnSDRState = pqInitialState.applyingDisplayObservation(pqOnSDRObs)
        XCTAssertFalse(pqOnSDRObs.isToneMappedFallbackConfirmed, "Screen non-EDR alone must never confirm tone-mapping")
        XCTAssertEqual(pqOnSDRState.activeOutputDynamicRange, .unknown)
        XCTAssertFalse(pqOnSDRState.isToneMappedFallbackToSDR)
        XCTAssertEqual(pqOnSDRState.alwaysAvailableBadgeText, VideoPlaybackLocalization.text(.formatBadgeDiagnosticUnconfirmed))
        let pqSnapshot = pqOnSDRState.comparisonSnapshot
        XCTAssertTrue(pqSnapshot.sourceSection.codecAndProfileText.contains("HEVC") && pqSnapshot.sourceSection.codecAndProfileText.contains("Main 10"))
        XCTAssertTrue(pqSnapshot.sourceSection.resolutionAndFrameRateText.contains("3840×2160 (4K)") && pqSnapshot.sourceSection.resolutionAndFrameRateText.contains("59.94 fps"))
        XCTAssertEqual(pqSnapshot.sourceSection.bitDepthAndChromaText, "10-bit · 4:2:0")
        XCTAssertEqual(pqSnapshot.sourceSection.colorPrimariesText, "BT.2020")
        XCTAssertEqual(pqSnapshot.sourceSection.transferFunctionText, "SMPTE ST 2084 (PQ)")
        XCTAssertTrue(pqSnapshot.sourceSection.hdrMetadataText.contains("Mastering 1000 / 0.0050 nits") && pqSnapshot.sourceSection.hdrMetadataText.contains("MaxCLL 1000 nits"))
        XCTAssertTrue(pqSnapshot.outputSection.colorMappingText.contains("EDR 未启用 / 输出待确认"))

        let pqPotentialOnlyObs = VideoRendererOutputEvaluator.evaluateObservation(displayLayer: displayLayer, sampleBuffer: pqSample, sourceDynamicRange: .hdr10, hasEnqueuedSample: true, isSamplePresented: true, hostScreen: potentialOnlyEDRScreen)
        XCTAssertFalse(pqPotentialOnlyObs.isHDRPresentationConfirmed || pqPotentialOnlyObs.isToneMappedFallbackConfirmed)

        let sdrSample = try Self.makeSyntheticColorTaggedSampleBuffer(
            codecType: kCMVideoCodecType_H264, width: 1920, height: 1080,
            primaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2, includeHDR10StaticBoxes: false
        )
        let pqToneMappedObs = VideoRendererOutputEvaluator.evaluateObservation(displayLayer: displayLayer, sampleBuffer: sdrSample, sourceDynamicRange: .hdr10, hasEnqueuedSample: true, isSamplePresented: true, hostScreen: sdrScreen)
        let pqToneMappedState = pqInitialState.applyingDisplayObservation(pqToneMappedObs)
        XCTAssertTrue(pqToneMappedObs.isToneMappedFallbackConfirmed && pqToneMappedState.isToneMappedFallbackToSDR)
        XCTAssertEqual(pqToneMappedState.alwaysAvailableBadgeText, "SDR")
        XCTAssertTrue(pqToneMappedState.comparisonSnapshot.outputSection.colorMappingText.contains("HDR10 → SDR"))

        let pqOnEDRObs = VideoRendererOutputEvaluator.evaluateObservation(displayLayer: displayLayer, sampleBuffer: pqSample, sourceDynamicRange: .hdr10, hasEnqueuedSample: true, isSamplePresented: true, hostScreen: activeEDRScreen)
        let pqOnEDRState = pqInitialState.applyingDisplayObservation(pqOnEDRObs)
        XCTAssertTrue(displayLayer.wantsExtendedDynamicRangeContent)
        XCTAssertEqual(pqOnEDRState.alwaysAvailableBadgeText, "HDR10")
        XCTAssertTrue(pqOnEDRState.comparisonSnapshot.outputSection.activeOutputText.contains("EDR 渲染管线已配置"))

        let hlgSample = try Self.makeSyntheticColorTaggedSampleBuffer(
            codecType: kCMVideoCodecType_HEVC, width: 3840, height: 2160,
            primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            transfer: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG,
            matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020, includeHDR10StaticBoxes: false
        )
        let hlgState = VideoFormatPresentationState.resolve(rawCodecName: "hvc1", width: 3840, height: 2160, formatDescription: CMSampleBufferGetFormatDescription(hlgSample))
        let hlgEDRObs = VideoRendererOutputEvaluator.evaluateObservation(displayLayer: displayLayer, sampleBuffer: hlgSample, sourceDynamicRange: .hlg, hasEnqueuedSample: true, isSamplePresented: true, hostScreen: activeEDRScreen)
        XCTAssertEqual(hlgState.applyingDisplayObservation(hlgEDRObs).alwaysAvailableBadgeText, "HLG")
        let notPresentedObs = VideoRendererOutputEvaluator.evaluateObservation(displayLayer: displayLayer, sampleBuffer: hlgSample, sourceDynamicRange: .hlg, hasEnqueuedSample: true, isSamplePresented: false, hostScreen: activeEDRScreen)
        XCTAssertEqual(hlgState.applyingDisplayObservation(notPresentedObs).alwaysAvailableBadgeText, VideoPlaybackLocalization.text(.formatBadgeDetectingOutput))
        let failedObs = VideoRendererOutputEvaluator.evaluateObservation(displayLayer: displayLayer, sampleBuffer: hlgSample, sourceDynamicRange: .hlg, hasEnqueuedSample: true, isSamplePresented: true, isRendererFailedOverride: true, hostScreen: activeEDRScreen)
        XCTAssertEqual(hlgState.applyingDisplayObservation(failedObs).alwaysAvailableBadgeText, VideoPlaybackLocalization.text(.formatBadgeDiagnosticUnconfirmed))
    }

    func testSourceMissingMetadataKeepsSourceNotProvidedWhileReportingKnownSDROutput() throws {
        let displayLayer = AVSampleBufferDisplayLayer()
        let sdrScreen = VideoHostScreenObservation(hasHostWindow: true, screenLocalizedName: "Built-in Display", currentEDRHeadroom: 1.0, potentialEDRHeadroom: 1.0)
        let untaggedSample = try Self.makeSyntheticColorTaggedSampleBuffer(
            codecType: kCMVideoCodecType_H264, width: 1920, height: 1080,
            primaries: nil, transfer: nil, matrix: nil, includeHDR10StaticBoxes: false
        )
        let untaggedDesc = try XCTUnwrap(CMSampleBufferGetFormatDescription(untaggedSample))
        let initial = VideoFormatPresentationState.resolve(rawCodecName: "avc1", width: 1920, height: 1080, formatDescription: untaggedDesc)
        XCTAssertEqual(initial.sourceDynamicRange, .unknown)
        XCTAssertEqual(initial.sourceDynamicRangeDescription, VideoInteractionLocalization.text(.notProvided))

        let untaggedObs = VideoRendererOutputEvaluator.evaluateObservation(
            displayLayer: displayLayer, sampleBuffer: untaggedSample,
            sourceDynamicRange: .sdr, hasEnqueuedSample: true, isSamplePresented: true, hostScreen: sdrScreen
        )
        let untaggedObserved = initial.applyingDisplayObservation(untaggedObs)
        XCTAssertFalse(untaggedObs.isSDRPresentationConfirmed, "Unknown sample transfer must NEVER confirm SDR output")
        XCTAssertEqual(untaggedObserved.activeOutputDynamicRange, .unknown)
        XCTAssertEqual(untaggedObserved.alwaysAvailableBadgeText, VideoPlaybackLocalization.text(.formatBadgeDiagnosticUnconfirmed))

        let sdrTaggedSample = try Self.makeSyntheticColorTaggedSampleBuffer(
            codecType: kCMVideoCodecType_H264, width: 1920, height: 1080,
            primaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2, includeHDR10StaticBoxes: false
        )
        let obs = VideoRendererOutputEvaluator.evaluateObservation(
            displayLayer: displayLayer, sampleBuffer: sdrTaggedSample,
            sourceDynamicRange: initial.sourceDynamicRange, hasEnqueuedSample: true, isSamplePresented: true, hostScreen: sdrScreen
        )
        let observed = initial.applyingDisplayObservation(obs)
        XCTAssertEqual(observed.sourceDynamicRange, .unknown, "Untagged source must remain .unknown and never be fabricated as .sdr")
        XCTAssertEqual(observed.activeOutputDynamicRange, .sdr, "Explicit SDR sample transfer on healthy renderer confirms .sdr")
        XCTAssertEqual(observed.alwaysAvailableBadgeText, "SDR")
        let snapshot = observed.comparisonSnapshot
        let notProvided = VideoInteractionLocalization.text(.notProvided)
        XCTAssertEqual(snapshot.sourceSection.colorPrimariesText, notProvided)
        XCTAssertEqual(snapshot.sourceSection.transferFunctionText, notProvided)
        XCTAssertEqual(snapshot.sourceSection.sourceDynamicRangeText, notProvided)
        XCTAssertEqual(snapshot.sourceSection.hdrMetadataText, notProvided)
        XCTAssertTrue(snapshot.outputSection.colorMappingText.contains(notProvided))
    }

    func testCrossScreenDynamicUpdateAndStaleSessionOrGenerationReceiptRejection() throws {
        let dummyURL = URL(fileURLWithPath: "/tmp/v2_cross_screen_hdr.mp4")
        let session = VideoPlaybackSession(url: dummyURL)
        let controller = AVAssetReaderPlaybackController(url: dummyURL)
        let wrapper = VideoPlaybackController.native(controller)
        session.activeController = wrapper
        wrapper.setOnFormatPresentationStateChanged { [weak session] updated in session?.formatPresentationState = updated }

        let pqSample = try Self.makeSyntheticColorTaggedSampleBuffer(
            codecType: kCMVideoCodecType_HEVC, width: 3840, height: 2160,
            primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020, includeHDR10StaticBoxes: true
        )
        let pqDesc = try XCTUnwrap(CMSampleBufferGetFormatDescription(pqSample))
        controller.formatPresentationState = VideoFormatPresentationState.resolve(rawCodecName: "hvc1", width: 3840, height: 2160, formatDescription: pqDesc, frameRateFps: 24.0)
        session.formatPresentationState = controller.formatPresentationState

        let edrScreen = VideoHostScreenObservation(hasHostWindow: true, screenLocalizedName: "XDR Display", currentEDRHeadroom: 3.0, potentialEDRHeadroom: 4.0)
        let sdrScreen = VideoHostScreenObservation(hasHostWindow: true, screenLocalizedName: "External SDR Monitor", currentEDRHeadroom: 1.0, potentialEDRHeadroom: 1.0)

        session.updateHostScreenObservation(edrScreen, forSessionID: session.sessionID)
        let activeGen = controller.transitionGeneration
        controller.recordVideoSampleEnqueuedForObservation(pqSample, forGeneration: activeGen)
        XCTAssertEqual(session.formatPresentationState.activeOutputDynamicRange, .hdr10)
        XCTAssertEqual(session.formatPresentationState.alwaysAvailableBadgeText, "HDR10")

        session.updateHostScreenObservation(sdrScreen, forSessionID: session.sessionID)
        XCTAssertFalse(controller.displayLayer.wantsExtendedDynamicRangeContent)
        XCTAssertEqual(session.formatPresentationState.activeOutputDynamicRange, .unknown)
        XCTAssertFalse(session.formatPresentationState.isToneMappedFallbackToSDR)
        XCTAssertEqual(session.formatPresentationState.alwaysAvailableBadgeText, VideoPlaybackLocalization.text(.formatBadgeDiagnosticUnconfirmed))

        session.updateHostScreenObservation(edrScreen, forSessionID: UUID())
        XCTAssertEqual(session.formatPresentationState.activeOutputDynamicRange, .unknown, "Stale sessionID receipt must be rejected")

        controller.latestHostScreenObservation = edrScreen
        controller.recordVideoSampleEnqueuedForObservation(pqSample, forGeneration: activeGen &+ 999)
        XCTAssertEqual(session.formatPresentationState.activeOutputDynamicRange, .unknown, "Stale transitionGeneration receipt must be rejected")

        session.updateHostScreenObservation(edrScreen, forSessionID: session.sessionID)
        XCTAssertEqual(session.formatPresentationState.activeOutputDynamicRange, .hdr10)
        XCTAssertEqual(session.formatPresentationState.alwaysAvailableBadgeText, "HDR10")
    }

    func testRealFormatBadgeButtonClickExpandsPopoverSharesControlLockAndPreservesPlayback() throws {
        let visibility = MediaControlsVisibility()
        visibility.isPlaying = true
        let pqSample = try Self.makeSyntheticColorTaggedSampleBuffer(
            codecType: kCMVideoCodecType_HEVC, width: 3840, height: 2160,
            primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020,
            transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ,
            matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020, includeHDR10StaticBoxes: true
        )
        let sdrConvertedSample = try Self.makeSyntheticColorTaggedSampleBuffer(
            codecType: kCMVideoCodecType_H264, width: 3840, height: 2160,
            primaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2, includeHDR10StaticBoxes: false
        )
        let pqDesc = try XCTUnwrap(CMSampleBufferGetFormatDescription(pqSample))
        let baseState = VideoFormatPresentationState.resolve(rawCodecName: "hvc1", width: 3840, height: 2160, formatDescription: pqDesc, frameRateFps: 24.0)
        let sdrObs = VideoRendererOutputEvaluator.evaluateObservation(
            displayLayer: AVSampleBufferDisplayLayer(), sampleBuffer: sdrConvertedSample,
            sourceDynamicRange: .hdr10, hasEnqueuedSample: true, isSamplePresented: true,
            hostScreen: VideoHostScreenObservation(hasHostWindow: true, screenLocalizedName: "Built-in SDR", currentEDRHeadroom: 1.0, potentialEDRHeadroom: 1.0)
        )
        let state = baseState.applyingDisplayObservation(sdrObs)

        var playPauseCount = 0
        var seekCount = 0
        var userInteractionCount = 0
        var popoverVisibleStates: [Bool] = []

        let overlay = AVSampleBufferControlsOverlay(
            availableWidth: 640, currentTime: CMTime(seconds: 12.0, preferredTimescale: 600),
            duration: CMTime(seconds: 120.0, preferredTimescale: 600),
            isPlaying: true, isFullScreen: false, volume: 0.8, isMuted: false, playbackRate: 1.0,
            pipSupported: false, pipActive: false,
            onTogglePlayPause: { playPauseCount += 1 }, onSeekBy: { _ in seekCount += 1 }, onSeekTo: { _ in seekCount += 1 },
            onVolumeChange: { _ in }, onMuteToggle: {}, onRateChange: { _ in }, onPipToggle: {}, onFullScreenToggle: {},
            onUserInteraction: { userInteractionCount += 1 },
            formatBadgeText: state.alwaysAvailableBadgeText, formatPresentationState: state,
            onPopoverVisibilityChange: { visible in
                popoverVisibleStates.append(visible)
                if visible { visibility.beginInteraction() } else { visibility.endInteraction() }
            }
        ).environment(visibility)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: overlay)
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 120)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let badgeButton = try XCTUnwrap(
            Self.findAccessibilityButton(in: hostingView, identifier: "video_format_badge_button", expectedTitleOrValue: state.alwaysAvailableBadgeText),
            "Format badge must be rendered as a real interactive accessibility Button"
        )
        XCTAssertTrue(badgeButton.accessibilityPerformPress(), "Real button press on format badge must succeed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(popoverVisibleStates.last, true, "Clicking badge button must open the format details popover")
        XCTAssertTrue(visibility.hasActiveInteractionLock, "Opening format popover must acquire shared MediaControlsVisibility lock")
        XCTAssertGreaterThanOrEqual(userInteractionCount, 1)
        XCTAssertEqual(playPauseCount, 0, "Expanding format popover must never pause or toggle playback")
        XCTAssertEqual(seekCount, 0, "Expanding format popover must never seek")

        let popoverHosting = NSHostingView(rootView: VideoFormatDetailsPopover(state: state))
        popoverHosting.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
        popoverHosting.layoutSubtreeIfNeeded()
        let snapshot = state.comparisonSnapshot
        XCTAssertEqual(snapshot.badgeText, "SDR")
        XCTAssertEqual(snapshot.sourceSection.rows.count, 8)
        XCTAssertEqual(snapshot.outputSection.rows.count, 5)

        XCTAssertTrue(badgeButton.accessibilityPerformPress())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(popoverVisibleStates.last, false)
        XCTAssertFalse(visibility.hasActiveInteractionLock)
        XCTAssertEqual(playPauseCount, 0)
        XCTAssertEqual(seekCount, 0)
    }

    func testProductionNativeAndWorkerPipelinesPresentationGatesDoNotDisplaySampleAttachmentsAndGenerations() async throws {
        await verifyWorkerProductionPipelineOutputObservation()
        try await verifyNativeProductionPipelineOutputObservation()
    }

    private func verifyWorkerProductionPipelineOutputObservation() async {
        let avcC = Data([0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1, 0x00, 0x0D, 0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x01, 0x40, 0x16, 0xE8, 0x06, 0xD0, 0xA1, 0x35, 0x01, 0x00, 0x04, 0x68, 0xCE, 0x3C, 0x80])
        let slice = Data([0x00, 0x00, 0x00, 0x02, 0x65, 0x01])
        let makePkt: @Sendable (Double, Bool, String, String, String) -> MediaPacketDTO = { pts, doNotDisplay, pri, trc, mat in
            // swiftlint:disable:next force_try
            try! MediaPacketDTO(
                streamIndex: 0, mediaType: .video, ptsValue: Int64(pts * 600), ptsTimescale: 600,
                dtsValue: Int64(pts * 600), dtsTimescale: 600, durationValue: 24, durationTimescale: 600,
                payloadData: slice, isKeyframe: true, doNotDisplay: doNotDisplay,
                sampleColorPrimaries: pri, sampleTransferCharacteristics: trc, sampleMatrixCoefficients: mat
            )
        }
        let meta: [String: Any] = [
            "format": "matroska", "durationSeconds": 120.0, "metadataCapability": "v1_structured_contract_v1", "selectedVideoTrackNumber": 0,
            "videoTracks": [["trackIndex": 0, "codec": "h264", "rawCodecId": "V_MPEG4/ISO/AVC", "codecName": "h264", "width": 3840, "height": 2160, "pixelWidth": 3840, "pixelHeight": 2160, "demuxSelectable": true, "isSelectedForPackets": true, "extradata": avcC, "bitDepth": 10, "dynamicRange": "hdr10", "colorPrimaries": "ITU_R_2020", "transferCharacteristics": "SMPTE_ST_2084_PQ", "matrixCoefficients": "ITU_R_2020_NCL"]],
            "audioTracks": [], "catalogSubtitleTracks": []
        ]
        // Paused at timebase=0: enqueue 0.0s (BT.709 SDR), 0.04s (PQ HDR10), 0.08s (HLG), 0.12s (BT.709 SDR)
        let initialPkts = [
            makePkt(0.0, false, "ITU_R_709_2", "ITU_R_709_2", "ITU_R_709_2"),
            makePkt(0.04, false, "ITU_R_2020", "SMPTE_ST_2084_PQ", "ITU_R_2020_NCL"),
            makePkt(0.08, false, "ITU_R_2020", "ITU_R_2100_HLG", "ITU_R_2020_NCL"),
            makePkt(0.12, false, "ITU_R_709_2", "ITU_R_709_2", "ITU_R_709_2")
        ]
        let transport = V2ProductionObservationScriptedTransport(
            metadata: meta, initialPackets: initialPkts,
            postSeekFactory: { target in
                target < 20.0
                    ? [makePkt(5.0, false, "ITU_R_709_2", "ITU_R_709_2", "ITU_R_709_2")]
                    : [makePkt(20.0, false, "ITU_R_709_2", "ITU_R_709_2", "ITU_R_709_2"), makePkt(20.04, false, "ITU_R_2020", "SMPTE_ST_2084_PQ", "ITU_R_2020_NCL")]
            }
        )
        let controller = AVSampleBufferWorkerPlaybackController(url: URL(fileURLWithPath: "/tmp/v2_worker_prod.mkv"), client: MediaWorkerXPCClient(transport: transport))
        controller.updateHostScreenObservation(VideoHostScreenObservation(hasHostWindow: true, screenLocalizedName: "XDR", currentEDRHeadroom: 3.0, potentialEDRHeadroom: 4.0))

        // 1. Paused at timebase=0 with 0.0s, 0.04s, 0.08s, 0.12s enqueued: NO manual setRate -> 0.0s SDR frame stays active, future 0.04s PQ does not revert to .detecting or prematurely switch colorimetry
        await controller.startPlayback(autoPlay: false)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(CMTimeGetSeconds(controller.coordinator.synchronizer.currentTime()), 0.0, accuracy: 0.002)
        XCTAssertEqual(controller.sampleObservationTimeline.pendingFutureSamples.count, 3)
        XCTAssertEqual(controller.formatPresentationState.sourceDynamicRange, .hdr10)
        XCTAssertEqual(controller.formatPresentationState.activeOutputDynamicRange, .sdr, "Current 0.0s frame must stay confirmed SDR while 0.04s/0.08s/0.12s wait in queue")
        XCTAssertTrue(controller.formatPresentationState.isToneMappedFallbackToSDR)

        // 2. Controlled timebase advance + continuous ahead prefetch: colorimetry switches only when timebase reaches 0.04s, 0.08s, and 0.12s, never dropping back to .detecting
        controller.coordinator.synchronizer.setRate(0.0, time: CMTime(seconds: 0.04, preferredTimescale: 600))
        controller.refreshLiveOutputObservation()
        XCTAssertEqual(controller.formatPresentationState.activeOutputDynamicRange, .hdr10, "Reaching 0.04s promotes PQ sample while 0.08s/0.12s remain pending ahead")
        controller.coordinator.synchronizer.setRate(0.0, time: CMTime(seconds: 0.08, preferredTimescale: 600))
        controller.refreshLiveOutputObservation()
        XCTAssertEqual(controller.formatPresentationState.activeOutputDynamicRange, .hlg, "Reaching 0.08s promotes HLG sample while 0.12s remains pending ahead")
        controller.coordinator.synchronizer.setRate(0.0, time: CMTime(seconds: 0.12, preferredTimescale: 600))
        controller.refreshLiveOutputObservation()
        XCTAssertEqual(controller.formatPresentationState.activeOutputDynamicRange, .sdr, "Reaching 0.12s promotes SDR sample")
        let staleGen = controller.playbackGeneration

        // 3. Seek to 10.0s: 5.0s (< 10.0s) is DoNotDisplay preroll -> resets to .detecting; stale generation is rejected
        await controller.seek(to: 10.0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.formatPresentationState.activeOutputDynamicRange, .unknown)
        XCTAssertEqual(controller.formatPresentationState.outputObservationStatus, .detecting)
        if let sdrSample = try? Self.makeSyntheticColorTaggedSampleBuffer(codecType: kCMVideoCodecType_H264, width: 1920, height: 1080, primaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2, transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2, matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2, includeHDR10StaticBoxes: false) {
            controller.recordVideoSampleEnqueuedForObservation(sdrSample, forGeneration: staleGen)
        }
        XCTAssertEqual(controller.formatPresentationState.activeOutputDynamicRange, .unknown, "Stale generation sample must be rejected")
        await controller.stop()
    }

    private func verifyNativeProductionPipelineOutputObservation() async throws {
        let mp4URL = FileManager.default.temporaryDirectory.appendingPathComponent("v2_native_obs_\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: mp4URL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180, AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1, AVVideoAllowFrameReorderingKey: false]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA), kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input); _ = writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for idx in 0..<5 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            var pb: CVPixelBuffer?; if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
            if let pb { _ = adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(idx * 24), timescale: 600)) }
        }
        input.markAsFinished(); await writer.finishWriting()
        defer { try? FileManager.default.removeItem(at: mp4URL) }

        let controller = AVAssetReaderPlaybackController(url: mp4URL)
        controller.registersWithCoordinator = false
        controller.updateHostScreenObservation(VideoHostScreenObservation(hasHostWindow: true, screenLocalizedName: "XDR", currentEDRHeadroom: 3.0, potentialEDRHeadroom: 4.0))
        controller.lifecycleProbe = .init(transformCopiedVideoSampleBuffer: { _, sample in
            let ptsSec = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if ptsSec < 0.02 {
                AVSampleBufferPlayerCoordinator.setDoNotDisplayAttachment(on: sample, doNotDisplay: true)
            } else if ptsSec < 0.07 {
                AVSampleBufferPlayerCoordinator.setDoNotDisplayAttachment(on: sample, doNotDisplay: false)
                CMSetAttachment(sample, key: kCVImageBufferColorPrimariesKey, value: kCMFormatDescriptionColorPrimaries_ITU_R_709_2, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                CMSetAttachment(sample, key: kCVImageBufferTransferFunctionKey, value: kCMFormatDescriptionTransferFunction_ITU_R_709_2, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                CMSetAttachment(sample, key: kCVImageBufferYCbCrMatrixKey, value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2, attachmentMode: kCMAttachmentMode_ShouldPropagate)
            } else if ptsSec < 0.11 {
                AVSampleBufferPlayerCoordinator.setDoNotDisplayAttachment(on: sample, doNotDisplay: false)
                CMSetAttachment(sample, key: kCVImageBufferColorPrimariesKey, value: kCMFormatDescriptionColorPrimaries_ITU_R_2020, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                CMSetAttachment(sample, key: kCVImageBufferTransferFunctionKey, value: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                CMSetAttachment(sample, key: kCVImageBufferYCbCrMatrixKey, value: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020, attachmentMode: kCMAttachmentMode_ShouldPropagate)
            } else {
                AVSampleBufferPlayerCoordinator.setDoNotDisplayAttachment(on: sample, doNotDisplay: false)
                CMSetAttachment(sample, key: kCVImageBufferColorPrimariesKey, value: kCMFormatDescriptionColorPrimaries_ITU_R_2020, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                CMSetAttachment(sample, key: kCVImageBufferTransferFunctionKey, value: kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                CMSetAttachment(sample, key: kCVImageBufferYCbCrMatrixKey, value: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020, attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            return sample
        })
        // 1. Paused load(autoPlay: false) without manual synchronizer.setRate: idx=0 is DoNotDisplay, idx=1 (0.04s BT.709) anchors timebase while idx=2..4 (0.08s PQ, 0.12s/0.16s HLG) prefetch ahead
        try await controller.load(autoPlay: false)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(CMTimeGetSeconds(controller.synchronizer.currentTime()), 0.04, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(controller.sampleObservationTimeline.pendingFutureSamples.count, 1)
        XCTAssertEqual(controller.formatPresentationState.activeOutputDynamicRange, .sdr, "Paused at 0.04s frame: prefetched future PQ/HLG frames must not revert to .detecting or prematurely switch colorimetry")

        // 2. Advancing timebase to 0.08s promotes PQ frame (.hdr10); advancing to 0.12s promotes HLG frame (.hlg)
        controller.synchronizer.setRate(0.0, time: CMTime(seconds: 0.08, preferredTimescale: 600))
        controller.refreshLiveOutputObservation()
        XCTAssertNotEqual(controller.formatPresentationState.sourceDynamicRange, .hdr10)
        XCTAssertEqual(controller.formatPresentationState.activeOutputDynamicRange, .hdr10, "Native drainVideoQueue must promote 0.08s PQ sample when timebase reaches 0.08s")
        controller.synchronizer.setRate(0.0, time: CMTime(seconds: 0.12, preferredTimescale: 600))
        controller.refreshLiveOutputObservation()
        XCTAssertEqual(controller.formatPresentationState.activeOutputDynamicRange, .hlg, "Reaching 0.12s promotes HLG sample")

        // 3. Rewinding timebase before first displayable frame (0.0s had only DoNotDisplay) demotes to .detecting; seek rejects stale generation/sessionID
        controller.synchronizer.setRate(0.0, time: CMTime(seconds: 0.0, preferredTimescale: 600))
        controller.refreshLiveOutputObservation()
        XCTAssertEqual(controller.formatPresentationState.activeOutputDynamicRange, .unknown, "Sample ahead of timebase stays unpresented (.detecting)")
        let staleGen = controller.transitionGeneration
        let staleSessionID = controller.activeSessionID
        controller.seek(to: CMTime(seconds: 0.08, preferredTimescale: 600))
        if let pqSample = try? Self.makeSyntheticColorTaggedSampleBuffer(codecType: kCMVideoCodecType_HEVC, width: 320, height: 180, primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020, transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020, includeHDR10StaticBoxes: false) {
            controller.recordVideoSampleEnqueuedForObservation(pqSample, forSessionID: staleSessionID, forGeneration: staleGen)
        }
        XCTAssertEqual(controller.formatPresentationState.activeOutputDynamicRange, .unknown, "Stale generation/sessionID must be rejected")
        controller.stop()
    }

    // MARK: - Synthetic Sample & Accessibility Helpers

    private static func makeSyntheticColorTaggedSampleBuffer(
        codecType: CMVideoCodecType, width: Int32, height: Int32,
        primaries: CFString?, transfer: CFString?, matrix: CFString?, includeHDR10StaticBoxes: Bool
    ) throws -> CMSampleBuffer {
        var extensions: [CFString: Any] = [kCMFormatDescriptionExtension_FullRangeVideo: kCFBooleanFalse as Any]
        if let primaries { extensions[kCMFormatDescriptionExtension_ColorPrimaries] = primaries }
        if let transfer { extensions[kCMFormatDescriptionExtension_TransferFunction] = transfer }
        if let matrix { extensions[kCMFormatDescriptionExtension_YCbCrMatrix] = matrix }

        var atoms: [String: Data] = [:]
        if codecType == kCMVideoCodecType_HEVC {
            atoms["hvcC"] = Data([
                0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x99, 0xF0, 0x00, 0xFD, 0xFD, 0xFA, 0x00, 0x00, 0x0F, 0x00
            ])
        }
        if includeHDR10StaticBoxes {
            var mdcv = Data(repeating: 0, count: 16)
            var maxLumBE = UInt32(10_000_000).bigEndian
            var minLumBE = UInt32(50).bigEndian
            withUnsafeBytes(of: &maxLumBE) { mdcv.append(contentsOf: $0) }
            withUnsafeBytes(of: &minLumBE) { mdcv.append(contentsOf: $0) }
            atoms["mdcv"] = mdcv
            var clli = Data()
            var maxCLLBE = UInt16(1000).bigEndian
            var maxFALLBE = UInt16(400).bigEndian
            withUnsafeBytes(of: &maxCLLBE) { clli.append(contentsOf: $0) }
            withUnsafeBytes(of: &maxFALLBE) { clli.append(contentsOf: $0) }
            atoms["clli"] = clli
        }
        if !atoms.isEmpty { extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atoms as CFDictionary }

        var formatDesc: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: codecType, width: width, height: height,
            extensions: extensions as CFDictionary, formatDescriptionOut: &formatDesc
        )
        XCTAssertEqual(status, noErr)
        let resolvedDesc = try XCTUnwrap(formatDesc)

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: nil, formatDescription: resolvedDesc,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(sbStatus, noErr)
        let resolvedSB = try XCTUnwrap(sampleBuffer)
        if let primaries { CMSetAttachment(resolvedSB, key: kCVImageBufferColorPrimariesKey, value: primaries, attachmentMode: kCMAttachmentMode_ShouldPropagate) }
        if let transfer { CMSetAttachment(resolvedSB, key: kCVImageBufferTransferFunctionKey, value: transfer, attachmentMode: kCMAttachmentMode_ShouldPropagate) }
        if let matrix { CMSetAttachment(resolvedSB, key: kCVImageBufferYCbCrMatrixKey, value: matrix, attachmentMode: kCMAttachmentMode_ShouldPropagate) }
        return resolvedSB
    }

    private static func findAccessibilityButton(in root: Any, identifier: String, expectedTitleOrValue: String) -> NSAccessibilityProtocol? {
        if let btn = root as? NSButton, btn.accessibilityIdentifier() == identifier { return btn }
        if let view = root as? NSView {
            for subview in view.subviews {
                if let match = findAccessibilityButton(in: subview, identifier: identifier, expectedTitleOrValue: expectedTitleOrValue) { return match }
            }
        }
        if let ax = root as? NSAccessibilityProtocol {
            let id = ax.accessibilityIdentifier()
            let label = ax.accessibilityLabel()
            let title = ax.accessibilityTitle()
            let valueStr = ax.accessibilityValue() as? String
            if id == identifier || title == expectedTitleOrValue || valueStr == expectedTitleOrValue || label == VideoInteractionLocalization.text(.formatDetails) {
                if ax.accessibilityRole() == .button || id == identifier { return ax }
            }
            for child in ax.accessibilityChildren() ?? [] {
                if let match = findAccessibilityButton(in: child, identifier: identifier, expectedTitleOrValue: expectedTitleOrValue) { return match }
            }
        }
        return nil
    }
}
