// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import TTZipUI

extension FinderMillerColumnsView {
    func loadColumnContents(index: Int, dirURL: URL, currentSort: DiskSortOption, cacheKey: String) async {
        guard cachedColumnItems[cacheKey] == nil else { return }
        let expectedSessionID = activeViewModel?.navigationState.activeSessionID
        let projection = expectedSessionID.flatMap { sessionID in
            activeViewModel?.explorerState.acceptedArchiveProjection(
                for: sessionID, archivePath: dirURL.path
            )
        }
        guard let sorted = await readColumnContents(
            index: index, dirURL: dirURL, currentSort: currentSort, projection: projection
        ) else { return }
        acceptColumnContents(
            sorted, index: index, dirURL: dirURL, cacheKey: cacheKey,
            expectedSessionID: expectedSessionID, projection: projection
        )
    }

    /// Selection of a reader is separate from publication; missing accepted catalogs stay owner work.
    private func readColumnContents(
        index: Int, dirURL: URL, currentSort: DiskSortOption,
        projection: AcceptedArchiveDirectoryProjection?
    ) async -> [DiskItemInfo]? {
        if let projection {
            return await MillerColumnDirectoryScanner.loadAcceptedArchiveContents(
                dirURL: dirURL, sortOption: currentSort, projection: projection
            )
        }
        guard !isArchiveLocation(dirURL) else { return nil }
        let winID = activeViewModel?.windowID
        let scopeID = "window_\(winID?.uuidString ?? "default")_col_\(index)"
        return await MillerColumnDirectoryScanner.loadPhysicalContentsResult(
            dirURL: dirURL, sortOption: currentSort, scopeID: scopeID
        )
    }

    /// Validation and publication remain one synchronous owner acceptance block.
    private func acceptColumnContents(
        _ sorted: [DiskItemInfo], index: Int, dirURL: URL, cacheKey: String,
        expectedSessionID: UUID?, projection: AcceptedArchiveDirectoryProjection?
    ) {
        if let projection {
            guard let sessionID = expectedSessionID,
                  let accepted = activeViewModel?.explorerState.acceptedArchiveProjection(
                    for: sessionID, archivePath: dirURL.path
                  ), accepted.entries == projection.entries else { return }
        }
        guard !Task.isCancelled,
              activeViewModel?.navigationState.activeSessionID == expectedSessionID,
              columnPaths.indices.contains(index), columnPaths[index] == dirURL else { return }
        cachedColumnItems[cacheKey] = sorted
        pruneInactiveColumnCache()
    }

    private func pruneInactiveColumnCache() {
        guard cachedColumnItems.count > 64 else { return }
        let activeKeys = Set(columnPaths.enumerated().map { index, path in
            let sort = perColumnSortOption[index] ?? sortOption
            return "\(path.absoluteString)_\(sort.rawValue)"
        })
        for key in Array(cachedColumnItems.keys) where !activeKeys.contains(key) {
            cachedColumnItems.removeValue(forKey: key)
        }
    }
}
