// swift-tools-version: 6.0
// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0
//
// TTMediaKit: Universal Media & Document Kit integrating TTMPV and Metal pipelines.

import PackageDescription
import Foundation

let packageDependencies: [Package.Dependency] = [
    .package(path: "../ttkit"),
    .package(path: "../tti18n/apple/TTI18n")
]
let targetDependencies: [Target.Dependency] = [
    .product(name: "TTKitCore", package: "ttkit"),
    .product(name: "TTKitDesign", package: "ttkit"),
    .product(name: "TTI18nUI", package: "tti18n"),
    .product(name: "TTI18nCore", package: "tti18n")
]


let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

let package = Package(
    name: "TTMediaKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "TTMediaKit", targets: ["TTMediaKit"])
    ],
    dependencies: packageDependencies,
    targets: [
        .systemLibrary(
            name: "TTMediaDemux",
            path: "include"
        ),
        .binaryTarget(
            name: "TTMediaVendor",
            path: "Frameworks/TTMediaVendor.xcframework"
        ),
        .target(
            name: "TTMediaKit",
            dependencies: targetDependencies + ["TTMediaDemux", "TTMediaVendor"],
            path: "Sources/TTMediaKit",
            resources: [
                .process("Shaders")
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "TTMediaKitTests",
            dependencies: [
                "TTMediaKit"
            ],
            path: "Tests/TTMediaKitTests",
            swiftSettings: swiftSettings
        )
    ]
)
