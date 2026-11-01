// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Live Renderer, Sample Attachment & Host Screen Output Evaluator

/// Evaluates rendering output strictly by separating five distinct evidence layers:
/// 1. Native source signal (`sourceDynamicRange` / container track metadata)
/// 2. Actual sample buffer delivered to the renderer (`sampleTransferFunction` / `observedSampleDynamicRange`)
/// 3. Renderer configuration & health/presentation state (`displayLayer.status`, `wantsExtendedDynamicRangeContent`, `hasEnqueuedSample`, `isSamplePresented`)
/// 4. Host screen current capability (`currentEDRHeadroom` vs `potentialEDRHeadroom`)
/// 5. Final physical optical output (unmeasurable in software; documented as a hardware boundary)
public enum VideoRendererOutputEvaluator {
    @MainActor
    public static func snapshotHostScreen(from window: NSWindow?) -> VideoHostScreenObservation {
        if let screen = window?.screen ?? NSScreen.main {
            return VideoHostScreenObservation(
                hasHostWindow: window != nil,
                screenLocalizedName: screen.localizedName,
                colorSpaceName: screen.colorSpace?.localizedName,
                currentEDRHeadroom: screen.maximumExtendedDynamicRangeColorComponentValue,
                potentialEDRHeadroom: screen.maximumPotentialExtendedDynamicRangeColorComponentValue
            )
        }
        return VideoHostScreenObservation(
            hasHostWindow: false,
            screenLocalizedName: nil,
            colorSpaceName: nil,
            currentEDRHeadroom: 1.0,
            potentialEDRHeadroom: 1.0
        )
    }

    @MainActor
    @discardableResult
    public static func configureDisplayLayerEDR(
        displayLayer: AVSampleBufferDisplayLayer,
        sourceDynamicRange: VideoDynamicRangeMode,
        sampleDynamicRange: VideoDynamicRangeMode = .unknown,
        hostScreen: VideoHostScreenObservation?
    ) -> Bool {
        let isHDRSampleOrSource = sampleDynamicRange.isHDR || (sampleDynamicRange == .unknown && sourceDynamicRange.isHDR)
        let hasActiveEDR = (hostScreen?.currentEDRHeadroom ?? 1.0) > 1.001
        let shouldEnableEDR = isHDRSampleOrSource && hasActiveEDR && displayLayer.status != .failed
        if displayLayer.wantsExtendedDynamicRangeContent != shouldEnableEDR {
            displayLayer.wantsExtendedDynamicRangeContent = shouldEnableEDR
        }
        return displayLayer.wantsExtendedDynamicRangeContent
    }

    /// Extracts colorimetry and transfer dynamic range strictly from the sample buffer delivered to the renderer.
    /// Does not borrow container Dolby Vision codec/box tags to claim Dolby Vision display sample output.
    public static func extractSampleColorimetry(
        from sampleBuffer: CMSampleBuffer?
    ) -> (primaries: String?, transfer: String?, matrix: String?, dynamicRange: VideoDynamicRangeMode) {
        guard let sampleBuffer else { return (nil, nil, nil, .unknown) }
        let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
        let ext = formatDesc.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] }
        let rawPrimaries = attachmentString(sampleBuffer, key: kCVImageBufferColorPrimariesKey)
            ?? (ext?[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String)
        let rawTransfer = attachmentString(sampleBuffer, key: kCVImageBufferTransferFunctionKey)
            ?? (ext?[kCMFormatDescriptionExtension_TransferFunction as String] as? String)
        let rawMatrix = attachmentString(sampleBuffer, key: kCVImageBufferYCbCrMatrixKey)
            ?? (ext?[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String)
        let mode = classifySampleTransferDynamicRange(rawTransfer)
        return (
            CMFormatDescriptionMetadataExtractor.humanReadablePrimaries(rawPrimaries),
            CMFormatDescriptionMetadataExtractor.humanReadableTransferFunction(rawTransfer),
            CMFormatDescriptionMetadataExtractor.humanReadableMatrix(rawMatrix),
            mode
        )
    }

    public static func classifySampleTransferDynamicRange(_ rawTransfer: String?) -> VideoDynamicRangeMode {
        guard let trimmed = rawTransfer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return .unknown
        }
        return VideoFormatPresentationState.classifyTransferFunction(trimmed)
    }

    private static func attachmentString(_ sampleBuffer: CMSampleBuffer, key: CFString) -> String? {
        if let value = CMGetAttachment(sampleBuffer, key: key, attachmentModeOut: nil) as? String {
            return value
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            let keyPtr = Unmanaged.passUnretained(key).toOpaque()
            if let valPtr = CFDictionaryGetValue(dict, keyPtr) {
                let cfType = Unmanaged<AnyObject>.fromOpaque(valPtr).takeUnretainedValue()
                if let str = cfType as? String {
                    return str
                }
            }
        }
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
           let value = CVBufferCopyAttachment(imageBuffer, key, nil) as? String {
            return value
        }
        return nil
    }

    /// Evaluates software-observable pipeline presentation readiness from actual renderer health,
    /// `DoNotDisplay` / preroll suppression state, and synchronizer `CMTimebase` alignment.
    @MainActor
    public static func isSampleReadyForPresentation(
        displayLayer: AVSampleBufferDisplayLayer,
        hasEnqueuedDisplayableSample: Bool,
        latestSampleIsDoNotDisplay: Bool,
        isPrerolling: Bool,
        displayImmediately: Bool,
        samplePTS: CMTime?,
        synchronizerCurrentTime: CMTime
    ) -> Bool {
        guard displayLayer.status != .failed,
              displayLayer.sampleBufferRenderer.status != .failed else {
            return false
        }
        guard hasEnqueuedDisplayableSample, !latestSampleIsDoNotDisplay, !isPrerolling else {
            return false
        }
        guard let pts = samplePTS, pts.isNumeric else {
            return true
        }
        guard synchronizerCurrentTime.isNumeric else {
            return displayImmediately
        }
        return CMTimeGetSeconds(synchronizerCurrentTime) + 0.005 >= CMTimeGetSeconds(pts)
    }

    @MainActor
    public static func evaluateObservation(
        displayLayer: AVSampleBufferDisplayLayer,
        sampleBuffer: CMSampleBuffer?,
        cachedSampleColorimetry: (primaries: String?, transfer: String?, matrix: String?, dynamicRange: VideoDynamicRangeMode)? = nil,
        sourceDynamicRange: VideoDynamicRangeMode,
        hasEnqueuedSample: Bool,
        isSamplePresented: Bool,
        isSampleDoNotDisplay: Bool = false,
        isToneMappingConversionObserved: Bool = false,
        isRendererFailedOverride: Bool = false,
        hostScreen: VideoHostScreenObservation?,
        sessionID: UUID? = nil,
        playbackGeneration: UInt64? = nil
    ) -> VideoDisplayOutputObservation {
        let sampleHasDoNotDisplay = isSampleDoNotDisplay
            || (sampleBuffer.map { AVSampleBufferPlayerCoordinator.isDoNotDisplayAttachmentSet(on: $0) } ?? false)
        let sampleInfo = sampleBuffer != nil
            ? extractSampleColorimetry(from: sampleBuffer)
            : (cachedSampleColorimetry ?? (nil, nil, nil, .unknown))
        let edrConfigured = configureDisplayLayerEDR(
            displayLayer: displayLayer,
            sourceDynamicRange: sourceDynamicRange,
            sampleDynamicRange: sampleInfo.dynamicRange,
            hostScreen: hostScreen
        )
        let confirmation = classifyDisplayConfirmation(
            displayLayer: displayLayer,
            sourceDynamicRange: sourceDynamicRange,
            sampleDynamicRange: sampleInfo.dynamicRange,
            edrConfigured: edrConfigured,
            hasEnqueuedSample: hasEnqueuedSample,
            sampleHasDoNotDisplay: sampleHasDoNotDisplay,
            isSamplePresented: isSamplePresented,
            isToneMappingConversionObserved: isToneMappingConversionObserved,
            isRendererFailedOverride: isRendererFailedOverride,
            hostScreen: hostScreen
        )
        return VideoDisplayOutputObservation(
            screenSupportsEDR: hostScreen?.screenSupportsEDR ?? false,
            isHDRPresentationConfirmed: confirmation.hdrConfirmed,
            isToneMappedFallbackConfirmed: confirmation.toneMappedConfirmed,
            isSDRPresentationConfirmed: confirmation.sdrConfirmed,
            currentEDRHeadroom: hostScreen?.currentEDRHeadroom,
            potentialEDRHeadroom: hostScreen?.potentialEDRHeadroom,
            screenLocalizedName: hostScreen?.screenLocalizedName,
            screenColorSpaceName: hostScreen?.colorSpaceName,
            rendererName: "AVSampleBufferDisplayLayer",
            isRendererEDRConfigured: edrConfigured,
            hasEnqueuedVideoSample: hasEnqueuedSample && !sampleHasDoNotDisplay,
            sampleTransferFunction: sampleInfo.transfer,
            sampleColorPrimaries: sampleInfo.primaries,
            sampleYCbCrMatrix: sampleInfo.matrix,
            observedSampleDynamicRange: sampleInfo.dynamicRange,
            isDetecting: confirmation.isDetecting,
            diagnosticReason: confirmation.diagnosticReason,
            sessionID: sessionID,
            playbackGeneration: playbackGeneration
        )
    }

    @MainActor
    private static func classifyDisplayConfirmation(
        displayLayer: AVSampleBufferDisplayLayer,
        sourceDynamicRange: VideoDynamicRangeMode,
        sampleDynamicRange: VideoDynamicRangeMode,
        edrConfigured: Bool,
        hasEnqueuedSample: Bool,
        sampleHasDoNotDisplay: Bool,
        isSamplePresented: Bool,
        isToneMappingConversionObserved: Bool,
        isRendererFailedOverride: Bool,
        hostScreen: VideoHostScreenObservation?
    ) -> (hdrConfirmed: Bool, toneMappedConfirmed: Bool, sdrConfirmed: Bool, isDetecting: Bool, diagnosticReason: String?) {
        if displayLayer.status == .failed
            || displayLayer.sampleBufferRenderer.status == .failed
            || isRendererFailedOverride {
            let errText = displayLayer.error?.localizedDescription
                ?? displayLayer.sampleBufferRenderer.error?.localizedDescription
                ?? "AVSampleBufferDisplayLayer 渲染状态失败"
            return (false, false, false, false, errText)
        }
        guard hasEnqueuedSample else {
            return (false, false, false, true, nil)
        }
        if sampleHasDoNotDisplay {
            return (false, false, false, true, "当前样本标记为 DoNotDisplay（Preroll 预热帧），等待可显示样本提交")
        }
        guard isSamplePresented else {
            return (false, false, false, true, "首帧样本已入队，等待时间基准到达或渲染管线就绪")
        }
        guard sampleDynamicRange != .unknown else {
            return (false, false, false, false, "入队样本缺少明确传递函数（Transfer Function），无法仅凭缺失 HDR 元数据确认 SDR 或 HDR 输出")
        }
        if sampleDynamicRange == .sdr {
            if sourceDynamicRange.isHDR {
                return (false, true, true, false, "已观测到输出样本转换为明确 SDR 传递函数")
            }
            return (false, false, true, false, nil)
        }
        return classifyHDRSampleConfirmation(
            sampleDynamicRange: sampleDynamicRange,
            edrConfigured: edrConfigured,
            isToneMappingConversionObserved: isToneMappingConversionObserved,
            hostScreen: hostScreen
        )
    }

    private static func classifyHDRSampleConfirmation(
        sampleDynamicRange: VideoDynamicRangeMode,
        edrConfigured: Bool,
        isToneMappingConversionObserved: Bool,
        hostScreen: VideoHostScreenObservation?
    ) -> (hdrConfirmed: Bool, toneMappedConfirmed: Bool, sdrConfirmed: Bool, isDetecting: Bool, diagnosticReason: String?) {
        if isToneMappingConversionObserved && !edrConfigured {
            return (false, true, false, false, "管线已执行显式 SDR 色调映射转换")
        }
        guard let hostScreen, hostScreen.hasHostWindow else {
            return (false, false, false, false, "已入队 HDR 样本帧（\(sampleDynamicRange.rawValue)），但尚未绑定宿主屏幕，EDR 状态与输出待确认")
        }
        let hasActiveEDR = hostScreen.currentEDRHeadroom > 1.001
        if hasActiveEDR && edrConfigured {
            return (true, false, false, false, "可显示样本已提交，EDR 渲染管线已配置（\(sampleDynamicRange.rawValue)），硬件最终光学输出未直接测量")
        }
        let reason = (hostScreen.potentialEDRHeadroom > 1.001 && !hasActiveEDR)
            ? "EDR 未启用 / 输出待确认：宿主屏幕具 EDR 潜在上限但当前 Headroom 为 1.0x，入队样本仍为 \(sampleDynamicRange.rawValue)，未观测到显式 SDR 色调映射转换"
            : "EDR 未启用 / 输出待确认：宿主屏幕不支持 EDR，入队样本仍为 \(sampleDynamicRange.rawValue)，管线未执行或未观测到显式 SDR 色调映射转换"
        return (false, false, false, false, reason)
    }
}

// MARK: - Bounded Sample Presentation Timeline Tracker (Active Timebase vs. Future Prefetch Queue)

/// Lightweight value-type colorimetry & timing snapshot extracted at sample enqueue time.
/// Avoids retaining `CMSampleBuffer` / `CVPixelBuffer` instances in a secondary video frame queue.
public struct VideoSampleColorimetrySnapshot: Sendable, Equatable {
    public let pts: CMTime
    public let displayImmediately: Bool
    public let primaries: String?
    public let transfer: String?
    public let matrix: String?
    public let dynamicRange: VideoDynamicRangeMode

    public var tuple: (primaries: String?, transfer: String?, matrix: String?, dynamicRange: VideoDynamicRangeMode) {
        (primaries, transfer, matrix, dynamicRange)
    }

    public func hasSameColorimetry(as other: VideoSampleColorimetrySnapshot) -> Bool {
        primaries == other.primaries
            && transfer == other.transfer
            && matrix == other.matrix
            && dynamicRange == other.dynamicRange
    }
}

/// Tracks the distinction between the currently presented sample at `synchronizer.currentTime()`
/// and future prefetched samples waiting in `AVSampleBufferDisplayLayer`.
///
/// Invariants:
/// - Enqueuing a future sample (`pts > currentTime + tolerance`) never invalidates or overwrites
///   an already-active `activePresentedSample`.
/// - Colorimetry changes in a future sample take effect only after `synchronizer.currentTime()` reaches its `pts`.
/// - `DoNotDisplay` preroll samples never promote to `activePresentedSample` or `pendingFutureSamples`.
/// - Capacity of `pendingFutureSamples` is strictly bounded (`maxPendingSnapshots = 64`) and cleared on `reset()`.
public struct VideoSamplePresentationTimelineTracker: Sendable {
    public static let maxPendingSnapshots = 64
    public static let timebaseToleranceSeconds = 0.005

    public private(set) var hasEnqueuedAnySample: Bool = false
    public private(set) var hasEnqueuedDoNotDisplaySample: Bool = false
    public private(set) var activePresentedSample: VideoSampleColorimetrySnapshot? = nil
    public private(set) var pendingFutureSamples: [VideoSampleColorimetrySnapshot] = []

    public init() {}

    public mutating func reset() {
        hasEnqueuedAnySample = false
        hasEnqueuedDoNotDisplaySample = false
        activePresentedSample = nil
        pendingFutureSamples.removeAll(keepingCapacity: false)
    }

    public mutating func recordEnqueuedSample(
        _ sampleBuffer: CMSampleBuffer?,
        preextractedSnapshot: VideoSampleColorimetrySnapshot? = nil,
        isDoNotDisplayOverride: Bool? = nil,
        currentTime: CMTime,
        isPrerolling: Bool
    ) {
        hasEnqueuedAnySample = true
        guard sampleBuffer != nil || preextractedSnapshot != nil else {
            _ = synchronizeWithTimebase(currentTime: currentTime, isPrerolling: isPrerolling)
            return
        }
        let isDoNotDisplay = isDoNotDisplayOverride
            ?? sampleBuffer.map { AVSampleBufferPlayerCoordinator.isDoNotDisplayAttachmentSet(on: $0) }
            ?? false
        if isDoNotDisplay {
            hasEnqueuedDoNotDisplaySample = true
            _ = synchronizeWithTimebase(currentTime: currentTime, isPrerolling: isPrerolling)
            return
        }
        let snapshot: VideoSampleColorimetrySnapshot
        if let preextractedSnapshot {
            snapshot = preextractedSnapshot
        } else if let sampleBuffer {
            let color = VideoRendererOutputEvaluator.extractSampleColorimetry(from: sampleBuffer)
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let displayImmediately = AVSampleBufferPlayerCoordinator.isDisplayImmediatelyAttachmentSet(on: sampleBuffer)
            snapshot = VideoSampleColorimetrySnapshot(
                pts: pts,
                displayImmediately: displayImmediately,
                primaries: color.primaries,
                transfer: color.transfer,
                matrix: color.matrix,
                dynamicRange: color.dynamicRange
            )
        } else {
            return
        }
        insertPendingSnapshot(snapshot)
        _ = synchronizeWithTimebase(currentTime: currentTime, isPrerolling: isPrerolling)
    }

    @discardableResult
    public mutating func synchronizeWithTimebase(
        currentTime: CMTime,
        isPrerolling: Bool
    ) -> VideoSampleColorimetrySnapshot? {
        if isPrerolling {
            return activePresentedSample
        }
        if let active = activePresentedSample,
           active.pts.isNumeric {
            if !currentTime.isNumeric
                || CMTimeGetSeconds(currentTime) + Self.timebaseToleranceSeconds < CMTimeGetSeconds(active.pts) {
                activePresentedSample = nil
                insertPendingSnapshot(active)
            }
        }
        while let earliest = pendingFutureSamples.first {
            let isDue: Bool
            if !earliest.pts.isNumeric {
                isDue = true
            } else if currentTime.isNumeric {
                isDue = CMTimeGetSeconds(currentTime) + Self.timebaseToleranceSeconds >= CMTimeGetSeconds(earliest.pts)
            } else {
                isDue = earliest.displayImmediately
            }
            guard isDue else { break }
            let candidate = pendingFutureSamples.removeFirst()
            if let active = activePresentedSample,
               active.pts.isNumeric,
               candidate.pts.isNumeric,
               !candidate.displayImmediately,
               CMTimeGetSeconds(candidate.pts) + 0.000_1 < CMTimeGetSeconds(active.pts) {
                continue
            }
            activePresentedSample = candidate
        }
        return activePresentedSample
    }

    private mutating func insertPendingSnapshot(_ snapshot: VideoSampleColorimetrySnapshot) {
        if !snapshot.pts.isNumeric {
            guard snapshot.displayImmediately else { return }
            pendingFutureSamples.insert(snapshot, at: 0)
            trimPendingIfNeeded()
            return
        }
        let targetSec = CMTimeGetSeconds(snapshot.pts)
        if let existingIdx = pendingFutureSamples.firstIndex(where: {
            $0.pts.isNumeric && abs(CMTimeGetSeconds($0.pts) - targetSec) < 0.000_1
        }) {
            pendingFutureSamples[existingIdx] = snapshot
            return
        }
        if let insertIdx = pendingFutureSamples.firstIndex(where: {
            $0.pts.isNumeric && CMTimeGetSeconds($0.pts) > targetSec
        }) {
            pendingFutureSamples.insert(snapshot, at: insertIdx)
        } else {
            pendingFutureSamples.append(snapshot)
        }
        trimPendingIfNeeded()
    }

    private mutating func trimPendingIfNeeded() {
        while pendingFutureSamples.count > Self.maxPendingSnapshots {
            if let redundantIdx = (1..<(pendingFutureSamples.count - 1)).first(where: { idx in
                pendingFutureSamples[idx].hasSameColorimetry(as: pendingFutureSamples[idx - 1])
            }) {
                pendingFutureSamples.remove(at: redundantIdx)
            } else {
                pendingFutureSamples.remove(at: 1)
            }
        }
    }
}

// MARK: - Controller & Session Live Output Observation Wiring (Session & Generation Guarded)

extension AVAssetReaderPlaybackController {
    internal func resetSampleObservationForNewGeneration() {
        sampleObservationTimeline.reset()
        formatPresentationState = formatPresentationState.applyingDisplayObservation(nil)
        onFormatPresentationStateChanged?(formatPresentationState)
    }

    public func updateHostScreenObservation(
        _ screenObservation: VideoHostScreenObservation?,
        forGeneration generation: UInt64? = nil
    ) {
        if let generation, generation != transitionGeneration {
            return
        }
        latestHostScreenObservation = screenObservation
        refreshLiveOutputObservation()
    }

    internal func recordVideoSampleEnqueuedForObservation(
        _ sample: CMSampleBuffer? = nil,
        preextractedSnapshot: VideoSampleColorimetrySnapshot? = nil,
        isDoNotDisplayOverride: Bool? = nil,
        forSessionID sessionID: UUID? = nil,
        forGeneration generation: UInt64? = nil
    ) {
        if let generation, generation != transitionGeneration {
            return
        }
        if let sessionID, let activeID = activeSessionID, sessionID != activeID {
            return
        }
        if let sessionID, activeSessionID == nil, retiringSessionID == sessionID {
            return
        }
        let isDoNotDisplay = isDoNotDisplayOverride
            ?? sample.map { AVSampleBufferPlayerCoordinator.isDoNotDisplayAttachmentSet(on: $0) }
            ?? false
        if let sample, !isDoNotDisplay,
           let desc = CMSampleBufferGetFormatDescription(sample) {
            latestVideoFormatDescription = desc
        }
        sampleObservationTimeline.recordEnqueuedSample(
            sample,
            preextractedSnapshot: preextractedSnapshot,
            isDoNotDisplayOverride: isDoNotDisplayOverride,
            currentTime: synchronizer.currentTime(),
            isPrerolling: pendingStartRequest != nil
        )
        refreshLiveOutputObservation()
    }

    internal func refreshLiveOutputObservation(sampleBuffer: CMSampleBuffer? = nil) {
        let syncTime = synchronizer.currentTime()
        let isPrerolling = pendingStartRequest != nil
        let activeSample = sampleObservationTimeline.synchronizeWithTimebase(
            currentTime: syncTime,
            isPrerolling: isPrerolling
        )
        let hasDisplayable = activeSample != nil || !sampleObservationTimeline.pendingFutureSamples.isEmpty
        let isOnlyDoNotDisplay = sampleObservationTimeline.hasEnqueuedDoNotDisplaySample && !hasDisplayable
        let isReadyForPresentation = VideoRendererOutputEvaluator.isSampleReadyForPresentation(
            displayLayer: displayLayer,
            hasEnqueuedDisplayableSample: activeSample != nil,
            latestSampleIsDoNotDisplay: isOnlyDoNotDisplay,
            isPrerolling: isPrerolling,
            displayImmediately: activeSample?.displayImmediately ?? false,
            samplePTS: activeSample?.pts,
            synchronizerCurrentTime: syncTime
        )
        let colorimetry = activeSample?.tuple ?? sampleObservationTimeline.pendingFutureSamples.first?.tuple
        let observation = VideoRendererOutputEvaluator.evaluateObservation(
            displayLayer: displayLayer,
            sampleBuffer: nil,
            cachedSampleColorimetry: colorimetry,
            sourceDynamicRange: formatPresentationState.sourceDynamicRange,
            hasEnqueuedSample: sampleObservationTimeline.hasEnqueuedAnySample,
            isSamplePresented: isReadyForPresentation,
            isSampleDoNotDisplay: isOnlyDoNotDisplay,
            hostScreen: latestHostScreenObservation,
            sessionID: activeSessionID,
            playbackGeneration: transitionGeneration
        )
        formatPresentationState = formatPresentationState.applyingDisplayObservation(observation)
        onFormatPresentationStateChanged?(formatPresentationState)
    }
}

extension AVSampleBufferWorkerPlaybackController {
    internal static func makeFormatPresentationState(from track: TTMediaVideoTrackInfo) -> VideoFormatPresentationState {
        VideoFormatPresentationState.fromWorkerVideoTrack(track)
    }

    internal func resetSampleObservationForNewGeneration() {
        sampleObservationTimeline.reset()
        formatPresentationState = formatPresentationState.applyingDisplayObservation(nil)
        onFormatPresentationStateChanged?(formatPresentationState)
    }

    public func applyDisplayObservation(_ observation: VideoDisplayOutputObservation?) {
        if let gen = observation?.playbackGeneration, gen != playbackGeneration {
            return
        }
        formatPresentationState = formatPresentationState.applyingDisplayObservation(observation)
        onFormatPresentationStateChanged?(formatPresentationState)
    }

    public func updateHostScreenObservation(
        _ screenObservation: VideoHostScreenObservation?,
        forGeneration generation: UInt64? = nil
    ) {
        if let generation, generation != playbackGeneration {
            return
        }
        latestHostScreenObservation = screenObservation
        refreshLiveOutputObservation(sampleBuffer: nil)
    }

    internal func recordVideoSampleEnqueuedForObservation(
        _ sample: CMSampleBuffer,
        forGeneration generation: UInt64? = nil
    ) {
        if let generation, generation != playbackGeneration {
            return
        }
        sampleObservationTimeline.recordEnqueuedSample(
            sample,
            currentTime: coordinator.synchronizer.currentTime(),
            isPrerolling: coordinator.isPrerolling
        )
        refreshLiveOutputObservation(sampleBuffer: nil)
    }

    internal func refreshLiveOutputObservation(sampleBuffer: CMSampleBuffer? = nil) {
        let syncTime = coordinator.synchronizer.currentTime()
        let isPrerolling = coordinator.isPrerolling
        let activeSample = sampleObservationTimeline.synchronizeWithTimebase(
            currentTime: syncTime,
            isPrerolling: isPrerolling
        )
        let hasDisplayable = activeSample != nil || !sampleObservationTimeline.pendingFutureSamples.isEmpty
        let isOnlyDoNotDisplay = sampleObservationTimeline.hasEnqueuedDoNotDisplaySample && !hasDisplayable
        let isReadyForPresentation = VideoRendererOutputEvaluator.isSampleReadyForPresentation(
            displayLayer: coordinator.displayLayer,
            hasEnqueuedDisplayableSample: activeSample != nil,
            latestSampleIsDoNotDisplay: isOnlyDoNotDisplay,
            isPrerolling: isPrerolling,
            displayImmediately: activeSample?.displayImmediately ?? false,
            samplePTS: activeSample?.pts,
            synchronizerCurrentTime: syncTime
        )
        let colorimetry = activeSample?.tuple ?? sampleObservationTimeline.pendingFutureSamples.first?.tuple
        let observation = VideoRendererOutputEvaluator.evaluateObservation(
            displayLayer: coordinator.displayLayer,
            sampleBuffer: nil,
            cachedSampleColorimetry: colorimetry,
            sourceDynamicRange: formatPresentationState.sourceDynamicRange,
            hasEnqueuedSample: sampleObservationTimeline.hasEnqueuedAnySample,
            isSamplePresented: isReadyForPresentation,
            isSampleDoNotDisplay: isOnlyDoNotDisplay,
            hostScreen: latestHostScreenObservation,
            sessionID: nil,
            playbackGeneration: playbackGeneration
        )
        formatPresentationState = formatPresentationState.applyingDisplayObservation(observation)
        onFormatPresentationStateChanged?(formatPresentationState)
    }
}

extension VideoPlaybackSession {
    /// Applies a display/renderer output observation to the active playback session,
    /// strictly rejecting stale receipts from an older `sessionID` or `playbackGeneration`.
    func applyDisplayObservation(_ observation: VideoDisplayOutputObservation?) {
        guard !isStopped else { return }
        if let receiptSessionID = observation?.sessionID, receiptSessionID != sessionID {
            return
        }
        if let receiptGen = observation?.playbackGeneration, receiptGen != sessionGeneration {
            return
        }
        switch activeController {
        case .native(let nc):
            let controllerObs = observation.map { obs in
                Self.rebindingObservation(obs, sessionID: sessionID, generation: nc.transitionGeneration)
            }
            nc.applyDisplayObservation(controllerObs)
            formatPresentationState = nc.formatPresentationState
        case .worker(let wc):
            let controllerObs = observation.map { obs in
                Self.rebindingObservation(obs, sessionID: sessionID, generation: wc.playbackGeneration)
            }
            wc.applyDisplayObservation(controllerObs)
            formatPresentationState = wc.formatPresentationState
        case .none:
            formatPresentationState = formatPresentationState.applyingDisplayObservation(observation)
        }
    }

    private static func rebindingObservation(
        _ obs: VideoDisplayOutputObservation,
        sessionID: UUID,
        generation: UInt64
    ) -> VideoDisplayOutputObservation {
        VideoDisplayOutputObservation(
            screenSupportsEDR: obs.screenSupportsEDR,
            isHDRPresentationConfirmed: obs.isHDRPresentationConfirmed,
            isToneMappedFallbackConfirmed: obs.isToneMappedFallbackConfirmed,
            isSDRPresentationConfirmed: obs.isSDRPresentationConfirmed,
            currentEDRHeadroom: obs.currentEDRHeadroom,
            potentialEDRHeadroom: obs.potentialEDRHeadroom,
            screenLocalizedName: obs.screenLocalizedName,
            screenColorSpaceName: obs.screenColorSpaceName,
            rendererName: obs.rendererName,
            isRendererEDRConfigured: obs.isRendererEDRConfigured,
            hasEnqueuedVideoSample: obs.hasEnqueuedVideoSample,
            sampleTransferFunction: obs.sampleTransferFunction,
            sampleColorPrimaries: obs.sampleColorPrimaries,
            sampleYCbCrMatrix: obs.sampleYCbCrMatrix,
            observedSampleDynamicRange: obs.observedSampleDynamicRange,
            isDetecting: obs.isDetecting,
            diagnosticReason: obs.diagnosticReason,
            sessionID: sessionID,
            playbackGeneration: generation
        )
    }

    /// Updates the hosting `NSScreen` observation for the active session, reconfiguring `displayLayer` EDR
    /// and updating `formatPresentationState` while rejecting stale session or generation receipts.
    func updateHostScreenObservation(
        _ screenObservation: VideoHostScreenObservation?,
        forSessionID receiptSessionID: UUID? = nil,
        generation: UInt64? = nil
    ) {
        guard !isStopped else { return }
        if let receiptSessionID, receiptSessionID != sessionID {
            return
        }
        if let generation, generation != sessionGeneration {
            return
        }
        latestHostScreenObservation = screenObservation
        guard let activeController else { return }
        propagateHostScreenObservation(to: activeController)
    }

    internal func propagateHostScreenObservation(to wrapper: VideoPlaybackController) {
        guard let latestHostScreenObservation else { return }
        switch wrapper {
        case .native(let nc):
            nc.updateHostScreenObservation(latestHostScreenObservation, forGeneration: nc.transitionGeneration)
            formatPresentationState = nc.formatPresentationState
        case .worker(let wc):
            wc.updateHostScreenObservation(latestHostScreenObservation, forGeneration: wc.playbackGeneration)
            formatPresentationState = wc.formatPresentationState
        }
    }
}
