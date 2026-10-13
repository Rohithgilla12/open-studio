// swift-tools-version: 6.2
import PackageDescription

// The app (later unit) is a thin checked-in Xcode project in App/ that depends on this package by
// local path. It owns the bundle identifier, usage strings, entitlements, and signing, so nothing
// here needs a bundle and `swift build` and `swift test` keep working.

let strictConcurrency: [SwiftSetting] = [
    // Match the Xcode 27 project defaults so library code behaves the same inside the app target.
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
        .executable(name: "osrec", targets: ["osrec"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // The on-disk contract. Not a product: Recording and Timeline import it with
        // `internal import`, so wire types cannot appear on either public API.
        .target(
            name: "RecordingFormat",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "Recording",
            dependencies: ["RecordingFormat"],
            swiftSettings: strictConcurrency,
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
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "osrec",
            dependencies: [
                "Recording",
                "Timeline",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "RecordingFormatTests",
            dependencies: ["RecordingFormat"],
            swiftSettings: strictConcurrency
        ),
        // Pure parts only. Capture itself is verified with `osrec record` on real hardware, because
        // CI has no Screen Recording grant.
        .testTarget(
            name: "RecordingTests",
            dependencies: ["Recording"],
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "TimelineTests",
            // Fixtures/recordings is found through #filePath rather than declared as a resource:
            // SwiftPM rejects resource paths outside the target directory, and the fixtures are
            // shared with the osrec smoke checks.
            dependencies: ["Timeline"],
            swiftSettings: strictConcurrency
        ),
    ]
)
