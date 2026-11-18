// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlyCamKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FlyCamKit", targets: ["FlyCamKit"]),
        .executable(name: "flycam-golden", targets: ["FlyCamGolden"]),
    ],
    targets: [
        .target(name: "FlyCamKit"),
        // Golden files shared with Tools/ (docs/protocol.md section 6). Not part of the apps.
        .target(name: "FlyCamGoldenSupport", dependencies: ["FlyCamKit"]),
        .executableTarget(name: "FlyCamGolden", dependencies: ["FlyCamKit", "FlyCamGoldenSupport"]),
        .testTarget(name: "FlyCamKitTests", dependencies: ["FlyCamKit", "FlyCamGoldenSupport"]),
    ]
)
