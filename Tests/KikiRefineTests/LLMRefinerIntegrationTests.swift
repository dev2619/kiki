import XCTest
@testable import KikiCore
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

    /// Prueba directa del contrato de FIX 1: antes, `LLMRefiner.refine` usaba
    /// `ChatSession.respond` → `MLXLMCommon.generate(input:context:iterator:)`
    /// con un callback fijo `{ _ in .more }` que nunca revisa cancelación, así
    /// que el `withThrowingTimeout` de `DictationController` no podía cortar
    /// una generación en curso: la tarea quedaba "cancelada" en el papel pero
    /// seguía corriendo hasta terminar sola. Ahora `refine` usa el API de más
    /// bajo nivel con un `didGenerate` que devuelve `.stop` en cuanto
    /// `Task.isCancelled` es true, así que envolver una llamada real en un
    /// timeout corto debe cortarla en un tiempo acotado (un token, no toda la
    /// generación) en vez de bloquear hasta el final natural (~1-3s).
    func test_timeoutActuallyCancelsInFlightGeneration() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KIKI_LLM_TEST"] == "1",
            "gated: exportar KIKI_LLM_TEST=1 (descarga el modelo, ~1.8GB)")

        let refiner = LLMRefiner()
        try await refiner.prepare()
        XCTAssertTrue(refiner.isReady)

        // Texto largo a propósito: buscamos una generación que tome más de
        // los 0.5s del timeout, para que haya margen real de cancelar a
        // mitad de camino (no que termine sola antes de que el timeout
        // dispare).
        let raw = """
            eh bueno este quería decirte que eh la reunión de mañana mejor la \
            movemos al jueves, necesito que confirmes antes del mediodía \
            porque tengo que avisarle también al equipo de diseño y al de \
            producto sobre el cambio de fecha, y de paso eh revisar si el \
            informe trimestral ya está listo para compartir en esa misma \
            reunión, este, y si no está listo pues hay que decidir si la \
            movemos otra vez o la hacemos igual con lo que tengamos
            """

        let started = Date()
        do {
            _ = try await withThrowingTimeout(seconds: 0.5) {
                try await refiner.refine(raw, profile: .chat)
            }
            XCTFail("se esperaba que el timeout de 0.5s cortara la generación antes de que terminara sola")
        } catch {
            // Esperado: withThrowingTimeout debe ganarle la carrera a la
            // generación y lanzar (timeout o CancellationError propagado
            // desde LLMRefiner tras el `try Task.checkCancellation()`).
        }
        let elapsed = Date().timeIntervalSince(started)

        // Contrato: la cancelación debe cortar en un tiempo acotado por un
        // solo paso de token (decenas de ms), no bloquear hasta que la
        // generación completa termine sola. 2s de margen es generoso vs. los
        // 0.5s del timeout — si esto falla y tarda ~1-3s+ es la señal exacta
        // de que volvimos al bug que este fix corrige.
        XCTAssertLessThan(
            elapsed, 2.0,
            "el timeout no cortó la generación a tiempo (tardó \(elapsed)s) — la cancelación no se está propagando")
    }
}
