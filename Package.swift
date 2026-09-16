// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Tractanda",
    // Category preview uses Swift 6.4's checked Synchronization.Mutex.  The supported desktop
    // baseline is the current macOS 15 runtime; Linux remains supported by SwiftPM.
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TractandaCore", targets: ["TractandaCore"]),
        .library(name: "TractandaLearning", targets: ["TractandaLearning"]),
        .library(name: "TractandaVectors", targets: ["TractandaVectors"]),
        .executable(name: "tractanda", targets: ["TractandaCLI"]),
        .executable(name: "tractanda-mcp", targets: ["TractandaMCPCLI"]),
        .executable(name: "tractanda-tui", targets: ["TractandaTUICLI"]),
        .executable(name: "tractanda-auth-helper", targets: ["TractandaAuthHelper"]),
        .executable(name: "tractanda-setup", targets: ["TractandaSetup"]),
    ],
    dependencies: [
        .package(path: "Packages/TractandaClient"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite", pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        .target(
            name: "CTractandaVec1",
            dependencies: ["CSQLite"],
            exclude: ["Vendor"],
            publicHeadersPath: "include"),
        .target(
            name: "TractandaVectors",
            dependencies: [
                "CSQLite", "CTractandaVec1",
                .product(name: "TractandaClient", package: "TractandaClient"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .target(
            name: "CTractandaPlatform",
            linkerSettings: [.linkedLibrary("pam"), .linkedLibrary("uuid", .when(platforms: [.linux]))]),
        .executableTarget(name: "TractandaAuthHelper", dependencies: ["CTractandaPlatform"]),
        .executableTarget(
            name: "TractandaSetup",
            dependencies: [
                "CTractandaPlatform", "TractandaCore", .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .target(name: "CTractandaTerminal"),
        .target(name: "TractandaLearning"),
        .target(
            name: "TractandaCore",
            dependencies: [
                "CSQLite", "CTractandaPlatform", "TractandaLearning", "TractandaVectors",
                .product(name: "TractandaClient", package: "TractandaClient"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .target(name: "TractandaKanban", dependencies: ["TractandaCore"]),
        .target(
            name: "TractandaMCP",
            dependencies: [
                "TractandaCore", .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]),
        .executableTarget(name: "TractandaMCPCLI", dependencies: ["TractandaMCP", "TractandaCore"]),
        .target(
            name: "TractandaTUI",
            dependencies: [
                "TractandaCore", "CTractandaTerminal", "CTractandaPlatform",
                .product(name: "TractandaClient", package: "TractandaClient"),
            ],
            resources: [.process("Resources")]),
        .executableTarget(name: "TractandaTUICLI", dependencies: ["TractandaTUI", "TractandaCore"]),
        .target(
            name: "TractandaWeb",
            dependencies: [
                "TractandaCore", "TractandaKanban",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ], resources: [.copy("Resources")]),
        .target(
            name: "TractandaServer",
            dependencies: [
                "TractandaCore", "TractandaWeb", "TractandaMCP", "TractandaKanban",
                "CTractandaPlatform",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "MCP", package: "swift-sdk"),
            ]),
        .executableTarget(
            name: "TractandaCLI",
            dependencies: ["TractandaCore", "TractandaKanban", "TractandaWeb", "TractandaServer"]),
        .testTarget(name: "TractandaCoreTests", dependencies: ["TractandaCore"]),
        .testTarget(name: "TractandaSetupTests", dependencies: ["TractandaSetup"]),
        .testTarget(
            name: "TractandaVectorsTests", dependencies: ["TractandaVectors", "CSQLite", "CTractandaVec1"]),
        .testTarget(name: "TractandaMCPTests", dependencies: ["TractandaMCP", "TractandaCore"]),
        .testTarget(name: "TractandaTUITests", dependencies: ["TractandaTUI", "TractandaCore"]),
        .testTarget(
            name: "TractandaLearningTests", dependencies: ["TractandaLearning"],
            resources: [.copy("Fixtures")]),
        .testTarget(
            name: "TractandaKanbanTests", dependencies: ["TractandaCore", "TractandaKanban", "TractandaWeb"]),
        .testTarget(
            name: "TractandaServerTests",
            dependencies: [
                "TractandaServer", "CTractandaPlatform",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
