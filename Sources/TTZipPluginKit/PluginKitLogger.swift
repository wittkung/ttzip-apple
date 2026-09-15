// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import os

/// Internal diagnostic logger for TTZipPluginKit infrastructure
enum PluginKitLogger {
    static let logger = Logger(subsystem: "com.metastudyline.ttzip", category: "PluginKit")
    
    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
    
    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
    
    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }
    
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
