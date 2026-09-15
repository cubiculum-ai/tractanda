// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TractandaClient",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "TractandaClient", targets: ["TractandaClient"])],
    targets: [
        .target(name: "TractandaClient"),
        .testTarget(name: "TractandaClientTests", dependencies: ["TractandaClient"]),
    ],
    swiftLanguageModes: [.v6]
)
