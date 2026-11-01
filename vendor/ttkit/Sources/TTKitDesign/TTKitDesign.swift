// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
@_exported import TTKitCore

/// Unified palette and static convenience references for TTKit design tokens.
public enum TTKitTheme {
    /// Kintsugi Gold (金缮金: asset/visual media)
    public static var kintsugiGold: Color {
        UniversalTokens.Mineral.gold
    }

    /// Kintsugi Gold Editorial / High-Contrast Rule Lines (金缮金高对比界标线)
    public static var kintsugiGoldEditorial: Color {
        UniversalTokens.Mineral.goldEditorial
    }

    /// Bamboo Green (竹青色: documents/system accent)
    public static var bambooGreen: Color {
        UniversalTokens.Mineral.bamboo
    }

    /// Archival Amber (琥珀色: archives/packages)
    public static var archivalAmber: Color {
        UniversalTokens.Mineral.amber
    }

    /// Cinnabar Red (朱砂红: destruction/alerts)
    public static var cinnabarRed: Color {
        UniversalTokens.Mineral.cinnabar
    }

    /// Acoustic Indigo & Amethyst (声学黛青 / 紫水晶: audio/flow)
    public static var acousticIndigo: Color {
        UniversalTokens.Mineral.acousticIndigo
    }

    /// Celestial Purple (苍穹紫 / 群青紫: spiritual/tarot media)
    public static var celestialPurple: Color {
        UniversalTokens.Mineral.celestialPurple
    }

    /// Paper White (和纸白: #FBFBF9)
    public static var paperWhite: Color {
        UniversalTokens.Mineral.paperWhite
    }

    /// Porcelain Gray (瓷灰: #F2F2EF)
    public static var porcelainGray: Color {
        UniversalTokens.Mineral.porcelainGray
    }

    /// Obsidian Black (曜石纯黑)
    public static var obsidianBlack: Color {
        UniversalTokens.Mineral.obsidianBlack
    }

    /// Ink Charcoal (水墨炭黑: #1C1C1E)
    public static var inkCharcoal: Color {
        UniversalTokens.Mineral.inkCharcoal
    }

    /// Standard hairline border (0.5pt specular Fresnel highlight).
    public static var hairlineBorder: Color {
        UniversalTokens.Border.specularHairline
    }

    // MARK: - Motion Dynamics

    /// Micro-interactions: buttons, toggles, icon feedback (0.28s, 0.82)
    public static var motionMicro: Animation {
        UniversalTokens.Motion.micro
    }

    /// Structural layout transitions: columns, sidebars, panes (0.42s, 0.88)
    public static var motionLayout: Animation {
        UniversalTokens.Motion.layout
    }

    /// Snappy popovers, dialogs, Omnibar results (0.35s, 0.80)
    public static var motionSnap: Animation {
        UniversalTokens.Motion.snap
    }

    /// Large modal sheets and full-canvas transitions (0.50s, 0.84)
    public static var motionSheet: Animation {
        UniversalTokens.Motion.sheet
    }
}
