// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ZuluKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ZulipAPI", targets: ["ZulipAPI"]),
        .library(name: "ZuluStore", targets: ["ZuluStore"]),
        .library(name: "ZuluSync", targets: ["ZuluSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "ZulipAPI"),
        .target(name: "ZuluStore", dependencies: [
            "ZulipAPI",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "ZuluSync", dependencies: ["ZulipAPI", "ZuluStore"]),
        .testTarget(name: "ZuluStoreTests", dependencies: ["ZuluStore"]),
    ]
)
