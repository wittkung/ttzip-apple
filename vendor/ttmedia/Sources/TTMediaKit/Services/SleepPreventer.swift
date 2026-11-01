// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import IOKit.pwr_mgt
import os

/// Supported power assertion categories defining sleep prevention scope.
public enum SleepAssertionMode: Sendable, Equatable {
    /// Prevents both display sleep and system idle sleep (standard video playback).
    case videoPlayback
    /// Prevents system idle sleep while allowing the display to sleep normally to conserve energy (pure audio playback).
    case audioPlayback
}

/// High-precision power assertion coordinator managing display and system sleep suppression during active media playback,
/// strictly aligned with IINA's `SleepPreventer.swift` architecture and Apple IOKit power management guidelines.
public final class SleepPreventer: @unchecked Sendable {
    public static let shared = SleepPreventer()
    
    private let logger = Logger(subsystem: "com.metastudyline.ttmedia", category: "SleepPreventer")
    private let lock = NSLock()
    
    private var videoHoldCount: Int = 0
    private var audioHoldCount: Int = 0
    private var isDisplaySuspended: Bool = false
    private var assertionID: IOPMAssertionID = 0
    private var activeAssertionType: CFString? = nil
    private var currentReason: String = "TTMedia Playback Active"
    
    private init() {}
    
    /// Acquires power assertion under the specified mode.
    /// Thread-safe and re-entrant across concurrent players or playback pipelines.
    ///
    /// - Parameters:
    ///   - mode: The assertion scope (`.videoPlayback` or `.audioPlayback`).
    ///   - reason: Human-readable assertion description reported to macOS pmset.
    public func acquire(mode: SleepAssertionMode, reason: String = "TTMedia Playback Active") {
        lock.lock()
        defer { lock.unlock() }
        
        switch mode {
        case .videoPlayback:
            videoHoldCount += 1
        case .audioPlayback:
            audioHoldCount += 1
        }
        self.currentReason = reason
        updateAssertionUnderLock()
    }
    
    /// Releases an active sleep assertion.
    /// Decrements hold count and releases OS power assertions when all holds drop to zero.
    ///
    /// - Parameter mode: Specific assertion mode to release. If nil, releases video hold first, then audio.
    public func release(mode: SleepAssertionMode? = nil) {
        lock.lock()
        defer { lock.unlock() }
        
        if let mode {
            switch mode {
            case .videoPlayback:
                if videoHoldCount > 0 { videoHoldCount -= 1 }
            case .audioPlayback:
                if audioHoldCount > 0 { audioHoldCount -= 1 }
            }
        } else {
            if videoHoldCount > 0 {
                videoHoldCount -= 1
            } else if audioHoldCount > 0 {
                audioHoldCount -= 1
            }
        }
        updateAssertionUnderLock()
    }
    
    /// Temporarily suspends display sleep assertion while keeping system sleep assertion active.
    /// Invoked when playback window is minimized to the Dock or occluded, preventing screen burn-in and energy drain.
    public func suspendDisplayAssertion() {
        lock.lock()
        defer { lock.unlock() }
        guard !isDisplaySuspended else { return }
        isDisplaySuspended = true
        logger.info("Suspended display sleep assertion (window minimized/hidden)")
        updateAssertionUnderLock()
    }
    
    /// Resumes display sleep assertion when the playback window is un-minimized or becomes visible again.
    public func resumeDisplayAssertion() {
        lock.lock()
        defer { lock.unlock() }
        guard isDisplaySuspended else { return }
        isDisplaySuspended = false
        logger.info("Resumed display sleep assertion (window visible)")
        updateAssertionUnderLock()
    }
    
    /// Backward-compatible video playback sleep hold.
    public func holdSleep() {
        acquire(mode: .videoPlayback)
    }
    
    /// Backward-compatible video playback sleep release.
    public func releaseSleep() {
        release(mode: .videoPlayback)
    }
    
    /// Forces complete release of any active power assertions during teardown, emergency backgrounding, or tests.
    public func forceReset() {
        lock.lock()
        defer { lock.unlock() }
        videoHoldCount = 0
        audioHoldCount = 0
        isDisplaySuspended = false
        if assertionID != 0 {
            _ = IOPMAssertionRelease(assertionID)
            assertionID = 0
            activeAssertionType = nil
            logger.info("Force reset all power assertions")
        }
    }
    
    /// Returns true if any sleep assertion is currently held.
    public var isHoldingSleep: Bool {
        lock.lock()
        defer { lock.unlock() }
        return videoHoldCount > 0 || audioHoldCount > 0
    }
    
    // MARK: - Internal State Reconciliation
    
    private func updateAssertionUnderLock() {
        let desiredType: CFString?
        if videoHoldCount > 0 {
            if isDisplaySuspended {
                desiredType = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
            } else {
                desiredType = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
            }
        } else if audioHoldCount > 0 {
            desiredType = kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        } else {
            desiredType = nil
        }
        
        if let desiredType {
            if assertionID != 0 && activeAssertionType == desiredType {
                return
            }
            
            var newAssertionID: IOPMAssertionID = 0
            let reasonCF = currentReason as CFString
            let result = IOPMAssertionCreateWithName(
                desiredType,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reasonCF,
                &newAssertionID
            )
            
            if result == kIOReturnSuccess {
                if assertionID != 0 {
                    _ = IOPMAssertionRelease(assertionID)
                }
                assertionID = newAssertionID
                activeAssertionType = desiredType
                logger.info("Acquired sleep assertion: type=\(desiredType as String), ID=\(newAssertionID)")
            } else {
                logger.warning("Failed to create sleep assertion: type=\(desiredType as String), err=\(result)")
            }
        } else {
            if assertionID != 0 {
                let result = IOPMAssertionRelease(assertionID)
                if result == kIOReturnSuccess {
                    logger.info("Released sleep assertion: ID=\(self.assertionID)")
                } else {
                    logger.warning("Failed to release sleep assertion: err=\(result)")
                }
                assertionID = 0
                activeAssertionType = nil
            }
        }
    }
}
