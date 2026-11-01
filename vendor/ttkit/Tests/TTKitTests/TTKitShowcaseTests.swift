// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import SwiftUI
@testable import TTKitCore
@testable import TTKitDesign
@testable import TTKitFluid
@testable import TTKit

final class TTKitShowcaseTests: XCTestCase {

    @MainActor
    func testShowcaseViewInstantiation() {
        let showcase = TTKitShowcaseView()
        _ = showcase
    }

    @MainActor
    func testMineralOptionColorCalibration() {
        for mineral in TTKitShowcaseView.MineralOption.allCases {
            XCTAssertFalse(mineral.rawValue.isEmpty)
            _ = mineral.color
        }
    }

    @MainActor
    func testThreeTierStackingDepthProgression() {
        // Base plate: Tier 1
        let baseView = Text("Tier 1 Base")
            .ttFloatingGlassPlate(tier: .base, cornerRadius: 20)
        _ = baseView

        // Primary plates: Tier 2
        let primaryView = Text("Tier 2 Primary")
            .ttPrimaryGlassPlate(cornerRadius: 16)
        _ = primaryView

        // Overlay plate: Tier 3
        let overlayView = Text("Tier 3 Overlay")
            .ttOverlayGlassPlate(cornerRadius: 18)
        _ = overlayView
    }
}
