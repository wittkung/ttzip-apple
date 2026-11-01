// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import Combine

// MARK: - EPUB In-Book Pagination Controller

@MainActor
public final class EPUBPaginationController: ObservableObject {
    public let instanceID: UUID
    @Published public private(set) var currentChapterIndex: Int
    @Published public private(set) var totalChapters: Int
    @Published public private(set) var currentPageIndex: Int
    @Published public private(set) var totalPagesInChapter: Int
    @Published public private(set) var readingDirection: EPUBReadingDirection
    @Published public private(set) var pendingLanding: EPUBBoundaryLanding
    @Published public private(set) var boundaryNotice: EPUBBookBoundaryNotice
    @Published public private(set) var anchorBlockIndex: Int?
    @Published public private(set) var anchorCharOffset: Int = 0
    @Published public private(set) var normalizedProgressInChapter: Double
    @Published public private(set) var latestFirstScreenMetrics: EPUBFirstScreenPerfMetrics?
    @Published public private(set) var isChapterTransitionInFlight: Bool = false
    /// `true` only after WebKit has reported a real pagination snapshot for the current chapter of the
    /// current book generation. While `false`, `totalPagesInChapter == 1` is a placeholder and must never
    /// be treated as a genuinely single-page chapter.
    @Published public private(set) var isPaginationReady: Bool = false
    /// Incremented on every `configureBook`. Stale WebKit callbacks carrying an older generation are dropped.
    @Published public private(set) var bookGeneration: Int = 0
    @Published public private(set) var layoutMode: EPUBReadingLayoutMode = .paginated

    public var onRequestWebViewPageJump: (@MainActor (Int) -> Void)?
    public var onRequestChapterIndexChange: (@MainActor (Int, EPUBBoundaryLanding) -> Void)?
    public var onRequestRestoreReaderFocus: (@MainActor () -> Void)?
    public var onRequestAnchorJump: (@MainActor (Int, Int, Double) -> Void)?
    public var onRequestVerticalScroll: (@MainActor (Bool) -> Void)?

    private var queuedForwardFlags: [Bool] = []
    private let maxQueuedSteps = 16

    public init(
        instanceID: UUID = UUID(),
        initialChapterIndex: Int = 0,
        totalChapters: Int = 1,
        readingDirection: EPUBReadingDirection = .leftToRight,
        layoutMode: EPUBReadingLayoutMode = .paginated
    ) {
        self.instanceID = instanceID
        self.currentChapterIndex = max(0, initialChapterIndex)
        self.totalChapters = max(1, totalChapters)
        self.currentPageIndex = 0
        self.totalPagesInChapter = 1
        self.readingDirection = readingDirection
        self.pendingLanding = .firstPage
        self.boundaryNotice = .none
        self.anchorBlockIndex = 0
        self.anchorCharOffset = 0
        self.normalizedProgressInChapter = 0.0
        self.layoutMode = layoutMode
    }

    public func configureBook(totalChapters: Int, initialChapterIndex: Int = 0) {
        let clampedTotal = max(1, totalChapters)
        bookGeneration &+= 1
        self.totalChapters = clampedTotal
        self.currentChapterIndex = min(max(0, initialChapterIndex), clampedTotal - 1)
        self.currentPageIndex = 0
        self.totalPagesInChapter = 1
        self.anchorBlockIndex = 0
        self.anchorCharOffset = 0
        self.normalizedProgressInChapter = 0.0
        self.pendingLanding = .firstPage
        self.boundaryNotice = .none
        self.isChapterTransitionInFlight = true
        self.isPaginationReady = false
        self.queuedForwardFlags.removeAll()
    }

    /// Marks the start of a chapter content load. Page counts become placeholders until WebKit reports
    /// a real pagination snapshot for this chapter; direction keys are queued instead of crossing chapters.
    ///
    /// Intentionally does not require `chapterIndex == currentChapterIndex`: internal link navigation calls
    /// this before SwiftUI has committed the new `selectedChapterIndex`, and a stale "ready + 1 page" state
    /// during that window would let the next arrow key skip a chapter.
    public func beginChapterLoad(chapterIndex: Int) {
        totalPagesInChapter = 1
        currentPageIndex = 0
        isPaginationReady = false
        isChapterTransitionInFlight = true
        queuedForwardFlags.removeAll()
    }

    /// Restores a persisted reading position without requiring the chapter index to change.
    ///
    /// `selectChapterExplicitly` deliberately short-circuits when the target chapter equals the current
    /// one, which would silently drop the saved anchor on reopen. This entry point keeps the landing.
    public func restoreReadingPosition(chapterIndex: Int, landing: EPUBBoundaryLanding) {
        let target = min(max(0, chapterIndex), max(totalChapters - 1, 0))
        currentChapterIndex = target
        currentPageIndex = 0
        totalPagesInChapter = 1
        pendingLanding = landing
        boundaryNotice = .none
        isPaginationReady = false
        isChapterTransitionInFlight = true
        queuedForwardFlags.removeAll()
    }

    public func setLayoutMode(_ mode: EPUBReadingLayoutMode) {
        self.layoutMode = mode
    }

    public func setReadingDirection(_ direction: EPUBReadingDirection) {
        self.readingDirection = direction
    }

    public func prepareAnchorPreservationBeforeRelayout() {
        self.pendingLanding = .preserveAnchor(
            progressRatio: normalizedProgressInChapter,
            anchorBlockIndex: anchorBlockIndex,
            anchorCharOffset: anchorCharOffset
        )
    }

    public func selectChapterExplicitly(
        _ index: Int,
        landing: EPUBBoundaryLanding = .firstPage
    ) {
        let target = min(max(0, index), max(totalChapters - 1, 0))
        guard target != currentChapterIndex || isChapterTransitionInFlight else {
            if case .firstPage = landing {
                jumpToPageInCurrentChapter(0)
            } else if case .lastPage = landing {
                jumpToPageInCurrentChapter(max(totalPagesInChapter - 1, 0))
            }
            return
        }
        currentChapterIndex = target
        pendingLanding = landing
        isChapterTransitionInFlight = true
        isPaginationReady = false
        boundaryNotice = .none
        onRequestChapterIndexChange?(target, landing)
    }

    @discardableResult
    public func handleHorizontalArrow(isRightArrow: Bool) -> EPUBPageTurnStepOutcome {
        let isForward = readingDirection.isForwardStep(forRightArrow: isRightArrow)
        return stepLogical(isForward: isForward)
    }

    @discardableResult
    public func handleVerticalArrow(isDownArrow: Bool) -> Bool {
        guard layoutMode == .scrolling else { return false }
        onRequestVerticalScroll?(isDownArrow)
        return true
    }

    @discardableResult
    public func stepLogical(isForward: Bool) -> EPUBPageTurnStepOutcome {
        if !isPaginationReady || isChapterTransitionInFlight {
            if queuedForwardFlags.count < maxQueuedSteps {
                queuedForwardFlags.append(isForward)
            }
            return .deferredUntilPaginationReady
        }
        return executeImmediateStep(isForward: isForward)
    }

    private func executeImmediateStep(isForward: Bool) -> EPUBPageTurnStepOutcome {
        isForward ? executeForwardStep() : executeBackwardStep()
    }

    private func executeForwardStep() -> EPUBPageTurnStepOutcome {
        if currentPageIndex + 1 < totalPagesInChapter {
            let nextPage = currentPageIndex + 1
            currentPageIndex = nextPage
            updateNormalizedProgress()
            boundaryNotice = .none
            onRequestWebViewPageJump?(nextPage)
            return .turnedPageInChapter(
                chapterIndex: currentChapterIndex, pageIndex: nextPage, totalPages: totalPagesInChapter
            )
        }
        if currentChapterIndex + 1 < totalChapters {
            let fromChapter = currentChapterIndex
            let nextChapter = currentChapterIndex + 1
            currentChapterIndex = nextChapter
            currentPageIndex = 0
            totalPagesInChapter = 1
            pendingLanding = .firstPage
            boundaryNotice = .none
            isChapterTransitionInFlight = true
            isPaginationReady = false
            onRequestChapterIndexChange?(nextChapter, .firstPage)
            return .transitionedChapter(
                fromChapter: fromChapter, toChapter: nextChapter, landing: .firstPage
            )
        }
        boundaryNotice = .bookEnd
        return .clampedAtBookEnd(
            chapterIndex: currentChapterIndex, pageIndex: currentPageIndex, totalPages: totalPagesInChapter
        )
    }

    private func executeBackwardStep() -> EPUBPageTurnStepOutcome {
        if currentPageIndex > 0 {
            let prevPage = currentPageIndex - 1
            currentPageIndex = prevPage
            updateNormalizedProgress()
            boundaryNotice = .none
            onRequestWebViewPageJump?(prevPage)
            return .turnedPageInChapter(
                chapterIndex: currentChapterIndex, pageIndex: prevPage, totalPages: totalPagesInChapter
            )
        }
        if currentChapterIndex > 0 {
            let fromChapter = currentChapterIndex
            let prevChapter = currentChapterIndex - 1
            currentChapterIndex = prevChapter
            currentPageIndex = 0
            totalPagesInChapter = 1
            pendingLanding = .lastPage
            boundaryNotice = .none
            isChapterTransitionInFlight = true
            isPaginationReady = false
            onRequestChapterIndexChange?(prevChapter, .lastPage)
            return .transitionedChapter(
                fromChapter: fromChapter, toChapter: prevChapter, landing: .lastPage
            )
        }
        boundaryNotice = .bookStart
        return .clampedAtBookStart(chapterIndex: 0, pageIndex: 0)
    }

    public func didSynchronizeWebViewPagination(
        chapterIndex: Int,
        pageIndex: Int,
        totalPages: Int,
        anchorBlockIndex: Int?,
        anchorCharOffset: Int = 0,
        readingDirectionRaw: String?,
        bookGeneration: Int? = nil,
        isLayoutReady: Bool = true
    ) {
        if let bookGeneration, bookGeneration != self.bookGeneration { return }
        guard chapterIndex == currentChapterIndex else { return }
        let clampedTotal = max(1, totalPages)
        let clampedPage = min(max(0, pageIndex), clampedTotal - 1)
        self.totalPagesInChapter = clampedTotal
        self.currentPageIndex = clampedPage
        self.anchorBlockIndex = anchorBlockIndex
        self.anchorCharOffset = max(0, anchorCharOffset)
        if let raw = readingDirectionRaw, let resolved = EPUBReadingDirection(rawValue: raw) {
            self.readingDirection = resolved
        }
        updateNormalizedProgress()
        guard isLayoutReady else {
            isPaginationReady = false
            isChapterTransitionInFlight = true
            return
        }
        self.isPaginationReady = true
        self.isChapterTransitionInFlight = false
        self.pendingLanding = .preserveAnchor(
            progressRatio: normalizedProgressInChapter,
            anchorBlockIndex: anchorBlockIndex,
            anchorCharOffset: self.anchorCharOffset
        )
        drainQueuedStepsIfNeeded()
    }

    public func recordFirstScreenMetrics(_ metrics: EPUBFirstScreenPerfMetrics) {
        self.latestFirstScreenMetrics = metrics
    }

    /// Keeps the page indicator in sync when vertical scrolling hits a chapter boundary.
    /// Deliberately does not change `boundaryNotice` or the chapter: scrolling never crosses chapters.
    public func synchronizeScrollingPageIndex(_ pageIndex: Int?) {
        guard let pageIndex else { return }
        currentPageIndex = min(max(0, pageIndex), max(totalPagesInChapter - 1, 0))
        updateNormalizedProgress()
    }

    public func navigateToAnchor(chapterIndex: Int, blockIndex: Int, characterOffset: Int, ratio: Double) {
        guard (0..<totalChapters).contains(chapterIndex) else { return }
        if chapterIndex == currentChapterIndex && isPaginationReady {
            onRequestAnchorJump?(blockIndex, characterOffset, ratio)
        } else {
            selectChapterExplicitly(chapterIndex, landing: .preserveAnchor(
                progressRatio: ratio, anchorBlockIndex: blockIndex, anchorCharOffset: characterOffset
            ))
        }
    }

    public func jumpToPageInCurrentChapter(_ targetPage: Int) {
        guard isPaginationReady else { return }
        let clamped = min(max(0, targetPage), max(totalPagesInChapter - 1, 0))
        currentPageIndex = clamped
        updateNormalizedProgress()
        boundaryNotice = .none
        onRequestWebViewPageJump?(clamped)
    }

    public var estimatedOverallBookProgress: Double {
        guard totalChapters > 0 else { return 0.0 }
        let chapterBase = Double(currentChapterIndex) / Double(totalChapters)
        let chapterContribution = normalizedProgressInChapter / Double(totalChapters)
        return min(1.0, max(0.0, chapterBase + chapterContribution))
    }

    private func updateNormalizedProgress() {
        if totalPagesInChapter <= 1 {
            normalizedProgressInChapter = 0.0
        } else {
            normalizedProgressInChapter = Double(currentPageIndex) / Double(totalPagesInChapter - 1)
        }
    }

    private func drainQueuedStepsIfNeeded() {
        while !isChapterTransitionInFlight, !queuedForwardFlags.isEmpty {
            let nextFlag = queuedForwardFlags.removeFirst()
            _ = executeImmediateStep(isForward: nextFlag)
        }
    }
}
