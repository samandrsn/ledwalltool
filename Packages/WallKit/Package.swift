// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WallKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WallKit", targets: ["WallKit"])
    ],
    targets: [
        .target(name: "WallKit"),
        .testTarget(name: "WallKitTests", dependencies: ["WallKit"])
    ]
)
