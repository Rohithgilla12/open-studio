// swift-tools-version: 6.0
import PackageDescription

// Dependency direction (no cycles, no sideways imports):
//
//   osrec ──► Recording ──► RecordingFormat ◄── Timeline
//
// RecordingFormat owns the on-disk contract and nothing else. Timeline never
// sees Recording, so it cannot pull in AppKit, ScreenCaptureKit or AVFoundation.
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
        .target(name: "RecordingFormat"),
        .target(
            name: "Recording",
            dependencies: ["RecordingFormat"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
            ]
        ),
        .target(name: "Timeline", dependencies: ["RecordingFormat"]),
        .executableTarget(
            name: "osrec",
            dependencies: [
                "Recording", "Timeline", "RecordingFormat",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                // A bare CLI has no bundle, so TCC's microphone prompt needs the plist
                // embedded in the Mach-O. Screen Recording and Input Monitoring attach
                // to the terminal app (the responsible process), not to osrec.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist", "-Xlinker", "Sources/osrec/Info.plist",
                ]),
            ]
        ),
        // Tests find Fixtures/recordings through #filePath, because SwiftPM resources
        // cannot point outside the target directory.
        .testTarget(
            name: "RecordingFormatTests",
            dependencies: ["RecordingFormat"]
        ),
        .testTarget(
            name: "TimelineTests",
            dependencies: ["Timeline", "RecordingFormat"]
        ),
        .testTarget(name: "RecordingTests", dependencies: ["Recording"]),
    ]
)
