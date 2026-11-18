// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Observation
import TTZipCore

/// Quick compression profile tier persisted by Settings -> Compression Defaults and read by `CompressFormSession`.
public enum DefaultCompressionTier: String, CaseIterable, Identifiable, Sendable {
    case store = "store"
    case fastest = "fastest"
    case normal = "normal"
    case maximum = "maximum"
    case ultra = "ultra"

    public var id: String { rawValue }

    public var archiveCompressionLevel: ArchiveCompressionLevel {
        switch self {
        case .store: return .store
        case .fastest: return .level1
        case .normal: return .level6
        case .maximum: return .level7
        case .ultra: return .level9
        }
    }

    /// Resolves current string tiers as well as legacy integer level values into a valid tier.
    public init(persistedValue: Any?) {
        if let raw = persistedValue as? String {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let direct = Self(rawValue: clean) {
                self = direct
                return
            }
            if let numeric = Int(clean) {
                self = Self.fromNumericLevel(numeric)
                return
            }
            self = Self.fromLegacyName(clean)
            return
        }
        if let numeric = persistedValue as? Int {
            self = Self.fromNumericLevel(numeric)
            return
        }
        self = .normal
    }

    private static func fromLegacyName(_ clean: String) -> Self {
        switch clean {
        case "fast": return .fastest
        case "medium": return .normal
        default: return .normal
        }
    }

    private static func fromNumericLevel(_ level: Int) -> Self {
        switch level {
        case ...0: return .store
        case 1...2: return .fastest
        case 3...6: return .normal
        case 7...8: return .maximum
        default: return .ultra
        }
    }
}

/// Immutable snapshot of user-configured archive creation defaults.
public struct CompressionDefaultsSnapshot: Equatable, Sendable {
    public static let defaultFormatKey = "ttzip_default_compression_format"
    public static let defaultLevelKey = "ttzip_default_compression_level"
    public static let skipMacJunkKey = "ttzip_default_skip_mac_junk"
    public static let openFinderAfterCompressKey = "ttzip_default_open_finder_after_compress"

    public static let supportedDefaultFormats: [ArchiveCompressionFormat] = [
        .sevenZip,
        .zip,
        .tarZst,
        .tarGz,
        .tarXz,
    ]

    public var defaultFormat: ArchiveCompressionFormat
    public var defaultTier: DefaultCompressionTier
    public var skipMacJunk: Bool
    public var openFinderAfterCompress: Bool

    public init(
        defaultFormat: ArchiveCompressionFormat = .sevenZip,
        defaultTier: DefaultCompressionTier = .normal,
        skipMacJunk: Bool = true,
        openFinderAfterCompress: Bool = false
    ) {
        self.defaultFormat = Self.resolvedDefaultFormat(from: defaultFormat.rawValue)
        self.defaultTier = defaultTier
        self.skipMacJunk = skipMacJunk
        self.openFinderAfterCompress = openFinderAfterCompress
    }

    public static func resolvedDefaultFormat(from rawValue: String?) -> ArchiveCompressionFormat {
        guard let rawValue,
              let format = ArchiveCompressionFormat.from(extensionOrName: rawValue),
              supportedDefaultFormats.contains(format) else {
            return .sevenZip
        }
        return format
    }

    public static func clampedLevel(
        _ level: ArchiveCompressionLevel,
        for format: ArchiveCompressionFormat
    ) -> ArchiveCompressionLevel {
        let clamped = max(format.minCompressionLevel, min(format.maxCompressionLevel, level.rawValue))
        return ArchiveCompressionLevel(levelInt: clamped)
    }

    public static func load(
        from defaults: UserDefaults = .standard,
        defaultOpenFinder: Bool = false
    ) -> CompressionDefaultsSnapshot {
        let format = resolvedDefaultFormat(from: defaults.string(forKey: defaultFormatKey))
        let tier = DefaultCompressionTier(persistedValue: defaults.object(forKey: defaultLevelKey))
        let skipMacJunk = (defaults.object(forKey: skipMacJunkKey) as? Bool) ?? true
        let openFinder = (defaults.object(forKey: openFinderAfterCompressKey) as? Bool) ?? defaultOpenFinder
        return CompressionDefaultsSnapshot(
            defaultFormat: format,
            defaultTier: tier,
            skipMacJunk: skipMacJunk,
            openFinderAfterCompress: openFinder
        )
    }
}

/// Observable single-owner store reading and writing Settings -> Compression Defaults preferences.
@MainActor
@Observable
public final class CompressionDefaultsStore {
    @ObservationIgnored private let defaults: UserDefaults
    private var storedDefaultFormat: ArchiveCompressionFormat

    public var defaultFormat: ArchiveCompressionFormat {
        get { storedDefaultFormat }
        set {
            let normalized = CompressionDefaultsSnapshot.resolvedDefaultFormat(from: newValue.rawValue)
            guard normalized != storedDefaultFormat else { return }
            storedDefaultFormat = normalized
            defaults.set(normalized.rawValue, forKey: CompressionDefaultsSnapshot.defaultFormatKey)
        }
    }

    public var defaultTier: DefaultCompressionTier {
        didSet {
            guard defaultTier != oldValue else { return }
            defaults.set(defaultTier.rawValue, forKey: CompressionDefaultsSnapshot.defaultLevelKey)
        }
    }

    public var skipMacJunk: Bool {
        didSet {
            guard skipMacJunk != oldValue else { return }
            defaults.set(skipMacJunk, forKey: CompressionDefaultsSnapshot.skipMacJunkKey)
        }
    }

    public var openFinderAfterCompress: Bool {
        didSet {
            guard openFinderAfterCompress != oldValue else { return }
            defaults.set(openFinderAfterCompress, forKey: CompressionDefaultsSnapshot.openFinderAfterCompressKey)
        }
    }

    public init(defaults: UserDefaults = .standard, defaultOpenFinder: Bool = false) {
        self.defaults = defaults
        let snapshot = CompressionDefaultsSnapshot.load(
            from: defaults,
            defaultOpenFinder: defaultOpenFinder
        )
        self.storedDefaultFormat = snapshot.defaultFormat
        self.defaultTier = snapshot.defaultTier
        self.skipMacJunk = snapshot.skipMacJunk
        self.openFinderAfterCompress = snapshot.openFinderAfterCompress
    }
}
