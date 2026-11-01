// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
@preconcurrency import AVFoundation
@preconcurrency import AVKit
import CoreMedia
import Foundation
import os

/// Hardware-accelerated Picture-in-Picture controller for `AVSampleBufferDisplayLayer`.
///
/// Binds native macOS floating Picture-in-Picture directly to `AVSampleBufferPlayerCoordinator`,
/// responding to system play, pause, time-range requests, render size adjustments, and skip intervals.
@MainActor
public final class AVSampleBufferPiPController: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "AVSampleBufferPiPController")

    // MARK: - Properties

    public let displayLayer: AVSampleBufferDisplayLayer
    public weak var coordinator: AVSampleBufferPlayerCoordinator?

    public private(set) var pipController: AVPictureInPictureController?

    @Published public private(set) var isPictureInPictureActive: Bool = false
    @Published public private(set) var isPictureInPicturePossible: Bool = false

    private var pipPossibleObservation: NSKeyValueObservation?

    // MARK: - Initialization

    public init(displayLayer: AVSampleBufferDisplayLayer, coordinator: AVSampleBufferPlayerCoordinator? = nil) {
        self.displayLayer = displayLayer
        self.coordinator = coordinator
        super.init()
        setupPiPController()
    }

    public convenience init(coordinator: AVSampleBufferPlayerCoordinator) {
        self.init(displayLayer: coordinator.displayLayer, coordinator: coordinator)
    }

    deinit {
        pipPossibleObservation?.invalidate()
    }

    // MARK: - Controller Setup

    private func setupPiPController() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            logger.debug("Picture in Picture is not supported on this platform configuration.")
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self

        self.isPictureInPicturePossible = controller.isPictureInPicturePossible
        self.pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] ctrl, _ in
            Task { @MainActor [weak self] in
                self?.isPictureInPicturePossible = ctrl.isPictureInPicturePossible
            }
        }
        self.pipController = controller
    }

    // MARK: - PiP Actions

    /// Whether Picture-in-Picture is supported on the current hardware/OS.
    public var isPictureInPictureSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// Whether PiP can be toggled in current state.
    public var canTogglePictureInPicture: Bool {
        isPictureInPictureSupported && (isPictureInPictureActive || isPictureInPicturePossible)
    }

    /// Requests presentation of the Picture-in-Picture window.
    public func startPictureInPicture() {
        guard let pipController = pipController, pipController.isPictureInPicturePossible else {
            logger.warning("Picture in Picture cannot start: controller unavailable or not possible")
            return
        }
        pipController.startPictureInPicture()
    }

    /// Requests dismissal of the Picture-in-Picture window.
    public func stopPictureInPicture() {
        guard let pipController = pipController, pipController.isPictureInPictureActive else { return }
        pipController.stopPictureInPicture()
    }

    /// Toggles Picture-in-Picture active state.
    public func togglePictureInPicture() {
        if isPictureInPictureActive {
            stopPictureInPicture()
        } else {
            startPictureInPicture()
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension AVSampleBufferPiPController: @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        if playing {
            coordinator?.play()
        } else {
            coordinator?.pause()
        }
    }

    public func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        guard let coordinator = coordinator, coordinator.duration > .zero else {
            return CMTimeRange(start: .zero, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: coordinator.duration)
    }

    public func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        return !(coordinator?.isPlaying ?? false)
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        logger.debug("PiP did transition to render size: \(newRenderSize.width)x\(newRenderSize.height)")
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping () -> Void
    ) {
        if let coordinator = coordinator {
            let current = coordinator.currentTime
            let target = CMTimeAdd(current, skipInterval)
            coordinator.seek(to: target, preroll: true)
        }
        completion()
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completionHandler: @escaping () -> Void
    ) {
        self.pictureInPictureController(
            pictureInPictureController,
            skipByInterval: skipInterval,
            completion: completionHandler
        )
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension AVSampleBufferPiPController: @preconcurrency AVPictureInPictureControllerDelegate {
    public func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        logger.debug("Picture-in-Picture will start")
    }

    public func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActive = true
        logger.debug("Picture-in-Picture did start")
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureActive = false
        logger.error("Picture-in-Picture failed to start: \(error.localizedDescription)")
    }

    public func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        logger.debug("Picture-in-Picture will stop")
    }

    public func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActive = false
        logger.debug("Picture-in-Picture did stop")
    }

    public func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
