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
        .executableTarget(name: "FlyCamGolden", dependencies: ["FlyCamKit"]),
        .testTarget(name: "FlyCamKitTests", dependencies: ["FlyCamKit"]),
    ]
)
