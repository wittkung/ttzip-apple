// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import XCTest
import CoreGraphics
@testable import TTKitCore

final class TTKitCoreTests: XCTestCase {

    // MARK: - Core Info

    func testCoreInfoVersion() {
        XCTAssertEqual(TTKitCoreInfo.version, "1.0.0")
    }

    // MARK: - CIELAB Color Space & Photometry

    func testCIELABBlackAndWhiteLStar() {
        let blackL = CIELAB.cielabLStar(red: 0.0, green: 0.0, blue: 0.0)
        XCTAssertEqual(blackL, 0.0, accuracy: 1e-6)

        let whiteL = CIELAB.cielabLStar(red: 1.0, green: 1.0, blue: 1.0)
        XCTAssertEqual(whiteL, 100.0, accuracy: 1e-4)
    }

    func testCIELABRelativeLuminance() {
        let blackY = CIELAB.relativeLuminance(red: 0.0, green: 0.0, blue: 0.0)
        XCTAssertEqual(blackY, 0.0, accuracy: 1e-6)

        let whiteY = CIELAB.relativeLuminance(red: 1.0, green: 1.0, blue: 1.0)
        XCTAssertEqual(whiteY, 1.0, accuracy: 1e-5)

        // Rec. 709 standard primary coefficients
        let redY = CIELAB.relativeLuminance(red: 1.0, green: 0.0, blue: 0.0)
        XCTAssertEqual(redY, 0.2126729, accuracy: 1e-5)

        let greenY = CIELAB.relativeLuminance(red: 0.0, green: 1.0, blue: 0.0)
        XCTAssertEqual(greenY, 0.7151522, accuracy: 1e-5)

        let blueY = CIELAB.relativeLuminance(red: 0.0, green: 0.0, blue: 1.0)
        XCTAssertEqual(blueY, 0.0721750, accuracy: 1e-5)
    }

    func testCIELABRoundtripReversibility() {
        let testColors: [(Double, Double, Double)] = [
            (0.12, 0.34, 0.56),
            (0.85, 0.65, 0.45),
            (0.50, 0.50, 0.50),
            (0.95, 0.10, 0.20),
            (0.05, 0.80, 0.30)
        ]

        for (r, g, b) in testColors {
            let lab = CIELAB.srgbToCIELAB(red: r, green: g, blue: b)
            let (rBack, gBack, bBack) = CIELAB.cielabToSRGB(lab: lab)

            XCTAssertEqual(rBack, r, accuracy: 1e-3, "Red roundtrip failed for (\(r), \(g), \(b))")
            XCTAssertEqual(gBack, g, accuracy: 1e-3, "Green roundtrip failed for (\(r), \(g), \(b))")
            XCTAssertEqual(bBack, b, accuracy: 1e-3, "Blue roundtrip failed for (\(r), \(g), \(b))")
        }
    }

    func testCIELABDeltaE76() {
        let colorA = CIELABColor(L: 50.0, a: 10.0, b: -20.0)
        let identicalDistance = CIELAB.deltaE76(color1: colorA, color2: colorA)
        XCTAssertEqual(identicalDistance, 0.0, accuracy: 1e-6)

        let blackLab = CIELABColor(L: 0.0, a: 0.0, b: 0.0)
        let whiteLab = CIELABColor(L: 100.0, a: 0.0, b: 0.0)
        let bwDistance = CIELAB.deltaE76(color1: blackLab, color2: whiteLab)
        XCTAssertEqual(bwDistance, 100.0, accuracy: 1e-5)
    }

    func testCIELABContrastRatio() {
        let blackLum = 0.0
        let whiteLum = 1.0

        let maxContrast = CIELAB.contrastRatio(lum1: blackLum, lum2: whiteLum)
        XCTAssertEqual(maxContrast, 21.0, accuracy: 1e-4)

        let minContrast = CIELAB.contrastRatio(lum1: 0.45, lum2: 0.45)
        XCTAssertEqual(minContrast, 1.0, accuracy: 1e-6)

        // Symmetry
        let contrastAB = CIELAB.contrastRatio(lum1: 0.2, lum2: 0.8)
        let contrastBA = CIELAB.contrastRatio(lum1: 0.8, lum2: 0.2)
        XCTAssertEqual(contrastAB, contrastBA, accuracy: 1e-6)
    }
}
