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

let ttmpvDependencyResolution: (dependency: Package.Dependency, packageName: String) = {
    // Tier 1: Explicit environment variable override
    if let envPath = ProcessInfo.processInfo.environment["TTMPV_PATH"],
       FileManager.default.fileExists(atPath: "\(envPath)/Package.swift") {
        return (.package(path: envPath), "ttmpv")
    }

    // Tier 2: Standard peer workspace probe (e.g. products/ttmpv)
    if ProcessInfo.processInfo.environment["TTZIP_USE_REMOTE_MPV"] != "1" {
        let peerManifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../ttmpv/Package.swift")
            .standardized
        if FileManager.default.fileExists(atPath: peerManifest.path) {
            return (.package(path: "../../ttmpv"), "ttmpv")
        }
    }

    // Tier 3: Remote GitHub repository fallback for external machines and CI
    return (.package(url: "https://github.com/wittkung/ttmpv.git", branch: "main"), "ttmpv")
}()

let mpvDependency = ttmpvDependencyResolution.dependency
let mpvPackageName = ttmpvDependencyResolution.packageName

let swiftSettings: [SwiftSetting] = [
    .define("GL_SILENCE_DEPRECATION"),
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
        .library(name: "TTZipPluginKit", type: .dynamic, targets: ["TTZipPluginKit"]),
        .library(name: "TTZipQuickLook", type: .dynamic, targets: ["TTZipQuickLook"]),
        .library(name: "TTZipFinderSync", type: .dynamic, targets: ["TTZipFinderSync"]),
        .library(name: "TTZipFileProvider", type: .dynamic, targets: ["TTZipFileProvider"])
    ],
    dependencies: [
        coreDependency,
        mpvDependency,
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
                    "-Xlinker", "@loader_path/../../Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@loader_path/../../../Frameworks",
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
            dependencies: [],
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
                .product(name: "TTMPVKit", package: mpvPackageName),
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
        .target(
            name: "TTZipFileProvider",
            dependencies: [
                .product(name: "TTZipCore", package: corePackageName)
            ],
            path: "Sources/TTZipFileProvider",
            exclude: [
                "Info.plist",
                "TTZipFileProvider.entitlements"
            ],
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
                "TTZipFileProvider",
                "CMPVBridge",
                .product(name: "TTZipCore", package: corePackageName)
            ],
            path: "Tests/TTZipAppTests",
            swiftSettings: swiftSettings
        )
    ]
)
