// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore

/// The existing reader result projected for directory listing. No credential or navigation owner.
public struct AcceptedArchiveDirectoryProjection: Sendable {
    public let archivePath: String
    public let entries: [ArchiveEntry]
    public let subpaths: ArchiveSubpathMap

    public init(inspection: ArchiveInspectionResult) {
        self.archivePath = URL(fileURLWithPath: inspection.archivePath).standardizedFileURL.path
        self.entries = inspection.entries
        self.subpaths = ArchiveSubpathMap(rootComposite: inspection.treeNode)
    }
}
