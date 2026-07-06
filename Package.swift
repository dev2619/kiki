// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "kiki",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pines a `.upToNextMinor` en vez de `from:` (caret libre): un
        // `swift package update` no debe poder saltar de minor sin que
        // alguien lo revise a propósito. Esto es crítico sobre todo para
        // mlx-swift-examples: `LLMRefiner.swift` depende directamente de
        // los internals de `Libraries/MLXLMCommon/Evaluate.swift`
        // (`TokenIterator`, `generate(input:context:iterator:didGenerate:)`)
        // para poder cancelar la generación token a token — un bump de
        // minor podría cambiar esas firmas o el comportamiento de
        // cancelación sin avisar. Versiones tomadas de Package.resolved
        // (las que ya están resueltas y probadas en este branch).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "1.0.0")),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", .upToNextMinor(from: "2.25.9")),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.25.6")),
    ],
    targets: [
        .target(name: "KikiCore"),
        .target(name: "KikiContext", dependencies: ["KikiCore"]),
        .target(name: "KikiAudio", dependencies: ["KikiCore"]),
        .target(name: "KikiInsert", dependencies: ["KikiCore"]),
        .target(name: "KikiWake", dependencies: ["KikiCore"]),
        .target(
            name: "KikiRefine",
            dependencies: [
                "KikiCore",
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "MLX", package: "mlx-swift"),
            ]
        ),
        .target(
            name: "KikiSTT",
            dependencies: [
                "KikiCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "Kiki",
            dependencies: ["KikiCore", "KikiAudio", "KikiInsert", "KikiSTT", "KikiContext", "KikiRefine"]
        ),
        .testTarget(name: "KikiCoreTests", dependencies: ["KikiCore"]),
        .testTarget(name: "KikiContextTests", dependencies: ["KikiContext"]),
        .testTarget(name: "KikiAudioTests", dependencies: ["KikiAudio"]),
        .testTarget(name: "KikiInsertTests", dependencies: ["KikiInsert"]),
        .testTarget(name: "KikiWakeTests", dependencies: ["KikiWake"]),
        .testTarget(name: "KikiRefineTests", dependencies: ["KikiRefine"]),
        .testTarget(
            name: "KikiSTTTests",
            dependencies: ["KikiSTT", "KikiAudio"]
        ),
    ]
)
