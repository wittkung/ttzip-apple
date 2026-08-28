// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import XCTest
import SwiftUI
import TTZipUI
import TTZipPreviewKit
import TTZipBenchmarkKit
@testable import TTZipApp

@MainActor
final class DesignSystemLayoutAlignmentTests: XCTestCase {
    
    func test_sidebar_workspace_inspector_golden_rule_aligned_at_y90() {
        // Design system baseline invariants
        let topInset: CGFloat = TTZipTheme.Layout.topBarOffset
        let headerHeight: CGFloat = TTZipTheme.Layout.headerBarHeight
        let goldenLineY: CGFloat = topInset + headerHeight
        
        XCTAssertEqual(topInset, 38.0, "Top safety offset must be exactly 38.0pt")
        XCTAssertEqual(headerHeight, 52.0, "Header bar height must be exactly 52.0pt")
        XCTAssertEqual(goldenLineY, 90.0, "Golden Rule Line across 3 columns must align precisely at Y = 90pt")
    }
    
    func test_zen_gutter_and_scaffold_spacing_tokens() {
        XCTAssertEqual(ResizableDividerHandle.gutterWidth, 8.0, "Zen Gutter width must be strictly 8.0pt")
        XCTAssertEqual(TTZipTheme.Spacing.xs, 8.0, "Inset card leading spacing must be 8.0pt")
        XCTAssertEqual(TTZipTheme.Layout.kintsugiGoldLineHeight, 1.5, "Kintsugi gold line height must be 1.5pt")
    }
    
    func test_52pt_header_bar_typography_tokens() {
        guard let aquaAppearance = NSAppearance(named: .aqua),
              let darkAquaAppearance = NSAppearance(named: .darkAqua) else {
            XCTFail("Failed to load standard system appearances")
            return
        }
        
        // 1. Kintsugi Gold Token (#D4AF37 = 212, 175, 55 in Aqua; 230, 195, 92 in DarkAqua)
        let goldNSColor = NSColor(TTZipTheme.kintsugiGold)
        var goldAqua = goldNSColor
        var goldDark = goldNSColor
        aquaAppearance.performAsCurrentDrawingAppearance {
            goldAqua = goldNSColor.usingColorSpace(.sRGB) ?? goldNSColor
        }
        darkAquaAppearance.performAsCurrentDrawingAppearance {
            goldDark = goldNSColor.usingColorSpace(.sRGB) ?? goldNSColor
        }
        
        XCTAssertEqual(goldAqua.redComponent, 212.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Aqua Red channel must be #D4 (212/255)")
        XCTAssertEqual(goldAqua.greenComponent, 175.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Aqua Green channel must be #AF (175/255)")
        XCTAssertEqual(goldAqua.blueComponent, 55.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Aqua Blue channel must be #37 (55/255)")
        
        XCTAssertEqual(goldDark.redComponent, 230.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Dark Red channel must be 230/255")
        XCTAssertEqual(goldDark.greenComponent, 195.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Dark Green channel must be 195/255")
        XCTAssertEqual(goldDark.blueComponent, 92.0 / 255.0, accuracy: 0.01, "Kintsugi Gold Dark Blue channel must be 92/255")
        
        // 2. Bamboo Green Token (120, 146, 98 in Aqua; 143, 168, 118 in DarkAqua)
        let bambooNSColor = NSColor(TTZipTheme.bambooGreen)
        var bambooAqua = bambooNSColor
        var bambooDark = bambooNSColor
        aquaAppearance.performAsCurrentDrawingAppearance {
            bambooAqua = bambooNSColor.usingColorSpace(.sRGB) ?? bambooNSColor
        }
        darkAquaAppearance.performAsCurrentDrawingAppearance {
            bambooDark = bambooNSColor.usingColorSpace(.sRGB) ?? bambooNSColor
        }
        
        XCTAssertEqual(bambooAqua.redComponent, 120.0 / 255.0, accuracy: 0.01, "Bamboo Green Aqua Red channel must be 120/255")
        XCTAssertEqual(bambooAqua.greenComponent, 146.0 / 255.0, accuracy: 0.01, "Bamboo Green Aqua Green channel must be 146/255")
        XCTAssertEqual(bambooAqua.blueComponent, 98.0 / 255.0, accuracy: 0.01, "Bamboo Green Aqua Blue channel must be 98/255")
        
        XCTAssertEqual(bambooDark.redComponent, 143.0 / 255.0, accuracy: 0.01, "Bamboo Green Dark Red channel must be 143/255")
        XCTAssertEqual(bambooDark.greenComponent, 168.0 / 255.0, accuracy: 0.01, "Bamboo Green Dark Green channel must be 168/255")
        XCTAssertEqual(bambooDark.blueComponent, 118.0 / 255.0, accuracy: 0.01, "Bamboo Green Dark Blue channel must be 118/255")
        
        // 3. Cinnabar Red (#D15947 / 0.82, 0.35, 0.28)
        let redNSColor = NSColor(TTZipTheme.cinnabarRed).usingColorSpace(.sRGB) ?? NSColor(TTZipTheme.cinnabarRed)
        XCTAssertEqual(redNSColor.redComponent, 0.82, accuracy: 0.02, "Cinnabar Red Red channel")
        XCTAssertEqual(redNSColor.greenComponent, 0.35, accuracy: 0.02, "Cinnabar Red Green channel")
        XCTAssertEqual(redNSColor.blueComponent, 0.28, accuracy: 0.02, "Cinnabar Red Blue channel")
    }
}
