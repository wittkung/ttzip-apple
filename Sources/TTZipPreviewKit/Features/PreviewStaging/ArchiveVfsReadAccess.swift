// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCoreArchive

extension TTZipArchiveVfsProvider {
    package struct ReadAccess: Sendable {
        package let readEntry: @Sendable (String, String, String?) async throws -> Data?
        let listEntrySizes: @Sendable (String, String?) throws -> [(path: String, size: UInt64)]

        package init(
            readEntry: @escaping @Sendable (_ archivePath: String, _ entryPath: String, _ password: String?) async throws -> Data?,
            listEntrySizes: @escaping @Sendable (_ archivePath: String, _ password: String?) throws -> [(path: String, size: UInt64)]
        ) {
            self.readEntry = readEntry
            self.listEntrySizes = listEntrySizes
        }

        package static let archiveRuntime = Self(
            readEntry: { archivePath, entryPath, password in
                try await ArchiveRuntime.readEntry(
                    archivePath: archivePath,
                    entryPath: entryPath,
                    password: password
                )
            },
            listEntrySizes: { archivePath, password in
                try ArchiveRuntime.entrySizes(archivePath: archivePath, password: password)
            }
        )
    }
}
