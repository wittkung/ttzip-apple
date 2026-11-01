// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import SwiftUI
import TTZipCore
import TTZipUI

extension FinderMillerColumnsView {
    func isArchiveLocation(_ location: URL) -> Bool {
        guard AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(location) else { return false }
        if URLComponents(url: location, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "subpath" }) == true { return true }
        guard let owner = activeViewModel else { return false }
        return owner.navigationState.activeTabSession?.archivePath == location.path
            || owner.explorerState.acceptedArchiveProjection(
            for: owner.navigationState.activeSessionID, archivePath: location.path
        ) != nil
    }

    /// Derives visible columns from the owner's location, not from an independent history.
    /// An explicit marker can be displayed while its owner-controlled reload is pending.
    public static func restoredArchiveColumnPaths(
        location: URL,
        projection: AcceptedArchiveDirectoryProjection?,
        preserving currentPaths: [URL]
    ) -> [URL]? {
        guard let sequence = archiveColumnSequence(location: location, projection: projection),
              let root = sequence.columns.first else { return nil }
        return columnsRetainingParentPrefix(
            currentPaths: currentPaths, archiveColumns: sequence.columns,
            archiveRoot: root, physicalParent: sequence.physicalParent
        )
    }

    /// Constructs the archive's own column chain from its validated address and accepted tree.
    private static func archiveColumnSequence(
        location: URL, projection: AcceptedArchiveDirectoryProjection?
    ) -> (columns: [URL], physicalParent: URL)? {
        guard AcceptedArchiveDirectoryProjection.isLocalArchiveAddress(location),
              var components = URLComponents(url: location, resolvingAgainstBaseURL: false) else { return nil }
        if components.percentEncodedQuery == nil, projection != nil {
            components.queryItems = [URLQueryItem(name: "subpath", value: "")]
        }
        guard let markedLocation = components.url,
              let subpath = AcceptedArchiveDirectoryProjection.archiveSubpath(in: markedLocation) else { return nil }
        if let projection, location.standardizedFileURL.path != projection.archivePath { return nil }
        components.queryItems = nil
        guard let physicalArchive = components.url else { return nil }
        func columnURL(_ subpath: String) -> URL? {
            guard let encoded = AppViewState.makeArchiveEntryVirtualURL(
                archivePath: physicalArchive.path, entrySubpath: subpath
            ).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedQuery }) else { return nil }
            var visible = components
            visible.percentEncodedQuery = [components.percentEncodedQuery, encoded]
                .compactMap { $0 }.joined(separator: "&")
            return visible.url
        }
        guard let root = columnURL("") else { return nil }
        var archiveColumns = [root]
        var partial = ""
        for segment in subpath.split(separator: "/", omittingEmptySubsequences: false) where !subpath.isEmpty {
            partial = partial.isEmpty ? String(segment) : partial + "/" + String(segment)
            if let projection, projection.subpaths[partial]?.isDirectory != true { return nil }
            guard let step = columnURL(partial) else { return nil }
            archiveColumns.append(step)
        }

        return (archiveColumns, physicalArchive.deletingLastPathComponent())
    }

    /// Reuses visible filesystem columns without treating their transient order as history.
    private static func columnsRetainingParentPrefix(
        currentPaths: [URL], archiveColumns: [URL], archiveRoot: URL, physicalParent: URL
    ) -> [URL] {
        if let rootIndex = currentPaths.firstIndex(where: { sameColumnLocation($0, archiveRoot) }) {
            return Array(currentPaths.prefix(rootIndex)) + archiveColumns
        }
        if let parentIndex = currentPaths.firstIndex(where: { sameColumnLocation($0, physicalParent) }) {
            return Array(currentPaths.prefix(parentIndex + 1)) + archiveColumns
        }
        return [physicalParent] + archiveColumns
    }

    private static func sameColumnLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        func identity(_ url: URL) -> URL {
            let location = WorkspaceHistoryStack.standardizedLocation(url)
            guard var components = URLComponents(url: location, resolvingAgainstBaseURL: false) else { return location }
            if components.percentEncodedPath.count > 1, components.percentEncodedPath.hasSuffix("/") {
                components.percentEncodedPath.removeLast()
            }
            let items = components.queryItems ?? []
            let known = items.filter { $0.name == "subpath" }
            if known.count == 1, known.first?.value == "" {
                components.queryItems = items.filter { $0.name != "subpath" }
                if components.queryItems?.isEmpty == true { components.queryItems = nil }
            }
            return components.url ?? location
        }
        return identity(lhs) == identity(rhs)
    }

    @discardableResult
    func restoreArchiveColumns(for location: URL) -> Bool {
        let projection = activeViewModel.flatMap { owner in
            owner.explorerState.acceptedArchiveProjection(
                for: owner.navigationState.activeSessionID, archivePath: location.path
            )
        }
        guard let paths = Self.restoredArchiveColumnPaths(
            location: location, projection: projection, preserving: columnPaths
        ) else { return false }
        var restoredSelection: [Int: String] = [:]
        for index in paths.indices.dropLast() {
            let next = paths[index + 1]
            let subpath = URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "subpath" })?.value
            restoredSelection[index] = subpath?.isEmpty == false ? next.absoluteString : next.path
        }
        let previousSelection = selectedItem
        let selectionColumn = previousSelection.flatMap { item in
            paths.indices.first { index in
                let sort = perColumnSortOption[index] ?? sortOption
                return cachedColumnItems["\(paths[index].absoluteString)_\(sort.rawValue)"]?
                    .contains(where: { $0.path == item.path }) == true
            }
        }
        if let previousSelection, let selectionColumn {
            restoredSelection[selectionColumn] = previousSelection.path
        } else {
            selectedItem = nil
            activeViewModel?.selectionState.clear()
        }
        columnPaths = paths
        selectedPaths = restoredSelection
        multiSelectedPaths = previousSelection.flatMap { selectionColumn == nil ? nil : Set([$0.path]) } ?? []
        activeViewModel?.activeBrowsingDirectory = paths.last
        scrollTarget = paths.last.map { HorizontalScrollTarget(id: $0.absoluteString, anchor: .trailing) }
        return true
    }
}
