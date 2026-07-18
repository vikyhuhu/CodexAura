// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexAura",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CodexAura",
            path: "Sources/CodexAura",
            resources: [
                .copy("Renderer/payload.js"),
                .copy("Renderer/skin.css")
            ]
        )
    ]
)
