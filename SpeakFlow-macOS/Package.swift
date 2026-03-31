// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeakFlow",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", from: "0.2.1"),
    ],
    targets: [
        .executableTarget(
            name: "SpeakFlow",
            dependencies: ["HotKey"],
            path: "SpeakFlow",
            exclude: [
                "Resources/Info.plist",
                "Resources/SpeakFlow.entitlements",
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
            ]
        ),
    ]
)
