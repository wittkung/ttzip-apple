// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import XCTest

@testable import TTZipCore

/// Proves that the prebuilt engine framework shipped with this package is
/// linked and that its Rust code runs. The engine is the only part of the
/// package that is not compiled from source here, so it is also the part that
/// breaks the most often.
final class EngineSmokeTests: XCTestCase {

    /// Adler-32 of "Wikipedia" is the reference vector of the checksum.
    func testEngineRunsAdler32() {
        let checksum = HardwareChecksumAdapter.adler32(for: Data("Wikipedia".utf8))
        XCTAssertEqual(checksum, 0x11E6_0398)
    }
}
