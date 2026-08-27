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
                .headerSearchPath("include")
            ],
            linkerSettings: [
                .linkedLibrary("mpv"),
                .unsafeFlags([
                    "-LVendor",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../../../../../Vendor",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../../../../Vendor",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../../../Vendor",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../../Vendor",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
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
        .executableTarget(
            name: "TTZipApp",
            dependencies: [
                .product(name: "TTZipCore", package: corePackageName),
                .product(name: "Sparkle", package: "Sparkle"),
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
