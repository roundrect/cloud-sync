// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cloud-sync",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CloudSync", targets: ["CloudSync"]),
    ],
    targets: [
        .target(name: "CloudSync"),
        .testTarget(name: "CloudSyncTests", dependencies: ["CloudSync"]),
    ]
)
