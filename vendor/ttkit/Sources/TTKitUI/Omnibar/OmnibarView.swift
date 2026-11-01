// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import TTKitCore
import TTKitDesign

// MARK: - Omnibar Category

/// Classification taxonomy for Omnibar searchable commands and resources.
public enum OmnibarCategory: String, Sendable, CaseIterable, Identifiable {
    case all = "All"
    case commands = "Commands"
    case archives = "Archives"
    case media = "Media"
    case navigation = "Navigation"
    case system = "System"

    public var id: String { rawValue }

    public var iconSystemName: String {
        switch self {
        case .all:
            return "square.grid.2x2"
        case .commands:
            return "terminal"
        case .archives:
            return "archivebox"
        case .media:
            return "waveform"
        case .navigation:
            return "arrow.triangle.turn.up.right.diamond"
        case .system:
            return "gearshape"
        }
    }
}

// MARK: - Omnibar Action Model

/// Action entry registered in the universal Cmd+K suite palette.
public struct OmnibarAction: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let category: OmnibarCategory
    public let iconSystemName: String
    public let shortcutHint: String?
    public let prefixCommand: String?
    public let isDestructive: Bool
    public let handler: @Sendable @MainActor () -> Void

    public init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String,
        category: OmnibarCategory,
        iconSystemName: String = "bolt.fill",
        shortcutHint: String? = nil,
        prefixCommand: String? = nil,
        isDestructive: Bool = false,
        handler: @escaping @Sendable @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.iconSystemName = iconSystemName
        self.shortcutHint = shortcutHint
        self.prefixCommand = prefixCommand
        self.isDestructive = isDestructive
        self.handler = handler
    }
}

// MARK: - Fuzzy Matcher

/// Deterministic, allocation-free fuzzy string matching and scoring utility.
public enum FuzzyMatcher: Sendable {
    public struct MatchResult: Sendable, Comparable {
        public let isMatch: Bool
        public let score: Int

        public static func < (lhs: MatchResult, rhs: MatchResult) -> Bool {
            lhs.score < rhs.score
        }
    }

    /// Evaluates fuzzy similarity score between candidate and pattern.
    /// Higher score indicates higher match relevance.
    public static func match(candidate: String, pattern: String) -> MatchResult {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedPattern.isEmpty else {
            return MatchResult(isMatch: true, score: 0)
        }

        let lowerCandidate = candidate.lowercased()

        // Exact match bonus
        if lowerCandidate == trimmedPattern {
            return MatchResult(isMatch: true, score: 10_000)
        }

        // Prefix match bonus
        if lowerCandidate.hasPrefix(trimmedPattern) {
            return MatchResult(isMatch: true, score: 5_000 + (100 - lowerCandidate.count))
        }

        // Substring match bonus
        if lowerCandidate.contains(trimmedPattern) {
            return MatchResult(isMatch: true, score: 2_000 + (50 - lowerCandidate.count))
        }

        // Subsequence fuzzy match
        var score = 0
        var patternIndex = trimmedPattern.startIndex
        var lastMatchIndex: String.Index?
        var consecutiveMatches = 0

        for candidateIndex in lowerCandidate.indices {
            guard patternIndex < trimmedPattern.endIndex else { break }

            if lowerCandidate[candidateIndex] == trimmedPattern[patternIndex] {
                score += 10

                // Consecutive match bonus
                if let last = lastMatchIndex, lowerCandidate.index(after: last) == candidateIndex {
                    consecutiveMatches += 1
                    score += consecutiveMatches * 15
                } else {
                    consecutiveMatches = 0
                }

                // Word boundary bonus (beginning of word after space or delimiter)
                if candidateIndex == lowerCandidate.startIndex ||
                   lowerCandidate[lowerCandidate.index(before: candidateIndex)] == " " ||
                   lowerCandidate[lowerCandidate.index(before: candidateIndex)] == "-" ||
                   lowerCandidate[lowerCandidate.index(before: candidateIndex)] == "_" {
                    score += 50
                }

                lastMatchIndex = candidateIndex
                patternIndex = trimmedPattern.index(after: patternIndex)
            }
        }

        let isComplete = patternIndex == trimmedPattern.endIndex
        return MatchResult(isMatch: isComplete, score: isComplete ? score : -1)
    }
}

// MARK: - Cmd+K Suite Omnibar View

/// Universal floating glass palette for command dispatch and fuzzy navigation.
/// Satisfies the TTKit 4-layer optical model sitting on Layer 3 Overlay Plate.
@MainActor
public struct OmnibarView: View {
    public let actions: [OmnibarAction]
    public let onDismiss: @Sendable @MainActor () -> Void

    @State private var queryString: String = ""
    @State private var selectedIndex: Int = 0
    @State private var selectedCategory: OmnibarCategory = .all
    @FocusState private var isSearchFocused: Bool

    public init(
        actions: [OmnibarAction]? = nil,
        onDismiss: @escaping @Sendable @MainActor () -> Void = {}
    ) {
        self.actions = actions ?? OmnibarView.defaultSuiteActions
        self.onDismiss = onDismiss
    }

    // MARK: - Filtered Actions

    private var filteredActions: [OmnibarAction] {
        let categoryFiltered: [OmnibarAction]
        if selectedCategory == .all {
            categoryFiltered = actions
        } else {
            categoryFiltered = actions.filter { $0.category == selectedCategory }
        }

        let query = queryString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return categoryFiltered
        }

        // Fuzzy filter and rank
        let scored: [(action: OmnibarAction, score: Int)] = categoryFiltered.compactMap { action in
            let titleMatch = FuzzyMatcher.match(candidate: action.title, pattern: query)
            let subtitleMatch = FuzzyMatcher.match(candidate: action.subtitle, pattern: query)
            let prefixMatch: FuzzyMatcher.MatchResult
            if let prefix = action.prefixCommand {
                prefixMatch = FuzzyMatcher.match(candidate: prefix, pattern: query)
            } else {
                prefixMatch = FuzzyMatcher.MatchResult(isMatch: false, score: -1)
            }

            let bestScore = max(titleMatch.score, subtitleMatch.score, prefixMatch.score)
            let matched = titleMatch.isMatch || subtitleMatch.isMatch || prefixMatch.isMatch

            return matched ? (action, bestScore) : nil
        }

        return scored.sorted { $0.score > $1.score }.map(\.action)
    }

    // MARK: - Body View

    public var body: some View {
        VStack(spacing: 0) {
            // Search Input Header
            searchHeaderView

            // Hairline separator
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: UniversalTokens.Dimensions.hairlineWidth)

            // Category Scope Filters
            categoryFilterBarView

            // Action List
            actionListContentView

            // Bottom Status / Navigation Hints Footer
            footerView
        }
        .frame(width: 620, height: 440)
        .ttOverlayGlassPlate(cornerRadius: 18)
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            navigateSelection(direction: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            navigateSelection(direction: 1)
            return .handled
        }
        .onKeyPress(.return) {
            triggerSelectedAction()
            return .handled
        }
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
    }

    // MARK: - Search Header

    private var searchHeaderView: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(TTKitTheme.kintsugiGold)

            TextField(
                "Search actions, archives, or type '>' for commands...",
                text: $queryString
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .regular))
            .focused($isSearchFocused)
            .onChange(of: queryString) { _, _ in
                selectedIndex = 0
            }
            .onSubmit {
                triggerSelectedAction()
            }

            if !queryString.isEmpty {
                Button {
                    queryString = ""
                    selectedIndex = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Keyboard shortcut badge
            HStack(spacing: 3) {
                Text("ESC")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Category Filter Bar

    private var categoryFilterBarView: some View {
        HStack(spacing: 6) {
            ForEach(OmnibarCategory.allCases) { category in
                Button {
                    withAnimation(UniversalTokens.Motion.micro) {
                        selectedCategory = category
                        selectedIndex = 0
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: category.iconSystemName)
                            .font(.system(size: 9))
                        Text(category.rawValue)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        if selectedCategory == category {
                            Capsule()
                                .fill(TTKitTheme.kintsugiGold.opacity(0.20))
                        } else {
                            Capsule()
                                .fill(Color.primary.opacity(0.04))
                        }
                    }
                    .overlay {
                        if selectedCategory == category {
                            Capsule()
                                .strokeBorder(TTKitTheme.kintsugiGold.opacity(0.60), lineWidth: UniversalTokens.Dimensions.hairlineWidth)
                        }
                    }
                    .foregroundStyle(selectedCategory == category ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
    }

    // MARK: - Action List Content

    private var actionListContentView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if filteredActions.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(Array(filteredActions.enumerated()), id: \.element.id) { index, action in
                            actionRowView(action: action, isSelected: index == selectedIndex)
                                .id(index)
                                .onTapGesture {
                                    selectedIndex = index
                                    action.handler()
                                    onDismiss()
                                }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(UniversalTokens.Motion.micro) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Action Row

    @ViewBuilder
    private func actionRowView(action: OmnibarAction, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: action.iconSystemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(action.isDestructive ? TTKitTheme.cinnabarRed : TTKitTheme.bambooGreen)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(action.isDestructive ? TTKitTheme.cinnabarRed.opacity(0.12) : TTKitTheme.bambooGreen.opacity(0.12))
                )

            // Text
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(action.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(action.isDestructive ? TTKitTheme.cinnabarRed : .primary)

                    if let prefix = action.prefixCommand {
                        Text(prefix)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(TTKitTheme.kintsugiGold)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(TTKitTheme.kintsugiGold.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }

                Text(action.subtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Shortcut hint badge
            if let shortcut = action.shortcutHint {
                Text(shortcut)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TTKitTheme.kintsugiGold.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(TTKitTheme.kintsugiGold.opacity(0.35), lineWidth: UniversalTokens.Dimensions.hairlineWidth)
                    )
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)

            Text("No actions found matching \"\(queryString)\"")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            HStack(spacing: 12) {
                hintBadge(symbol: "↑↓", label: "Navigate")
                hintBadge(symbol: "↵", label: "Execute")
                hintBadge(symbol: "esc", label: "Dismiss")
            }

            Spacer()

            Text("\(filteredActions.count) actions")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.02))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: UniversalTokens.Dimensions.hairlineWidth)
        }
    }

    private func hintBadge(symbol: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(symbol)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Navigation & Action Handling

    private func navigateSelection(direction: Int) {
        let count = filteredActions.count
        guard count > 0 else { return }
        let nextIndex = selectedIndex + direction
        if nextIndex < 0 {
            selectedIndex = count - 1
        } else if nextIndex >= count {
            selectedIndex = 0
        } else {
            selectedIndex = nextIndex
        }
    }

    private func triggerSelectedAction() {
        guard !filteredActions.isEmpty, selectedIndex >= 0, selectedIndex < filteredActions.count else { return }
        let action = filteredActions[selectedIndex]
        action.handler()
        onDismiss()
    }

    private func handleEscape() {
        if !queryString.isEmpty {
            queryString = ""
            selectedIndex = 0
        } else {
            onDismiss()
        }
    }

    // MARK: - Canonical Default Suite Actions

    public static let defaultSuiteActions: [OmnibarAction] = [
        OmnibarAction(
            title: "Instant Audio Transcription",
            subtitle: "Transcribe active speech buffer to timed SRT / VTT via TTSubs",
            category: .media,
            iconSystemName: "waveform.and.mic",
            shortcutHint: "⌘T",
            prefixCommand: ">transcribe"
        ) {},
        OmnibarAction(
            title: "Assemble B-Roll Video",
            subtitle: "Synthesize background visuals and camera moves via TTBroll",
            category: .media,
            iconSystemName: "film.stack",
            shortcutHint: "⌘B",
            prefixCommand: ">broll"
        ) {},
        OmnibarAction(
            title: "Inspect Download Tasks",
            subtitle: "Monitor chunked high-concurrency daemon throughput via TTDown",
            category: .commands,
            iconSystemName: "arrow.down.circle.fill",
            shortcutHint: "⌘D",
            prefixCommand: ">download"
        ) {},
        OmnibarAction(
            title: "Decompress Archive",
            subtitle: "High-speed multi-threaded decompression via TTZip microkernel",
            category: .archives,
            iconSystemName: "archivebox.fill",
            shortcutHint: "⌘E",
            prefixCommand: ">extract"
        ) {},
        OmnibarAction(
            title: "Create Solid 7z Archive",
            subtitle: "Kahn DAG topologically sorted compression container",
            category: .archives,
            iconSystemName: "doc.zipper",
            shortcutHint: "⌘Z",
            prefixCommand: ">compress"
        ) {},
        OmnibarAction(
            title: "Tarot Spread Synthesis",
            subtitle: "High-precision resonant card calculation engine via TaroTurn",
            category: .commands,
            iconSystemName: "suit.spade.fill",
            shortcutHint: "⌘R",
            prefixCommand: ">tarot"
        ) {},
        OmnibarAction(
            title: "Slide Forge Synthesis",
            subtitle: "Presentation slide layout generation via Slide-Forge",
            category: .commands,
            iconSystemName: "rectangle.stack.fill",
            shortcutHint: "⌘S",
            prefixCommand: ">slide"
        ) {},
        OmnibarAction(
            title: "Workspace Preferences",
            subtitle: "Configure hardware acceleration and sandbox file descriptors",
            category: .system,
            iconSystemName: "gearshape.fill",
            shortcutHint: "⌘,"
        ) {}
    ]
}
