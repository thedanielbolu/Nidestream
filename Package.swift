// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nidestream",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Nidestream", targets: ["Nidestream"]),
    ],
    targets: [
        // Download engine, parsers and protocol helpers. No UI, fully testable.
        .target(name: "NidestreamCore"),
        // The macOS app (SwiftUI + AppKit).
        .executableTarget(name: "Nidestream", dependencies: ["NidestreamCore"]),
        .testTarget(name: "NidestreamCoreTests", dependencies: ["NidestreamCore"]),
    ]
)
