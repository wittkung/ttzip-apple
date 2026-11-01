// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Color representation in the CIE 1976 L*a*b* perceptual color space.
public struct CIELABColor: Sendable, Equatable {
    /// Perceptual lightness: 0.0 (black) to 100.0 (diffuse white).
    public let L: Double
    /// Green-red opponent chromatic dimension: negative for green, positive for red.
    public let a: Double
    /// Blue-yellow opponent chromatic dimension: negative for blue, positive for yellow.
    public let b: Double

    public init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }
}

/// Colorimetric calculations conforming to CIE 1976 (L*a*b*) and Rec. 709 / sRGB specifications.
/// Reference illuminant: standard CIE D65 (Xn = 0.95047, Yn = 1.00000, Zn = 1.08883).
public enum CIELAB: Sendable {

    // MARK: - Reference White Point (D65)

    private static let Xn: Double = 0.95047
    private static let Yn: Double = 1.00000
    private static let Zn: Double = 1.08883

    private static let delta: Double = 6.0 / 29.0
    private static let deltaSq: Double = (6.0 / 29.0) * (6.0 / 29.0)
    private static let deltaCube: Double = (6.0 / 29.0) * (6.0 / 29.0) * (6.0 / 29.0)

    // MARK: - Perceptual Lightness L*

    /// Computes genuine CIE 1976 L* (perceptual lightness) from non-linear sRGB components in [0.0, 1.0].
    public static func cielabLStar(red: Double, green: Double, blue: Double) -> Double {
        let y = relativeLuminance(red: red, green: green, blue: blue)
        let fy: Double
        if y > deltaCube {
            fy = cbrt(y)
        } else {
            fy = (y / (3.0 * deltaSq)) + (4.0 / 29.0)
        }
        return max(0.0, min(100.0, 116.0 * fy - 16.0))
    }

    // MARK: - Relative Luminance (Rec. 709 / sRGB D65)

    /// Computes relative luminance Y in [0.0, 1.0] from non-linear sRGB components in [0.0, 1.0].
    public static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        let rLin = linearize(red)
        let gLin = linearize(green)
        let bLin = linearize(blue)
        return 0.2126729 * rLin + 0.7151522 * gLin + 0.0721750 * bLin
    }

    // MARK: - sRGB <-> CIELAB Conversion

    /// Converts non-linear sRGB components in [0.0, 1.0] to CIELAB coordinates.
    public static func srgbToCIELAB(red: Double, green: Double, blue: Double) -> CIELABColor {
        let rLin = linearize(red)
        let gLin = linearize(green)
        let bLin = linearize(blue)

        // Forward matrix transform: sRGB -> CIE XYZ (D65)
        let x = 0.4124564 * rLin + 0.3575761 * gLin + 0.1804375 * bLin
        let y = 0.2126729 * rLin + 0.7151522 * gLin + 0.0721750 * bLin
        let z = 0.0193339 * rLin + 0.1191920 * gLin + 0.9503041 * bLin

        let fx = fxyz(x / Xn)
        let fy = fxyz(y / Yn)
        let fz = fxyz(z / Zn)

        let L = max(0.0, min(100.0, 116.0 * fy - 16.0))
        let a = 500.0 * (fx - fy)
        let b = 200.0 * (fy - fz)

        return CIELABColor(L: L, a: a, b: b)
    }

    /// Converts CIELAB coordinates back to non-linear sRGB components in [0.0, 1.0].
    public static func cielabToSRGB(lab: CIELABColor) -> (red: Double, green: Double, blue: Double) {
        let fy = (lab.L + 16.0) / 116.0
        let fx = (lab.a / 500.0) + fy
        let fz = fy - (lab.b / 200.0)

        let xr = fxyzInv(fx)
        let yr = fxyzInv(fy)
        let zr = fxyzInv(fz)

        let x = xr * Xn
        let y = yr * Yn
        let z = zr * Zn

        // Reverse matrix transform: CIE XYZ -> sRGB (linear)
        let rLin =  3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let gLin = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let bLin =  0.0556434 * x - 0.2040259 * y + 1.0572252 * z

        let r = delinearize(rLin)
        let g = delinearize(gLin)
        let b = delinearize(bLin)

        return (r, g, b)
    }

    // MARK: - Color Difference & Contrast

    /// Computes CIE 1976 color difference Delta E*76.
    public static func deltaE76(color1: CIELABColor, color2: CIELABColor) -> Double {
        let dL = color1.L - color2.L
        let da = color1.a - color2.a
        let db = color1.b - color2.b
        return sqrt(dL * dL + da * da + db * db)
    }

    /// Computes WCAG 2.1 contrast ratio between two relative luminance values.
    /// Returns value in [1.0, 21.0].
    public static func contrastRatio(lum1: Double, lum2: Double) -> Double {
        let lighter = max(lum1, lum2)
        let darker = min(lum1, lum2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    // MARK: - Internal Math Helpers

    private static func linearize(_ c: Double) -> Double {
        let clamped = max(0.0, min(1.0, c))
        if clamped <= 0.04045 {
            return clamped / 12.92
        } else {
            return pow((clamped + 0.055) / 1.055, 2.4)
        }
    }

    private static func delinearize(_ c: Double) -> Double {
        let clamped = max(0.0, min(1.0, c))
        if clamped <= 0.0031308 {
            return clamped * 12.92
        } else {
            return 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        }
    }

    private static func fxyz(_ t: Double) -> Double {
        if t > deltaCube {
            return cbrt(t)
        } else {
            return (t / (3.0 * deltaSq)) + (4.0 / 29.0)
        }
    }

    private static func fxyzInv(_ t: Double) -> Double {
        if t > delta {
            return t * t * t
        } else {
            return 3.0 * deltaSq * (t - 4.0 / 29.0)
        }
    }
}
