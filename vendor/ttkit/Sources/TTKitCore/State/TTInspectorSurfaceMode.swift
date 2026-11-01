// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Discriminated union for contextual inspector surface modes conforming to TTKit Architecture Spec §5.
public enum TTInspectorSurfaceMode<Item: Sendable, Metrics: Sendable, Context: Sendable>: Sendable, Equatable where Item: Equatable, Metrics: Equatable, Context: Equatable {
    case empty
    case single(item: Item)
    case multiple(metrics: Metrics)
    case workspace(context: Context)

    public var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }

    public var isSingle: Bool {
        if case .single = self { return true }
        return false
    }

    public var isMultiple: Bool {
        if case .multiple = self { return true }
        return false
    }

    public var isWorkspace: Bool {
        if case .workspace = self { return true }
        return false
    }
}
