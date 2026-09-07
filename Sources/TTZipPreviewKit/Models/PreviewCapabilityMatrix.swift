// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Foundation

/// Discrete capability bitmask representing what preview presentations a format supports.
public struct PreviewCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    /// Visual rich rendering (e.g. WKWebView HTML/SVG, Markdown canvas, ImageIO, PDF viewport).
    public static let visualRender = PreviewCapabilities(rawValue: 1 << 0)
    
    /// Syntax-highlighted text editor or source code inspector.
    public static let sourceCode = PreviewCapabilities(rawValue: 1 << 1)
    
    /// Structured table/key-value/tree inspection (e.g. CSV/TSV table, JSON/XML outline).
    public static let structuredData = PreviewCapabilities(rawValue: 1 << 2)
    
    /// Raw byte-level inspection with ASCII decoding table.
    public static let hexBinary = PreviewCapabilities(rawValue: 1 << 3)
    
    /// Hardware-accelerated continuous media stream playback (AVFoundation / libmpv).
    public static let mediaPlayback = PreviewCapabilities(rawValue: 1 << 4)
    
    /// Paginated multi-page document navigation (PDFKit, EPUB reader, Docx viewer).
    public static let documentPagination = PreviewCapabilities(rawValue: 1 << 5)
    
    /// Virtual archive filesystem container navigation.
    public static let archiveBrowse = PreviewCapabilities(rawValue: 1 << 6)
}

/// Preferred primary presentation mode when opening a file for the first time.
public enum PreviewPrimaryMode: String, Sendable, CaseIterable {
    case visualRender
    case sourceCode
    case structuredData
    case hexBinary
    case mediaPlayback
    case documentPagination
    case archiveBrowse
}

/// Architectural format descriptor encapsulating capabilities, preferred primary mode, and UX metadata.
public struct PreviewFormatDescriptor: Sendable, Hashable {
    public let extensionName: String
    public let displayName: String
    public let capabilities: PreviewCapabilities
    public let primaryMode: PreviewPrimaryMode
    public let iconName: String
    public let mimeType: String
    public let isEditableSource: Bool
    
    public init(
        extensionName: String,
        displayName: String,
        capabilities: PreviewCapabilities,
        primaryMode: PreviewPrimaryMode,
        iconName: String,
        mimeType: String,
        isEditableSource: Bool = false
    ) {
        self.extensionName = extensionName.lowercased()
        self.displayName = displayName
        self.capabilities = capabilities
        self.primaryMode = primaryMode
        self.iconName = iconName
        self.mimeType = mimeType
        self.isEditableSource = isEditableSource
    }
}

/// High-performance deterministic capability registry and format routing matrix.
public enum PreviewCapabilityMatrix {

    // MARK: - Registry Storage

    private static let descriptors: [String: PreviewFormatDescriptor] = {
        var map: [String: PreviewFormatDescriptor] = [:]
        
        func register(
            _ exts: [String],
            name: String,
            capabilities: PreviewCapabilities,
            primary: PreviewPrimaryMode,
            icon: String,
            mime: String,
            editable: Bool = false
        ) {
            for ext in exts {
                let clean = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                map[clean] = PreviewFormatDescriptor(
                    extensionName: clean,
                    displayName: name,
                    capabilities: capabilities,
                    primaryMode: primary,
                    iconName: icon,
                    mimeType: mime,
                    isEditableSource: editable
                )
            }
        }
        
        // 1. Web & Interactive Renderable Documents (HTML, HTM, XHTML, MHTML, SVG)
        register(
            ["html", "htm"],
            name: "HTML Web Document",
            capabilities: [.visualRender, .sourceCode],
            primary: .visualRender,
            icon: "globe",
            mime: "text/html",
            editable: true
        )
        register(
            ["xhtml"],
            name: "XHTML Document",
            capabilities: [.visualRender, .sourceCode],
            primary: .visualRender,
            icon: "globe",
            mime: "application/xhtml+xml",
            editable: true
        )
        register(
            ["mhtml"],
            name: "MHTML Web Archive",
            capabilities: [.visualRender, .sourceCode],
            primary: .visualRender,
            icon: "globe",
            mime: "multipart/related",
            editable: true
        )
        register(
            ["svg"],
            name: "SVG Vector Graphic",
            capabilities: [.visualRender, .sourceCode],
            primary: .visualRender,
            icon: "photo.fill",
            mime: "image/svg+xml",
            editable: true
        )
        register(
            ["svgz"],
            name: "Compressed SVG Vector Graphic",
            capabilities: [.visualRender, .sourceCode],
            primary: .visualRender,
            icon: "photo.fill",
            mime: "image/svg+xml",
            editable: false
        )
        
        // 2. Markdown Documents
        register(
            ["md", "markdown", "mdown", "mkd", "mkdn", "mdtxt", "mdtext"],
            name: "Markdown Document",
            capabilities: [.visualRender, .sourceCode],
            primary: .visualRender,
            icon: "doc.text.fill",
            mime: "text/markdown",
            editable: true
        )
        
        // 3. Tabular & Spreadsheets (Delimited & Workbooks)
        register(
            ["csv"],
            name: "CSV Comma-Separated Values",
            capabilities: [.structuredData, .sourceCode],
            primary: .structuredData,
            icon: "tablecells.fill",
            mime: "text/csv",
            editable: true
        )
        register(
            ["tsv", "tab"],
            name: "TSV Tab-Separated Values",
            capabilities: [.structuredData, .sourceCode],
            primary: .structuredData,
            icon: "tablecells.fill",
            mime: "text/tab-separated-values",
            editable: true
        )
        register(
            ["psv", "ssv"],
            name: "Delimited Spreadsheet Table",
            capabilities: [.structuredData, .sourceCode],
            primary: .structuredData,
            icon: "tablecells.fill",
            mime: "text/plain",
            editable: true
        )
        register(
            ["xlsx", "xls"],
            name: "Excel Spreadsheet Workbook",
            capabilities: [.structuredData],
            primary: .structuredData,
            icon: "tablecells.fill",
            mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            editable: false
        )
        register(
            ["ods"],
            name: "OpenDocument Spreadsheet",
            capabilities: [.structuredData],
            primary: .structuredData,
            icon: "tablecells.fill",
            mime: "application/vnd.oasis.opendocument.spreadsheet",
            editable: false
        )
        
        // 4. Structured Data, Serialization & Notebooks
        register(
            ["json"],
            name: "JSON Structured Document",
            capabilities: [.structuredData, .sourceCode],
            primary: .structuredData,
            icon: "curlybraces",
            mime: "application/json",
            editable: true
        )
        register(
            ["xml"],
            name: "XML Document",
            capabilities: [.structuredData, .sourceCode],
            primary: .structuredData,
            icon: "curlybraces",
            mime: "application/xml",
            editable: true
        )
        register(
            ["plist"],
            name: "Apple Property List",
            capabilities: [.structuredData, .sourceCode],
            primary: .structuredData,
            icon: "doc.text.fill",
            mime: "application/x-plist",
            editable: true
        )
        register(
            ["yaml", "yml"],
            name: "YAML Configuration",
            capabilities: [.structuredData, .sourceCode],
            primary: .structuredData,
            icon: "curlybraces",
            mime: "text/yaml",
            editable: true
        )
        register(
            ["toml"],
            name: "TOML Configuration",
            capabilities: [.structuredData, .sourceCode],
            primary: .structuredData,
            icon: "curlybraces",
            mime: "application/toml",
            editable: true
        )
        register(
            ["ipynb"],
            name: "Jupyter Interactive Notebook",
            capabilities: [.structuredData, .sourceCode],
            primary: .structuredData,
            icon: "curlybraces",
            mime: "application/x-ipynb+json",
            editable: true
        )
        
        // 5. Source Code & Scripts
        register(
            ["swift"],
            name: "Swift Source File",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/x-swift",
            editable: true
        )
        register(
            ["rs"],
            name: "Rust Source File",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/x-rust",
            editable: true
        )
        register(
            ["py"],
            name: "Python Script",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/x-python",
            editable: true
        )
        register(
            ["js", "jsx"],
            name: "JavaScript Source",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/javascript",
            editable: true
        )
        register(
            ["ts", "tsx"],
            name: "TypeScript Source",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/typescript",
            editable: true
        )
        register(
            ["c", "h"],
            name: "C Source / Header",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/x-c",
            editable: true
        )
        register(
            ["cpp", "hpp", "cc", "cxx"],
            name: "C++ Source / Header",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/x-c++src",
            editable: true
        )
        register(
            ["m", "mm"],
            name: "Objective-C Source",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/x-objcsrc",
            editable: true
        )
        register(
            ["go"],
            name: "Go Source File",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/x-go",
            editable: true
        )
        register(
            ["java"],
            name: "Java Source File",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/x-java-source",
            editable: true
        )
        register(
            ["kt", "kts"],
            name: "Kotlin Source File",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/x-kotlin",
            editable: true
        )
        register(
            ["cs"],
            name: "C# Source File",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/plain",
            editable: true
        )
        register(
            ["sh", "bash", "zsh", "fish"],
            name: "Shell Script",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "application/x-sh",
            editable: true
        )
        register(
            ["css", "scss", "less"],
            name: "Stylesheet",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/css",
            editable: true
        )
        register(
            ["sql"],
            name: "SQL Query File",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "application/sql",
            editable: true
        )
        register(
            ["vue", "svelte"],
            name: "Frontend Component",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/plain",
            editable: true
        )
        register(
            ["rb", "php", "gradle"],
            name: "Script Source",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "chevron.left.forwardslash.chevron.right",
            mime: "text/plain",
            editable: true
        )
        
        // 6. Plain Text & Configuration
        register(
            ["txt", "log", "ini", "conf", "cfg", "properties", "env"],
            name: "Plain Text / Config",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "doc.text.fill",
            mime: "text/plain",
            editable: true
        )
        register(
            ["srt", "ass", "vtt", "lrc", "sub"],
            name: "Subtitle / Lyric Document",
            capabilities: [.sourceCode],
            primary: .sourceCode,
            icon: "captions.bubble.fill",
            mime: "text/plain",
            editable: true
        )
        
        // 7. Paginated Documents & Office
        register(
            ["pdf"],
            name: "PDF Document",
            capabilities: [.visualRender, .documentPagination],
            primary: .visualRender,
            icon: "doc.richtext.fill",
            mime: "application/pdf",
            editable: false
        )
        register(
            ["docx", "doc", "rtf", "odt"],
            name: "Word Processing Document",
            capabilities: [.visualRender, .documentPagination],
            primary: .visualRender,
            icon: "doc.richtext.fill",
            mime: "application/msword",
            editable: false
        )
        register(
            ["pptx", "ppt", "odp", "key"],
            name: "Presentation Slides",
            capabilities: [.visualRender, .structuredData],
            primary: .visualRender,
            icon: "rectangle.inset.filled.and.person.filled",
            mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            editable: false
        )
        register(
            ["epub"],
            name: "EPUB Publication",
            capabilities: [.visualRender, .documentPagination],
            primary: .visualRender,
            icon: "book.closed.fill",
            mime: "application/epub+zip",
            editable: false
        )
        register(
            ["mobi", "azw", "azw3", "fb2", "cbz", "cbr", "ibooks"],
            name: "E-Book Document",
            capabilities: [.visualRender, .documentPagination],
            primary: .visualRender,
            icon: "book.closed.fill",
            mime: "application/octet-stream",
            editable: false
        )
        
        // 8. Raster Images
        register(
            ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico", "arw", "cr3", "nef", "dng"],
            name: "Bitmap Image",
            capabilities: [.visualRender],
            primary: .visualRender,
            icon: "photo.fill",
            mime: "image/png",
            editable: false
        )
        
        // 9. Continuous Audio & Video Media
        register(
            [
                "mp4", "mov", "m4v", "qt", "mkv", "avi", "webm", "ogv", "flv", "3gp",
                "3g2", "ts", "mts", "m2ts", "m2t", "wmv", "vob", "rmvb", "rm", "divx",
                "asf", "f4v", "y4m", "mpg", "mpeg", "mpe", "mpv", "m2v", "vro", "dat",
                "nut", "dv", "mxf"
            ],
            name: "Video Media Container",
            capabilities: [.mediaPlayback],
            primary: .mediaPlayback,
            icon: "film.fill",
            mime: "video/mp4",
            editable: false
        )
        register(
            [
                "mp3", "wav", "m4a", "aac", "flac", "aifc", "aiff", "aif", "m4b", "m4r",
                "alac", "caf", "ogg", "oga", "opus", "wma", "ape", "dts", "ac3", "eac3",
                "amr", "mid", "midi", "mka", "dsd", "dsf", "dff", "wv", "tta", "mpc",
                "tak", "spx", "au", "snd", "voc", "ra", "gsm"
            ],
            name: "Audio Media Stream",
            capabilities: [.mediaPlayback],
            primary: .mediaPlayback,
            icon: "music.note",
            mime: "audio/mpeg",
            editable: false
        )
        
        // 10. Archive Files
        register(
            ["7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "xz", "001", "002", "003", "zst", "iso"],
            name: "Archive Container",
            capabilities: [.archiveBrowse],
            primary: .archiveBrowse,
            icon: "archivebox.fill",
            mime: "application/zip",
            editable: false
        )
        
        // 11. Compiled Binary & Byte Stream Executables
        register(
            ["bin", "so", "dylib", "wasm", "class", "o", "exe", "dll", "obj", "a", "lib", "hex", "rom", "elf", "dex", "pyc"],
            name: "Binary Executable / Byte Stream",
            capabilities: [.hexBinary],
            primary: .hexBinary,
            icon: "memorychip.fill",
            mime: "application/octet-stream",
            editable: false
        )
        
        return map
    }()

    // MARK: - Query APIs

    /// Retrieves format descriptor for a given file extension or full path.
    public static func descriptor(for extensionOrFileName: String) -> PreviewFormatDescriptor? {
        let cleanExt = cleanExtension(from: extensionOrFileName)
        return descriptors[cleanExt]
    }
    
    /// Queries the full capability bitmask for a given extension.
    /// Unknown extensions fall back to empty capabilities.
    public static func capabilities(for extensionOrFileName: String) -> PreviewCapabilities {
        descriptor(for: extensionOrFileName)?.capabilities ?? []
    }
    
    /// Queries the preferred primary preview presentation mode.
    public static func primaryMode(for extensionOrFileName: String) -> PreviewPrimaryMode? {
        descriptor(for: extensionOrFileName)?.primaryMode
    }
    
    /// Determines whether the format supports visual rendering (WKWebView, Markdown, Image, PDF, etc.).
    public static func isVisualRenderable(_ extensionOrFileName: String) -> Bool {
        capabilities(for: extensionOrFileName).contains(.visualRender)
    }
    
    /// Determines whether the format can be viewed/edited as syntax source code.
    public static func hasSourceCode(_ extensionOrFileName: String) -> Bool {
        capabilities(for: extensionOrFileName).contains(.sourceCode)
    }
    
    /// Determines whether the format supports structured data view (Table, Tree, Key-Value).
    public static func isStructuredData(_ extensionOrFileName: String) -> Bool {
        capabilities(for: extensionOrFileName).contains(.structuredData)
    }
    
    /// Resolves recommended SF Symbol icon for a file or extension name.
    public static func iconName(for extensionOrFileName: String) -> String {
        if let desc = descriptor(for: extensionOrFileName) {
            return desc.iconName
        }
        return "doc.fill"
    }
    
    /// Set of all explicitly registered extensions in the matrix.
    public static var allSupportedExtensions: Set<String> {
        Set(descriptors.keys)
    }
    
    // MARK: - Helper Sanitization
    
    private static func cleanExtension(from string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let strippedLeadingDots = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if strippedLeadingDots.contains(".") {
            let ext = (strippedLeadingDots as NSString).pathExtension.lowercased()
            return ext.isEmpty ? strippedLeadingDots : ext
        }
        return strippedLeadingDots
    }
}
