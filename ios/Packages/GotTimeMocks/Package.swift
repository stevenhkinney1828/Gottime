// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GotTimeMocks",
    platforms: [.iOS(.v17)],
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
