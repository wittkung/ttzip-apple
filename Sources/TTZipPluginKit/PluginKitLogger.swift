// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTLogKit

/// Internal diagnostic logger for TTZipPluginKit infrastructure
public enum PluginKitLogger {
    public static let logger = TTLog(TTLogCategory(rawValue: "PluginKit"))
    
    @inline(__always)
    public static func debug(_ message: @autoclosure () -> String, file: String = #file, line: UInt = #line) {
        let msg = message()
        logger.debug("\(msg)")
    }
    
    @inline(__always)
    public static func info(_ message: @autoclosure () -> String, file: String = #file, line: UInt = #line) {
        let msg = message()
        logger.info("\(msg)")
    }
    
    @inline(__always)
    public static func warning(_ message: @autoclosure () -> String, file: String = #file, line: UInt = #line) {
        let msg = message()
        logger.warning("\(msg)")
    }
    
    @inline(__always)
    public static func error(_ message: @autoclosure () -> String, file: String = #file, line: UInt = #line) {
        let msg = message()
        logger.error("\(msg)")
    }
}
