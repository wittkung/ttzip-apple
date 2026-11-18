// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import AppKit
import os

extension NSApplication {
    private static let relaunchLogger = Logger(subsystem: "com.metastudyline.ttzip", category: "Relaunch")
    
    /// Relaunches the current application instance safely, terminating the current instance
    /// strictly after the child relaunch process has launched successfully.
    @MainActor
    public static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let process = Process()
        
        if bundleURL.pathExtension == "app" {
            // Packaged app via /usr/bin/open with PID spinwait to ensure clean handover
            let currentPID = ProcessInfo.processInfo.processIdentifier
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open -n \"$2\"",
                "_",
                String(currentPID),
                bundleURL.path
            ]
        } else {
            // CLI or Xcode run
            let executablePath = CommandLine.arguments[0]
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = Array(CommandLine.arguments.dropFirst())
        }
        
        do {
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            relaunchLogger.error("Failed to launch replacement process for relaunch: \(error.localizedDescription, privacy: .public)")
        }
    }
}
