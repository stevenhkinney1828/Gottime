// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GotTimeMocks",
    // See the matching comment in GotTimeCore/Package.swift — same reason needed here.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GotTimeMocks", targets: ["GotTimeMocks"])
    ],
    dependencies: [
        .package(path: "../GotTimeCore")
    ],
    targets: [
        .target(name: "GotTimeMocks", dependencies: ["GotTimeCore"]),
        .testTarget(name: "GotTimeMocksTests", dependencies: ["GotTimeMocks"])
    ]
)
