// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import Foundation
import Observation
import TTZipPluginKit

/// Central aggregation and search service powering the Universal Omnibar.
@Observable
@MainActor
public final class OmniSearchEngine {
    /// Current search query string.
    public var query: String = "" {
        didSet {
            scheduleDebouncedSearch()
        }
    }

    /// Active directory context for relative path resolution and contextual commands.
    public var currentDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()) {
        didSet {
            scheduleDebouncedSearch()
        }
    }

    /// Canonical algebraic state representing the single source of truth for the Omnibar.
    public private(set) var state: OmniEngineState = .idleWithRecommendations(categories: [])

    /// Categorized search results grouped by category.
    public private(set) var categorizedResults: [OmniSearchCategory: [OmniSearchItem]] = [:]

    /// Flat ordered results list optimized for arrow-key keyboard navigation.
    public private(set) var flatResults: [OmniSearchItem] = []

    /// Public alias for flatResults representing all items currently displayed in the palette.
    public var items: [OmniSearchItem] { flatResults }

    /// Strongly-typed categorized sections derived from the active state.
    public var sections: [OmniSection] { state.sections }

    /// Currently selected search item, defaulting to the first item in flat results.
    public private(set) var selectedItem: OmniSearchItem?

    /// Currently selected index within flatResults with automatic bounds clamping.
    public private(set) var selectedIndex: Int = 0

    /// Cached default recommendations for fast reset and zero-latency fallback.
    public private(set) var defaultRecommendations: [OmniSection] = []

    /// Active debouncing task for responsive, zero-frame-drop keystroke handling.
    @ObservationIgnored
    private var debounceTask: Task<Void, Never>?

    /// Dedicated Spotlight query service.
    @ObservationIgnored
    private let spotlightService = SpotlightSearchService()

    /// Structured tasks for catalog and search stream observation.
    @ObservationIgnored
    private var catalogObservationTask: Task<Void, Never>?
    @ObservationIgnored
    private var spotlightObservationTask: Task<Void, Never>?

    /// Internal descriptor for registered Omnibar commands.
    struct CommandDefinition {
        let id: String
        let title: String
        let subtitle: String
        let systemIcon: String
        let shortcutHint: String?
        let keywords: [String]
        let action: @MainActor (URL) -> Void
    }

    /// Registry of built-in system and operational commands.
    private let builtInCommands: [CommandDefinition]

    public init() {
        self.builtInCommands = Self.createBuiltInCommands()
        bindSpotlightStream()
        bindAppCatalogStream()
        executeSearch(query: "", directory: currentDirectory)
    }

    deinit {
        debounceTask?.cancel()
        catalogObservationTask?.cancel()
        spotlightObservationTask?.cancel()
    }

    /// Binds application catalog changes to refresh default recommendations when query is empty.
    private func bindAppCatalogStream() {
        catalogObservationTask?.cancel()
        catalogObservationTask = Task { [weak self] in
            for await _ in AppCatalogService.shared.makeAppsStream() {
                guard let self = self, !Task.isCancelled else { break }
                guard self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                self.executeUniversalSearch(query: "", directory: self.currentDirectory)
            }
        }
    }

    /// Selects the item at the specified index with automatic boundary clamping.
    public func selectIndex(_ index: Int) {
        guard !flatResults.isEmpty else {
            selectedItem = nil
            selectedIndex = 0
            return
        }
        let clamped = max(0, min(index, flatResults.count - 1))
        selectedIndex = clamped
        selectedItem = flatResults[clamped]
    }

    /// Clamps selectedIndex and selectedItem within valid bounds of flatResults.
    private func clampSelection() {
        guard !flatResults.isEmpty else {
            selectedItem = nil
            selectedIndex = 0
            return
        }

        if let current = selectedItem, let idx = flatResults.firstIndex(where: { $0.id == current.id }) {
            selectedIndex = idx
        } else {
            let clamped = max(0, min(selectedIndex, flatResults.count - 1))
            selectedIndex = clamped
            selectedItem = flatResults[clamped]
        }
    }

    /// Strips null bytes, limits maximum query length, and normalizes input.
    private func sanitizeQuery(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "\0", with: "")
        if stripped.count > 1000 {
            return String(stripped.prefix(1000))
        }
        return stripped
    }

    /// Explicitly transitions the state machine to an unrecoverable failure state.
    public func reportFailure(description: String) {
        self.state = .failure(errorDescription: description)
    }

    /// Binds asynchronous Spotlight results into the file category when appropriate.
    private func bindSpotlightStream() {
        spotlightObservationTask?.cancel()
        spotlightObservationTask = Task { [weak self] in
            guard let self = self else { return }
            for await results in self.spotlightService.makeResultsStream() {
                guard !Task.isCancelled else { break }
                self.mergeSpotlightResults(results)
            }
        }
    }

    /// Updates the search query string.
    public func updateQuery(_ newQuery: String) {
        self.query = newQuery
    }

    /// Updates the active browsing directory.
    public func navigate(to directory: URL) {
        self.currentDirectory = directory
    }

    /// Schedules an 80ms debounced search to avoid UI frame hitching during fast typing.
    private func scheduleDebouncedSearch() {
        debounceTask?.cancel()

        let sanitized = sanitizeQuery(self.query)
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDir = self.currentDirectory

        if trimmed.isEmpty {
            executeSearch(query: "", directory: currentDir)
            return
        }

        // Enter debouncing state
        self.state = .typingDebounce(query: sanitized)

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.executeSearch(query: sanitized, directory: currentDir)
        }
    }

    /// Executes search across applications, paths, actions, and disk items.
    private func executeSearch(query: String, directory: URL) {
        let sanitized = sanitizeQuery(query)
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            populateDefaultRecommendations(directory: directory)
            spotlightService.cancelSearch()
            return
        }

        // Enter searching state
        self.state = .searching(query: sanitized)

        if trimmed.hasPrefix(">") {
            executeCommandSearch(query: trimmed, directory: directory)
            return
        }

        if isPathLike(trimmed) {
            executePathSearch(query: trimmed, directory: directory)
            return
        }

        executeUniversalSearch(query: trimmed, directory: directory)
    }

    /// Determines whether the given query should be treated as a filesystem path.
    private func isPathLike(_ input: String) -> Bool {
        input.contains("/") || input.hasPrefix("~") || input.hasPrefix(".")
    }

    /// Handles dedicated command mode triggered by the '>' prefix.
    private func executeCommandSearch(query: String, directory: URL) {
        spotlightService.cancelSearch()

        let commandQuery = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
        let matchingCommands = filterCommands(query: commandQuery, directory: directory)

        if matchingCommands.isEmpty {
            categorizedResults = [:]
            flatResults = []
            clampSelection()
            self.state = .noMatches(query: query)
        } else {
            let section = OmniSection(category: .commands, items: matchingCommands)
            categorizedResults = [.commands: matchingCommands]
            flatResults = matchingCommands
            clampSelection()
            self.state = .populated(query: query, results: [section])
        }
    }

    /// Handles filesystem path lookahead and auto-completion.
    private func executePathSearch(query: String, directory: URL) {
        spotlightService.cancelSearch()

        let (dirs, files) = resolvePathCandidates(query: query, baseDirectory: directory)

        var dict: [OmniSearchCategory: [OmniSearchItem]] = [:]
        var sections: [OmniSection] = []

        if !dirs.isEmpty {
            dict[.directories] = dirs
            sections.append(OmniSection(category: .directories, items: dirs))
        }
        if !files.isEmpty {
            dict[.files] = files
            sections.append(OmniSection(category: .files, items: files))
        }

        categorizedResults = dict
        flatResults = dirs + files
        clampSelection()

        if sections.isEmpty {
            self.state = .noMatches(query: query)
        } else {
            self.state = .populated(query: query, results: sections)
        }
    }

    /// Handles universal fuzzy aggregation across apps, commands, current directory, and Spotlight.
    private func executeUniversalSearch(query: String, directory: URL) {
        if query.isEmpty {
            populateDefaultRecommendations(directory: directory)
            spotlightService.cancelSearch()
            return
        }

        let apps = AppCatalogService.shared.searchApps(query: query)
        let commands = filterCommands(query: query, directory: directory)
        let (dirs, files) = searchCurrentDirectory(query: query, directory: directory)

        var dict: [OmniSearchCategory: [OmniSearchItem]] = [:]
        var sections: [OmniSection] = []

        if !apps.isEmpty {
            dict[.applications] = apps
            sections.append(OmniSection(category: .applications, items: apps))
        }
        if !commands.isEmpty {
            dict[.commands] = commands
            sections.append(OmniSection(category: .commands, items: commands))
        }
        if !dirs.isEmpty {
            dict[.directories] = dirs
            sections.append(OmniSection(category: .directories, items: dirs))
        }
        if !files.isEmpty {
            dict[.files] = files
            sections.append(OmniSection(category: .files, items: files))
        }

        categorizedResults = dict
        rebuildFlatResults()

        if sections.isEmpty {
            self.state = .noMatches(query: query)
        } else {
            self.state = .populated(query: query, results: sections)
        }

        spotlightService.performSearch(query: query, searchDirectory: directory.path)
    }

    /// Populates rich default recommendations across top applications, quick commands, and common directories.
    private func populateDefaultRecommendations(directory: URL) {
        var dict: [OmniSearchCategory: [OmniSearchItem]] = [:]
        var sections: [OmniSection] = []

        let topApps = resolveTopApplications()
        if !topApps.isEmpty {
            dict[.applications] = topApps
            sections.append(OmniSection(category: .applications, items: topApps))
        }

        let quickCommands = resolveQuickCommands(directory: directory)
        if !quickCommands.isEmpty {
            dict[.commands] = quickCommands
            sections.append(OmniSection(category: .commands, items: quickCommands))
        }

        let commonDirs = resolveCommonDirectories()
        if !commonDirs.isEmpty {
            dict[.directories] = commonDirs
            sections.append(OmniSection(category: .directories, items: commonDirs))
        }

        categorizedResults = dict
        rebuildFlatResults()

        self.defaultRecommendations = sections
        self.state = .idleWithRecommendations(categories: sections)
    }

    /// Resolves top applications from the catalog or standard system locations.
    private func resolveTopApplications() -> [OmniSearchItem] {
        let catalogApps = AppCatalogService.shared.installedApps
        if !catalogApps.isEmpty {
            let prioritizedNames: [String] = ["Safari", "Terminal", "Finder", "Visual Studio Code", "Notes"]
            var results: [OmniSearchItem] = []

            for name in prioritizedNames {
                if let app = catalogApps.first(where: { $0.displayName.localizedCaseInsensitiveContains(name) }) {
                    results.append(AppCatalogService.shared.makeSearchItem(from: app))
                    if results.count >= 4 { break }
                }
            }
            if results.count < 4 {
                for app in catalogApps.prefix(4) {
                    if !results.contains(where: { $0.title == app.displayName }) {
                        results.append(AppCatalogService.shared.makeSearchItem(from: app))
                    }
                    if results.count >= 4 { break }
                }
            }
            if !results.isEmpty {
                return Array(results.prefix(4))
            }
        }
        return Array(Self.discoverCommonFallbackApps().prefix(4))
    }

    /// Discovers common fallback applications installed in standard macOS system directories.
    private static func discoverCommonFallbackApps() -> [OmniSearchItem] {
        let candidates: [(name: String, path: String)] = [
            ("Safari", "/System/Applications/Safari.app"),
            ("Terminal", "/System/Applications/Utilities/Terminal.app"),
            ("Finder", "/System/Library/CoreServices/Finder.app"),
            ("Notes", "/System/Applications/Notes.app"),
            ("Visual Studio Code", "/Applications/Visual Studio Code.app")
        ]

        var items: [OmniSearchItem] = []
        for c in candidates {
            if FileManager.default.fileExists(atPath: c.path) {
                let url = URL(fileURLWithPath: c.path)
                let icon = AppCatalogService.shared.icon(forPath: c.path)
                let prettyPath = c.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                items.append(OmniSearchItem(
                    id: "app:\(c.path)",
                    category: .applications,
                    title: c.name,
                    subtitle: prettyPath,
                    systemIcon: "app.fill",
                    customIcon: icon,
                    shortcutHint: "⏎ 打开",
                    payload: .application(url)
                ))
            }
        }
        return items
    }

    /// Resolves default quick operational commands for empty query state.
    private func resolveQuickCommands(directory: URL) -> [OmniSearchItem] {
        let targetIds: [String] = ["new_archive", "reveal_finder", "open_terminal", "toggle_hidden"]
        let matched = builtInCommands.filter { targetIds.contains($0.id) }
        return matched.map { cmd in
            makeCommandItem(cmd, directory: directory)
        }
    }

    /// Resolves common user directories (Downloads, Documents, Home).
    private func resolveCommonDirectories() -> [OmniSearchItem] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates: [(name: String, url: URL, icon: String)] = [
            ("Downloads", home.appendingPathComponent("Downloads"), "arrow.down.circle.fill"),
            ("Documents", home.appendingPathComponent("Documents"), "doc.fill"),
            ("Home (~)", home, "house.fill"),
            ("Desktop", home.appendingPathComponent("Desktop"), "desktopcomputer")
        ]

        var results: [OmniSearchItem] = []
        for c in candidates {
            if FileManager.default.fileExists(atPath: c.url.path) {
                let prettyPath = c.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                results.append(OmniSearchItem(
                    id: "dir:\(c.url.path)",
                    category: .directories,
                    title: c.name,
                    subtitle: prettyPath,
                    systemIcon: c.icon,
                    shortcutHint: "⏎ 进入",
                    payload: .directory(c.url)
                ))
            }
        }
        return results
    }

    /// Merges asynchronous Spotlight search results into the file list.
    private func mergeSpotlightResults(_ results: [DiskItemInfo]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(">"), !isPathLike(trimmed) else {
            return
        }

        var existingIDs = Set(flatResults.map { $0.id })
        var fileItems = categorizedResults[.files] ?? []

        for item in results {
            let itemURL = URL(fileURLWithPath: item.path)
            let itemID = "spotlight:\(item.path)"
            guard !existingIDs.contains(itemID),
                  !existingIDs.contains("cur_file:\(item.path)"),
                  !existingIDs.contains("file:\(item.path)") else {
                continue
            }
            existingIDs.insert(itemID)

            let prettySubtitle = item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            fileItems.append(OmniSearchItem(
                id: itemID,
                category: .files,
                title: item.name,
                subtitle: prettySubtitle,
                systemIcon: Self.systemIconName(for: itemURL),
                shortcutHint: "⏎ 打开",
                payload: .file(itemURL)
            ))
        }

        if !fileItems.isEmpty {
            categorizedResults[.files] = fileItems
            rebuildFlatResults()

            // Synchronize state with updated spotlight results
            var updatedSections: [OmniSection] = []
            if let apps = categorizedResults[.applications], !apps.isEmpty {
                updatedSections.append(OmniSection(category: .applications, items: apps))
            }
            if let commands = categorizedResults[.commands], !commands.isEmpty {
                updatedSections.append(OmniSection(category: .commands, items: commands))
            }
            if let dirs = categorizedResults[.directories], !dirs.isEmpty {
                updatedSections.append(OmniSection(category: .directories, items: dirs))
            }
            if !fileItems.isEmpty {
                updatedSections.append(OmniSection(category: .files, items: fileItems))
            }
            self.state = .populated(query: trimmed, results: updatedSections)
        }
    }

    /// Rebuilds the flattened results list according to category hierarchy.
    private func rebuildFlatResults() {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">") {
            flatResults = categorizedResults[.commands] ?? []
            clampSelection()
            return
        }

        var flat: [OmniSearchItem] = []
        if let apps = categorizedResults[.applications] { flat.append(contentsOf: apps) }
        if let commands = categorizedResults[.commands] { flat.append(contentsOf: commands) }
        if let dirs = categorizedResults[.directories] { flat.append(contentsOf: dirs) }
        if let files = categorizedResults[.files] { flat.append(contentsOf: files) }
        self.flatResults = flat
        clampSelection()
    }

    /// Resolves child directories and files along a path prefix.
    private func resolvePathCandidates(query: String, baseDirectory: URL) -> (directories: [OmniSearchItem], files: [OmniSearchItem]) {
        let expanded: String
        if query.hasPrefix("~") {
            let home = NSHomeDirectory()
            expanded = home + query.dropFirst()
        } else if query.hasPrefix(".") {
            let relativeURL = URL(fileURLWithPath: query, relativeTo: baseDirectory)
            expanded = relativeURL.standardized.path
        } else {
            expanded = query
        }

        let parentPath: String
        let prefix: String

        if expanded.hasSuffix("/") {
            parentPath = expanded
            prefix = ""
        } else {
            let url = URL(fileURLWithPath: expanded)
            parentPath = url.deletingLastPathComponent().path
            prefix = url.lastPathComponent
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentPath, isDirectory: &isDir), isDir.boolValue else {
            return ([], [])
        }

        let parentURL = URL(fileURLWithPath: parentPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }

        var dirItems: [OmniSearchItem] = []
        var fileItems: [OmniSearchItem] = []

        for item in contents {
            let name = item.lastPathComponent
            if !prefix.isEmpty && !name.localizedStandardContains(prefix) {
                continue
            }

            let isItemDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let isPackage = (try? item.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            let prettyPath = item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")

            if isItemDir && !isPackage {
                dirItems.append(OmniSearchItem(
                    id: "dir:\(item.path)",
                    category: .directories,
                    title: name,
                    subtitle: prettyPath,
                    systemIcon: "folder.fill",
                    shortcutHint: "⇥ 补全 / ⏎ 进入",
                    payload: .directory(item)
                ))
            } else {
                fileItems.append(OmniSearchItem(
                    id: "file:\(item.path)",
                    category: .files,
                    title: name,
                    subtitle: prettyPath,
                    systemIcon: Self.systemIconName(for: item),
                    shortcutHint: "⏎ 打开",
                    payload: .file(item)
                ))
            }
        }

        dirItems.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        fileItems.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return (dirItems, fileItems)
    }

    /// Scans items located in the immediate active directory.
    private func searchCurrentDirectory(query: String, directory: URL) -> (directories: [OmniSearchItem], files: [OmniSearchItem]) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }

        var dirItems: [OmniSearchItem] = []
        var fileItems: [OmniSearchItem] = []

        for item in contents {
            let name = item.lastPathComponent
            if !query.isEmpty && !name.localizedStandardContains(query) {
                continue
            }

            let isItemDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let isPackage = (try? item.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            let prettyPath = item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")

            if isItemDir && !isPackage {
                dirItems.append(OmniSearchItem(
                    id: "cur_dir:\(item.path)",
                    category: .directories,
                    title: name,
                    subtitle: prettyPath,
                    systemIcon: "folder.fill",
                    shortcutHint: "⏎ 进入",
                    payload: .directory(item)
                ))
            } else {
                fileItems.append(OmniSearchItem(
                    id: "cur_file:\(item.path)",
                    category: .files,
                    title: name,
                    subtitle: prettyPath,
                    systemIcon: Self.systemIconName(for: item),
                    shortcutHint: "⏎ 打开",
                    payload: .file(item)
                ))
            }
        }

        dirItems.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        fileItems.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        return (Array(dirItems.prefix(20)), Array(fileItems.prefix(20)))
    }

    /// Filters commands by keyword or title matching.
    private func filterCommands(query: String, directory: URL) -> [OmniSearchItem] {
        let q = query.lowercased()

        var matched = builtInCommands.compactMap { cmd -> OmniSearchItem? in
            if q.isEmpty {
                return makeCommandItem(cmd, directory: directory)
            }

            let matchesTitle = cmd.title.lowercased().contains(q)
            let matchesSubtitle = cmd.subtitle.lowercased().contains(q)
            let matchesKeywords = cmd.keywords.contains { $0.lowercased().contains(q) }

            if matchesTitle || matchesSubtitle || matchesKeywords {
                return makeCommandItem(cmd, directory: directory)
            }
            return nil
        }

        // Plugin registered commands
        for pluginCmd in TTZipPluginRegistry.shared.omnibarCommands {
            if q.isEmpty ||
               pluginCmd.title.lowercased().contains(q) {
                matched.append(OmniSearchItem(
                    id: "plugin_cmd:\(pluginCmd.id)",
                    category: .commands,
                    title: pluginCmd.title,
                    subtitle: "Plugin Command",
                    systemIcon: pluginCmd.icon.isEmpty ? "puzzlepiece.extension" : pluginCmd.icon,
                    shortcutHint: pluginCmd.shortcut ?? "⏎ Run",
                    payload: .command(id: pluginCmd.id, action: {
                        pluginCmd.action()
                    })
                ))
            }
        }

        return matched
    }

    /// Maps a command definition to an `OmniSearchItem`.
    private func makeCommandItem(_ cmd: CommandDefinition, directory: URL) -> OmniSearchItem {
        OmniSearchItem(
            id: "cmd:\(cmd.id)",
            category: .commands,
            title: cmd.title,
            subtitle: cmd.subtitle,
            systemIcon: cmd.systemIcon,
            shortcutHint: cmd.shortcutHint,
            payload: .command(id: cmd.id, action: { [directory] in
                cmd.action(directory)
            })
        )
    }
}
