// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GotTimeCore",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "GotTimeCore", targets: ["GotTimeCore"])
    ],
    targets: [
        .target(name: "GotTimeCore"),
        .testTarget(name: "GotTimeCoreTests", dependencies: ["GotTimeCore"])
    ]
)
