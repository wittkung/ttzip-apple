// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

// MARK: - EPUB Reading Layout Mode

public enum EPUBReadingLayoutMode: String, Sendable, CaseIterable {
    case paginated = "paginated"
    case scrolling = "scrolling"
}

/// Resolves the persisted reading-layout preference without ever inventing a new default.
///
/// The product contract is: a first launch (no stored value) or an unparsable legacy value
/// falls back to horizontal auto-pagination, while an explicit `scrolling` preference chosen by
/// the user must survive relaunches.
public enum EPUBReadingLayoutPreference {
    public static let defaultMode: EPUBReadingLayoutMode = .paginated

    public static func resolve(stored: String?) -> EPUBReadingLayoutMode {
        guard let stored, !stored.isEmpty,
              let mode = EPUBReadingLayoutMode(rawValue: stored) else {
            return defaultMode
        }
        return mode
    }
}

// MARK: - EPUB Reading Direction, Boundary Landing & Stage Telemetry

public enum EPUBReadingDirection: String, Sendable, Equatable {
    case leftToRight = "ltr"
    case rightToLeft = "rtl"
    case verticalRightToLeft = "vertical-rl"

    public func isForwardStep(forRightArrow isRightArrow: Bool) -> Bool {
        switch self {
        case .leftToRight:
            return isRightArrow
        case .rightToLeft, .verticalRightToLeft:
            return !isRightArrow
        }
    }
}

public enum EPUBBoundaryLanding: Sendable, Equatable {
    case firstPage
    case lastPage
    case preserveAnchor(progressRatio: Double, anchorBlockIndex: Int?, anchorCharOffset: Int = 0)
    case fragment(String)
}

public enum EPUBBookBoundaryNotice: String, Sendable, Equatable {
    case none
    case bookStart
    case bookEnd
}

public enum EPUBPageTurnStepOutcome: Sendable, Equatable {
    case turnedPageInChapter(chapterIndex: Int, pageIndex: Int, totalPages: Int)
    case transitionedChapter(fromChapter: Int, toChapter: Int, landing: EPUBBoundaryLanding)
    case clampedAtBookStart(chapterIndex: Int, pageIndex: Int)
    case clampedAtBookEnd(chapterIndex: Int, pageIndex: Int, totalPages: Int)
    /// The page count of the current chapter is still a placeholder: layout has not been measured yet.
    /// The step has been queued and will be drained in order once the WebKit pagination snapshot arrives.
    case deferredUntilPaginationReady
}

/// Records the chapter-loading stage durations up to the WebKit JavaScript multi-column pagination callback.
public struct EPUBFirstScreenPerfMetrics: Sendable, Equatable {
    public let chapterURL: URL
    public let isVFSSource: Bool
    public let chapterReadMs: Double
    public let resourceAuthAndInlineMs: Double
    public let webKitLoadToFinishMs: Double
    public let firstPaginationLayoutCallbackMs: Double
    public let totalToPaginationCallbackMs: Double
    public let inlinedResourceCount: Int
    public let authenticatedCacheHitCount: Int
    public let initialPageCount: Int

    public var firstPaginationAndPaintMs: Double {
        firstPaginationLayoutCallbackMs
    }

    public var totalFirstScreenMs: Double {
        totalToPaginationCallbackMs
    }

    public init(
        chapterURL: URL,
        isVFSSource: Bool,
        chapterReadMs: Double,
        resourceAuthAndInlineMs: Double,
        webKitLoadToFinishMs: Double,
        firstPaginationLayoutCallbackMs: Double,
        totalToPaginationCallbackMs: Double,
        inlinedResourceCount: Int,
        authenticatedCacheHitCount: Int,
        initialPageCount: Int
    ) {
        self.chapterURL = chapterURL
        self.isVFSSource = isVFSSource
        self.chapterReadMs = chapterReadMs
        self.resourceAuthAndInlineMs = resourceAuthAndInlineMs
        self.webKitLoadToFinishMs = webKitLoadToFinishMs
        self.firstPaginationLayoutCallbackMs = firstPaginationLayoutCallbackMs
        self.totalToPaginationCallbackMs = totalToPaginationCallbackMs
        self.inlinedResourceCount = inlinedResourceCount
        self.authenticatedCacheHitCount = authenticatedCacheHitCount
        self.initialPageCount = initialPageCount
    }

    public init(
        chapterURL: URL,
        isVFSSource: Bool,
        chapterReadMs: Double,
        resourceAuthAndInlineMs: Double,
        webKitLoadToFinishMs: Double,
        firstPaginationAndPaintMs: Double,
        totalFirstScreenMs: Double,
        inlinedResourceCount: Int,
        authenticatedCacheHitCount: Int,
        initialPageCount: Int
    ) {
        self.init(
            chapterURL: chapterURL,
            isVFSSource: isVFSSource,
            chapterReadMs: chapterReadMs,
            resourceAuthAndInlineMs: resourceAuthAndInlineMs,
            webKitLoadToFinishMs: webKitLoadToFinishMs,
            firstPaginationLayoutCallbackMs: firstPaginationAndPaintMs,
            totalToPaginationCallbackMs: totalFirstScreenMs,
            inlinedResourceCount: inlinedResourceCount,
            authenticatedCacheHitCount: authenticatedCacheHitCount,
            initialPageCount: initialPageCount
        )
    }
}

// MARK: - Keyboard Contracts & Query Types

public enum TTPreviewKeyboardContractVersion: String, Sendable {
    case v1 = "1.0.0"
    case v2 = "2.0.0"
}

public enum TTPreviewFocusSource: String, Sendable, Equatable {
    case none
    case readingArea
    case toolbarOrPopover
}

public enum TTPreviewKeyboardDisposition: String, Sendable, Equatable {
    case passThrough
    case consumedByPreviewOwner
    case yieldToTextInput
}

public struct TTPreviewKeyboardOwnershipQuery: Sendable, Equatable {
    public let contractVersion: TTPreviewKeyboardContractVersion
    public let ownsHorizontalArrowKeys: Bool
    public let ownsVerticalArrowKeys: Bool
    public let isTextInputActive: Bool
    public let isEventAlreadyHandled: Bool
    public let focusSource: TTPreviewFocusSource
    public let ownerInstanceID: UUID?
    public let windowNumber: Int?

    public init(
        contractVersion: TTPreviewKeyboardContractVersion = .v2,
        ownsHorizontalArrowKeys: Bool,
        ownsVerticalArrowKeys: Bool = false,
        isTextInputActive: Bool,
        isEventAlreadyHandled: Bool,
        focusSource: TTPreviewFocusSource = .none,
        ownerInstanceID: UUID?,
        windowNumber: Int?
    ) {
        self.contractVersion = contractVersion
        self.ownsHorizontalArrowKeys = ownsHorizontalArrowKeys
        self.ownsVerticalArrowKeys = ownsVerticalArrowKeys
        self.isTextInputActive = isTextInputActive
        self.isEventAlreadyHandled = isEventAlreadyHandled
        self.focusSource = focusSource
        self.ownerInstanceID = ownerInstanceID
        self.windowNumber = windowNumber
    }
}
