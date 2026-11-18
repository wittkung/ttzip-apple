// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import TTZipSearchKit

public enum DirectorySearchComposition {
    public static func makeScanner(
        customDatalessDetector: (@Sendable (String, UInt32) -> Bool)? = nil,
        entryVisitHook: (@Sendable (String, Int) throws -> Void)? = nil,
        scanTerminationHook: (@Sendable (Bool, Int) -> Void)? = nil
    ) -> DefaultDirectoryRecursiveScanner {
        DefaultDirectoryRecursiveScanner(
            archiveExtensions: SpotlightArchiveSearchProvider.supportedArchiveExtensions,
            withMaterializationDisabled: DatalessProtection.withMaterializationDisabled,
            customDatalessDetector: customDatalessDetector,
            entryVisitHook: entryVisitHook,
            scanTerminationHook: scanTerminationHook
        )
    }
}
