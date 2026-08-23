// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (c) 2026 Witt Kung <witt.w.kung@gmail.com>

import PackageDescription

let package = Package(
    name: "TTZipApp",
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
        .package(url: "https://github.com/wittkung/ttzip-core.git", branch: "main"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "TTZipApp",
            dependencies: [
                .product(name: "TTZipCore", package: "ttzip-core"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/TTZipApp"
        ),
        .target(
            name: "TTZipQuickLook",
            dependencies: [
                .product(name: "TTZipCore", package: "ttzip-core")
            ],
            path: "Sources/TTZipQuickLook"
        ),
        .target(
            name: "TTZipFinderSync",
            dependencies: [
                .product(name: "TTZipCore", package: "ttzip-core")
            ],
            path: "Sources/TTZipFinderSync"
        ),
        .testTarget(
            name: "TTZipAppTests",
            dependencies: ["TTZipApp"],
            path: "Tests/TTZipAppTests"
        )
    ]
)
