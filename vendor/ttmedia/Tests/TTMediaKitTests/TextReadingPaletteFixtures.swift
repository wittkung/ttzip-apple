// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
@testable import TTMediaKit

enum TextReadingPaletteFixtures {
    enum Mode: CaseIterable, Equatable {
        case black
        case white
        case fluidTransparent
    }

    static func resolve(
        mode: Mode,
        isDarkAppearance: Bool
    ) -> TTTextReadingPalette {
        switch mode {
        case .black:
            return makeDarkPalette(isOpaque: true)
        case .white:
            return makeLightPalette(isOpaque: true)
        case .fluidTransparent:
            return isDarkAppearance
                ? makeDarkPalette(isOpaque: false)
                : makeLightPalette(isOpaque: false)
        }
    }

    private static func makeDarkPalette(
        isOpaque: Bool
    ) -> TTTextReadingPalette {
        let canvasNS = isOpaque
            ? NSColor(srgbRed: 0.067, green: 0.075, blue: 0.094, alpha: 1.0)
            : NSColor.clear
        let containerSwiftUI = isOpaque
            ? Color(nsColor: canvasNS)
            : Color.clear
        let gutterBG = isOpaque
            ? NSColor(srgbRed: 0.086, green: 0.098, blue: 0.125, alpha: 1.0)
            : NSColor.clear
        let gutterBorder = isOpaque
            ? NSColor(srgbRed: 0.165, green: 0.180, blue: 0.224, alpha: 1.0)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.12)

        return TTTextReadingPalette(
            drawsOpaqueBackground: isOpaque,
            containerBackgroundColor: containerSwiftUI,
            nsCanvasBackgroundColor: canvasNS,
            nsGutterBackgroundColor: gutterBG,
            nsGutterBorderColor: gutterBorder,
            nsGutterLabelColor: NSColor(srgbRed: 0.545, green: 0.580, blue: 0.620, alpha: 1.0),
            nsForegroundColor: NSColor(srgbRed: 0.925, green: 0.929, blue: 0.941, alpha: 1.0),
            nsInsertionPointColor: NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            nsSelectionBackgroundColor: NSColor(srgbRed: 0.149, green: 0.310, blue: 0.471, alpha: 0.88),
            nsSelectionTextColor: NSColor(srgbRed: 0.960, green: 0.969, blue: 0.980, alpha: 1.0),
            nsSearchMatchBackgroundColor: NSColor(srgbRed: 0.420, green: 0.325, blue: 0.078, alpha: 0.92),
            nsSearchMatchTextColor: NSColor(srgbRed: 1.0, green: 0.898, blue: 0.561, alpha: 1.0),
            syntaxKeywordColor: NSColor(srgbRed: 1.0, green: 0.482, blue: 0.447, alpha: 1.0),
            syntaxStringColor: NSColor(srgbRed: 0.647, green: 0.839, blue: 1.0, alpha: 1.0),
            syntaxCommentColor: NSColor(srgbRed: 0.545, green: 0.580, blue: 0.620, alpha: 1.0),
            syntaxNumberColor: NSColor(srgbRed: 0.475, green: 0.753, blue: 1.0, alpha: 1.0),
            syntaxTypeColor: NSColor(srgbRed: 1.0, green: 0.651, blue: 0.341, alpha: 1.0)
        )
    }

    private static func makeLightPalette(
        isOpaque: Bool
    ) -> TTTextReadingPalette {
        let canvasNS = isOpaque
            ? NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            : NSColor.clear
        let containerSwiftUI = isOpaque
            ? Color(nsColor: canvasNS)
            : Color.clear
        let gutterBG = isOpaque
            ? NSColor(srgbRed: 0.965, green: 0.969, blue: 0.976, alpha: 1.0)
            : NSColor.clear
        let gutterBorder = isOpaque
            ? NSColor(srgbRed: 0.847, green: 0.871, blue: 0.894, alpha: 1.0)
            : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.12)

        return TTTextReadingPalette(
            drawsOpaqueBackground: isOpaque,
            containerBackgroundColor: containerSwiftUI,
            nsCanvasBackgroundColor: canvasNS,
            nsGutterBackgroundColor: gutterBG,
            nsGutterBorderColor: gutterBorder,
            nsGutterLabelColor: NSColor(srgbRed: 0.341, green: 0.376, blue: 0.416, alpha: 1.0),
            nsForegroundColor: NSColor(srgbRed: 0.094, green: 0.098, blue: 0.110, alpha: 1.0),
            nsInsertionPointColor: NSColor(srgbRed: 0.094, green: 0.098, blue: 0.110, alpha: 1.0),
            nsSelectionBackgroundColor: NSColor(srgbRed: 0.706, green: 0.847, blue: 0.992, alpha: 0.90),
            nsSelectionTextColor: NSColor(srgbRed: 0.059, green: 0.067, blue: 0.078, alpha: 1.0),
            nsSearchMatchBackgroundColor: NSColor(srgbRed: 1.0, green: 0.949, blue: 0.659, alpha: 0.95),
            nsSearchMatchTextColor: NSColor(srgbRed: 0.094, green: 0.098, blue: 0.110, alpha: 1.0),
            syntaxKeywordColor: NSColor(srgbRed: 0.812, green: 0.133, blue: 0.180, alpha: 1.0),
            syntaxStringColor: NSColor(srgbRed: 0.039, green: 0.188, blue: 0.412, alpha: 1.0),
            syntaxCommentColor: NSColor(srgbRed: 0.067, green: 0.388, blue: 0.161, alpha: 1.0),
            syntaxNumberColor: NSColor(srgbRed: 0.020, green: 0.314, blue: 0.682, alpha: 1.0),
            syntaxTypeColor: NSColor(srgbRed: 0.584, green: 0.220, blue: 0.0, alpha: 1.0)
        )
    }

}
