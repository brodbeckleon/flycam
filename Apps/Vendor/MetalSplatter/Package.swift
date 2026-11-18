// swift-tools-version: 6.1
// Vendored copy of MetalSplatter 1.0.1 (https://github.com/scier/MetalSplatter, tag 1.0.1,
// commit 71ff248e3016ac43c0a9271e322538421b28c360, MIT licence, see LICENSE).
// Changes against upstream are listed in VENDORED.md.

import PackageDescription

let package = Package(
    name: "MetalSplatter",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "PLYIO", targets: ["PLYIO"]),
        .library(name: "SplatIO", targets: ["SplatIO"]),
        .library(name: "MetalSplatter", targets: ["MetalSplatter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scier/spz-swift.git", exact: "2.1.0"),
    ],
    targets: [
        .target(name: "PLYIO", path: "PLYIO", sources: ["Sources"]),
        .target(
            name: "SplatIO",
            dependencies: ["PLYIO", .product(name: "spz", package: "spz-swift")],
            path: "SplatIO",
            sources: ["Sources"]
        ),
        .target(
            name: "MetalSplatter",
            dependencies: ["PLYIO", "SplatIO"],
            path: "MetalSplatter",
            sources: ["Sources"],
            // Shader sources are copied, not compiled: they are compiled at runtime (VENDORED.md).
            resources: [.copy("Shaders")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
