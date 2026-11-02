// swift-tools-version: 6.0
// Copyright 2026 MetastudyLine. All rights reserved.
// SPDX-License-Identifier: MIT OR Apache-2.0

import PackageDescription
import Foundation

let coreDependency: Package.Dependency = .package(url: "https://github.com/wittkung/ttzip-core.git", exact: "0.1.1")
let corePackageName = "ttzip-core"

let appCoreDependency: Package.Dependency = .package(url: "https://github.com/wittkung/ttzip-app-core.git", exact: "0.1.1")
let appCorePackageName = "ttzip-app-core"

let ttmediaDependency: Package.Dependency = .package(path: "vendor/ttmedia")
let ttmediaPackageName = "ttmedia"

let ttlogPackage: Package.Dependency = .package(url: "https://github.com/wittkung/ttlog.git", exact: "1.0.1")
let ttlogPackageName = "ttlog"

let ttkitPackage: Package.Dependency = .package(path: "vendor/ttkit")
let ttkitPackageName = "ttkit"

let isMASBuild = ProcessInfo.processInfo.environment["TTZIP_CHANNEL"] == "mas"
    || ProcessInfo.processInfo.environment["MAS_BUILD"] == "1"

var swiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-Xcc", "-DGL_SILENCE_DEPRECATION"]),
    .define("GL_SILENCE_DEPRECATION"),
    .enableUpcomingFeature("StrictConcurrency")
]

if isMASBuild {
    swiftSettings.append(.define("MAS_BUILD"))
}

var packageDependencies: [Package.Dependency] = [
    coreDependency,
    appCoreDependency,
    ttmediaDependency,
    ttlogPackage,
    ttkitPackage,
    .package(path: "vendor/tti18n/apple/TTI18n"),
]

if !isMASBuild {
    packageDependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.6.0"))
}

var appDependencies: [Target.Dependency] = [
    .product(name: "TTZipCore", package: corePackageName),
    .product(name: "TTZipAppCore", package: appCorePackageName),
    .product(name: "CTTZipAppCoreBridge", package: appCorePackageName),
    .product(name: "TTLogKit", package: ttlogPackageName),
    .product(name: "TTMediaKit", package: ttmediaPackageName),
    .product(name: "TTKitCore", package: ttkitPackageName),
    .product(name: "TTKitDesign", package: ttkitPackageName),
    .product(name: "TTKitFluid", package: ttkitPackageName),
    .product(name: "TTKitUI", package: ttkitPackageName),
]

if !isMASBuild {
    appDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
}

appDependencies.append(contentsOf: [
    "TTZipUI",
    "TTZipPreviewKit",
    "TTZipBenchmarkKit"
])

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
        .library(name: "TTZipQuickLook", type: .dynamic, targets: ["TTZipQuickLook"]),
        .library(name: "TTZipFinderSync", type: .dynamic, targets: ["TTZipFinderSync"])
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "TTZipUI",
            dependencies: [
                .product(name: "TTI18nUI", package: "tti18n"),
                .product(name: "TTI18nCore", package: "tti18n"),
                .product(name: "TTZipCore", package: corePackageName),
                .product(name: "TTKitDesign", package: ttkitPackageName),
                .product(name: "TTKitFluid", package: ttkitPackageName),
                .product(name: "TTKitUI", package: ttkitPackageName)
            ],
            path: "Sources/TTZipUI",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "TTZipPreviewKit",
            dependencies: [
                .product(name: "TTZipAppCore", package: appCorePackageName),
                .product(name: "TTZipCore", package: corePackageName),
                .product(name: "TTMediaKit", package: ttmediaPackageName),
                "TTZipUI"
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
            dependencies: appDependencies,
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
            exclude: [
                "Info.plist",
                "TTZipFinderSync.entitlements"
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "TTZipCoreSmokeTests",
            dependencies: [
                .product(name: "TTZipCore", package: corePackageName)
            ],
            path: "Tests/TTZipCoreSmokeTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
