// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TractandaEmbeddings",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/osaurus-ai/vmlx-swift.git",
            revision: "d47c8d0dad91d8c0628a24a5a2c4cada082dc2ee"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        .executableTarget(
            name: "TractandaEmbeddingsHost",
            dependencies: [
                .product(name: "MLX", package: "vmlx-swift"),
                .product(name: "MLXEmbedders", package: "vmlx-swift"),
                .product(name: "MLXLMCommon", package: "vmlx-swift"),
                .product(name: "VMLXTokenizers", package: "vmlx-swift"),
                .product(name: "MLXHuggingFace", package: "vmlx-swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
