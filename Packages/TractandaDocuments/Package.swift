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

#if os(Linux)
// The reviewed build driver supplies a verified, target-specific native prefix.
// These support libraries are bundled package inputs, never a host service.
guard let native = Context.environment["TRACTANDA_DOCLING_NATIVE_PREFIX"],
    native.hasPrefix("/"), !native.contains("\0") else {
    fatalError("Linux Docling requires its verified private native build prefix")
}
package.dependencies.append(.package(
    url: "https://github.com/apple/swift-crypto.git",
    exact: "4.5.2"))
package.targets.append(.target(
    name: "CDoclingRaster", path: "Sources/CDoclingRaster",
    exclude: ["raster.c", "png.c", "jpeg.c", "color.c", "metadata.c", "images.exports", "pdf.exports", "internal.h"],
    sources: ["module.c"], publicHeadersPath: "include",
    linkerSettings: [.unsafeFlags(["-L" + native + "/lib", "-Xlinker", "-rpath", "-Xlinker", "$ORIGIN/../lib/tractanda/document-native"]),
        .linkedLibrary("tractanda_docling_pdf")]))
for target in package.targets where ["DoclingRaster", "TractandaDocumentConverter"].contains(target.name) {
    target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
    if target.name == "DoclingRaster" { target.dependencies.append("CDoclingRaster") }
}
// This existing check generates Mac fixtures with CoreGraphics; the portable
// regression target below supplies Linux checks without pulling Apple frameworks.
package.products.removeAll { $0.name == "docling-raster-check" }
package.targets.removeAll { $0.name == "DoclingRasterCheck" }
#endif
package.targets.append(.testTarget(name: "DoclingRasterTests", dependencies: ["DoclingRaster", "DoclingRGB"],
    resources: [.copy("Fixtures")]))
