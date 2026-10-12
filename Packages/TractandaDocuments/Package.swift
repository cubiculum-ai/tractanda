// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TractandaDocuments",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DoclingRGB", targets: ["DoclingRGB"]),
        .library(name: "DoclingRaster", targets: ["DoclingRaster"]),
        .executable(name: "tractanda-document-converter", targets: ["TractandaDocumentConverter"]),
        .executable(name: "docling-raster-check", targets: ["DoclingRasterCheck"]),
        .executable(name: "docling-rgb-check", targets: ["DoclingRGBCheck"]),
    ],
    dependencies: [
        .package(path: "../TractandaClient"),
        .package(
            url: "https://github.com/osaurus-ai/vmlx-swift.git",
            revision: "61a4b20d4ad01b10466e8fc94c50402a9f994430"),
    ],
    targets: [
        .target(name: "DoclingRGB"),
        .target(
            name: "DoclingRaster",
            dependencies: ["DoclingRGB", .product(name: "TractandaClient", package: "TractandaClient")]),
        .executableTarget(name: "DoclingRasterCheck", dependencies: ["DoclingRaster", "DoclingRGB"]),
        .executableTarget(name: "DoclingRGBCheck", dependencies: ["DoclingRGB"]),
        .executableTarget(
            name: "TractandaDocumentConverter",
            dependencies: [
                "DoclingRGB", "DoclingRaster",
                .product(name: "TractandaClient", package: "TractandaClient"),
                .product(name: "MLXVLM", package: "vmlx-swift"),
                .product(name: "MLXLMCommon", package: "vmlx-swift"),
                .product(name: "MLXHuggingFace", package: "vmlx-swift"),
                .product(name: "VMLXTokenizers", package: "vmlx-swift"),
                .product(name: "MLXNN", package: "vmlx-swift"),
                .product(name: "MLX", package: "vmlx-swift"),
            ], resources: [.copy("Resources/ModelAssets.json")]),
    ],
    swiftLanguageModes: [.v6]
)
