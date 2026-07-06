import XCTest
import KikiCore
@testable import KikiRefine

// MARK: - Metal build constraint
//
// MLX no puede inicializar GPU/Metal si el proceso host no vino de xcodebuild
// (SwiftPM CLI no compila los shaders `.metal` de `mlx-swift`/Cmlx — ver nota
// completa en `Sources/KikiRefine/LLMRefiner.swift`). Por eso este test gated
// NO se corre con `swift test`, sino con:
//   TEST_RUNNER_KIKI_LLM_TEST=1 xcodebuild test -scheme kiki \
//     -destination 'platform=macOS' \
//     -only-testing:KikiRefineTests/LLMRefinerIntegrationTests
//
/// Test de integración real (modelo Qwen2.5-3B-Instruct-4bit vía MLX).
final class LLMRefinerIntegrationTests: XCTestCase {
    func test_refinesSpanishDictation() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KIKI_LLM_TEST"] == "1",
            "gated: exportar KIKI_LLM_TEST=1 (descarga el modelo, ~1.8GB)")

        let refiner = LLMRefiner()
        try await refiner.prepare()
        XCTAssertTrue(refiner.isReady)

        let raw = "eh bueno este quería decirte que eh la reunión de mañana mejor la movemos al jueves"
        let refined = try await refiner.refine(raw, profile: .chat)
        let lower = refined.lowercased()
        XCTAssertFalse(lower.contains("eh "), "muletilla sobrevivió: \(refined)")
        XCTAssertTrue(lower.contains("reunión") || lower.contains("reunion"))
        XCTAssertTrue(lower.contains("jueves"))
        XCTAssertLessThan(refined.count, raw.count + 40, "el LLM agregó contenido: \(refined)")
    }
}
