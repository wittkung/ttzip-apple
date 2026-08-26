// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>
// All rights reserved.
//
// TTZip: High-performance native archiving and compression engine.

import PackageDescription

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
        .library(name: "TTZipQuickLook", type: .dynamic, targets: ["TTZipQuickLook"]),
        .library(name: "TTZipFinderSync", type: .dynamic, targets: ["TTZipFinderSync"])
    ],
    dependencies: [
        .package(path: "../core"),
        .package(path: "../ttkit-localization/TTLocalizationKit"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "TTZipApp",
            dependencies: [
                .product(name: "TTZipCore", package: "core"),
                .product(name: "TTLocalizationKit", package: "TTLocalizationKit"),
                .product(name: "Sparkle", package: "Sparkle")
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
                .product(name: "TTZipCore", package: "core")
            ],
            path: "Sources/TTZipQuickLook",
            exclude: ["Info.plist"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "TTZipFinderSync",
            dependencies: [
                .product(name: "TTZipCore", package: "core")
            ],
            path: "Sources/TTZipFinderSync",
            exclude: ["Info.plist"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "TTZipAppTests",
            dependencies: ["TTZipApp"],
            path: "Tests/TTZipAppTests",
            swiftSettings: swiftSettings
        )
    ]
)
