// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipSearchKit

package enum SemanticSearchComposition {
    package static let shared = makeSharedEngine()

    package static func makeEngine(
        storageDirectory: URL,
        pluginEnabled: Bool = false
    ) -> SemanticSearchEngine {
        SemanticSearchEngine(
            bridge: UniFFIRustSemanticCoreBridge(storageDirectory: storageDirectory),
            directoryLeaseProvider: { url in
                await MainActor.run { RootFolderAccessManager.shared.acquireLease(for: url) }
            },
            verifyModelFile: verifyModelFile,
            pluginEnabled: pluginEnabled,
            allowsNonExactModelRuntimeFallback: true
        )
    }

    package static func verifyModelFile(_ url: URL, _ requireExactChecksum: Bool) async throws {
        _ = try await GGUFModelVerifier.verifyModelFileAsync(at: url, requireExactChecksum: requireExactChecksum)
    }

    private static func makeSharedEngine() -> SemanticSearchEngine {
        let storageDirectory = LocalModelPathResolver.defaultResolver().semanticStorageDirectoryURL
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        return makeEngine(
            storageDirectory: storageDirectory,
            pluginEnabled: LocalSemanticPluginPreferences.isEnabled
        )
    }
}
