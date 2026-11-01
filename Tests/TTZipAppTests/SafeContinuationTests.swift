// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import Foundation
import TTZipCore
@testable import TTZipApp

final class SafeContinuationTests: XCTestCase {

    func testSafeContinuationSingleResumeSuccess() async {
        let value: Int = await withCheckedContinuation { (raw: CheckedContinuation<Int, Never>) in
            let safe = SafeContinuation(raw)
            XCTAssertFalse(safe.isResumed)
            let won = safe.resume(returning: 42)
            XCTAssertTrue(won)
            XCTAssertTrue(safe.isResumed)
        }
        XCTAssertEqual(value, 42)
    }

    func testSafeContinuationConcurrentDoubleResumeSafety() async {
        let value: Int = await withCheckedContinuation { (raw: CheckedContinuation<Int, Never>) in
            let safe = SafeContinuation(raw)
            
            // Spawn 50 concurrent tasks racing to resume the same continuation
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "test.safe.continuation.race", attributes: .concurrent)
            
            for index in 0..<50 {
                group.enter()
                queue.async {
                    _ = safe.resume(returning: index)
                    group.leave()
                }
            }
            
            group.wait()
            XCTAssertTrue(safe.isResumed)
        }
        
        // Assert that exactly one value resolved and no fatalError / SIGTRAP occurred
        XCTAssertTrue((0..<50).contains(value))
    }

    func testWithSafeTimeoutContinuationFiresFallbackOnTimeout() async {
        let startTime = Date()
        let result = await withSafeTimeoutContinuation(
            seconds: 0.05,
            fallbackOnTimeout: "timed_out",
            operation: "TimeoutTest"
        ) { _ in
            // Intentionally don't call resume to trigger timeout
        }
        let elapsed = Date().timeIntervalSince(startTime)
        
        XCTAssertEqual(result, "timed_out")
        XCTAssertGreaterThanOrEqual(elapsed, 0.04)
    }

    func testWithSafeTimeoutContinuationReturnsFastOnNormalResume() async {
        let startTime = Date()
        let result = await withSafeTimeoutContinuation(
            seconds: 2.0,
            fallbackOnTimeout: "timed_out",
            operation: "FastResumeTest"
        ) { safe in
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                safe.resume(returning: "fast_completed")
            }
        }
        let elapsed = Date().timeIntervalSince(startTime)
        
        XCTAssertEqual(result, "fast_completed")
        XCTAssertLessThan(elapsed, 1.0)
    }
}
