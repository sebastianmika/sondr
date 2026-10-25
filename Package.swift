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
        // MetalTSNE (vendored) is added with the map phase.
        .target(
            name: "SondrCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Resources/ClapTokenizer"), .copy("Resources/Tagger"), .copy("Resources/Clusters")],
            swiftSettings: accelerateSettings
        ),
        .executableTarget(name: "sondr-testlib", dependencies: ["SondrCore"]),
        .executableTarget(name: "sondr-multisamples", dependencies: ["SondrCore"]),
        .testTarget(name: "SondrCoreTests", dependencies: ["SondrCore"]),
    ]
)
