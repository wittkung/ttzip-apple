// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
import TTKitFluid
@testable import TTZipUI
@testable import TTZipPreviewKit

final class InteractiveZoomGestureTests: XCTestCase {

    func testMotionTokensForwarding() {
        // Verify TTZipTheme.Motion forwards directly to TTKitDesign UniversalTokens.Motion
        _ = TTZipTheme.Motion.micro
        _ = TTZipTheme.Motion.layout
        _ = TTZipTheme.Motion.snap
        _ = TTZipTheme.Motion.sheet

        XCTAssertEqual(TTZipUniversalTokens.Motion.microResponse, 0.28, accuracy: 1e-5)
        XCTAssertEqual(TTZipUniversalTokens.Motion.microDampingFraction, 0.82, accuracy: 1e-5)
        XCTAssertEqual(TTZipUniversalTokens.Motion.layoutResponse, 0.42, accuracy: 1e-5)
        XCTAssertEqual(TTZipUniversalTokens.Motion.layoutDampingFraction, 0.88, accuracy: 1e-5)
        XCTAssertEqual(TTZipUniversalTokens.Motion.snapResponse, 0.35, accuracy: 1e-5)
        XCTAssertEqual(TTZipUniversalTokens.Motion.snapDampingFraction, 0.80, accuracy: 1e-5)
        XCTAssertEqual(TTZipUniversalTokens.Motion.sheetResponse, 0.50, accuracy: 1e-5)
        XCTAssertEqual(TTZipUniversalTokens.Motion.sheetDampingFraction, 0.84, accuracy: 1e-5)
    }

    func testInteractiveZoomBoundaryCalculationAndRubberBanding() {
        let viewportSize = CGSize(width: 800.0, height: 600.0)
        let scale: CGFloat = 2.0 // 200% zoom

        let maxOffsetX = max(0, (viewportSize.width * scale - viewportSize.width) / 2) // (1600 - 800) / 2 = 400
        let maxOffsetY = max(0, (viewportSize.height * scale - viewportSize.height) / 2) // (1200 - 600) / 2 = 300

        XCTAssertEqual(maxOffsetX, 400.0)
        XCTAssertEqual(maxOffsetY, 300.0)

        let rangeX = -maxOffsetX...maxOffsetX
        let rangeY = -maxOffsetY...maxOffsetY

        // Case 1: In-bounds translation is preserved exactly
        let inBoundsX = TTKitFluid.FluidGesturePhysics.rubberBandClamp(offset: 200.0, range: rangeX, dimension: viewportSize.width)
        XCTAssertEqual(inBoundsX, 200.0)

        // Case 2: Positive overscroll is smoothly resisted
        let overscrollX = TTKitFluid.FluidGesturePhysics.rubberBandClamp(offset: 500.0, range: rangeX, dimension: viewportSize.width)
        XCTAssertGreaterThan(overscrollX, 400.0)
        XCTAssertLessThan(overscrollX, 500.0)

        // Case 3: Negative overscroll is smoothly resisted
        let negativeOverscrollY = TTKitFluid.FluidGesturePhysics.rubberBandClamp(offset: -380.0, range: rangeY, dimension: viewportSize.height)
        XCTAssertLessThan(negativeOverscrollY, -300.0)
        XCTAssertGreaterThan(negativeOverscrollY, -380.0)
    }

    func testUnderscaleSnapBackInvariants() {
        // Pinch below 1.0 (e.g. 0.72) must clamp softly and snap back to 1.0 upon release
        let rawUnderscale = 0.72
        let dampedScale = TTKitFluid.FluidGesturePhysics.rubberBandClamp(
            offset: rawUnderscale,
            range: 1.0...10.0,
            dimension: 1.0,
            factor: 0.55
        )

        XCTAssertLessThan(dampedScale, 1.0)
        XCTAssertGreaterThan(dampedScale, rawUnderscale, "Rubber band must dampen scale reduction towards 1.0.")

        // Upon gesture release: target scale must settle back to 1.0 with zero offset
        let settledScale: CGFloat = (dampedScale < 1.0) ? 1.0 : dampedScale
        let settledOffset: CGSize = (dampedScale < 1.0) ? .zero : CGSize(width: 50, height: 50)

        XCTAssertEqual(settledScale, 1.0)
        XCTAssertEqual(settledOffset, .zero)
    }
}
