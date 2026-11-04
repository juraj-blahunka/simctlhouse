// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "simctlhouse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "simctlhouse", targets: ["simctlhouse"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "simctlhouse",
            dependencies: [
                "SimctlHouseCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "SimctlHouseCore"),
        .testTarget(name: "SimctlHouseCoreTests", dependencies: ["SimctlHouseCore"]),
        .testTarget(name: "SimctlHouseTests", dependencies: ["simctlhouse", "SimctlHouseCore"]),
    ]
)
