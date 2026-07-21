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
        // Motor wake-word abierto (Apache 2.0) para detección instantánea de la
        // frase/comandos sin transcribir. macOS 14+, trae ONNX Runtime oficial.
        // Pin por REVISIÓN: el `Package.swift` forwarder en la raíz del repo
        // (que SPM necesita) solo existe en `main`, no en los tags v0.2.x — así
        // que se fija el commit exacto de main en vez de un tag.
        .package(url: "https://github.com/livekit/livekit-wakeword", revision: "60b5d755ee0835bd184cbb1f05063944a9bed121"),
    ],
    targets: [
        .target(name: "KikiCore"),
        .target(name: "KikiContext", dependencies: ["KikiCore"]),
        .target(name: "KikiAudio", dependencies: ["KikiCore"]),
        .target(name: "KikiInsert", dependencies: ["KikiCore"]),
        .target(name: "KikiStore", dependencies: ["KikiCore"]),
        .target(
            name: "KikiWake",
            dependencies: [
                "KikiCore", "KikiAudio",
                .product(name: "LiveKitWakeWord", package: "livekit-wakeword"),
            ]
        ),
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
            dependencies: ["KikiCore", "KikiAudio", "KikiInsert", "KikiSTT", "KikiContext", "KikiRefine", "KikiWake", "KikiStore"]
        ),
        .testTarget(name: "KikiCoreTests", dependencies: ["KikiCore"]),
        .testTarget(name: "KikiContextTests", dependencies: ["KikiContext"]),
        .testTarget(name: "KikiAudioTests", dependencies: ["KikiAudio"]),
        .testTarget(name: "KikiInsertTests", dependencies: ["KikiInsert"]),
        .testTarget(name: "KikiStoreTests", dependencies: ["KikiStore"]),
        .testTarget(name: "KikiWakeTests", dependencies: ["KikiWake"]),
        .testTarget(name: "KikiRefineTests", dependencies: ["KikiRefine"]),
        .testTarget(
            name: "KikiSTTTests",
            dependencies: ["KikiSTT", "KikiAudio", "KikiWake"]
        ),
    ]
)
