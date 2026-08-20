// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GotTimeCore",
    // .macOS is needed even though this package only ships on iOS: `swift test` (used by
    // ios-ci.yml to test this package directly, without the full Xcode project) runs
    // natively ON macOS, not iOS. Without an explicit macOS minimum, SwiftPM falls back to
    // an old default deployment target that predates AsyncStream and other Concurrency APIs
    // this package uses, causing a build failure that has nothing to do with iOS at all.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GotTimeCore", targets: ["GotTimeCore"])
    ],
    targets: [
        .target(name: "GotTimeCore"),
        .testTarget(name: "GotTimeCoreTests", dependencies: ["GotTimeCore"])
    ]
)
