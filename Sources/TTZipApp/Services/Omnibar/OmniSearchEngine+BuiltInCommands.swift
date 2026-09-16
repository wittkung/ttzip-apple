// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit
import Foundation

extension OmniSearchEngine {
    /// Derives an appropriate SF Symbol based on path extension.
    static func systemIconName(for url: URL) -> String {
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
    static func createBuiltInCommands() -> [CommandDefinition] {
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
