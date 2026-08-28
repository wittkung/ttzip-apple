// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import PackageDescription
import Foundation

let isLocalCoreAvailable: Bool = {
    if ProcessInfo.processInfo.environment["TTZIP_USE_REMOTE_CORE"] == "1" {
        return false
    }
    let localManifest = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../core/Package.swift")
        .standardized
    return FileManager.default.fileExists(atPath: localManifest.path)
}()

let coreDependency: Package.Dependency = isLocalCoreAvailable
    ? .package(path: "../core")
    : .package(url: "https://github.com/wittkung/ttzip-core.git", branch: "main")

let corePackageName = isLocalCoreAvailable ? "core" : "ttzip-core"

let swiftSettings: [SwiftSetting] = [
    .define("GL_SILENCE_DEPRECATION"),
    .unsafeFlags(["-Xcc", "-DGL_SILENCE_DEPRECATION"]),
    .enableUpcomingFeature("StrictConcurrency")
]

let package = Package(
    name: "TTZipApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "TTZipApp", targets: ["TTZipApp"]),
        .library(name: "TTZipUI", targets: ["TTZipUI"]),
        .library(name: "TTZipPreviewKit", targets: ["TTZipPreviewKit"]),
        .library(name: "TTZipBenchmarkKit", targets: ["TTZipBenchmarkKit"]),
        .library(name: "TTZipPluginKit", targets: ["TTZipPluginKit"]),
        .library(name: "TTZipQuickLook", type: .dynamic, targets: ["TTZipQuickLook"]),
        .library(name: "TTZipFinderSync", type: .dynamic, targets: ["TTZipFinderSync"])
    ],
    dependencies: [
        coreDependency,
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.0")
    ],
    targets: [
        .target(
            name: "CMPVBridge",
            path: "Sources/CMPVBridge",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .define("GL_SILENCE_DEPRECATION")
            ],
            linkerSettings: [
                .linkedLibrary("mpv"),
                .unsafeFlags([
                    "-LFrameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../../../../../Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../../../../Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../../../Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../../Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .target(
            name: "TTZipUI",
            dependencies: [
                .product(name: "TTZipCore", package: corePackageName)
            ],
            path: "Sources/TTZipUI",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "TTZipPluginKit",
            dependencies: [
                .product(name: "TTZipCore", package: corePackageName)
            ],
            path: "Sources/TTZipPluginKit",
            exclude: [
                "README.md",
                "README.zh-CN.md"
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "TTZipPreviewKit",
            dependencies: [
                .product(name: "TTZipCore", package: corePackageName),
                "TTZipUI",
                "TTZipPluginKit",
                "CMPVBridge"
            ],
            path: "Sources/TTZipPreviewKit",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "TTZipBenchmarkKit",
            dependencies: [
                .product(name: "TTZipCore", package: corePackageName),
                "TTZipUI"
            ],
            path: "Sources/TTZipBenchmarkKit",
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "TTZipApp",
            dependencies: [
                .product(name: "TTZipCore", package: corePackageName),
                .product(name: "Sparkle", package: "Sparkle"),
                "TTZipUI",
                "TTZipPreviewKit",
                "TTZipBenchmarkKit",
                "TTZipPluginKit",
                "CMPVBridge"
            ],
            path: "Sources/TTZipApp",
            exclude: [
                "Info.plist",
                "TTZip.entitlements",
                "TTZip-Direct.entitlements"
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "TTZipQuickLook",
            dependencies: [
                .product(name: "TTZipCore", package: corePackageName)
            ],
            path: "Sources/TTZipQuickLook",
            exclude: ["Info.plist"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "TTZipFinderSync",
            dependencies: [
                .product(name: "TTZipCore", package: corePackageName)
            ],
            path: "Sources/TTZipFinderSync",
            exclude: ["Info.plist"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "TTZipAppTests",
            dependencies: [
                "TTZipApp",
                "TTZipUI",
                "TTZipPreviewKit",
                "TTZipBenchmarkKit",
                "TTZipPluginKit",
                "TTZipFinderSync",
                "TTZipQuickLook",
                "CMPVBridge",
                .product(name: "TTZipCore", package: corePackageName)
            ],
            path: "Tests/TTZipAppTests",
            swiftSettings: swiftSettings
        )
    ]
)
