// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Atlas",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AtlasCore", targets: ["AtlasCore"]),
        .executable(name: "atlas", targets: ["atlas"]),
    ],
    targets: [
        .target(
            name: "AtlasCore",
            resources: [.embedInCode("Resources/atlas.json")]
        ),
        .target(
            name: "AtlasServer",
            dependencies: ["AtlasCore"],
            resources: [.copy("Public")]
        ),
        .executableTarget(
            name: "atlas",
            dependencies: ["AtlasCore", "AtlasServer"]
        ),
        // The test suite is an executable, not a .testTarget: XCTest ships with
        // Xcode, and this project is built with the command-line tools alone,
        // where `swift test` cannot run at all.  Tests/AtlasCoreTests/Harness.swift
        // supplies the handful of assertions XCTest would have.
        //
        //     swift run atlastests [suite-name-filter]
        .executableTarget(
            name: "atlastests",
            dependencies: ["AtlasCore", "AtlasServer"],
            path: "Tests/AtlasCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
