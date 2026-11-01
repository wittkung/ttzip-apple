// swift-tools-version: 6.0
// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
    .unsafeFlags(["-strict-concurrency=complete", "-warnings-as-errors"]),
]

let package = Package(
    name: "TTI18n",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "TTI18n",
            targets: ["TTI18nCore", "TTI18nUI", "TTI18nAppKit", "TTI18nIPC"]
        ),
        .library(
            name: "TTI18nCore",
            targets: ["TTI18nCore"]
        ),
        .library(
            name: "TTI18nUI",
            targets: ["TTI18nUI"]
        ),
        .library(
            name: "TTI18nAppKit",
            targets: ["TTI18nAppKit"]
        ),
        .library(
            name: "TTI18nIPC",
            targets: ["TTI18nIPC"]
        ),
    ],
    targets: [
        .target(
            name: "TTI18nCore",
            path: "Sources/TTI18nCore",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "TTI18nIPC",
            dependencies: ["TTI18nCore"],
            path: "Sources/TTI18nIPC",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "TTI18nUI",
            dependencies: ["TTI18nCore", "TTI18nIPC"],
            path: "Sources/TTI18nUI",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "TTI18nAppKit",
            dependencies: ["TTI18nCore"],
            path: "Sources/TTI18nAppKit",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "TTI18nTests",
            dependencies: ["TTI18nCore", "TTI18nUI", "TTI18nAppKit", "TTI18nIPC"],
            path: "Tests/TTI18nTests",
            swiftSettings: swiftSettings
        ),
    ]
)
