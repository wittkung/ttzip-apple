// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation
import TTZipCore

/// Dedicated logging channel for `TTZipPreviewKit` bridging component-level diagnostic telemetry
/// directly to `TTLogger` for Apple Unified Logging and persistent file logging (`~/Library/Logs/TTZip/ttzip.log`).
public struct PreviewKitLogger: Sendable {
    public let category: String

    public init(category: String) {
        self.category = category
    }

    @inline(__always)
    public func debug(
        _ message: @autoclosure () -> String,
        file: String = #file,
        line: UInt = #line
    ) {
        log(level: .debug, message: message(), file: file, line: line)
    }

    @inline(__always)
    public func info(
        _ message: @autoclosure () -> String,
        file: String = #file,
        line: UInt = #line
    ) {
        log(level: .info, message: message(), file: file, line: line)
    }

    @inline(__always)
    public func warning(
        _ message: @autoclosure () -> String,
        file: String = #file,
        line: UInt = #line
    ) {
        log(level: .warning, message: message(), file: file, line: line)
    }

    @inline(__always)
    public func error(
        _ message: @autoclosure () -> String,
        file: String = #file,
        line: UInt = #line
    ) {
        log(level: .error, message: message(), file: file, line: line)
    }

    @inline(__always)
    private func log(
        level: TTLogger.Level,
        message: String,
        file: String,
        line: UInt
    ) {
        TTLogger.shared.log(
            level: level,
            category: .preview,
            message: "[\(category)] \(message)",
            file: file,
            line: line
        )
    }
}
