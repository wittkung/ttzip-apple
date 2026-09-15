// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import Cocoa

/// High-performance extractor for currently selected items in macOS Finder.
@MainActor
public enum FinderSelectionExtractor {
    
    private static let compiledScript: NSAppleScript? = {
        let scriptText = """
        tell application "Finder"
            set selectedItems to selection as alias list
            set itemPaths to {}
            repeat with anItem in selectedItems
                set end of itemPaths to POSIX path of anItem
            end repeat
            return itemPaths
        end tell
        """
        return NSAppleScript(source: scriptText)
    }()
    
    /// Returns true if Finder is currently the frontmost active application.
    public static var isFinderFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }
    
    /// Extracts the list of file URLs currently highlighted/selected in Finder.
    /// Operates in sub-10ms using cached compiled AppleScript execution.
    @MainActor
    public static func getSelectedFileURLs() -> [URL] {
        guard isFinderFrontmost else {
            return []
        }
        
        guard let script = compiledScript else {
            return []
        }
        
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        
        guard errorInfo == nil else {
            return []
        }
        
        var urls: [URL] = []
        let count = descriptor.numberOfItems
        if count > 0 {
            for i in 1...count {
                if let pathItem = descriptor.atIndex(i)?.stringValue, !pathItem.isEmpty {
                    // Standardize and normalize trailing slash from directories
                    let cleanPath = (pathItem as NSString).standardizingPath
                    urls.append(URL(fileURLWithPath: cleanPath))
                }
            }
        }
        
        return urls
    }
}
