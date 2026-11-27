// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DMS",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "DMS", targets: ["DMS"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .executableTarget(
            name: "DMS",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/DMS",
            resources: [.copy("Resources/AppIcon.png")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DMSTests",
            dependencies: [
                "DMS",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/DMSTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
