// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SwiftDM",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SwiftDM", targets: ["SwiftDM"]),
    ],
    targets: [
        // Download engine, parsers and protocol helpers. No UI, fully testable.
        .target(name: "SwiftDMCore"),
        // The macOS app (SwiftUI + AppKit).
        .executableTarget(name: "SwiftDM", dependencies: ["SwiftDMCore"]),
        .testTarget(name: "SwiftDMCoreTests", dependencies: ["SwiftDMCore"]),
    ]
)
