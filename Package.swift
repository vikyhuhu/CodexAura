// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexAura",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Vendor/swift-corelibs-xctest")
    ],
    targets: [
        .target(
            name: "CodexAuraCore",
            path: "Sources/CodexAuraCore",
            resources: [
                .copy("Presets")
            ]
        ),
        .executableTarget(
            name: "CodexAura",
            dependencies: ["CodexAuraCore"],
            path: "Sources/CodexAura",
            resources: [
                .copy("Renderer/payload.js"),
                .copy("Renderer/skin.css")
            ]
        ),
        .executableTarget(
            name: "CodexAuraUnitTests",
            dependencies: [
                "CodexAuraCore",
                .product(name: "XCTest", package: "swift-corelibs-xctest")
            ],
            path: "Tests/CodexAuraUnitTests"
        )
    ]
)
