import XCTest
import AVFoundation
import KikiAudio
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
