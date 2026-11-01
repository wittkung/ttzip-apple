// swift-tools-version: 6.0
// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import PackageDescription

let package = Package(
    name: "TTKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "TTKitCore", targets: ["TTKitCore"]),
        .library(name: "TTKitFluid", targets: ["TTKitFluid"]),
        .library(name: "TTKitDesign", targets: ["TTKitDesign"]),
        .library(name: "TTKitUI", targets: ["TTKitUI"]),
        .library(name: "TTKit", targets: ["TTKitCore", "TTKitFluid", "TTKitDesign", "TTKitUI", "TTKit"]),
        .executable(name: "TTKitShowcaseApp", targets: ["TTKitShowcaseApp"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TTKitCore",
            dependencies: [],
            path: "Sources/TTKitCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "TTKitDesign",
            dependencies: ["TTKitCore"],
            path: "Sources/TTKitDesign",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "TTKitFluid",
            dependencies: ["TTKitCore", "TTKitDesign"],
            path: "Sources/TTKitFluid",
            resources: [
                .process("Shaders")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "TTKitUI",
            dependencies: [
                "TTKitCore",
                "TTKitDesign",
                "TTKitFluid"
            ],
            path: "Sources/TTKitUI",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "TTKit",
            dependencies: [
                "TTKitCore",
                "TTKitFluid",
                "TTKitDesign",
                "TTKitUI"
            ],
            path: "Sources/TTKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "TTKitCoreTests",
            dependencies: ["TTKitCore"],
            path: "Tests/TTKitCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "TTKitFluidTests",
            dependencies: [
                "TTKitCore",
                "TTKitDesign",
                "TTKitFluid"
            ],
            path: "Tests/TTKitFluidTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "TTKitDesignTests",
            dependencies: [
                "TTKitCore",
                "TTKitDesign"
            ],
            path: "Tests/TTKitDesignTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "TTKitTests",
            dependencies: [
                "TTKitCore",
                "TTKitDesign",
                "TTKitFluid",
                "TTKitUI",
                "TTKit"
            ],
            path: "Tests/TTKitTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "TTKitShowcaseApp",
            dependencies: [
                "TTKitCore",
                "TTKitDesign",
                "TTKitFluid",
                "TTKitUI",
                "TTKit"
            ],
            path: "Sources/TTKitShowcaseApp",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
