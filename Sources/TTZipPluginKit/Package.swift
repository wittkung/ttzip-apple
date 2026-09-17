// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import PackageDescription
import Foundation

let ttlogDependencyResolution: (dependency: Package.Dependency, packageName: String) = {
    // Tier 1: Explicit environment variable override
    if let envPath = ProcessInfo.processInfo.environment["TTLOG_PATH"],
       FileManager.default.fileExists(atPath: "\(envPath)/Package.swift") {
        return (.package(path: envPath), "TTLog")
    }

    // Tier 2: Standard peer workspace probe
    if ProcessInfo.processInfo.environment["TTZIP_USE_REMOTE_TTLOG"] != "1" {
        let candidates = [
            "../../../../../infra/ttlog",
            "../../../../infra/ttlog",
            "../../../infra/ttlog",
            "../../infra/ttlog"
        ]
        for relPath in candidates {
            let manifestURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("\(relPath)/Package.swift")
                .standardized
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return (.package(path: relPath), "TTLog")
            }
        }
    }

    // Tier 3: Remote GitHub repository fallback for external machines and CI
    return (.package(url: "https://github.com/wittkung/ttlog.git", branch: "main"), "TTLog")
}()

let ttlogPackage = ttlogDependencyResolution.dependency
let ttlogPackageName = ttlogDependencyResolution.packageName

let package = Package(
    name: "TTZipPluginKit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "TTZipPluginKit", type: .dynamic, targets: ["TTZipPluginKit"])
    ],
    dependencies: [
        ttlogPackage
    ],
    targets: [
        .target(
            name: "TTZipPluginKit",
            dependencies: [
                .product(name: "TTLogKit", package: ttlogPackageName)
            ],
            path: ".",
            exclude: [
                "README.md",
                "README.zh-CN.md",
                "Package.swift",
                "Testing/PluginCLI.swift"
            ],
            swiftSettings: [
                .define("GL_SILENCE_DEPRECATION"),
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
