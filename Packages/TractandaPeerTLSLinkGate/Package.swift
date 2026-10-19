// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TractandaPeerTLSLinkGate",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../.."),
        .package(path: "../TractandaPeerTLS"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
    ],
    targets: [
        .testTarget(
            name: "PeerTLSLinkGateTests",
            dependencies: [
                .product(name: "TractandaCore", package: "Tractanda"),
                .product(name: "TractandaPeerTLS", package: "TractandaPeerTLS"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ])
    ],
    swiftLanguageModes: [.v6]
)
