// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import Cocoa

/// In-memory cache for app logo asset resolving to avoid redundant disk I/O.
@MainActor
public enum AppLogoCache {
    public static let sharedLogoImage: NSImage? = {
        if let bundleImage = NSImage(named: "AppIcon") {
            return bundleImage
        }
        if let resourcePath = Bundle.main.path(forResource: "TTZip_AppIcon_1024x1024", ofType: "png") {
            return NSImage(contentsOfFile: resourcePath)
        }
        return nil
    }()
}
