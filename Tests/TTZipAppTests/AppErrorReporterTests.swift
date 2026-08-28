// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

@MainActor
final class AppErrorReporterTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        AppErrorReporter.shared.dismiss()
    }

    override func tearDown() async throws {
        AppErrorReporter.shared.dismiss()
        try await super.tearDown()
    }

    func testErrorReportingAndDismissalLifecycle() async throws {
        let reporter = AppErrorReporter.shared
        XCTAssertNil(reporter.activeError)
        XCTAssertFalse(reporter.isPresentingError)
        
        reporter.reportError(
            title: "Header Parse Failure",
            message: "The 7z header CRC checksum is invalid.",
            code: "ERR_CORRUPTED_HEADER",
            details: "Offset 0x0004: expected 0xDEADBEEF, got 0x00000000",
            recoveryTitle: "Attempt Recovery",
            onRecovery: {
                // Recovery closure
            }
        )
        
        XCTAssertTrue(reporter.isPresentingError)
        XCTAssertNotNil(reporter.activeError)
        XCTAssertEqual(reporter.activeError?.title, "Header Parse Failure")
        XCTAssertEqual(reporter.activeError?.diagnosticCode, "ERR_CORRUPTED_HEADER")
        XCTAssertEqual(reporter.activeError?.recoveryActionTitle, "Attempt Recovery")
        XCTAssertNotNil(reporter.activeError?.recoveryHandler)
        
        reporter.dismiss()
        XCTAssertFalse(reporter.isPresentingError)
        XCTAssertNil(reporter.activeError)
    }

    func testSwiftErrorMapping() async throws {
        let reporter = AppErrorReporter.shared
        let customError = NSError(
            domain: "TTZipTestDomain",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "File not found on disk"]
        )
        
        reporter.reportError(customError, contextTitle: "Test Context")
        XCTAssertTrue(reporter.isPresentingError)
        XCTAssertEqual(reporter.activeError?.title, "Test Context")
        XCTAssertEqual(reporter.activeError?.message, "File not found on disk")
        XCTAssertTrue(reporter.activeError?.diagnosticCode.contains("NSError") ?? false)
    }
}
