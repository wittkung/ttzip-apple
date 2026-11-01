// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest
@testable import TTMediaKit

final class HexByteCountDemandCacheTests: XCTestCase {
    func testDemandCacheAndClearPreserveFormatterOutputAcrossBoundaryValues() {
        let expected = ByteCountFormatter()
        expected.allowedUnits = [.useAll]
        expected.countStyle = .file
        let values: [Int64] = [-1, 0, 1, 512, 1024, 1025, 1_048_576, 3_584_066, Int64.max]
        let cache = ByteCountFormatterCache.shared
        cache.clearCache()
        for value in values {
            let reference = expected.string(fromByteCount: max(0, value))
            XCTAssertEqual(cache.string(fromByteCount: value), reference)
            XCTAssertEqual(cache.string(fromByteCount: value), reference)
        }
        cache.clearCache()
        for value in values {
            XCTAssertEqual(cache.string(fromByteCount: value), expected.string(fromByteCount: max(0, value)))
        }
    }
}
