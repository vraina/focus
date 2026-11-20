// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FocusSprint",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", from: "7.9.0"),
    ],
    targets: [
        .target(
            name: "FocusSprintCore",
            dependencies: [.product(name: "MongoKitten", package: "MongoKitten")]
        ),
        .executableTarget(name: "FocusSprint", dependencies: ["FocusSprintCore"]),
        .executableTarget(name: "focussprint-vaultd", dependencies: ["FocusSprintCore"]),
        .testTarget(name: "FocusSprintCoreTests", dependencies: ["FocusSprintCore"]),
    ]
)
