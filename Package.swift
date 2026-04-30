// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZendureBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ZendureBar",
            path: "Sources/ZendureBar",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
