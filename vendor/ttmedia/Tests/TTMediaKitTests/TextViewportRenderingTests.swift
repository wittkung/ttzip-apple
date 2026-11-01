// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import SwiftUI
import XCTest
@testable import TTMediaKit

@MainActor
final class TextViewportRenderingTests: XCTestCase {
    func testZeroSizeMountThenViewportPaintsSRTAcrossBackgrounds() throws {
        let source = "1\n00:00:01,000 --> 00:00:03,000\n中文正文 Visible subtitle\n\n2\n00:00:04,000 --> 00:00:06,000\nNext subtitle"
        let editor = CodeHighlightingEditorNSView(text: .constant(source), fileName: "Timeline.srt")
        let coordinator = editor.makeCoordinator()
        let scroll = editor.makeEditorScrollView(coordinator: coordinator)
        let text = try XCTUnwrap(scroll.documentView as? LargeTextEditorTextView)
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        for mode in TTTextReadingBackgroundMode.allCases {
            let palette = TTTextReadingPalette.resolve(mode: mode, isDarkAppearance: true)
            coordinator.applyReadingTheme(palette, to: text, scrollView: scroll, recolorStorage: true)
            scroll.tile()
            try assertVisibleText(text, source: source)
            if mode != .fluidTransparent {
                try assertBodyPainted(text, dark: mode == .black)
            }
        }
        coordinator.cancelPendingTasks()
    }

    func testNarrowAndWideResizesPreserveSelectionAndBodyGlyphs() throws {
        let source = (0..<400).map { "\($0) 中文字幕 line with JSON \"value\": 42" }.joined(separator: "\n")
        let editor = CodeHighlightingEditorNSView(text: .constant(source), fileName: "subtitle.srt")
        let coordinator = editor.makeCoordinator()
        let scroll = editor.makeEditorScrollView(coordinator: coordinator)
        let text = try XCTUnwrap(scroll.documentView as? LargeTextEditorTextView)
        text.setSelectedRange(NSRange(location: 3, length: 4))
        for width in [280.0, 720.0, 340.0] {
            scroll.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            scroll.tile()
            scroll.layoutSubtreeIfNeeded()
            try assertVisibleText(text, source: source)
            XCTAssertEqual(text.selectedRange(), NSRange(location: 3, length: 4))
        }
        coordinator.cancelPendingTasks()
    }

    private func assertVisibleText(_ text: NSTextView, source: String) throws {
        XCTAssertEqual(text.string, source)
        XCTAssertGreaterThan(text.frame.width, 0)
        XCTAssertGreaterThan(text.frame.height, 0)
        XCTAssertTrue(text.frame.width.isFinite)
        let manager = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        let range = manager.glyphRange(forCharacterRange: NSRange(location: 0, length: min(40, text.string.utf16.count)), actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: range, in: container)
            .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
        XCTAssertFalse(rect.isEmpty)
        XCTAssertTrue(rect.intersects(text.visibleRect), "Body glyphs must intersect the real viewport, not merely exist in storage")
    }

    private func assertBodyPainted(_ text: NSTextView, dark: Bool) throws {
        let rect = NSRect(x: 0, y: 0, width: min(text.bounds.width, 400), height: min(text.bounds.height, 150))
        let bitmap = try XCTUnwrap(text.bitmapImageRepForCachingDisplay(in: rect))
        text.cacheDisplay(in: rect, to: bitmap)
        var ink = 0
        for y in 8..<min(bitmap.pixelsHigh, 120) {
            for x in 8..<min(bitmap.pixelsWide, 390) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = TTTextReadingPalette.relativeLuminance(of: color)
                if dark ? luminance > 0.3 : luminance < 0.4 { ink += 1 }
            }
        }
        XCTAssertGreaterThan(ink, 20, "The document body must paint contrasting pixels independently of the ruler")
    }

    // MARK: - Bounded Controllable Tokenizer Backend & Task Completion Observer for IME Tests

    private final class BoundedIMESyntaxBackend: SyntaxTokenizingBackend, @unchecked Sendable {
        private struct CallGate {
            var isReleased: Bool
            let waiter: DispatchSemaphore
        }

        private let lock = NSLock()
        private var nextCallID: Int = 0
        private var gateNextCall: Bool = false
        private var stickyReleaseAll: Bool = false
        private var withholdReleaseOnTeardown: Bool = false
        private var enteredCallIDs: Set<Int> = []
        private var exitedCallIDs: Set<Int> = []
        private var gatesByCallID: [Int: CallGate] = [:]

        func setWithholdReleaseOnTeardown(_ enabled: Bool) {
            lock.lock()
            withholdReleaseOnTeardown = enabled
            lock.unlock()
        }

        func armHoldForNextCall() {
            lock.lock()
            stickyReleaseAll = false
            gateNextCall = true
            lock.unlock()
        }

        func disarmHoldForNextCall() {
            lock.lock()
            gateNextCall = false
            lock.unlock()
        }

        func callCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return nextCallID
        }

        func firstEnteredCall(after baselineCallID: Int) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            return enteredCallIDs.filter { $0 > baselineCallID }.min()
        }

        func hasExited(callID: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return exitedCallIDs.contains(callID)
        }

        func areAllEnteredCallsExited() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return exitedCallIDs.isSuperset(of: enteredCallIDs)
        }

        func tokenize(text: String, fileExtension: String, maxLength: Int) -> [TokenSpan] {
            lock.lock()
            nextCallID += 1
            let callID = nextCallID
            enteredCallIDs.insert(callID)
            let shouldHold = gateNextCall && !stickyReleaseAll
            let holdTimeout: Double = withholdReleaseOnTeardown ? 0.08 : 2.0
            gateNextCall = false
            let waiter: DispatchSemaphore?
            if shouldHold {
                let sem = DispatchSemaphore(value: 0)
                gatesByCallID[callID] = CallGate(isReleased: false, waiter: sem)
                waiter = sem
            } else {
                waiter = nil
            }
            lock.unlock()

            defer {
                lock.lock()
                gatesByCallID.removeValue(forKey: callID)
                exitedCallIDs.insert(callID)
                lock.unlock()
            }

            if let waiter {
                _ = waiter.wait(timeout: .now() + holdTimeout)
                if Task.isCancelled { return [] }
            }
            return BackgroundSyntaxTokenizer.defaultLexer(text: text, ext: fileExtension, maxLength: maxLength)
        }

        func releaseCall(callID: Int) {
            lock.lock()
            var waiterToSignal: DispatchSemaphore?
            if var gate = gatesByCallID[callID], !gate.isReleased {
                gate.isReleased = true
                gatesByCallID[callID] = gate
                waiterToSignal = gate.waiter
            }
            lock.unlock()
            waiterToSignal?.signal()
        }

        func releaseAllHolds(force: Bool = false) {
            lock.lock()
            if withholdReleaseOnTeardown && !force {
                gateNextCall = false
                lock.unlock()
                return
            }
            withholdReleaseOnTeardown = false
            stickyReleaseAll = true
            gateNextCall = false
            var waitersToSignal: [DispatchSemaphore] = []
            for (callID, var gate) in gatesByCallID where !gate.isReleased {
                gate.isReleased = true
                gatesByCallID[callID] = gate
                waitersToSignal.append(gate.waiter)
            }
            lock.unlock()
            for waiter in waitersToSignal {
                waiter.signal()
            }
        }

        func waitForEnteredCall(after baselineCallID: Int, timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Int? {
            let start = DispatchTime.now().uptimeNanoseconds
            while true {
                if let callID = firstEnteredCall(after: baselineCallID) {
                    return callID
                }
                if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                    return firstEnteredCall(after: baselineCallID)
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        func waitForExited(callID: Int, timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
            let start = DispatchTime.now().uptimeNanoseconds
            while !hasExited(callID: callID) {
                if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                    return hasExited(callID: callID)
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return true
        }

        func waitForAllInFlightCallsToExit(timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
            let start = DispatchTime.now().uptimeNanoseconds
            while !areAllEnteredCallsExited() {
                if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                    return areAllEnteredCallsExited()
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return true
        }
    }

    private final class HighlightTaskCompletionObserver: @unchecked Sendable {
        private let lock = NSLock()
        private var nextTicketID: Int = 0
        private var completedTickets: Set<Int> = []
        private var observedTasks: [Int: Task<Void, Never>] = [:]
        private var coordinators: [CodeHighlightingEditorNSView.Coordinator] = []

        @MainActor
        func registerCoordinator(_ coordinator: CodeHighlightingEditorNSView.Coordinator) {
            lock.lock()
            coordinators.append(coordinator)
            lock.unlock()
            if let initialTask = coordinator.currentHighlightTask {
                _ = observe(initialTask)
            }
        }

        func observe(_ task: Task<Void, Never>) -> Int {
            lock.lock()
            nextTicketID += 1
            let ticketID = nextTicketID
            observedTasks[ticketID] = task
            lock.unlock()

            Task.detached { [weak self] in
                _ = await task.value
                self?.markCompleted(ticketID: ticketID)
            }
            return ticketID
        }

        private func markCompleted(ticketID: Int) {
            lock.lock()
            completedTickets.insert(ticketID)
            lock.unlock()
        }

        func isCompleted(ticketID: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return completedTickets.contains(ticketID)
        }

        func areAllObservedTasksCompleted() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return completedTickets.count == observedTasks.count
        }

        @MainActor
        func cancelAllRegisteredCoordinators() {
            lock.lock()
            let registered = coordinators
            lock.unlock()
            for coord in registered {
                if let activeTask = coord.currentHighlightTask {
                    _ = observe(activeTask)
                }
                coord.cancelPendingTasks()
            }
        }

        func waitForCompleted(ticketID: Int, timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
            let start = DispatchTime.now().uptimeNanoseconds
            while !isCompleted(ticketID: ticketID) {
                if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                    return isCompleted(ticketID: ticketID)
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return true
        }

        func waitForAllObservedTasks(timeoutNanoseconds: UInt64 = 2_000_000_000) async -> Bool {
            let start = DispatchTime.now().uptimeNanoseconds
            while !areAllObservedTasksCompleted() {
                if DispatchTime.now().uptimeNanoseconds - start >= timeoutNanoseconds {
                    return areAllObservedTasksCompleted()
                }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return true
        }
    }

    private func withInstalledIMEBackend(
        cleanupTimeoutNanoseconds: UInt64 = 2_000_000_000,
        assertCleanup: (_ callsExited: Bool, _ tasksCompleted: Bool) -> Void = { callsExited, tasksCompleted in
            XCTAssertTrue(callsExited, "All in-flight tokenizer calls must exit during IME backend teardown within bound")
            XCTAssertTrue(tasksCompleted, "All observed highlight tasks must complete during IME backend teardown within bound")
        },
        _ body: (BoundedIMESyntaxBackend, HighlightTaskCompletionObserver) async throws -> Void
    ) async throws {
        let backend = BoundedIMESyntaxBackend()
        let observer = HighlightTaskCompletionObserver()
        await BackgroundSyntaxTokenizer.shared.setBackend(backend)
        var bodyError: Error?
        do {
            try await body(backend, observer)
        } catch {
            bodyError = error
        }
        backend.releaseAllHolds()
        observer.cancelAllRegisteredCoordinators()
        let callsExited = await backend.waitForAllInFlightCallsToExit(timeoutNanoseconds: cleanupTimeoutNanoseconds)
        let tasksCompleted = await observer.waitForAllObservedTasks(timeoutNanoseconds: cleanupTimeoutNanoseconds)
        await BackgroundSyntaxTokenizer.shared.setBackend(nil)
        assertCleanup(callsExited, tasksCompleted)
        if let bodyError {
            throw bodyError
        }
    }

    private func cancelAndDrainHighlight(
        _ coord: CodeHighlightingEditorNSView.Coordinator,
        backend: BoundedIMESyntaxBackend,
        observer: HighlightTaskCompletionObserver
    ) async {
        observer.registerCoordinator(coord)
        let existingTask = coord.currentHighlightTask
        let ticket = existingTask.map { observer.observe($0) }
        coord.cancelPendingTasks()
        backend.releaseAllHolds()
        if let ticket {
            let didFinish = await observer.waitForCompleted(ticketID: ticket)
            XCTAssertTrue(didFinish, "Cancelled highlight task must finish within bound")
        }
        let allExited = await backend.waitForAllInFlightCallsToExit()
        XCTAssertTrue(allExited, "All in-flight tokenizer calls must exit after cancellation")
    }

    private func startGatedHighlightPass(
        in coord: CodeHighlightingEditorNSView.Coordinator,
        textView: NSTextView,
        fileName: String,
        backend: BoundedIMESyntaxBackend,
        observer: HighlightTaskCompletionObserver
    ) async throws -> (callID: Int, taskTicket: Int) {
        let baselineCallID = backend.callCount()
        backend.armHoldForNextCall()
        coord.highlightSyntaxProgressive(in: textView, fileName: fileName)
        let task = try XCTUnwrap(coord.currentHighlightTask, "highlightSyntaxProgressive must create currentHighlightTask")
        let ticket = observer.observe(task)
        guard let enteredCallID = await backend.waitForEnteredCall(after: baselineCallID) else {
            backend.releaseAllHolds()
            _ = await observer.waitForCompleted(ticketID: ticket)
            XCTFail("Timed out waiting for highlight task (\(fileName)) to enter tokenizer backend")
            throw CancellationError()
        }
        return (enteredCallID, ticket)
    }

    private func releaseAndAwaitHighlightTask(
        callID: Int,
        taskTicket: Int,
        backend: BoundedIMESyntaxBackend,
        observer: HighlightTaskCompletionObserver
    ) async {
        backend.releaseCall(callID: callID)
        let didExitCall = await backend.waitForExited(callID: callID)
        XCTAssertTrue(didExitCall, "Held tokenizer call \(callID) must exit after release")
        let didCompleteTask = await observer.waitForCompleted(ticketID: taskTicket)
        XCTAssertTrue(didCompleteTask, "Coordinator currentHighlightTask (including MainActor writeback) must complete")
        let didExitAll = await backend.waitForAllInFlightCallsToExit()
        XCTAssertTrue(didExitAll, "All pipelined tokenizer calls must exit")
    }

    private func awaitScheduledHighlightPass(
        in coord: CodeHighlightingEditorNSView.Coordinator,
        previousTask: Task<Void, Never>?,
        baselineCallID: Int,
        backend: BoundedIMESyntaxBackend,
        observer: HighlightTaskCompletionObserver
    ) async {
        guard let newTask = coord.currentHighlightTask, newTask != previousTask else {
            XCTFail("Expected Coordinator to schedule a new currentHighlightTask")
            return
        }
        let ticket = observer.observe(newTask)
        let enteredCallID = await backend.waitForEnteredCall(after: baselineCallID)
        XCTAssertNotNil(enteredCallID, "Scheduled highlight task must enter tokenizer backend")
        if let enteredCallID {
            let didExit = await backend.waitForExited(callID: enteredCallID)
            XCTAssertTrue(didExit, "Scheduled tokenizer call \(enteredCallID) must exit")
        }
        let didCompleteTask = await observer.waitForCompleted(ticketID: ticket)
        XCTAssertTrue(didCompleteTask, "Scheduled Coordinator currentHighlightTask (including MainActor writeback) must complete")
        let didExitAll = await backend.waitForAllInFlightCallsToExit()
        XCTAssertTrue(didExitAll, "All tokenizer calls from scheduled pass must exit")
    }

    // MARK: - Formal IME Write-Side Protection & Post-Composition Reschedule Tests

    func testSmallDocAsyncHighlightPreservesMarkedTextAndRecolorsOnUnmark() async throws {
        try await withInstalledIMEBackend { backend, observer in
            let markerKey = NSAttributedString.Key("TTIMEProbeMarker")
            let darkPalette = TTTextReadingPalette.resolve(mode: .black, isDarkAppearance: true)
            var boundText = "let alpha = 1\nlet beta = 42\n"
            let editor = CodeHighlightingEditorNSView(
                text: Binding(get: { boundText }, set: { boundText = $0 }),
                fileName: "SmallIME.swift",
                isEditable: true,
                readingBackgroundMode: .black,
                isDarkAppearance: true,
                onTextChange: { boundText = $0 }
            )
            let coord = editor.makeCoordinator()
            let scroll = editor.makeEditorScrollView(coordinator: coord)
            await cancelAndDrainHighlight(coord, backend: backend, observer: observer)
            let tv = try XCTUnwrap(scroll.documentView as? LargeTextEditorTextView)
            let storage = try XCTUnwrap(tv.textStorage)

            coord.cachedTokenSpans = []
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: darkPalette.nsForegroundColor
            ], range: NSRange(location: 0, length: storage.length))

            let (call1, ticket1) = try await startGatedHighlightPass(
                in: coord, textView: tv, fileName: "SmallIME.swift", backend: backend, observer: observer
            )
            tv.setMarkedText("let beta = 42", selectedRange: NSRange(location: 4, length: 4), replacementRange: NSRange(location: 14, length: 13))
            storage.addAttribute(markerKey, value: "small-ime", range: tv.markedRange())
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: tv.markedRange())
            await releaseAndAwaitHighlightTask(callID: call1, taskTicket: ticket1, backend: backend, observer: observer)

            XCTAssertTrue(tv.hasMarkedText(), "Marked state must remain active before unmarkText")
            XCTAssertEqual(tv.selectedRange(), NSRange(location: 18, length: 4), "Marked sub-selection must be preserved")
            XCTAssertEqual(storage.attribute(markerKey, at: 14, effectiveRange: nil) as? String, "small-ime", "Marked attribute must not be wiped during IME")
            XCTAssertEqual(storage.attribute(.underlineStyle, at: 14, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 14, effectiveRange: nil) as? NSColor, darkPalette.nsForegroundColor)

            // Cross-text T0 -> T1 update during IME: binding updates immediately, highlight scheduling is suppressed
            let callsBeforeEdit = backend.callCount()
            let taskBeforeEdit = coord.currentHighlightTask
            tv.setMarkedText("let gamma = 99", selectedRange: NSRange(location: 4, length: 5), replacementRange: tv.markedRange())
            coord.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
            XCTAssertEqual(boundText, "let alpha = 1\nlet gamma = 99\n", "Text binding must stay synchronized during IME")
            XCTAssertTrue(coord.needsHighlightAfterMarkedText)
            XCTAssertNil(coord.debounceTask, "Debounced highlight task must be suppressed while marked text is active")
            XCTAssertEqual(backend.callCount(), callsBeforeEdit, "No new tokenizer request may start while suppressed by marked text")

            tv.unmarkText()
            await awaitScheduledHighlightPass(
                in: coord, previousTask: taskBeforeEdit, baselineCallID: callsBeforeEdit, backend: backend, observer: observer
            )

            XCTAssertFalse(tv.hasMarkedText(), "Marked state must clear after unmarkText")
            XCTAssertEqual(boundText, "let alpha = 1\nlet gamma = 99\n")
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, darkPalette.syntaxKeywordColor)
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 14, effectiveRange: nil) as? NSColor, darkPalette.syntaxKeywordColor)
        }
    }

    func testLargeDocAsyncStreamPreservesMarkedTextAndRecolorsLatestTextOnUnmark() async throws {
        try await withInstalledIMEBackend { backend, observer in
            let markerKey = NSAttributedString.Key("TTIMEProbeMarker")
            let darkPalette = TTTextReadingPalette.resolve(mode: .black, isDarkAppearance: true)
            let largeSource = "let header = 1\nlet nihao = 42\n"
                + String(repeating: "let item_value_0001 = 12345 // comment line\n", count: 3100)
            var boundText = largeSource
            let editor = CodeHighlightingEditorNSView(
                text: Binding(get: { boundText }, set: { boundText = $0 }),
                fileName: "LargeIME.swift",
                isEditable: true,
                readingBackgroundMode: .black,
                isDarkAppearance: true,
                onTextChange: { boundText = $0 }
            )
            let coord = editor.makeCoordinator()
            let scroll = editor.makeEditorScrollView(coordinator: coord)
            await cancelAndDrainHighlight(coord, backend: backend, observer: observer)
            let tv = try XCTUnwrap(scroll.documentView as? LargeTextEditorTextView)
            let storage = try XCTUnwrap(tv.textStorage)

            _ = coord.ensureMounted(throughUTF8Bytes: largeSource.utf8.count)
            await cancelAndDrainHighlight(coord, backend: backend, observer: observer)
            XCTAssertGreaterThanOrEqual(storage.length, 128_000)
            coord.cachedTokenSpans = []
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: darkPalette.nsForegroundColor
            ], range: NSRange(location: 0, length: storage.length))

            let (call1, ticket1) = try await startGatedHighlightPass(
                in: coord, textView: tv, fileName: "LargeIME.swift", backend: backend, observer: observer
            )
            tv.setMarkedText("let nihao = 42", selectedRange: NSRange(location: 4, length: 5), replacementRange: NSRange(location: 15, length: 14))
            storage.addAttribute(markerKey, value: "large-ime", range: tv.markedRange())
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: tv.markedRange())
            await releaseAndAwaitHighlightTask(callID: call1, taskTicket: ticket1, backend: backend, observer: observer)

            XCTAssertTrue(tv.hasMarkedText())
            XCTAssertEqual(tv.selectedRange(), NSRange(location: 19, length: 5))
            XCTAssertEqual(storage.attribute(markerKey, at: 15, effectiveRange: nil) as? String, "large-ime", "Large stream must not overwrite marked attribute")
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 15, effectiveRange: nil) as? NSColor, darkPalette.nsForegroundColor)

            // Mutate marked text to T1 ("let omega = 99") and commit via unmarkText
            tv.setMarkedText("let omega = 99", selectedRange: NSRange(location: 4, length: 5), replacementRange: tv.markedRange())
            storage.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: darkPalette.nsForegroundColor
            ], range: NSRange(location: 0, length: 30))
            let taskBeforeUnmark = coord.currentHighlightTask
            let callsBeforeUnmark = backend.callCount()
            tv.unmarkText()
            await awaitScheduledHighlightPass(
                in: coord, previousTask: taskBeforeUnmark, baselineCallID: callsBeforeUnmark, backend: backend, observer: observer
            )

            XCTAssertFalse(tv.hasMarkedText())
            XCTAssertEqual(boundText, tv.string, "Large doc binding must match committed text after unmarkText")
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 15, effectiveRange: nil) as? NSColor, darkPalette.syntaxKeywordColor)
        }
    }

    func testThemeSwitchAndSearchHighlightDuringIMEPreserveMarkedAttributesAndApplyOnUnmark() async throws {
        try await withInstalledIMEBackend { backend, observer in
            let markerKey = NSAttributedString.Key("TTIMEProbeMarker")
            let lightPalette = TTTextReadingPalette.resolve(mode: .white, isDarkAppearance: false)
            var boundText = "let first = 1\n"
            let editor = CodeHighlightingEditorNSView(
                text: Binding(get: { boundText }, set: { boundText = $0 }),
                fileName: "ThemeSearchIME.swift",
                isEditable: true,
                readingBackgroundMode: .black,
                isDarkAppearance: true,
                onTextChange: { boundText = $0 }
            )
            let coord = editor.makeCoordinator()
            let scroll = editor.makeEditorScrollView(coordinator: coord)
            await cancelAndDrainHighlight(coord, backend: backend, observer: observer)
            let tv = try XCTUnwrap(scroll.documentView as? LargeTextEditorTextView)
            let storage = try XCTUnwrap(tv.textStorage)

            tv.setMarkedText("let target = 42\n", selectedRange: NSRange(location: 4, length: 6), replacementRange: NSRange(location: storage.length, length: 0))
            storage.addAttribute(markerKey, value: "theme-search-ime", range: tv.markedRange())
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: tv.markedRange())

            let callsBeforeTheme = backend.callCount()
            let taskBeforeTheme = coord.currentHighlightTask
            coord.applyReadingTheme(lightPalette, to: tv, scrollView: scroll, recolorStorage: true)
            coord.updateSearchHighlights(query: "target", in: tv)

            XCTAssertEqual(coord.activeReadingPalette, lightPalette, "Active palette must update immediately")
            XCTAssertEqual(tv.backgroundColor, lightPalette.nsCanvasBackgroundColor, "Canvas background must update immediately")
            XCTAssertEqual(storage.attribute(markerKey, at: 14, effectiveRange: nil) as? String, "theme-search-ime", "Theme and search updates must not wipe marked attributes during IME")
            XCTAssertEqual(tv.selectedRange(), NSRange(location: 18, length: 6), "Selection must remain intact during IME theme/search update")
            XCTAssertTrue(coord.needsHighlightAfterMarkedText)
            XCTAssertEqual(backend.callCount(), callsBeforeTheme, "Theme and search deferral during IME must not launch tokenizer")

            tv.unmarkText()
            await awaitScheduledHighlightPass(
                in: coord, previousTask: taskBeforeTheme, baselineCallID: callsBeforeTheme, backend: backend, observer: observer
            )

            XCTAssertFalse(tv.hasMarkedText())
            XCTAssertFalse(coord.searchMatchRanges.isEmpty, "Search match ranges must be populated after unmarkText")
            let matchLoc = coord.searchMatchRanges.first?.location ?? 18
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 14, effectiveRange: nil) as? NSColor, lightPalette.syntaxKeywordColor, "Latest light palette keyword color must apply after unmarkText")
            XCTAssertEqual(storage.attribute(.backgroundColor, at: matchLoc, effectiveRange: nil) as? NSColor, lightPalette.nsSearchMatchBackgroundColor, "Deferred search highlight must apply after unmarkText")
        }
    }

    func testInsertTextCommitRepeatedUnmarkCancelCompositionAndPlainTextModes() async throws {
        try await withInstalledIMEBackend { backend, observer in
            let markerKey = NSAttributedString.Key("TTIMEProbeMarker")
            let darkPalette = TTTextReadingPalette.resolve(mode: .black, isDarkAppearance: true)
            let lightPalette = TTTextReadingPalette.resolve(mode: .white, isDarkAppearance: false)
            var boundText = "let alpha = 1\n"
            let editor = CodeHighlightingEditorNSView(
                text: Binding(get: { boundText }, set: { boundText = $0 }),
                fileName: "CommitModes.swift",
                isEditable: true,
                readingBackgroundMode: .black,
                isDarkAppearance: true,
                onTextChange: { boundText = $0 }
            )
            let coord = editor.makeCoordinator()
            let scroll = editor.makeEditorScrollView(coordinator: coord)
            await cancelAndDrainHighlight(coord, backend: backend, observer: observer)
            let tv = try XCTUnwrap(scroll.documentView as? LargeTextEditorTextView)
            let storage = try XCTUnwrap(tv.textStorage)

            // 1. insertText commit + redundant unmarkText idempotency
            tv.setMarkedText("pinyin", selectedRange: NSRange(location: 0, length: 6), replacementRange: NSRange(location: 14, length: 0))
            let taskBeforeCommit = coord.currentHighlightTask
            let callsBeforeCommit = backend.callCount()
            tv.insertText("let committed = 88\n", replacementRange: tv.markedRange())
            tv.unmarkText()
            tv.unmarkText()
            await awaitScheduledHighlightPass(
                in: coord, previousTask: taskBeforeCommit, baselineCallID: callsBeforeCommit, backend: backend, observer: observer
            )

            XCTAssertFalse(tv.hasMarkedText())
            XCTAssertEqual(boundText, "let alpha = 1\nlet committed = 88\n")
            XCTAssertEqual(backend.callCount(), callsBeforeCommit + 1, "Commit hooks must be idempotent and schedule only one highlight pass")
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 14, effectiveRange: nil) as? NSColor, darkPalette.syntaxKeywordColor)

            // 2. Composition cancellation via empty setMarkedText("", ...)
            tv.setMarkedText("temp_ime", selectedRange: NSRange(location: 0, length: 8), replacementRange: NSRange(location: storage.length, length: 0))
            storage.setAttributes([.foregroundColor: darkPalette.nsForegroundColor], range: NSRange(location: 0, length: storage.length))
            let taskBeforeCancel = coord.currentHighlightTask
            let callsBeforeCancel = backend.callCount()
            tv.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: tv.markedRange())
            await awaitScheduledHighlightPass(
                in: coord, previousTask: taskBeforeCancel, baselineCallID: callsBeforeCancel, backend: backend, observer: observer
            )
            XCTAssertFalse(tv.hasMarkedText())
            XCTAssertEqual(boundText, "let alpha = 1\nlet committed = 88\n")
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, darkPalette.syntaxKeywordColor)

            // 3. Plain-text (.txt) mode preserves marked attributes during IME and recolors synchronously on unmarkText
            coord.mountInitialPreview(displayString: "Plain line\n", in: tv, storage: storage, fileName: "Notes.txt")
            let callsBeforePlain = backend.callCount()
            tv.setMarkedText("Marked plain", selectedRange: NSRange(location: 0, length: 6), replacementRange: NSRange(location: 11, length: 0))
            storage.addAttribute(markerKey, value: "plain-ime", range: tv.markedRange())
            coord.applyReadingTheme(lightPalette, to: tv, scrollView: scroll, recolorStorage: true)
            XCTAssertEqual(storage.attribute(markerKey, at: 11, effectiveRange: nil) as? String, "plain-ime")
            tv.unmarkText()
            XCTAssertNil(coord.currentHighlightTask, "Plain text mode recolors synchronously without spawning a syntax task")
            XCTAssertEqual(backend.callCount(), callsBeforePlain, "Plain text mode must never invoke syntax tokenizer")
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, lightPalette.nsForegroundColor)
            XCTAssertTrue(coord.cachedTokenSpans.isEmpty)
        }
    }

    func testInFlightFileSwitchDismantleIsolationAndNonIMEPositiveControl() async throws {
        try await withInstalledIMEBackend { backend, observer in
            let darkPalette = TTTextReadingPalette.resolve(mode: .black, isDarkAppearance: true)
            let lightPalette = TTTextReadingPalette.resolve(mode: .white, isDarkAppearance: false)
            var boundText = "let oldSecret = 999\n"
            let editor = CodeHighlightingEditorNSView(
                text: Binding(get: { boundText }, set: { boundText = $0 }),
                fileName: "OldFile.swift",
                isEditable: true,
                readingBackgroundMode: .black,
                isDarkAppearance: true,
                onTextChange: { boundText = $0 }
            )
            let coord = editor.makeCoordinator()
            let scroll = editor.makeEditorScrollView(coordinator: coord)
            await cancelAndDrainHighlight(coord, backend: backend, observer: observer)
            let tv = try XCTUnwrap(scroll.documentView as? LargeTextEditorTextView)
            let storage = try XCTUnwrap(tv.textStorage)

            // 1. In-flight highlight + active IME on OldFile.swift, then switch to NewFile.txt
            let (oldCallID, oldTicket) = try await startGatedHighlightPass(
                in: coord, textView: tv, fileName: "OldFile.swift", backend: backend, observer: observer
            )
            tv.setMarkedText("let imeOld = 1\n", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: 0, length: 0))
            let oldGen = coord.documentGeneration

            coord.mountInitialPreview(displayString: "let plainNewDoc = 123\n", in: tv, storage: storage, fileName: "NewFile.txt")
            XCTAssertGreaterThan(coord.documentGeneration, oldGen)
            XCTAssertFalse(coord.needsHighlightAfterMarkedText)
            await releaseAndAwaitHighlightTask(callID: oldCallID, taskTicket: oldTicket, backend: backend, observer: observer)
            XCTAssertTrue(coord.cachedTokenSpans.isEmpty, "Stale tokens from OldFile.swift must never write into NewFile.txt")
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, darkPalette.nsForegroundColor)

            // 2. Positive control: non-IME editing and synchronous theme switch apply immediately
            let taskBeforeNormal = coord.currentHighlightTask
            let callsBeforeNormal = backend.callCount()
            coord.mountInitialPreview(displayString: "let normal = 7\n", in: tv, storage: storage, fileName: "Normal.swift")
            await awaitScheduledHighlightPass(
                in: coord, previousTask: taskBeforeNormal, baselineCallID: callsBeforeNormal, backend: backend, observer: observer
            )
            XCTAssertFalse(tv.hasMarkedText())
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, darkPalette.syntaxKeywordColor)
            coord.applyReadingTheme(lightPalette, to: tv, scrollView: scroll, recolorStorage: true)
            XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, lightPalette.syntaxKeywordColor)

            // 3. View dismantle cancels pending tasks and blocks stale callbacks
            let (dismantleCallID, dismantleTicket) = try await startGatedHighlightPass(
                in: coord, textView: tv, fileName: "Normal.swift", backend: backend, observer: observer
            )
            CodeHighlightingEditorNSView.dismantleNSView(scroll, coordinator: coord)
            XCTAssertNil(coord.currentHighlightTask)
            XCTAssertFalse(coord.needsHighlightAfterMarkedText)
            await releaseAndAwaitHighlightTask(callID: dismantleCallID, taskTicket: dismantleTicket, backend: backend, observer: observer)
        }

        try await verifyTeardownBoundedFailureVisibilityAndErrorPropagation()
    }

    private func verifyTeardownBoundedFailureVisibilityAndErrorPropagation() async throws {
        struct SimulatedTeardownError: Error, Equatable {}
        var capturedBackend: BoundedIMESyntaxBackend?
        var capturedObserver: HighlightTaskCompletionObserver?
        var recordedCallsExited = true
        var recordedTasksCompleted = true
        var caughtError: SimulatedTeardownError?

        do {
            try await withInstalledIMEBackend(
                cleanupTimeoutNanoseconds: 15_000_000,
                assertCleanup: { callsExited, tasksCompleted in
                    recordedCallsExited = callsExited
                    recordedTasksCompleted = tasksCompleted
                }
            ) { backend, observer in
                capturedBackend = backend
                capturedObserver = observer
                backend.setWithholdReleaseOnTeardown(true)
                var text = "let probe = 1\n"
                let editor = CodeHighlightingEditorNSView(
                    text: Binding(get: { text }, set: { text = $0 }),
                    fileName: "TeardownProbe.swift",
                    isEditable: true
                )
                let coord = editor.makeCoordinator()
                let scroll = editor.makeEditorScrollView(coordinator: coord)
                await cancelAndDrainHighlight(coord, backend: backend, observer: observer)
                let tv = try XCTUnwrap(scroll.documentView as? LargeTextEditorTextView)
                _ = try await startGatedHighlightPass(
                    in: coord, textView: tv, fileName: "TeardownProbe.swift", backend: backend, observer: observer
                )
                throw SimulatedTeardownError()
            }
        } catch let error as SimulatedTeardownError {
            caughtError = error
        }

        XCTAssertEqual(caughtError, SimulatedTeardownError(), "Original bodyError must propagate after teardown")
        XCTAssertFalse(recordedCallsExited, "Missing backend exit must surface as false within bounded teardown timeout")
        XCTAssertFalse(recordedTasksCompleted, "Missing task completion must surface as false within bounded teardown timeout")

        if let capturedBackend, let capturedObserver {
            capturedBackend.releaseAllHolds(force: true)
            let drainedCalls = await capturedBackend.waitForAllInFlightCallsToExit()
            let drainedTasks = await capturedObserver.waitForAllObservedTasks()
            XCTAssertTrue(drainedCalls)
            XCTAssertTrue(drainedTasks)
        }
        let defaultTokens = await BackgroundSyntaxTokenizer.shared.tokenize(
            text: "let ok = 1", ext: "swift", targetRange: NSRange(location: 0, length: 10)
        )
        XCTAssertFalse(defaultTokens.isEmpty, "Default tokenizer backend must be restored even when teardown times out")
    }
}
