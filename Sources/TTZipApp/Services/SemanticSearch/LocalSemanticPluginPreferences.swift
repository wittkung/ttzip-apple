// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Explicit opt-in is independent of whether model files have been installed.
public enum LocalSemanticPluginPreferences {
    public static let enabledKey = "localSemanticPlugin.enabled.v1"
    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
}

/// Unified local model path resolver compatible across MAS Sandbox, Direct, Steam, and Acceptance containers.
/// Never hardcodes developer home paths.
public struct LocalModelPathResolver: Sendable, Equatable {
    public let containerRootURL: URL
    public let semanticStorageDirectoryURL: URL
    public let legacyModelFileURL: URL?

    public var modelsDirectoryURL: URL {
        semanticStorageDirectoryURL.appendingPathComponent("models", isDirectory: true)
    }

    public var canonicalModelFileURL: URL {
        modelsDirectoryURL.appendingPathComponent(SemanticModelSpec.pinnedGGUFFilename, isDirectory: false)
    }

    public var stagingPartFileURL: URL {
        modelsDirectoryURL.appendingPathComponent("\(SemanticModelSpec.pinnedGGUFFilename).part", isDirectory: false)
    }

    public func stagingPartFileURL(forGeneration generation: UInt64) -> URL {
        modelsDirectoryURL.appendingPathComponent(
            "\(SemanticModelSpec.pinnedGGUFFilename).part.\(generation)",
            isDirectory: false
        )
    }

    public init(
        containerRootURL: URL,
        semanticStorageDirectoryURL: URL,
        legacyModelFileURL: URL? = nil
    ) {
        self.containerRootURL = containerRootURL.standardizedFileURL
        self.semanticStorageDirectoryURL = semanticStorageDirectoryURL.standardizedFileURL
        self.legacyModelFileURL = legacyModelFileURL?.standardizedFileURL
    }

    public init(
        semanticStorageDirectory: URL,
        legacyModelsDirectory: URL? = nil
    ) {
        let standardizedStorage = semanticStorageDirectory.standardizedFileURL
        self.containerRootURL = standardizedStorage.deletingLastPathComponent()
        self.semanticStorageDirectoryURL = standardizedStorage
        self.legacyModelFileURL = legacyModelsDirectory?.standardizedFileURL.appendingPathComponent(
            SemanticModelSpec.pinnedGGUFFilename,
            isDirectory: false
        )
    }

    public static func defaultResolver(fileManager: FileManager = .default) -> LocalModelPathResolver {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return resolver(applicationSupportBaseURL: baseURL, bundleIdentifier: "com.metastudyline.ttzip")
    }

    public static func resolver(
        applicationSupportBaseURL: URL,
        bundleIdentifier: String = "com.metastudyline.ttzip"
    ) -> LocalModelPathResolver {
        let containerRoot = applicationSupportBaseURL
            .standardizedFileURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        let semanticStorage = containerRoot.appendingPathComponent("SemanticIndex", isDirectory: true)
        let legacyModel = containerRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(SemanticModelSpec.pinnedGGUFFilename, isDirectory: false)
        return LocalModelPathResolver(
            containerRootURL: containerRoot,
            semanticStorageDirectoryURL: semanticStorage,
            legacyModelFileURL: legacyModel
        )
    }
}

