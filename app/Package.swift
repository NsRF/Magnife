// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Magnife",
    platforms: [.macOS(.v26)],
    // Software updates (Sparkle 2) are opt-in: `swift build --traits Sparkle`,
    // which build.sh passes when MAGNIFE_SPARKLE=1. Without the trait SwiftPM
    // neither fetches nor links Sparkle, and the app has no updater.
    traits: [
        .trait(name: "Sparkle", description: "Link Sparkle 2 and show Check for Updates…"),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Data reading, helper supervision, and formatting rules with no
        // SwiftUI, so tests run without the app.
        .target(
            name: "MagnifeKit",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "Magnife",
            dependencies: [
                "MagnifeKit",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle", condition: .when(traits: ["Sparkle"])),
            ],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .define("MAGNIFE_SPARKLE", .when(traits: ["Sparkle"])),
            ]
        ),
        .testTarget(
            name: "MagnifeKitTests",
            dependencies: ["MagnifeKit", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
