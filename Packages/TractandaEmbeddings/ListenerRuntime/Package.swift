// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TractandaListenerRuntime",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TractandaListenerRuntime", targets: ["TractandaListenerRuntime"])],
    dependencies: [.package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3")],
    targets: [
        .target(
            name: "TractandaListenerRuntime",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "TractandaListenerRuntimeTests",
            dependencies: [
                "TractandaListenerRuntime",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
