// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTLogKit
import TTZipAppCore
import TTZipCore
import TTZipPreviewKit

@MainActor
package enum AppStartup {
    package static func initializeRuntime() {
        TTZipCore.enableMicrokernelLoggingBridge()
        TTLogKit.MainThreadHangWatchdog.shared.start()
        TTZipEngineFacade.initializeSubsystems()
        let provider = TTZipArchiveVfsProvider.shared
        let readAccess = TTZipArchiveVfsProvider.ReadAccess.archiveRuntime
        provider.installReadAccess(readAccess)
        provider.installMediaCacheExtraction(
            ArchiveMediaCachePool.Extraction(
                toDisk: { archivePath, entryPath, outputDirectory, password in
                    _ = try await TTZipEngineFacade.shared.extractSingleEntry(
                        archivePath: archivePath,
                        entryPath: entryPath,
                        destinationDir: outputDirectory,
                        password: password,
                        handling: .policy(.replace)
                    )
                },
                toMemory: readAccess.readEntry
            )
        )
        EPUBArchiveUnpacker.register()
        PreviewPlaybackPersistence.install(resumePosition: mediaResumePosition)
    }
}
