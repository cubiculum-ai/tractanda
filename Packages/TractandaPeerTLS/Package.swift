// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TractandaPeerTLS",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TractandaPeerTLS", targets: ["TractandaPeerTLS"]),
        .library(name: "TractandaHTTPSIdentity", targets: ["TractandaHTTPSIdentity"]),
    ],
    dependencies: [.package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3")],
    targets: [
        .target(name: "CHTTPSIdentityValidation", dependencies: ["CNIOBoringSSL"]),
        .target(name: "TractandaHTTPSIdentity", dependencies: [
            "CHTTPSIdentityValidation", "NIOSSL", .product(name: "NIOCore", package: "swift-nio"),
        ]),
        .testTarget(name: "TractandaHTTPSIdentityTests", dependencies: [
            "TractandaHTTPSIdentity", "NIOSSL", "CNIOBoringSSL",
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
        ]),
        .target(
            name: "CNIOBoringSSL",
            cSettings: [
                .define("_GNU_SOURCE"), .define("_POSIX_C_SOURCE", to: "200112L"),
                .define("_DARWIN_C_SOURCE"),
                .define("_WINSOCKAPI_", .when(platforms: [.windows])),
                .define("NOMINMAX", .when(platforms: [.windows])),
                .define("NOCRYPT", .when(platforms: [.windows])),
            ],
            cxxSettings: [
                .define("_WINSOCKAPI_", .when(platforms: [.windows])),
                .define("NOMINMAX", .when(platforms: [.windows])),
                .define("NOCRYPT", .when(platforms: [.windows])),
            ]),
        .target(
            name: "CNIOBoringSSLShims", dependencies: ["CNIOBoringSSL"], cSettings: [.define("_GNU_SOURCE")]),
        .target(
            name: "NIOSSL",
            dependencies: [
                "CNIOBoringSSL", "CNIOBoringSSLShims", .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
            ], resources: [.copy("PrivacyInfo.xcprivacy")],
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]),
        .target(
            name: "TractandaPeerTLS",
            dependencies: [
                "NIOSSL", "CNIOBoringSSL", .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
            ]),
        .testTarget(
            name: "TractandaPeerTLSTests",
            dependencies: [
                "TractandaPeerTLS", "NIOSSL", "CNIOBoringSSL",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
            ]),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
