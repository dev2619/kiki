import XCTest
@testable import KikiSTT

// MARK: - Alcance de este archivo (Fix 5, ronda de revisión final)
//
// Puerto del no-op test de `LLMRefinerModelSwitchTests` a `WhisperTranscriber`:
// `switchModel`/`prepare` reales requieren descargar+cargar un modelo
// WhisperKit real (red + CoreML/ANE), así que solo se pueden ejercer con
// `KIKI_STT_TEST=1` (ver `WhisperTranscriberIntegrationTests`), no en el
// `swift test` normal. Lo que SÍ se puede probar sin tocar red/CoreML es el
// camino no-op de `switchModel` (`guard model != modelName else { return }`):
// pedir el modelo YA activo no debe llegar a `loadModel` en absoluto — si lo
// hiciera, este test colgaría o fallaría por falta de red bajo `swift test`.
// Que pase demuestra que el guard corta ANTES de tocar la carga real, y que
// `currentModel`/`isReady` (ambos leídos a través del actor) hacen
// round-trip correctamente.
final class WhisperTranscriberModelSwitchTests: XCTestCase {
    func test_initSetsCurrentModel() async {
        let transcriber = WhisperTranscriber(model: "small_216MB")
        let current = await transcriber.currentModel
        XCTAssertEqual(current, "small_216MB")
    }

    func test_defaultInitUsesPreferredModel() async {
        let transcriber = WhisperTranscriber()
        let current = await transcriber.currentModel
        XCTAssertEqual(current, WhisperTranscriber.preferredModel)
    }

    /// Prueba real (no fake) del camino no-op: pedir el modelo YA activo no
    /// debe tocar `loadModel`/WhisperKit en absoluto — si lo hiciera, este
    /// test colgaría o fallaría por falta de red bajo `swift test` (ver doc
    /// del archivo). Que pase demuestra que el guard corta antes de tocar la
    /// carga real, y que `isReady` queda intacto (nunca se llamó `prepare`).
    func test_switchModelNoOpsWhenAlreadyActive() async throws {
        let transcriber = WhisperTranscriber(model: "small_216MB")
        try await transcriber.switchModel(to: "small_216MB")

        let current = await transcriber.currentModel
        XCTAssertEqual(current, "small_216MB")
        let ready = await transcriber.isReady
        XCTAssertFalse(ready, "switchModel no-op no debe tocar isReady")
    }
}
