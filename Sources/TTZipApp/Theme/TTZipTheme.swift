// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine for macOS.

import SwiftUI
import AppKit

/// Unified theme design system for TTZip combining Zen minimalism and WSJ editorial typography.
public enum TTZipTheme {
    // MARK: - 1. Color Palette
    
    /// Archival Amber (#D97706) — Brand identity accent.
    public static let archiveAmber = Color(red: 0.85, green: 0.47, blue: 0.15)
    /// Cinnabar Red (#D15947) — Primary emphasis and stamp highlight.
    public static let cinnabarRed = Color(red: 0.82, green: 0.35, blue: 0.28)
    /// Bamboo Green — Dynamic adaptive accent.
    public static let bambooGreen = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(red: 143.0 / 255.0, green: 168.0 / 255.0, blue: 118.0 / 255.0, alpha: 1.0)
        } else {
            return NSColor(red: 120.0 / 255.0, green: 146.0 / 255.0, blue: 98.0 / 255.0, alpha: 1.0)
        }
    }))
    /// Kintsugi Gold — Dynamic adaptive secondary accent.
    public static let kintsugiGold = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(red: 230.0 / 255.0, green: 195.0 / 255.0, blue: 92.0 / 255.0, alpha: 1.0)
        } else {
            return NSColor(red: 212.0 / 255.0, green: 175.0 / 255.0, blue: 55.0 / 255.0, alpha: 1.0)
        }
    }))
    
    /// Paper White (#FBFBF9).
    public static let paperWhite = Color(red: 0.98, green: 0.98, blue: 0.97)
    /// Porcelain Gray (#F2F2EF).
    public static let porcelainGray = Color(red: 0.95, green: 0.95, blue: 0.93)
    /// Ink Charcoal (#1C1C1E).
    public static let inkCharcoal = Color(red: 0.11, green: 0.11, blue: 0.12)
    
    /// Primary Accent Color.
    public static var accentColor: Color {
        bambooGreen
    }
    
    /// Card and container background.
    public static var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.65)
    }
    
    /// Subtle fill.
    public static var subtleFill: Color {
        Color(nsColor: .labelColor).opacity(0.035)
    }
    
    /// Hairline border (0.5pt).
    public static var hairlineBorder: Color {
        Color(nsColor: .separatorColor).opacity(0.35)
    }
    
    public static var adaptiveBorder: Color {
        hairlineBorder
    }
    
    // Semantic status colors
    public static let statusSuccess = bambooGreen
    public static let statusWarning = kintsugiGold
    public static let statusDanger = cinnabarRed
    public static let statusInfo = Color(red: 0.30, green: 0.55, blue: 0.75)
    
    /// Returns a harmonious theme color for file extensions and content categories.
    public static func fileCategoryColor(for categoryOrExtension: String) -> Color {
        let key = categoryOrExtension.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch key {
        // 1. Images & Visual Media -> Kintsugi Warm Gold Spectrum
        case "jpg", "jpeg", "image", "图片":
            return Color(red: 0.88, green: 0.68, blue: 0.28) // Kintsugi Gold
        case "png":
            return Color(red: 0.94, green: 0.76, blue: 0.38) // Light Amber Gold
        case "webp", "gif", "svg", "ico":
            return Color(red: 0.82, green: 0.60, blue: 0.22) // Deep Ochre
        case "heic", "heif", "tiff", "tif", "raw", "cr2", "nef", "arw", "psd", "ai":
            return Color(red: 0.90, green: 0.70, blue: 0.32)
            
        // 2. Documents & Text -> Bamboo Green Spectrum
        case "pdf", "document", "文档", "文档/代码/字幕":
            return bambooGreen // Bamboo Emerald
        case "doc", "docx", "pages", "rtf", "txt":
            return Color(red: 0.35, green: 0.72, blue: 0.50) // Bamboo Mint
        case "xls", "xlsx", "csv", "numbers":
            return Color(red: 0.20, green: 0.65, blue: 0.40) // Forest Bamboo
        case "ppt", "pptx", "key":
            return Color(red: 0.42, green: 0.78, blue: 0.58) // Sage Green
        case "epub", "mobi", "azw3":
            return Color(red: 0.28, green: 0.75, blue: 0.60) // Jade
            
        // 3. Audio & Lossless -> Amethyst Purple / Lavender Spectrum
        case "mp3", "audio", "音频":
            return Color(red: 0.65, green: 0.45, blue: 0.92) // Amethyst Purple
        case "m4a", "aac":
            return Color(red: 0.72, green: 0.52, blue: 0.96) // Lavender
        case "wav", "flac", "alac", "aiff", "aifc":
            return Color(red: 0.55, green: 0.35, blue: 0.85) // Deep Amethyst
        case "ogg", "opus", "wma", "mid", "midi":
            return Color(red: 0.60, green: 0.40, blue: 0.88)
            
        // 4. Video & Motion -> Cinnabar Coral / Ruby Spectrum
        case "mp4", "video", "视频":
            return Color(red: 0.90, green: 0.38, blue: 0.38) // Cinnabar Red
        case "mov", "m4v":
            return Color(red: 0.95, green: 0.45, blue: 0.45) // Coral Crimson
        case "mkv", "avi", "webm", "wmv", "flv", "mts", "m2ts":
            return Color(red: 0.82, green: 0.30, blue: 0.30) // Deep Ruby
            
        // 5. Archives & Disk Packages -> Archive Amber Spectrum
        case "zip", "7z", "tar", "gz", "bz2", "xz", "zst", "rar", "dmg", "iso", "pkg", "deb", "rpm", "ttzip", "archive", "压缩包", "归档包":
            return Color(red: 0.96, green: 0.62, blue: 0.20) // Archive Amber
            
        // 6. Code & Scripts & Developer Assets -> Celadon Teal Spectrum
        case "sh", "zsh", "bash":
            return Color(red: 0.22, green: 0.72, blue: 0.80) // Celadon Teal
        case "md", "markdown":
            return Color(red: 0.28, green: 0.78, blue: 0.85) // Bright Cyan
        case "swift", "rs", "c", "cpp", "h", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "toml", "xml", "html", "css":
            return Color(red: 0.18, green: 0.68, blue: 0.75) // Deep Celadon
            
        // 7. Shortcuts, Links & System
        case "shortcut", "webloc", "url", "alias", "lnk":
            return Color(red: 0.38, green: 0.65, blue: 0.95) // Sky Blue
        case "app", "dylib", "so", "bin", "exe", "dll":
            return Color(red: 0.85, green: 0.45, blue: 0.70) // Rosewood Magenta
            
        default:
            let hash = abs(key.hashValue)
            let palette: [Color] = [
                bambooGreen,
                Color(red: 0.88, green: 0.68, blue: 0.28), // Kintsugi Gold
                Color(red: 0.22, green: 0.72, blue: 0.80), // Celadon Teal
                Color(red: 0.65, green: 0.45, blue: 0.92), // Amethyst Purple
                Color(red: 0.96, green: 0.62, blue: 0.20), // Archive Amber
                Color(red: 0.90, green: 0.38, blue: 0.38), // Cinnabar Red
                Color(red: 0.38, green: 0.65, blue: 0.95), // Sky Blue
                Color(red: 0.85, green: 0.45, blue: 0.70)  // Rosewood
            ]
            return palette[hash % palette.count]
        }
    }
    
    public static var bambooGradient: LinearGradient {
        LinearGradient(
            colors: [bambooGreen, bambooGreen.opacity(0.85)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    public static var primaryGradient: LinearGradient {
        bambooGradient
    }

    // MARK: - 2. Typography Ramp
    
    public enum Typography {
        public static let wsjHeadline = Font.system(size: 26, weight: .light, design: .serif)
        public static let wsjSubheadline = Font.system(size: 18, weight: .medium, design: .serif)
        public static let displayTitle = Font.system(size: 24, weight: .light, design: .default)
        public static let title1 = Font.system(size: 18, weight: .light, design: .default)
        public static let title2 = Font.system(size: 15, weight: .medium, design: .default)
        public static let sectionHeader = Font.system(size: 13, weight: .medium, design: .default)
        public static let body = Font.system(size: 13, weight: .regular, design: .default)
        public static let bodyMedium = Font.system(size: 13, weight: .medium, design: .default)
        public static let callout = Font.system(size: 12, weight: .regular, design: .default)
        public static let subheadline = Font.system(size: 11, weight: .regular, design: .default)
        public static let caption = Font.system(size: 10, weight: .regular, design: .default)
        public static let codeCaption = Font.system(size: 11, weight: .regular, design: .monospaced)
    }

    // MARK: - 3. Spacing Grid
    
    public enum Spacing {
        public static let xxs: CGFloat = 4
        public static let xs: CGFloat = 8
        public static let sm: CGFloat = 12
        public static let md: CGFloat = 16
        public static let lg: CGFloat = 20
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 36
    }

    // MARK: - 4. Corner Radius Ramp
    
    public enum Radius {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 10
        public static let lg: CGFloat = 14
        public static let xl: CGFloat = 18
    }
}

// MARK: - 5. Surface ViewModifier

public struct MUJIPaperCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var padding: CGFloat
    @Environment(\.colorScheme) var colorScheme
    
    public init(
        cornerRadius: CGFloat = TTZipTheme.Radius.lg,
        padding: CGFloat = TTZipTheme.Spacing.md
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
    }
    
    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(colorScheme == .dark ? Color.primary.opacity(0.04) : Color.white.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.08)
                                    : Color.black.opacity(0.05),
                                lineWidth: 0.5
                            )
                    )
            )
            .shadow(
                color: colorScheme == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.03),
                radius: colorScheme == .dark ? 4 : 6,
                x: 0,
                y: 2
            )
    }
}

public extension View {
    func ttzipLiquidGlass(cornerRadius: CGFloat = TTZipTheme.Radius.lg, padding: CGFloat = TTZipTheme.Spacing.md) -> some View {
        self.modifier(MUJIPaperCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
    
    func ttzipSurface(cornerRadius: CGFloat = TTZipTheme.Radius.lg, padding: CGFloat = TTZipTheme.Spacing.md) -> some View {
        self.modifier(MUJIPaperCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
    
    func ttzipCard(padding: CGFloat = TTZipTheme.Spacing.md, cornerRadius: CGFloat = TTZipTheme.Radius.lg) -> some View {
        self.modifier(MUJIPaperCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}
