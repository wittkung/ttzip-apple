// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import os
import TTZipPluginKit

private let safeModeLogger = Logger(subsystem: "com.metastudyline.ttzip", category: "SafeMode")

/// Safe Mode crash counter and launch fault-isolation manager
@MainActor
public final class TTZipPluginSafeModeManager {
    public static let shared = TTZipPluginSafeModeManager()
    
    private let crashCountKey = "com.ttzip.consecutiveCrashCount"
    private let launchTimestampKey = "com.ttzip.lastLaunchTimestamp"
    
    public private(set) var isSafeModeActive: Bool = false
    
    private init() {}
    
    /// Evaluates crash frequency upon application launch.
    /// If app launched within 8 seconds of prior launch repeatedly (>= 3 times), triggers Safe Mode.
    public func evaluateCrashState() {
        let now = Date().timeIntervalSince1970
        let lastLaunch = UserDefaults.standard.double(forKey: launchTimestampKey)
        let currentCrashCount = UserDefaults.standard.integer(forKey: crashCountKey)
        
        if lastLaunch > 0 && (now - lastLaunch) < 8.0 {
            let newCount = currentCrashCount + 1
            UserDefaults.standard.set(newCount, forKey: crashCountKey)
            if newCount >= 3 {
                isSafeModeActive = true
                safeModeLogger.error("[SafeMode] Detected \(newCount) rapid consecutive launches/crashes. Safe Mode activated.")
            }
        } else if lastLaunch > 0 && (now - lastLaunch) > 60.0 {
            // Survived steady-state operation, reset counter
            UserDefaults.standard.set(0, forKey: crashCountKey)
            isSafeModeActive = false
        }
        UserDefaults.standard.set(now, forKey: launchTimestampKey)
    }
    
    /// Clears crash counter and disables safe mode
    public func resetSafeMode() {
        UserDefaults.standard.set(0, forKey: crashCountKey)
        UserDefaults.standard.removeObject(forKey: launchTimestampKey)
        isSafeModeActive = false
    }
}
