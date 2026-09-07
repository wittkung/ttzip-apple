// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import Combine
import Foundation

/// Central aggregation and search service powering the Universal Omnibar.
@MainActor
public final class OmniSearchEngine: ObservableObject {
    /// Current search query string.
    @Published public var query: String = "" {
        didSet {
            scheduleDebouncedSearch()
        }
    }

    /// Active directory context for relative path resolution and contextual commands.
    @Published public var currentDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()) {
        didSet {
            scheduleDebouncedSearch()
        }
    }

    /// Categorized search results grouped by category.
    @Published public private(set) var categorizedResults: [OmniSearchCategory: [OmniSearchItem]] = [:]

    /// Flat ordered results list optimized for arrow-key keyboard navigation.
    @Published public private(set) var flatResults: [OmniSearchItem] = []

    /// Active debouncing task for responsive, zero-frame-drop keystroke handling.
    private var debounceTask: Task<Void, Never>?

    /// Dedicated Spotlight query service.
    private let spotlightService = SpotlightSearchService()

    /// Subscription storage for Combine streams.
    private var cancellables = Set<AnyCancellable>()

    /// Internal descriptor for registered Omnibar commands.
    private struct CommandDefinition {
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
        executeSearch(query: "", directory: currentDirectory)
    }

    /// Binds asynchronous Spotlight results into the file category when appropriate.
    private func bindSpotlightStream() {
        spotlightService.$searchResults
            .receive(on: DispatchQueue.main)
            .sink { [weak self] results in
                self?.mergeSpotlightResults(results)
            }
            .store(in: &cancellables)
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

        let currentQuery = self.query
        let currentDir = self.currentDirectory

        if currentQuery.isEmpty {
            executeSearch(query: "", directory: currentDir)
            return
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.executeSearch(query: currentQuery, directory: currentDir)
        }
    }

    /// Executes search across applications, paths, actions, and disk items.
    private func executeSearch(query: String, directory: URL) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

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

        categorizedResults = [.commands: matchingCommands]
        flatResults = matchingCommands
    }

    /// Handles filesystem path lookahead and auto-completion.
    private func executePathSearch(query: String, directory: URL) {
        spotlightService.cancelSearch()

        let (dirs, files) = resolvePathCandidates(query: query, baseDirectory: directory)

        var dict: [OmniSearchCategory: [OmniSearchItem]] = [:]
        if !dirs.isEmpty { dict[.directories] = dirs }
        if !files.isEmpty { dict[.files] = files }

        categorizedResults = dict
        flatResults = dirs + files
    }

    /// Handles universal fuzzy aggregation across apps, commands, current directory, and Spotlight.
    private func executeUniversalSearch(query: String, directory: URL) {
        let apps = AppCatalogService.shared.searchApps(query: query)
        let commands = query.isEmpty ? [] : filterCommands(query: query, directory: directory)
        let (dirs, files) = searchCurrentDirectory(query: query, directory: directory)

        var dict: [OmniSearchCategory: [OmniSearchItem]] = [:]
        if !apps.isEmpty { dict[.applications] = apps }
        if !commands.isEmpty { dict[.commands] = commands }
        if !dirs.isEmpty { dict[.directories] = dirs }
        if !files.isEmpty { dict[.files] = files }

        categorizedResults = dict
        rebuildFlatResults()

        if !query.isEmpty {
            spotlightService.performSearch(query: query, searchDirectory: directory.path)
        } else {
            spotlightService.cancelSearch()
        }
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
        }
    }

    /// Rebuilds the flattened results list according to category hierarchy.
    private func rebuildFlatResults() {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(">") {
            flatResults = categorizedResults[.commands] ?? []
            return
        }

        var flat: [OmniSearchItem] = []
        if let apps = categorizedResults[.applications] { flat.append(contentsOf: apps) }
        if let commands = categorizedResults[.commands] { flat.append(contentsOf: commands) }
        if let dirs = categorizedResults[.directories] { flat.append(contentsOf: dirs) }
        if let files = categorizedResults[.files] { flat.append(contentsOf: files) }
        self.flatResults = flat
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

        let matched = builtInCommands.compactMap { cmd -> OmniSearchItem? in
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

    /// Derives an appropriate SF Symbol based on path extension.
    private static func systemIconName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz", "zst", "iso":
            return "doc.zipper"
        case "dmg", "pkg":
            return "shippingbox.fill"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg":
            return "photo.fill"
        case "mp4", "mov", "mkv", "avi":
            return "film.fill"
        case "mp3", "wav", "flac", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext.fill"
        case "swift", "rs", "c", "cpp", "h", "py", "js", "ts", "json", "yaml", "toml", "sh":
            return "curlybraces"
        default:
            return "doc.fill"
        }
    }

    /// Creates the standard set of built-in system and workspace commands.
    private static func createBuiltInCommands() -> [CommandDefinition] {
        [
            CommandDefinition(
                id: "new_archive",
                title: NSLocalizedString("New Archive Wizard", comment: "New archive command"),
                subtitle: NSLocalizedString("Create a new archive from current directory", comment: "Command description"),
                systemIcon: "archivebox.badge.plus.fill",
                shortcutHint: "⌘N",
                keywords: ["new", "archive", "compress", "zip", "tar", "新建", "压缩", "向导"],
                action: { dir in
                    NotificationCenter.default.post(name: .init("TTZipTriggerNewArchiveWizard"), object: dir)
                }
            ),
            CommandDefinition(
                id: "open_terminal",
                title: NSLocalizedString("Open in Terminal", comment: "Open in terminal command"),
                subtitle: NSLocalizedString("Open current location in macOS Terminal", comment: "Command description"),
                systemIcon: "terminal.fill",
                shortcutHint: "⌥T",
                keywords: ["terminal", "shell", "bash", "zsh", "终端", "命令行"],
                action: { dir in
                    let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                    let config = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open([dir], withApplicationAt: terminalURL, configuration: config, completionHandler: nil)
                }
            ),
            CommandDefinition(
                id: "reveal_finder",
                title: NSLocalizedString("Reveal in Finder", comment: "Reveal in finder command"),
                subtitle: NSLocalizedString("Open current location in Finder", comment: "Command description"),
                systemIcon: "macwindow",
                shortcutHint: "⌘R",
                keywords: ["finder", "reveal", "show", "访达", "定位", "显示"],
                action: { dir in
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            ),
            CommandDefinition(
                id: "toggle_hidden",
                title: NSLocalizedString("Toggle Hidden Files", comment: "Toggle hidden files command"),
                subtitle: NSLocalizedString("Toggle visibility of dotfiles in browser", comment: "Command description"),
                systemIcon: "eye.slash.fill",
                shortcutHint: "⌘.",
                keywords: ["hidden", "dotfile", "toggle", "隐藏", "点文件", "显示隐藏"],
                action: { _ in
                    NotificationCenter.default.post(name: .init("TTZipToggleHiddenFilesNotification"), object: nil)
                }
            ),
            CommandDefinition(
                id: "reload_directory",
                title: NSLocalizedString("Reload Directory", comment: "Reload directory command"),
                subtitle: NSLocalizedString("Rescan disk items for current folder", comment: "Command description"),
                systemIcon: "arrow.clockwise",
                shortcutHint: "⌘R",
                keywords: ["reload", "refresh", "rescan", "刷新", "重载"],
                action: { dir in
                    NotificationCenter.default.post(name: .init("TTZipReloadDirectoryNotification"), object: dir)
                }
            ),
            CommandDefinition(
                id: "copy_path",
                title: NSLocalizedString("Copy Current Path", comment: "Copy path command"),
                subtitle: NSLocalizedString("Copy absolute POSIX path to clipboard", comment: "Command description"),
                systemIcon: "doc.on.doc.fill",
                shortcutHint: "⌥⌘C",
                keywords: ["copy", "path", "posix", "clipboard", "复制", "路径", "剪贴板"],
                action: { dir in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(dir.path, forType: .string)
                }
            )
        ]
    }
}
