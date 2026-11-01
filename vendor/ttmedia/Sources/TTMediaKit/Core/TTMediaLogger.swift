// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import os

/// High-throughput structured diagnostic telemetry logger for TTMediaKit utilizing Apple Unified Logging.
public struct TTMediaLogger: Sendable {
    public static let subsystem = "com.metastudyline.ttmedia"

    public static let shared = TTMediaLogger(category: "Core")
    public static let detector = TTMediaLogger(category: "Detector")
    public static let matrix = TTMediaLogger(category: "Matrix")
    public static let security = TTMediaLogger(category: "Security")
    public static let content = TTMediaLogger(category: "ContentReader")

    public let category: String
    private let logger: Logger

    public init(category: String, subsystem: String = TTMediaLogger.subsystem) {
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    @inline(__always)
    public func debug(
        _ message: @autoclosure () -> String,
        file: String = #file,
        line: UInt = #line
    ) {
        let msg = message()
        logger.debug("[\(self.category)] \(msg, privacy: .public)")
    }

    @inline(__always)
    public func info(
        _ message: @autoclosure () -> String,
        file: String = #file,
        line: UInt = #line
    ) {
        let msg = message()
        logger.info("[\(self.category)] \(msg, privacy: .public)")
    }

    @inline(__always)
    public func warning(
        _ message: @autoclosure () -> String,
        file: String = #file,
        line: UInt = #line
    ) {
        let msg = message()
        logger.warning("[\(self.category)] \(msg, privacy: .public)")
    }

    @inline(__always)
    public func error(
        _ message: @autoclosure () -> String,
        file: String = #file,
        line: UInt = #line
    ) {
        let msg = message()
        logger.error("[\(self.category)] \(msg, privacy: .public)")
    }

    @inline(__always)
    public func fault(
        _ message: @autoclosure () -> String,
        file: String = #file,
        line: UInt = #line
    ) {
        let msg = message()
        logger.fault("[\(self.category)] \(msg, privacy: .public)")
    }
}

// MARK: - Compatibility Typealiases

public typealias PreviewKitLogger = TTMediaLogger
