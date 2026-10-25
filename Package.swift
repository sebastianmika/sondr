// swift-tools-version: 6.0
import PackageDescription

// Opt in to the non-deprecated CBLAS headers.
let accelerateSettings: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])]

let package = Package(
    name: "SondrCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SondrCore", targets: ["SondrCore"]),
        .executable(name: "sondr-testlib", targets: ["sondr-testlib"]),
        .executable(name: "sondr-multisamples", targets: ["sondr-multisamples"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "SondrCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "MetalTSNE"],
            resources: [.copy("Resources/ClapTokenizer"), .copy("Resources/Tagger"), .copy("Resources/Clusters")],
            swiftSettings: accelerateSettings
        ),
        // Vendored from https://github.com/vals/mac-tsne, see ThirdParty/MetalTSNE/VENDORED.md.
        .target(name: "MetalTSNE", swiftSettings: accelerateSettings),
        .executableTarget(name: "sondr-testlib", dependencies: ["SondrCore"]),
        .executableTarget(name: "sondr-multisamples", dependencies: ["SondrCore"]),
        .testTarget(name: "MetalTSNETests", dependencies: ["MetalTSNE"]),
        .testTarget(name: "SondrCoreTests", dependencies: ["SondrCore"]),
    ]
)
