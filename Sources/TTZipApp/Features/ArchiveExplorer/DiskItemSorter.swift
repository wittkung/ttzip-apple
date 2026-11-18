// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import TTZipCore
import TTZipUI
import TTZipPreviewKit

/// Multi-dimensional sorting strategy engine for disk and archive entries.
public enum DiskItemSorter {
    
    /// Sorts DiskItemInfo array deterministically according to chosen sort option.
    public static func sort(_ items: [DiskItemInfo], by option: DiskSortOption) -> [DiskItemInfo] {
        return items.sorted { isOrderedBefore($0, $1, option: option) }
    }
    
    /// Evaluates strict partial ordering ($a < $b) between two DiskItemInfo entries.
    public static func isOrderedBefore(_ a: DiskItemInfo, _ b: DiskItemInfo, option: DiskSortOption) -> Bool {
        if a.isDirectory != b.isDirectory {
            return a.isDirectory
        }
        if let primaryOrder = comparePrimarySortKey(a, b, option: option) {
            return primaryOrder
        }
        let nameCmp = a.name.localizedStandardCompare(b.name)
        if nameCmp != .orderedSame {
            return nameCmp == .orderedAscending
        }
        return a.path.compare(b.path) == .orderedAscending
    }

    private static func comparePrimarySortKey(
        _ a: DiskItemInfo,
        _ b: DiskItemInfo,
        option: DiskSortOption
    ) -> Bool? {
        switch option {
        case .nameAsc:
            return compareStrings(a.name, b.name, ascending: true)
        case .nameDesc:
            return compareStrings(a.name, b.name, ascending: false)
        case .sizeDesc:
            return a.rawSizeBytes == b.rawSizeBytes ? nil : (a.rawSizeBytes > b.rawSizeBytes)
        case .sizeAsc:
            return a.rawSizeBytes == b.rawSizeBytes ? nil : (a.rawSizeBytes < b.rawSizeBytes)
        case .dateDesc:
            return compareOptionalDates(a.modificationDate, b.modificationDate, ascending: false)
        case .dateAsc:
            return compareOptionalDates(a.modificationDate, b.modificationDate, ascending: true)
        case .kind:
            return compareStrings(a.kindText, b.kindText, ascending: true)
        }
    }

    private static func compareStrings(_ lhs: String, _ rhs: String, ascending: Bool) -> Bool? {
        let cmp = lhs.localizedStandardCompare(rhs)
        guard cmp != .orderedSame else { return nil }
        return ascending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
    }

    private static func compareOptionalDates(_ lhs: Date?, _ rhs: Date?, ascending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case let (dateA?, dateB?):
            guard dateA != dateB else { return nil }
            return ascending ? (dateA < dateB) : (dateA > dateB)
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return nil
        }
    }
}
