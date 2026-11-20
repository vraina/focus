// swift-tools-version:5.9
import PackageDescription

// No third-party dependencies: the Mac talks to the family service over HTTPS, never to a database.
let package = Package(
    name: "FocusSprint",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FocusSprintCore"),
        .executableTarget(name: "FocusSprint", dependencies: ["FocusSprintCore"]),
        .executableTarget(name: "focussprint-vaultd", dependencies: ["FocusSprintCore"]),
        .testTarget(name: "FocusSprintCoreTests", dependencies: ["FocusSprintCore"]),
    ]
)
