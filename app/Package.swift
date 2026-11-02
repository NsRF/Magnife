// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Magnife",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
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
            dependencies: ["MagnifeKit", .product(name: "GRDB", package: "GRDB.swift")],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "MagnifeKitTests",
            dependencies: ["MagnifeKit", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
