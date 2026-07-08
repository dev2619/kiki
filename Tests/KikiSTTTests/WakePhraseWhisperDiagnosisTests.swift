import XCTest
import AVFoundation
import KikiAudio
import KikiWake
@testable import KikiSTT

/// Diagnóstico de campo (fix/wake-phrase-matching): el bug reportado es que el
/// wake listener NUNCA matchea "escúchame kiki" pese a segmentos suficientemente
/// largos — el log de campo solo muestra `match no` / `segmento descartado (sin
/// frase)`. Este test sintetiza la frase con el TTS del sistema (`say`, mismo
/// patrón que `WhisperTranscriberIntegrationTests`), la pasa por el
/// `WhisperTranscriber` REAL (no un stub) y corre `WakePhraseMatcher.match`
/// sobre el transcript real — así se ve EXACTAMENTE qué produce Whisper para
/// la frase de activación en vez de adivinar.
///
/// Gated: solo corre con `KIKI_STT_TEST=1 swift test --filter
/// WakePhraseWhisperDiagnosisTests` (descarga el modelo, ~600MB+, cacheado en
/// disco tras la primera corrida).
final class WakePhraseWhisperDiagnosisTests: XCTestCase {

    /// Un caso de diagnóstico: qué se le pide a `say` y con qué voz/velocidad,
    /// más si se espera que sea un dictado en el mismo aliento (para loggear
    /// el remainder esperado).
    private struct Case {
        let label: String
        let text: String
        let voice: String?
        let rateWPM: Int?
    }

    func test_diagnoseRealWhisperTranscriptsOfWakePhrases() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KIKI_STT_TEST"] == "1",
            "gated: exportar KIKI_STT_TEST=1 (descarga el modelo, ~600MB+)")

        let cases: [Case] = [
            Case(label: "spanish plain", text: "escúchame kiki", voice: "Monica", rateWPM: nil),
            Case(label: "spanish same-breath dictation", text: "escúchame kiki, escribe hola mundo", voice: "Monica", rateWPM: nil),
            Case(label: "english plain", text: "listen to me kiki", voice: nil, rateWPM: nil),
            Case(label: "spanish with leading filler", text: "oye escúchame kiki", voice: "Monica", rateWPM: nil),
            Case(label: "spanish slow", text: "escúchame kiki", voice: "Monica", rateWPM: 140),
            Case(label: "spanish fast", text: "escúchame kiki", voice: "Monica", rateWPM: 260),
        ]

        let transcriber = WhisperTranscriber()
        try await transcriber.prepare()
        let ready = await transcriber.isReady
        XCTAssertTrue(ready)

        var report = "\n=== WAKE PHRASE WHISPER DIAGNOSIS ===\n"
        var anyNonEmptyTranscript = false

        for testCase in cases {
            let wavURL = try synthesize(testCase)
            defer { try? FileManager.default.removeItem(at: wavURL) }

            let samples = try loadSamples(url: wavURL)
            XCTAssertGreaterThan(samples.count, 0, "\(testCase.label): fixture vacío")

            let transcript = try await transcriber.transcribe(samples)
            let matched = WakePhraseMatcher.match(transcript)

            if !transcript.trimmingCharacters(in: .whitespaces).isEmpty {
                anyNonEmptyTranscript = true
            }

            let line = "[\(testCase.label)] said=\"\(testCase.text)\" whisper=\"\(transcript)\" match=\(matched.map { "YES remainder=\"\($0.remainder)\"" } ?? "NO")"
            report += line + "\n"
            // Also surface via XCTAttachment-free stderr so it shows in CI logs
            // even if the test runner truncates println/print output.
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        }

        print(report)
        FileHandle.standardError.write(report.data(using: .utf8)!)

        // Sanity gate distinct from matcher behavior (see task instructions):
        // if Whisper can't hear ANY of these clean TTS phrases at all, that's
        // an audio/model problem, not a matcher problem — fail loudly instead
        // of silently reporting the matcher as broken.
        XCTAssertTrue(anyNonEmptyTranscript, "Whisper no transcribió NADA de ninguna frase sintetizada — sospechar problema de audio/umbral, no del matcher")
    }

    // MARK: - Helpers

    private func synthesize(_ testCase: Case) throws -> URL {
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiki-wake-diag-\(UUID().uuidString).wav")

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args = ["-o", wavURL.path, "--data-format=LEF32@16000"]
        if let voice = testCase.voice {
            args += ["-v", voice]
        }
        if let rate = testCase.rateWPM {
            args += ["-r", String(rate)]
        }
        args.append(testCase.text)
        say.arguments = args
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0, "say falló para '\(testCase.text)'")
        return wavURL
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
