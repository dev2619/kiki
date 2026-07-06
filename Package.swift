// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "kiki",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .target(name: "KikiCore"),
        .target(name: "KikiContext", dependencies: ["KikiCore"]),
        .target(name: "KikiAudio", dependencies: ["KikiCore"]),
        .target(name: "KikiInsert", dependencies: ["KikiCore"]),
        .target(
            name: "KikiSTT",
            dependencies: [
                "KikiCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "Kiki",
            dependencies: ["KikiCore", "KikiAudio", "KikiInsert", "KikiSTT"]
        ),
        .testTarget(name: "KikiCoreTests", dependencies: ["KikiCore"]),
        .testTarget(name: "KikiContextTests", dependencies: ["KikiContext"]),
        .testTarget(name: "KikiAudioTests", dependencies: ["KikiAudio"]),
        .testTarget(name: "KikiInsertTests", dependencies: ["KikiInsert"]),
        .testTarget(
            name: "KikiSTTTests",
            dependencies: ["KikiSTT", "KikiAudio"]
        ),
    ]
)
