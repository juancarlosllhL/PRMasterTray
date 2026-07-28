// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PRMaster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PRMaster", targets: ["PRMaster"]),
    ],
    targets: [
        // Pure, testable core: no AppKit, no SwiftUI.
        .target(name: "PRMasterCore"),
        // Menu bar app shell.
        .executableTarget(name: "PRMaster", dependencies: ["PRMasterCore"]),
        .testTarget(
            name: "PRMasterCoreTests",
            dependencies: ["PRMasterCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
