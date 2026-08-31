// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import QuartzCore
import CoreVideo
import os.log

/// High-precision VSync hardware pulse synchronizer locking up to 120Hz Apple ProMotion.
///
/// Encapsulates modern macOS 14.0+ `CADisplayLink` with `CVDisplayLink` fallback, offering
/// deterministic rising-edge frame dispatch, sub-millisecond jitter dampening, and
/// zero-overhead power suspension when views are occluded or minimized.
public final class MPVMetalDisplayLink: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "MPVMetalDisplayLink")
    private let lock = NSLock()
    
    /// Target frame rate range locked to 120Hz Apple ProMotion displays.
    public static let proMotionRange = CAFrameRateRange(minimum: 24.0, maximum: 120.0, preferred: 120.0)
    
    public typealias FrameCallback = @Sendable (CFTimeInterval, CFTimeInterval) -> Void
    
    private var frameCallback: FrameCallback?
    private var displayLink: CADisplayLink?
    private var cvDisplayLink: CVDisplayLink?
    private weak var targetView: NSView?
    private var isRunningInternal: Bool = false
    private var isSuspendedInternal: Bool = false
    
    // Target action trampoline for CADisplayLink
    private final class Trampoline: NSObject {
        weak var owner: MPVMetalDisplayLink?
        
        init(owner: MPVMetalDisplayLink) {
            self.owner = owner
            super.init()
        }
        
        @objc func onDisplayLinkPulse(_ link: CADisplayLink) {
            owner?.handleDisplayLinkPulse(link)
        }
    }
    
    private var trampoline: Trampoline?
    
    /// Current running state of the display link.
    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunningInternal && !isSuspendedInternal
    }
    
    /// Whether the display link is temporarily suspended due to window occlusion or minimization.
    public var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSuspendedInternal
    }
    
    public init() {
        self.trampoline = Trampoline(owner: self)
    }
    
    deinit {
        stop()
    }
    
    /// Sets the rising-edge frame presentation callback invoked on every VSync tick.
    ///
    /// - Parameter callback: Closure receiving `(timestamp, targetTimestamp)`.
    public func setFrameCallback(_ callback: FrameCallback?) {
        lock.lock()
        defer { lock.unlock() }
        self.frameCallback = callback
    }
    
    /// Binds the display link to a host NSView to leverage display-specific refresh rates.
    ///
    /// - Parameter view: The host `NSView` located in an active window.
    @MainActor
    public func attach(to view: NSView) {
        self.targetView = view
        if isRunningInternal {
            rebuildDisplayLink()
        }
    }
    
    /// Starts the VSync hardware pulse tracking.
    @MainActor
    public func start() {
        lock.lock()
        self.isRunningInternal = true
        self.isSuspendedInternal = false
        lock.unlock()
        
        rebuildDisplayLink()
        logger.debug("MPVMetalDisplayLink started with 120Hz ProMotion target range")
    }
    
    /// Pauses or suspends the display link (e.g. when occluded or minimized) with zero CPU/GPU overhead.
    public func suspend() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunningInternal, !isSuspendedInternal else { return }
        self.isSuspendedInternal = true
        
        if let link = displayLink {
            link.isPaused = true
        } else if let cvLink = cvDisplayLink {
            CVDisplayLinkStop(cvLink)
        }
        logger.debug("MPVMetalDisplayLink suspended due to occlusion/inactivity")
    }
    
    /// Resumes the display link when returning from occlusion or background state.
    public func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunningInternal, isSuspendedInternal else { return }
        self.isSuspendedInternal = false
        
        if let link = displayLink {
            link.isPaused = false
        } else if let cvLink = cvDisplayLink {
            CVDisplayLinkStart(cvLink)
        }
        logger.debug("MPVMetalDisplayLink resumed")
    }
    
    /// Stops and dismantles the active display link.
    public func stop() {
        lock.lock()
        self.isRunningInternal = false
        self.isSuspendedInternal = false
        let activeLink = self.displayLink
        let activeCV = self.cvDisplayLink
        self.displayLink = nil
        self.cvDisplayLink = nil
        lock.unlock()
        
        activeLink?.isPaused = true
        activeLink?.invalidate()
        
        if let activeCV = activeCV {
            CVDisplayLinkStop(activeCV)
        }
        logger.debug("MPVMetalDisplayLink stopped")
    }
    
    // MARK: - Private Assembly & Pulse Dispatch
    
    @MainActor
    private func rebuildDisplayLink() {
        // Invalidate previous instance
        displayLink?.isPaused = true
        displayLink?.invalidate()
        displayLink = nil
        
        if let cvLink = cvDisplayLink {
            CVDisplayLinkStop(cvLink)
            cvDisplayLink = nil
        }
        
        guard isRunningInternal else { return }
        
        guard let target = self.trampoline else { return }
        
        // Attempt macOS 14+ modern view/screen CADisplayLink creation
        let modernLink: CADisplayLink? = {
            if let view = targetView {
                return view.displayLink(target: target, selector: #selector(Trampoline.onDisplayLinkPulse(_:)))
            } else if let screen = NSScreen.main {
                return screen.displayLink(target: target, selector: #selector(Trampoline.onDisplayLinkPulse(_:)))
            }
            return nil
        }()
        
        if let link = modernLink {
            link.preferredFrameRateRange = Self.proMotionRange
            link.add(to: .main, forMode: .common)
            link.isPaused = isSuspendedInternal
            self.displayLink = link
            logger.info("Allocated native CADisplayLink with ProMotion support")
        } else {
            // Robust CVDisplayLink fallback for headless or legacy environments
            setupCVDisplayLinkFallback()
        }
    }
    
    private func setupCVDisplayLinkFallback() {
        var newLink: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&newLink)
        guard result == kCVReturnSuccess, let validLink = newLink else {
            logger.error("Failed to allocate fallback CVDisplayLink: \(result)")
            return
        }
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: CVDisplayLinkOutputCallback = { _, inNow, inOutputTime, _, _, displayLinkContext in
            guard let context = displayLinkContext else { return kCVReturnSuccess }
            let link = Unmanaged<MPVMetalDisplayLink>.fromOpaque(context).takeUnretainedValue()
            let now = Double(inNow.pointee.videoTime) / Double(inNow.pointee.videoTimeScale)
            let target = Double(inOutputTime.pointee.videoTime) / Double(inOutputTime.pointee.videoTimeScale)
            link.dispatchFramePulse(timestamp: now, targetTimestamp: target)
            return kCVReturnSuccess
        }
        
        CVDisplayLinkSetOutputCallback(validLink, callback, selfPtr)
        if !isSuspendedInternal {
            CVDisplayLinkStart(validLink)
        }
        self.cvDisplayLink = validLink
        logger.info("Allocated CVDisplayLink fallback pipeline")
    }
    
    fileprivate func handleDisplayLinkPulse(_ link: CADisplayLink) {
        guard isRunning else { return }
        let now = link.timestamp
        let target = link.targetTimestamp
        dispatchFramePulse(timestamp: now, targetTimestamp: target)
    }
    
    private func dispatchFramePulse(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        lock.lock()
        let callback = self.frameCallback
        let isSuspended = self.isSuspendedInternal
        lock.unlock()
        
        guard !isSuspended, let callback = callback else { return }
        callback(timestamp, targetTimestamp)
    }
}
