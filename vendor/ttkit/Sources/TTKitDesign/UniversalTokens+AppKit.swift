// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

public extension UniversalTokens {
    /// Computes the CIE 1976 L* (perceptual lightness) from non-linear sRGB components in [0.0, 1.0].
    /// Standard CIE D65 reference white point (Yn = 1.00000).
    static func cielabLStar(red: Double, green: Double, blue: Double) -> Double {
        let linearize = { (c: Double) -> Double in
            if c <= 0.04045 {
                return c / 12.92
            } else {
                return pow((c + 0.055) / 1.055, 2.4)
            }
        }

        let rLin = linearize(max(0.0, min(1.0, red)))
        let gLin = linearize(max(0.0, min(1.0, green)))
        let bLin = linearize(max(0.0, min(1.0, blue)))

        // Rec. 709 / sRGB D65 luminance coefficients
        let y = 0.2126729 * rLin + 0.7151522 * gLin + 0.0721750 * bLin

        let epsilon = pow(24.0 / 116.0, 3.0)
        let fy: Double
        if y > epsilon {
            fy = cbrt(y)
        } else {
            fy = (841.0 / 108.0) * y + (16.0 / 116.0)
        }

        return 116.0 * fy - 16.0
    }
}

public extension UniversalTokens.Canvas {
    static let emitterNSColor: NSColor = NSColor(name: "canvas.emitter.base", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    })
}

public extension UniversalTokens.Fluid {
    static let bodyCoreNSColor: NSColor = NSColor(name: "fluid.body.core", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 250.0 / 255.0, green: 250.0 / 255.0, blue: 252.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 10.0 / 255.0, green: 10.0 / 255.0, blue: 12.0 / 255.0, alpha: 1.0)
    })

    static let sheenDispersionNSColor: NSColor = NSColor(name: "fluid.sheen.dispersion", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(displayP3Red: 0.1490, green: 0.5100, blue: 0.9800, alpha: 0.10)
            : NSColor(displayP3Red: 0.0235, green: 0.1333, blue: 0.2667, alpha: 0.06)
    })
}

public extension UniversalTokens.Border {
    static let specularHairlineNSColor: NSColor = NSColor(name: "plate.border.specular", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.14)
            : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.08)
    })

    static let kintsugiGoldNSColor: NSColor = NSColor(name: "plate.border.kintsugi", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(displayP3Red: 229.0 / 255.0, green: 193.0 / 255.0, blue: 88.0 / 255.0, alpha: 0.60)
            : NSColor(displayP3Red: 197.0 / 255.0, green: 160.0 / 255.0, blue: 89.0 / 255.0, alpha: 0.45)
    })
}

public extension UniversalTokens.Action {
    static let anchorNSColor: NSColor = NSColor(name: "action.anchor.singular", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 10.0 / 255.0, green: 132.0 / 255.0, blue: 255.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 0.0 / 255.0, green: 113.0 / 255.0, blue: 227.0 / 255.0, alpha: 1.0)
    })
}

public extension UniversalTokens.Text {
    static let primaryNSColor: NSColor = NSColor(name: "text.primary.photonic", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            : NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
    })

    static let invertedNSColor: NSColor = NSColor(name: "text.inverted.photonic", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    })
}

public extension UniversalTokens.Mineral {
    static let goldNSColor: NSColor = NSColor(name: "mineral.gold.asset", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 222.0 / 255.0, green: 184.0 / 255.0, blue: 75.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 191.0 / 255.0, green: 153.0 / 255.0, blue: 54.0 / 255.0, alpha: 1.0)
    })

    static let goldEditorialNSColor: NSColor = NSColor(name: "mineral.gold.editorial", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 230.0 / 255.0, green: 195.0 / 255.0, blue: 92.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 140.0 / 255.0, green: 109.0 / 255.0, blue: 35.0 / 255.0, alpha: 1.0)
    })

    static let bambooNSColor: NSColor = NSColor(name: "mineral.bamboo.system", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 145.0 / 255.0, green: 197.0 / 255.0, blue: 150.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 115.0 / 255.0, green: 169.0 / 255.0, blue: 121.0 / 255.0, alpha: 1.0)
    })

    static let amberNSColor: NSColor = NSColor(name: "mineral.amber.archive", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 255.0 / 255.0, green: 167.0 / 255.0, blue: 39.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 231.0 / 255.0, green: 137.0 / 255.0, blue: 21.0 / 255.0, alpha: 1.0)
    })

    static let cinnabarNSColor: NSColor = NSColor(name: "mineral.cinnabar.danger", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 255.0 / 255.0, green: 158.0 / 255.0, blue: 130.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 254.0 / 255.0, green: 113.0 / 255.0, blue: 95.0 / 255.0, alpha: 1.0)
    })

    static let amethystNSColor: NSColor = NSColor(name: "mineral.amethyst.audio", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 172.0 / 255.0, green: 180.0 / 255.0, blue: 255.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 148.0 / 255.0, green: 149.0 / 255.0, blue: 245.0 / 255.0, alpha: 1.0)
    })

    static let celestialPurpleNSColor: NSColor = NSColor(name: "mineral.celestialPurple.spiritual", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 167.0 / 255.0, green: 139.0 / 255.0, blue: 250.0 / 255.0, alpha: 1.0)
            : NSColor(srgbRed: 109.0 / 255.0, green: 40.0 / 255.0, blue: 217.0 / 255.0, alpha: 1.0)
    })
}
#endif
