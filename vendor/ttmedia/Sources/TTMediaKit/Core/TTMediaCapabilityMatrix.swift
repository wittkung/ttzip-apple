// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Discrete capability bitmask representing supported presentation modes for a file format.
public struct PreviewCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Visual rich rendering (WKWebView HTML/SVG, Markdown canvas, ImageIO, PDF viewport).
    public static let visualRender = PreviewCapabilities(rawValue: 1 << 0)

    /// Syntax-highlighted text editor or source code inspector.
    public static let sourceCode = PreviewCapabilities(rawValue: 1 << 1)

    /// Structured table/tree/outline inspection (CSV/TSV table, JSON/XML/YAML outline).
    public static let structuredData = PreviewCapabilities(rawValue: 1 << 2)

    /// Raw byte-level inspection with hex and ASCII decoding table.
    public static let hexBinary = PreviewCapabilities(rawValue: 1 << 3)

    /// Hardware-accelerated continuous media stream playback (AVFoundation / TTMPV).
    public static let mediaPlayback = PreviewCapabilities(rawValue: 1 << 4)

    /// Paginated multi-page document navigation (PDFKit, EPUB reader, Docx viewer).
    public static let documentPagination = PreviewCapabilities(rawValue: 1 << 5)

    /// Virtual archive filesystem container navigation.
    public static let archiveBrowse = PreviewCapabilities(rawValue: 1 << 6)

    // MARK: - Discrete Capability Convenience Aliases

    /// Audio media stream playback capability.
    public static let audio: PreviewCapabilities = [.mediaPlayback]

    /// Video media container playback capability.
    public static let video: PreviewCapabilities = [.mediaPlayback]

    /// Raster and vector visual rendering capability.
    public static let image: PreviewCapabilities = [.visualRender]

    /// Syntax-highlighted source code capability.
    public static let code: PreviewCapabilities = [.sourceCode]

    /// Markdown rich document and source inspection capability.
    public static let markdown: PreviewCapabilities = [.visualRender, .sourceCode]

    /// Portable document format pagination and visual presentation capability.
    public static let pdf: PreviewCapabilities = [.visualRender, .documentPagination]

    /// EPUB and electronic publication book navigation capability.
    public static let epub: PreviewCapabilities = [.visualRender, .documentPagination]

    /// Office suite document inspection capability.
    public static let office: PreviewCapabilities = [.visualRender, .documentPagination, .structuredData]

    /// Tabular spreadsheet table and structured inspection capability.
    public static let spreadsheet: PreviewCapabilities = [.structuredData, .sourceCode]

    /// Binary hexadecimal inspection capability.
    public static let hex: PreviewCapabilities = [.hexBinary]

    /// Archive container browsing capability.
    public static let archive: PreviewCapabilities = [.archiveBrowse]
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
public enum TTMediaCapabilityMatrix {

    // MARK: - Centralized Category Extension Sets

    /// Web and HTML interactive extensions.
    public static let htmlWebExtensions: Set<String> = [
        "html", "htm", "xhtml", "mhtml", "mht", "svg", "svgz"
    ]

    /// Markdown document extensions.
    public static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdtxt", "mdtext"
    ]

    /// Tabular plain-text spreadsheet extensions.
    public static let tabularSpreadsheetExtensions: Set<String> = ["csv", "tsv", "tab", "psv", "ssv"]

    /// Binary workbook spreadsheet extensions.
    public static let binarySpreadsheetExtensions: Set<String> = ["xlsx", "xlsm", "xls", "ods", "numbers"]

    /// Tabular and spreadsheet document extensions.
    public static let spreadsheetExtensions: Set<String> = ["xlsx", "xlsm", "xls", "ods", "csv", "tsv", "tab", "psv", "ssv"]

    /// Word processing document extensions.
    public static let docxExtensions: Set<String> = ["docx", "doc", "rtf", "odt"]

    /// Presentation slide extensions.
    public static let presentationExtensions: Set<String> = ["pptx", "ppt", "odp", "key"]

    /// E-book formats with full in-app paginated chapter rendering.
    public static let fullTextEbookExtensions: Set<String> = ["epub"]

    /// Non-EPUB e-book formats supported in metadata & SHA-256 checksum inspection mode only.
    public static let inspectionOnlyEbookExtensions: Set<String> = ["mobi", "azw", "azw3", "fb2", "ibooks"]

    /// Comic book container archives routed to archive browsing.
    public static let comicArchiveExtensions: Set<String> = ["cbz", "cbr", "cb7"]

    /// E-book publication extensions (including legacy compatibility aliases).
    public static let ebookExtensions: Set<String> = [
        "epub", "mobi", "azw", "azw3", "fb2", "cbz", "cbr", "ibooks"
    ]

    /// PDF document extensions.
    public static let pdfExtensions: Set<String> = ["pdf"]

    /// Raster and bitmap image extensions.
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico", "arw", "cr3", "nef", "dng"
    ]

    /// Unambiguous video container extensions (`.ts` and `.dat` require content probing).
    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "qt", "mkv", "avi", "webm", "ogv", "flv", "3gp",
        "3g2", "mts", "m2ts", "m2t", "wmv", "vob", "rmvb", "rm", "divx",
        "asf", "f4v", "y4m", "mpg", "mpeg", "mpe", "mpv", "m2v", "vro", "nut", "dv", "mxf"
    ]

    /// Extensions with format collisions that require content inspection before routing.
    public static let ambiguousExtensions: Set<String> = ["ts", "dat"]

    /// Audio extensions supported for playback and waveform visualization.
    public static let audioExtensions: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "aifc", "aiff", "aif", "m4b", "m4r",
        "alac", "caf", "ogg", "oga", "opus", "wma", "ape", "dts", "ac3", "eac3",
        "amr", "mid", "midi", "mka", "dsd", "dsf", "dff", "wv", "tta", "mpc",
        "tak", "spx", "au", "snd", "voc", "ra", "gsm"
    ]

    /// Binary executable and byte stream extensions.
    public static let binaryExtensions: Set<String> = [
        "bin", "dat", "so", "dylib", "wasm", "class", "o", "exe", "dll", "obj", "a", "lib", "hex", "rom", "elf", "dex", "pyc"
    ]

    /// Text and source code extensions.
    public static let textExtensions: Set<String> = [
        "txt", "log", "ini", "conf", "cfg", "properties", "env", "plist",
        "swift", "kt", "kts", "java", "rs", "go", "c", "cpp", "h", "hpp", "cs", "m", "mm",
        "js", "jsx", "ts", "tsx", "vue", "svelte", "py", "rb", "php", "sh", "bash", "zsh", "fish", "command",
        "css", "json", "xml", "yaml", "yml", "toml", "ipynb", "sql", "gradle", "srt", "ass", "vtt", "lrc", "sub"
    ]

    /// Archive extensions registered within the capability matrix.
    public static let archiveExtensions: Set<String> = [
        "7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "xz", "001", "002", "003", "z01", "z02", "z03", "zst", "iso",
        "br", "lz", "lz4", "lrz", "wim", "cbz", "cbr", "cb7"
    ]

    // MARK: - Canonical Content-Resolved Descriptors

    public static let mpegTSVideoDescriptor = PreviewFormatDescriptor(
        extensionName: "ts",
        displayName: "MPEG Transport Stream",
        capabilities: [.mediaPlayback],
        primaryMode: .mediaPlayback,
        iconName: "film.fill",
        mimeType: "video/mp2t",
        isEditableSource: false
    )

    public static let typeScriptSourceDescriptor = PreviewFormatDescriptor(
        extensionName: "ts",
        displayName: "TypeScript Source",
        capabilities: [.sourceCode],
        primaryMode: .sourceCode,
        iconName: "chevron.left.forwardslash.chevron.right",
        mimeType: "text/typescript",
        isEditableSource: true
    )

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

        // 1. Web & Interactive Renderable Documents
        register(["html", "htm"], name: "HTML Web Document", capabilities: [.visualRender, .sourceCode], primary: .visualRender, icon: "globe", mime: "text/html", editable: true)
        register(["xhtml"], name: "XHTML Document", capabilities: [.visualRender, .sourceCode], primary: .visualRender, icon: "globe", mime: "application/xhtml+xml", editable: true)
        register(["mhtml", "mht"], name: "MHTML Web Archive", capabilities: [.visualRender, .sourceCode], primary: .visualRender, icon: "globe", mime: "multipart/related", editable: true)
        register(["svg"], name: "SVG Vector Graphic", capabilities: [.visualRender, .sourceCode], primary: .visualRender, icon: "photo.fill", mime: "image/svg+xml", editable: true)
        register(["svgz"], name: "Compressed SVG Vector Graphic", capabilities: [.visualRender, .sourceCode], primary: .visualRender, icon: "photo.fill", mime: "image/svg+xml", editable: false)

        // 2. Markdown Documents
        register(["md", "markdown", "mdown", "mkd", "mkdn", "mdtxt", "mdtext"], name: "Markdown Document", capabilities: [.visualRender, .sourceCode], primary: .visualRender, icon: "doc.text.fill", mime: "text/markdown", editable: true)

        // 3. Tabular & Spreadsheets
        register(["csv"], name: "CSV Comma-Separated Values", capabilities: [.structuredData, .sourceCode], primary: .structuredData, icon: "tablecells.fill", mime: "text/csv", editable: true)
        register(["tsv", "tab"], name: "TSV Tab-Separated Values", capabilities: [.structuredData, .sourceCode], primary: .structuredData, icon: "tablecells.fill", mime: "text/tab-separated-values", editable: true)
        register(["psv", "ssv"], name: "Delimited Spreadsheet Table", capabilities: [.structuredData, .sourceCode], primary: .structuredData, icon: "tablecells.fill", mime: "text/plain", editable: true)
        register(["xlsx", "xlsm", "xls"], name: "Excel Spreadsheet Workbook", capabilities: [.structuredData], primary: .structuredData, icon: "tablecells.fill", mime: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", editable: false)
        register(["ods"], name: "OpenDocument Spreadsheet", capabilities: [.structuredData], primary: .structuredData, icon: "tablecells.fill", mime: "application/vnd.oasis.opendocument.spreadsheet", editable: false)

        // 4. Structured Data & Notebooks
        register(["json"], name: "JSON Structured Document", capabilities: [.structuredData, .sourceCode], primary: .structuredData, icon: "curlybraces", mime: "application/json", editable: true)
        register(["xml"], name: "XML Document", capabilities: [.structuredData, .sourceCode], primary: .structuredData, icon: "curlybraces", mime: "application/xml", editable: true)
        register(["plist"], name: "Apple Property List", capabilities: [.structuredData, .sourceCode], primary: .structuredData, icon: "doc.text.fill", mime: "application/x-plist", editable: true)
        register(["yaml", "yml"], name: "YAML Configuration", capabilities: [.structuredData, .sourceCode], primary: .structuredData, icon: "curlybraces", mime: "text/yaml", editable: true)
        register(["toml"], name: "TOML Configuration", capabilities: [.structuredData, .sourceCode], primary: .structuredData, icon: "curlybraces", mime: "application/toml", editable: true)
        register(["ipynb"], name: "Jupyter Interactive Notebook", capabilities: [.structuredData, .sourceCode], primary: .structuredData, icon: "curlybraces", mime: "application/x-ipynb+json", editable: true)

        // 5. Source Code & Scripts
        register(["swift"], name: "Swift Source File", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/x-swift", editable: true)
        register(["rs"], name: "Rust Source File", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/x-rust", editable: true)
        register(["py"], name: "Python Script", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/x-python", editable: true)
        register(["js", "jsx"], name: "JavaScript Source", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/javascript", editable: true)
        register(["tsx"], name: "TypeScript Source", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/typescript", editable: true)
        register(["ts"], name: "TypeScript / MPEG-TS", capabilities: [.sourceCode, .mediaPlayback], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/typescript", editable: true)
        register(["c", "h"], name: "C Source / Header", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/x-c", editable: true)
        register(["cpp", "hpp", "cc", "cxx"], name: "C++ Source / Header", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/x-c++src", editable: true)
        register(["m", "mm"], name: "Objective-C Source", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/x-objcsrc", editable: true)
        register(["go"], name: "Go Source File", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/x-go", editable: true)
        register(["java"], name: "Java Source File", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/x-java-source", editable: true)
        register(["kt", "kts"], name: "Kotlin Source File", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/x-kotlin", editable: true)
        register(["cs"], name: "C# Source File", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/plain", editable: true)
        register(["sh", "bash", "zsh", "fish", "command"], name: "Shell Script", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "application/x-sh", editable: true)
        register(["css", "scss", "less"], name: "Stylesheet", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/css", editable: true)
        register(["sql"], name: "SQL Query File", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "application/sql", editable: true)
        register(["vue", "svelte"], name: "Frontend Component", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/plain", editable: true)
        register(["rb", "php", "gradle"], name: "Script Source", capabilities: [.sourceCode], primary: .sourceCode, icon: "chevron.left.forwardslash.chevron.right", mime: "text/plain", editable: true)

        // 6. Plain Text & Subtitles
        register(["txt", "log", "ini", "conf", "cfg", "properties", "env"], name: "Plain Text / Config", capabilities: [.sourceCode], primary: .sourceCode, icon: "doc.text.fill", mime: "text/plain", editable: true)
        register(["srt", "ass", "vtt", "lrc", "sub"], name: "Subtitle / Lyric Document", capabilities: [.sourceCode], primary: .sourceCode, icon: "captions.bubble.fill", mime: "text/plain", editable: true)

        // 7. Paginated Documents, Non-EPUB E-Book Metadata Inspection & Comic Archives
        register(["pdf"], name: "PDF Document", capabilities: [.visualRender, .documentPagination], primary: .visualRender, icon: "doc.richtext.fill", mime: "application/pdf", editable: false)
        register(["docx", "doc", "rtf", "odt"], name: "Word Processing Document", capabilities: [.visualRender, .documentPagination], primary: .visualRender, icon: "doc.richtext.fill", mime: "application/msword", editable: false)
        register(["pptx", "ppt", "odp", "key"], name: "Presentation Slides", capabilities: [.visualRender, .structuredData], primary: .visualRender, icon: "rectangle.inset.filled.and.person.filled", mime: "application/vnd.openxmlformats-officedocument.presentationml.presentation", editable: false)
        register(["epub"], name: "EPUB Publication", capabilities: [.visualRender, .documentPagination], primary: .visualRender, icon: "book.closed.fill", mime: "application/epub+zip", editable: false)
        register(["mobi", "azw", "azw3", "fb2", "ibooks"], name: "E-Book Document (Metadata Inspection)", capabilities: [.structuredData], primary: .structuredData, icon: "book.closed.fill", mime: "application/octet-stream", editable: false)
        register(["cbz", "cbr", "cb7"], name: "Comic Book Archive", capabilities: [.archiveBrowse], primary: .archiveBrowse, icon: "book.closed.fill", mime: "application/zip", editable: false)

        // 8. Raster Images
        register(["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "ico", "arw", "cr3", "nef", "dng"], name: "Bitmap Image", capabilities: [.visualRender], primary: .visualRender, icon: "photo.fill", mime: "image/png", editable: false)

        // 9. Continuous Audio & Video Media
        register(Array(videoExtensions), name: "Video Media Container", capabilities: [.mediaPlayback], primary: .mediaPlayback, icon: "film.fill", mime: "video/mp4", editable: false)
        register(Array(audioExtensions), name: "Audio Media Stream", capabilities: [.mediaPlayback], primary: .mediaPlayback, icon: "music.note", mime: "audio/mpeg", editable: false)

        // 10. Archive Files
        register(["7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "xz", "001", "002", "003", "z01", "z02", "z03", "zst", "iso", "br", "lz", "lz4", "lrz", "wim"], name: "Archive Container", capabilities: [.archiveBrowse], primary: .archiveBrowse, icon: "archivebox.fill", mime: "application/zip", editable: false)

        // 11. Compiled Binary & Byte Stream Executables
        register(["bin", "dat", "so", "dylib", "wasm", "class", "o", "exe", "dll", "obj", "a", "lib", "hex", "rom", "elf", "dex", "pyc"], name: "Binary Executable / Byte Stream", capabilities: [.hexBinary], primary: .hexBinary, icon: "memorychip.fill", mime: "application/octet-stream", editable: false)

        return map
    }()

    // MARK: - Query APIs

    /// Retrieves format descriptor for a given file extension or path.
    public static func descriptor(for extensionOrFileName: String) -> PreviewFormatDescriptor? {
        let cleanExt = cleanExtension(from: extensionOrFileName)
        return descriptors[cleanExt]
    }

    /// Resolves the effective format descriptor by combining extension and content probe evidence.
    public static func resolveDescriptor(
        for extensionOrFileName: String,
        magic: TTMediaMagicKind,
        isBinaryContent: Bool
    ) -> PreviewFormatDescriptor? {
        let ext = cleanExtension(from: extensionOrFileName)

        switch magic {
        case .image(let mime):
            return PreviewFormatDescriptor(
                extensionName: ext.isEmpty ? "img" : ext,
                displayName: "Bitmap Image",
                capabilities: [.visualRender],
                primaryMode: .visualRender,
                iconName: "photo.fill",
                mimeType: mime
            )
        case .pdf:
            return descriptors["pdf"]
        case .video(let mime):
            return resolveVideoDescriptor(for: ext, mime: mime)
        case .audio(let mime):
            return resolveAudioDescriptor(for: ext, mime: mime)
        case .binary(let mime):
            return PreviewFormatDescriptor(
                extensionName: ext.isEmpty ? "bin" : ext,
                displayName: "Binary Executable / Byte Stream",
                capabilities: [.hexBinary],
                primaryMode: .hexBinary,
                iconName: "memorychip.fill",
                mimeType: mime
            )
        case .archive:
            return resolveArchiveDescriptor(for: ext)
        case .text, .unknown:
            return resolveFallbackDescriptor(for: ext, isBinaryContent: isBinaryContent)
        }
    }

    private static func resolveVideoDescriptor(for ext: String, mime: String) -> PreviewFormatDescriptor? {
        if ext == "ts" {
            return mpegTSVideoDescriptor
        }
        return PreviewFormatDescriptor(
            extensionName: ext.isEmpty ? "mp4" : ext,
            displayName: "Video Media Container",
            capabilities: [.mediaPlayback],
            primaryMode: .mediaPlayback,
            iconName: "film.fill",
            mimeType: mime
        )
    }

    private static func resolveAudioDescriptor(for ext: String, mime: String) -> PreviewFormatDescriptor? {
        PreviewFormatDescriptor(
            extensionName: ext.isEmpty ? "mp3" : ext,
            displayName: "Audio Media Stream",
            capabilities: [.mediaPlayback],
            primaryMode: .mediaPlayback,
            iconName: "music.note",
            mimeType: mime
        )
    }

    private static func resolveArchiveDescriptor(for ext: String) -> PreviewFormatDescriptor? {
        if isZipBackedDocument(ext) || ebookExtensions.contains(ext) || ext == "svgz" {
            return descriptors[ext]
        }
        return descriptors[ext] ?? descriptors["zip"]
    }

    private static func resolveFallbackDescriptor(
        for ext: String,
        isBinaryContent: Bool
    ) -> PreviewFormatDescriptor? {
        if ext == "ts" {
            return isBinaryContent ? descriptors["bin"] : typeScriptSourceDescriptor
        }
        if ext == "dat" || binaryExtensions.contains(ext) {
            return descriptors["dat"]
        }
        if videoExtensions.contains(ext) || audioExtensions.contains(ext) || ext == "pdf" || imageExtensions.contains(ext) {
            return isBinaryContent ? descriptors["bin"] : descriptors["txt"]
        }
        if isBinaryContent && (markdownExtensions.contains(ext) || htmlWebExtensions.contains(ext) || tabularSpreadsheetExtensions.contains(ext) || textExtensions.contains(ext)) {
            return descriptors["bin"]
        }
        return descriptors[ext]
    }

    // MARK: - Two-Layer Shared Container & Track Probing

    /// Layer 1: Identifies shared multimedia containers capable of holding audio-only or video+audio streams.
    public static func identifySharedContainer(
        in sample: Data,
        isBinaryPayload: Bool
    ) -> TTMediaSharedContainerKind? {
        guard sample.count >= 4 else { return nil }
        if sample.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return .matroska }
        if sample.starts(with: [0x4F, 0x67, 0x67, 0x53]) { return .ogg }
        if sample.starts(with: [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) { return .asf }
        if sample.starts(with: [0x2E, 0x52, 0x4D, 0x46]) { return .realMedia }
        guard sample.count >= 12 else { return nil }
        let boxType = String(bytes: sample.subdata(in: 4..<8), encoding: .isoLatin1) ?? ""
        if boxType == "ftyp" { return .isoBMFF }
        if sample[0] == 0x00 && (boxType == "moov" || boxType == "wide" || boxType == "mdat") && isBinaryPayload {
            return .isoBMFF
        }
        return nil
    }

    /// Layer 2: Resolves `.image`, `.audio`, `.video`, or `.unknown` by probing track descriptors inside a shared container.
    public static func probeSharedContainerTracks(
        container: TTMediaSharedContainerKind,
        sample: Data,
        moovSample: Data? = nil,
        isCompleteScan: Bool = true
    ) -> TTMediaMagicKind {
        switch container {
        case .isoBMFF:
            return probeISOBMFFContainerTracks(sample: sample, moovSample: moovSample, isCompleteScan: isCompleteScan)
        case .matroska: return probeMatroskaContainerTracks(sample: sample)
        case .ogg: return probeOggContainerTracks(sample: sample)
        case .asf: return probeASFContainerTracks(sample: sample)
        case .realMedia: return probeRealMediaContainerTracks(sample: sample)
        }
    }

    /// Queries the full capability bitmask for a given extension or filename.
    public static func capabilities(for extensionOrFileName: String) -> PreviewCapabilities {
        descriptor(for: extensionOrFileName)?.capabilities ?? []
    }

    /// Queries the preferred primary preview presentation mode.
    public static func primaryMode(for extensionOrFileName: String) -> PreviewPrimaryMode? {
        descriptor(for: extensionOrFileName)?.primaryMode
    }

    /// Determines whether the extension has format collisions requiring content inspection.
    public static func isAmbiguous(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return ambiguousExtensions.contains(ext)
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

    /// Determines whether the format is an unambiguous audio stream by extension.
    public static func isAudio(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return audioExtensions.contains(ext)
    }

    /// Determines whether the format is an audio stream given resolved content magic evidence.
    public static func isAudio(_ extensionOrFileName: String, magic: TTMediaMagicKind) -> Bool {
        if case .audio = magic { return true }
        return false
    }

    /// Determines whether the format is an unambiguous video container by extension.
    public static func isVideo(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return videoExtensions.contains(ext)
    }

    /// Determines whether the format is a video container given resolved content magic evidence.
    public static func isVideo(_ extensionOrFileName: String, magic: TTMediaMagicKind) -> Bool {
        if case .video = magic { return true }
        return false
    }

    private static func isZipBackedDocument(_ ext: String) -> Bool {
        docxExtensions.contains(ext) || presentationExtensions.contains(ext) || binarySpreadsheetExtensions.contains(ext)
    }

    /// Determines whether the format is a bitmap or vector image.
    public static func isImage(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return imageExtensions.contains(ext) || ext == "svg" || ext == "svgz"
    }

    /// Determines whether the format is source code or plain text.
    public static func isCode(_ extensionOrFileName: String) -> Bool {
        hasSourceCode(extensionOrFileName)
    }

    /// Determines whether the format is a Markdown document.
    public static func isMarkdown(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return markdownExtensions.contains(ext)
    }

    /// Determines whether the format is a PDF document.
    public static func isPdf(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return pdfExtensions.contains(ext)
    }

    /// Determines whether the format is an EPUB publication.
    public static func isEpub(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return ext == "epub"
    }

    /// Determines whether the format supports full in-app paginated book chapter rendering (only EPUB).
    public static func supportsFullTextEbookReading(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return fullTextEbookExtensions.contains(ext)
    }

    /// Determines whether the format is a non-EPUB e-book limited to metadata and SHA-256 inspection mode.
    public static func isInspectionOnlyEbook(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return inspectionOnlyEbookExtensions.contains(ext)
    }

    /// Determines whether the format is a comic book archive container (CBZ, CBR, CB7).
    public static func isComicArchive(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return comicArchiveExtensions.contains(ext)
    }

    /// Determines whether the format is an office document (Word, PowerPoint, Excel, ODF).
    public static func isOffice(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return docxExtensions.contains(ext) || presentationExtensions.contains(ext) || spreadsheetExtensions.contains(ext)
    }

    /// Determines whether the format is a spreadsheet or tabular format (CSV, TSV, XLSX, ODS).
    public static func isSpreadsheet(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return spreadsheetExtensions.contains(ext)
    }

    /// Determines whether the format is a plain-text delimited table (CSV, TSV, TAB, PSV, SSV).
    public static func isTabularSpreadsheet(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return tabularSpreadsheetExtensions.contains(ext)
    }

    /// Determines whether the format is a binary spreadsheet workbook (XLSX, XLS, ODS, Numbers).
    public static func isBinarySpreadsheet(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return binarySpreadsheetExtensions.contains(ext)
    }

    /// Determines whether the format defaults to raw hexadecimal binary inspection.
    public static func isHex(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return binaryExtensions.contains(ext) || primaryMode(for: extensionOrFileName) == .hexBinary
    }

    /// Determines whether the format is an archive container.
    public static func isArchive(_ extensionOrFileName: String) -> Bool {
        let ext = cleanExtension(from: extensionOrFileName)
        return archiveExtensions.contains(ext)
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

    public static func cleanExtension(from string: String) -> String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let strippedLeadingDots = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if strippedLeadingDots.contains(".") {
            let ext = (strippedLeadingDots as NSString).pathExtension.lowercased()
            return ext.isEmpty ? strippedLeadingDots : ext
        }
        return strippedLeadingDots
    }
}

// MARK: - Shared Container Kind & Compatibility Typealiases

/// Shared multimedia container families capable of carrying either audio-only or video+audio streams.
public enum TTMediaSharedContainerKind: String, Sendable, Equatable {
    case isoBMFF
    case matroska
    case ogg
    case asf
    case realMedia
}

public typealias TTMediaCapabilities = PreviewCapabilities
public typealias TTMediaPrimaryMode = PreviewPrimaryMode
public typealias TTMediaFormatDescriptor = PreviewFormatDescriptor
public typealias PreviewCapabilityMatrix = TTMediaCapabilityMatrix
