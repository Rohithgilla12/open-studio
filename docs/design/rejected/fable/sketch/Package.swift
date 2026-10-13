// swift-tools-version: 6.0
import PackageDescription

// SwiftPM-only for this unit. The SwiftUI app (later) is an Xcode project under App/
// that depends on this package by local path; it supplies the bundle identity and
// entitlements. Libraries stay buildable and testable with `swift build` / `swift test`.
let package = Package(
    name: "open-studio",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RecordingFormat", targets: ["RecordingFormat"]),
        .library(name: "Recording", targets: ["Recording"]),
        .library(name: "Timeline", targets: ["Timeline"]),
        .executable(name: "osrec", targets: ["osrec"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // The on-disk contract. Wire types, format version, NDJSON codec. Foundation only.
        .target(name: "RecordingFormat"),

        // Capture. The only module that links AppKit, ScreenCaptureKit, AVFoundation.
        .target(
            name: "Recording",
            dependencies: ["RecordingFormat"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AppKit"),
            ]
        ),

        // Pure domain. Depends on RecordingFormat for parsing only; its public API never
        // exposes a wire type. Load.swift is the one file allowed to touch the file system.
        .target(name: "Timeline", dependencies: ["RecordingFormat"]),

        .executableTarget(
            name: "osrec",
            dependencies: [
                "Recording",
                "Timeline",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // Fixtures live at Fixtures/recordings/ (repo root) and are located with #filePath,
        // because SwiftPM resources must sit inside the target directory and we want the
        // fixture to be a real recording directory that osrec can also inspect.
        .testTarget(name: "TimelineTests", dependencies: ["Timeline"]),
        .testTarget(name: "RecordingTests", dependencies: ["Recording"]),
        .testTarget(name: "RecordingFormatTests", dependencies: ["RecordingFormat"]),
    ],
    swiftLanguageModes: [.v6]
)
