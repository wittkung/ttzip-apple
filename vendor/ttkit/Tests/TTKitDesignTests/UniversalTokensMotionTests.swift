// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
@testable import TTKitDesign

final class UniversalTokensMotionTests: XCTestCase {

    func testMotionSpringTokenParameters() {
        // Assert parameters strictly match tokens.json specification
        XCTAssertEqual(UniversalTokens.Motion.microResponse, 0.28, accuracy: 1e-5)
        XCTAssertEqual(UniversalTokens.Motion.microDampingFraction, 0.82, accuracy: 1e-5)

        XCTAssertEqual(UniversalTokens.Motion.layoutResponse, 0.42, accuracy: 1e-5)
        XCTAssertEqual(UniversalTokens.Motion.layoutDampingFraction, 0.88, accuracy: 1e-5)

        XCTAssertEqual(UniversalTokens.Motion.snapResponse, 0.35, accuracy: 1e-5)
        XCTAssertEqual(UniversalTokens.Motion.snapDampingFraction, 0.80, accuracy: 1e-5)

        XCTAssertEqual(UniversalTokens.Motion.sheetResponse, 0.50, accuracy: 1e-5)
        XCTAssertEqual(UniversalTokens.Motion.sheetDampingFraction, 0.84, accuracy: 1e-5)
    }

    func testSemanticAnimationExtensionsInstantiate() {
        // Verify SwiftUI Animation semantic extensions are non-nil and accessible
        let micro = Animation.ttMicro
        let layout = Animation.ttLayout
        let snap = Animation.ttSnap
        let sheet = Animation.ttSheet

        _ = micro
        _ = layout
        _ = snap
        _ = sheet

        // Verify TTKitTheme static forwarders
        _ = TTKitTheme.motionMicro
        _ = TTKitTheme.motionLayout
        _ = TTKitTheme.motionSnap
        _ = TTKitTheme.motionSheet
    }
}
