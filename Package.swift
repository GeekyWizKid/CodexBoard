// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexBoard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexBoard", targets: ["CodexBoard"])
    ],
    targets: [
        .executableTarget(
            name: "CodexBoard",
            path: "Sources/CodexBoard",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "CodexBoardTests",
            dependencies: ["CodexBoard"],
            path: "Tests/CodexBoardTests"
        )
    ]
)
