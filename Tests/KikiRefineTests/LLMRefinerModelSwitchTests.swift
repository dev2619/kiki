import XCTest
@testable import KikiRefine

// MARK: - Alcance de este archivo (F3 Task 2, ronda de completion)
//
// `switchModel`/`refine` reales requieren un `ModelContainer` de MLX cargado
// (`LLMModelFactory.shared.loadContainer` → GPU/Metal real, ver el "Metal
// build constraint" documentado en `LLMRefiner.swift`), así que solo se
// pueden ejercer con `xcodebuild` + `KIKI_LLM_TEST=1` (ver
// `LLMRefinerIntegrationTests`), no con `swift test`. No hay ningún seam de
// inyección de `loadModel`/`ModelContainer` en el archivo de producción, y
// añadir uno solo para fabricar un `ModelContainer` de mentira no es
// razonable (`ModelContainer.perform` necesita un `ModelContext` real con
// tokenizer/processor/model MLX vivos) — la semántica completa de "snapshot
// al entrar sobrevive a un swap concurrente" queda cubierta por smoke manual
// (Task 4), no por un test unitario aquí. Ver `task-2-report.md` § Completion
// round para el detalle.
//
// Lo que SÍ se puede probar sin tocar MLX/Metal: el camino no-op de
// `switchModel` (`guard model != current else { return }`) nunca llega a
// `loadModel`, así que ejercerlo prueba de verdad — sin fingir nada — que el
// confinamiento a `@MainActor` de `modelName` (el hop `await MainActor.run`
// dentro de `switchModel`/`currentModel`) funciona: no hay deadlock, no hay
// crash, y el valor leído es el esperado.
final class LLMRefinerModelSwitchTests: XCTestCase {
    func test_initSetsCurrentModel() async {
        let refiner = LLMRefiner(model: "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        let current = await refiner.currentModel
        XCTAssertEqual(current, "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
    }

    func test_defaultInitUsesPreferredModel() async {
        let refiner = LLMRefiner()
        let current = await refiner.currentModel
        XCTAssertEqual(current, LLMRefiner.preferredModel)
    }

    /// Prueba real (no fake) del camino no-op: pedir el modelo YA activo no
    /// debe tocar `loadModel`/MLX en absoluto — si lo hiciera, este test
    /// colgaría o fallaría por "Failed to load the default metallib" bajo
    /// `swift test` (ver doc del archivo). Que pase demuestra que el guard
    /// (y el snapshot `await MainActor.run { modelName }` que lo alimenta)
    /// corta ANTES de tocar la carga real.
    func test_switchModelNoOpsWhenAlreadyActive() async throws {
        let refiner = LLMRefiner(model: "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        try await refiner.switchModel(to: "mlx-community/Qwen2.5-1.5B-Instruct-4bit")

        let current = await refiner.currentModel
        XCTAssertEqual(current, "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        XCTAssertFalse(refiner.isReady, "switchModel nunca debe tocar isReady")
    }
}
