// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import AppKit

extension NSApplication {
    /// Relaunches the current application instance.
    @MainActor
    public static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        
        if bundleURL.pathExtension == "app" {
            // Packaged app via /usr/bin/open
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", bundleURL.path]
            try? process.run()
        } else {
            // CLI or Xcode run
            let executablePath = CommandLine.arguments[0]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = Array(CommandLine.arguments.dropFirst())
            try? process.run()
        }
        
        NSApplication.shared.terminate(nil)
    }
}
