// swift-tools-version: 6.2
// Type-checks the candidate sketch against the real Timeline and Recording products. In the
// implementation these targets move into the root Package.swift (see rationale, Module map).
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "open-studio-render-sketch",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(name: "open-studio", path: "../../../.."),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Render",
            dependencies: [.product(name: "Timeline", package: "open-studio")],
            swiftSettings: settings),
        .target(
            name: "Studio",
            dependencies: [
                "Render",
                .product(name: "Timeline", package: "open-studio"),
                .product(name: "Recording", package: "open-studio"),
            ],
            swiftSettings: settings),
        .executableTarget(
            name: "osrec-export",
            dependencies: [
                "Render",
                .product(name: "Timeline", package: "open-studio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/osrec",
            swiftSettings: settings),
        .testTarget(
            name: "RenderTests",
            dependencies: ["Render", .product(name: "Timeline", package: "open-studio")],
            swiftSettings: settings),
    ]
)
