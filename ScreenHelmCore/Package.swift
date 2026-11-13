// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenHelmCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScreenHelmCore", targets: ["ScreenHelmCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "ScreenHelmCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "ScreenHelmCoreTests", dependencies: ["ScreenHelmCore"]),
    ]
)
