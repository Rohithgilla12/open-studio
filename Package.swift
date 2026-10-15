// swift-tools-version: 6.2
import PackageDescription

let xcodeProjectDefaults: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "open-studio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Recording", targets: ["Recording"]),
        .library(name: "Timeline", targets: ["Timeline"]),
        .library(name: "Render", targets: ["Render"]),
        .library(name: "Studio", targets: ["Studio"]),
        .executable(name: "osrec", targets: ["osrec"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "RecordingFormat",
            swiftSettings: xcodeProjectDefaults
        ),
        .target(
            name: "Recording",
            dependencies: ["RecordingFormat"],
            swiftSettings: xcodeProjectDefaults,
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
            ]
        ),
        .target(
            name: "Timeline",
            dependencies: ["RecordingFormat"],
            swiftSettings: xcodeProjectDefaults
        ),
        .target(
            name: "Render",
            dependencies: ["Timeline"],
            swiftSettings: xcodeProjectDefaults,
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .target(
            name: "Studio",
            dependencies: ["Recording", "RecordingFormat", "Render", "Timeline"],
            swiftSettings: xcodeProjectDefaults,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .executableTarget(
            name: "osrec",
            dependencies: [
                "Recording",
                "Render",
                "Timeline",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: xcodeProjectDefaults
        ),
        .testTarget(
            name: "RecordingFormatTests",
            dependencies: ["RecordingFormat"],
            swiftSettings: xcodeProjectDefaults
        ),
        .testTarget(
            name: "RecordingTests",
            dependencies: ["Recording"],
            swiftSettings: xcodeProjectDefaults
        ),
        .testTarget(
            name: "TimelineTests",
            dependencies: ["Timeline"],
            swiftSettings: xcodeProjectDefaults
        ),
        .testTarget(
            name: "RenderTests",
            dependencies: ["Render", "Timeline"],
            swiftSettings: xcodeProjectDefaults
        ),
        .testTarget(
            name: "StudioTests",
            dependencies: ["Studio", "Recording", "Render", "Timeline"],
            swiftSettings: xcodeProjectDefaults
        ),
    ]
)
