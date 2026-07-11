import XCTest
import AVFoundation
import KikiAudio
import KikiWake
@testable import KikiSTT

/// Test de integración real (modelo Whisper + audio sintetizado con `say`).
/// Se corre solo con: KIKI_STT_TEST=1 swift test --filter WhisperTranscriberIntegrationTests
final class WhisperTranscriberIntegrationTests: XCTestCase {
    func test_transcribesSynthesizedEnglishSpeech() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KIKI_STT_TEST"] == "1",
            "gated: exportar KIKI_STT_TEST=1 (descarga el modelo, ~600MB+)")

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiki-stt-fixture-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        // Sintetizar voz con el TTS del sistema, directo a WAV 16 kHz Float32.
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", wavURL.path,
            "--data-format=LEF32@16000",
            "hello world this is a dictation test",
        ]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "say falló")

        let samples = try loadSamples(url: wavURL)
        XCTAssertGreaterThan(samples.count, 16_000, "el fixture debe durar más de 1 s")

        let transcriber = WhisperTranscriber()
        try await transcriber.prepare()
        let ready = await transcriber.isReady
        XCTAssertTrue(ready)

        let text = try await transcriber.transcribe(samples)
        let normalized = text.lowercased()
        XCTAssertTrue(
            normalized.contains("hello") && normalized.contains("test"),
            "transcripción inesperada: '\(text)'")
    }

    /// Valida la config de PRODUCCIÓN de F4 end-to-end (AppDelegate, Task 3):
    /// tiny + `WakePhraseBiasProvider` inyectado ANTES de `prepare()`. Sin el
    /// prompt-bias el tiny transcribe con calidad insuficiente ("SKHAIM KIKI")
    /// y `WakePhraseMatcher` no matchea; con bias sí matchea de forma consistente.
    /// Gated: KIKI_STT_TEST=1 (descarga ~75MB la primera vez).
    func test_tinyModelDetectsWakePhrase() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KIKI_STT_TEST"] == "1",
            "gated: exportar KIKI_STT_TEST=1 (descarga el modelo tiny)")

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiki-wake-fixture-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        // Voz es-ES del sistema para el fixture de la frase en español.
        say.arguments = [
            "-v", "Mónica", "-o", wavURL.path,
            "--data-format=LEF32@16000",
            "escúchame kiki",
        ]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "say falló")

        let samples = try loadSamples(url: wavURL)
        let transcriber = WhisperTranscriber(model: WhisperTranscriber.wakeModel)
        // DictionaryProviding es weak: mantener referencia fuerte local mientras dure el test.
        let bias = WakePhraseBiasProvider()
        await transcriber.setDictionaryProvider(bias)
        try await transcriber.prepare()

        let started = Date()
        let text = try await transcriber.transcribe(samples)
        let seconds = Date().timeIntervalSince(started)
        XCTAssertNotNil(
            WakePhraseMatcher.match(text),
            "el tiny transcribió '\(text)' y el matcher no lo reconoció")
        // Guardia de la promesa de latencia de F4 (holgada para CI frío).
        XCTAssertLessThan(seconds, 2.0, "inferencia tiny tardó \(seconds)s")
    }

    private func loadSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length))
        else {
            throw NSError(domain: "fixture", code: 1)
        }
        try file.read(into: buffer)
        return AudioResampler.resampleTo16kMono(buffer)
    }
}
