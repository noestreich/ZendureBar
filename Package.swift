// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZendureBar",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/emqx/CocoaMQTT.git", .upToNextMajor(from: "2.2.3"))
    ],
    targets: [
        .executableTarget(
            name: "ZendureBar",
            dependencies: [
                .product(name: "CocoaMQTT", package: "CocoaMQTT")
            ],
            path: "Sources/ZendureBar",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
