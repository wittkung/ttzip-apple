// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// High-performance, non-reactive keyboard navigation and type-to-select coordinator.
/// Keeps transient key buffers out of SwiftUI @State to eliminate invalidation cascades.
/// Employs zero-allocation timestamp tracking and Finder-standard same-character cycling.
@MainActor
public final class SidebarKeyboardCoordinator {
    private var keyBuffer: String = ""
    private var lastKeyPressInstant: ContinuousClock.Instant = .now
    private var lastMatchedPath: String? = nil
    private var lastMatchedIndex: Int = -1

    public init() {}

    private static let allowedCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: " .-_")
        return set
    }()

    /// Handles a down keypress for type-to-select matching against provided candidates.
    /// The candidate list is lazily evaluated via `@autoclosure` so shortcut and non-printable
    /// keys exit immediately without allocating candidate collections.
    public func handleKeyPress<Target>(
        _ press: KeyPress,
        candidates: @autoclosure () -> [(title: String, target: Target)],
        onMatched: (Target) -> Void
    ) -> KeyPress.Result {
        // Disregard keypresses carrying control, command, or option modifiers to avoid intercepting shortcuts
        guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
        guard !press.characters.isEmpty else { return .ignored }
        let char = press.characters.lowercased()

        // Prevent leading whitespace from initiating a search buffer
        if keyBuffer.isEmpty && char.trimmingCharacters(in: .whitespaces).isEmpty {
            return .ignored
        }

        guard char.rangeOfCharacter(from: Self.allowedCharacters) != nil else { return .ignored }

        let now = ContinuousClock.now
        let isExpired = (now - lastKeyPressInstant) > .milliseconds(800)
        lastKeyPressInstant = now

        if isExpired {
            keyBuffer = ""
            lastMatchedPath = nil
            lastMatchedIndex = -1
        }

        let candidateList = candidates()
        guard !candidateList.isEmpty else { return .ignored }

        // Finder Pattern: Same-character cycling (e.g. typing "d", "d", "d" cycles Desktop -> Documents -> Downloads)
        if keyBuffer.count == 1 && keyBuffer == char {
            let matchingIndices = candidateList.indices.filter {
                candidateList[$0].title.lowercased().starts(with: char)
            }
            if !matchingIndices.isEmpty {
                let nextIdx: Int
                if let currentPos = matchingIndices.firstIndex(of: lastMatchedIndex) {
                    nextIdx = matchingIndices[(currentPos + 1) % matchingIndices.count]
                } else {
                    nextIdx = matchingIndices[0]
                }
                lastMatchedIndex = nextIdx
                let target = candidateList[nextIdx]
                onMatched(target.target)
                return .handled
            }
        }

        let tentativeBuffer = keyBuffer + char
        if let matchIndex = candidateList.firstIndex(where: { $0.title.lowercased().starts(with: tentativeBuffer) }) {
            keyBuffer = tentativeBuffer
            lastMatchedIndex = matchIndex
            let target = candidateList[matchIndex]
            onMatched(target.target)
            return .handled
        }

        // Keep current buffer untouched if new character doesn't form a valid prefix, avoiding lockout
        return .ignored
    }

    /// Explicitly resets the character buffer.
    public func reset() {
        keyBuffer = ""
        lastMatchedPath = nil
        lastMatchedIndex = -1
    }
}
