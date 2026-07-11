import XCTest
import KikiCore
@testable import KikiWake

/// Tests for F4 Task 2: `WakeListener.setWakeVerifier` and the same-breath
/// main-model re-verification path (`reverifySameBreath`).
///
/// Reuses the `_testActivate`/`_testIngest` harness from
/// `WakeListenerFlushTests` (drives the state machine deterministically
/// without a live `AVAudioEngine`), plus a `SpyDelegate` in the same shape as
/// that file's. The one addition needed here — absent from the existing
/// `StubTranscriber` — is a call counter and a configurable return
/// text/expectation, since these tests assert WHICH transcriber (tiny
/// verifier vs. main) got called and how many times.
final class WakeVerifierTests: XCTestCase {

    /// Configurable mock `Transcribing`: returns `textToReturn` (or throws
    /// `errorToThrow`), counts calls, and can fulfill an expectation the
    /// instant a call starts — needed because `transcribe()` runs inside a
    /// detached `Task` a couple of queue-hops away from `_testIngest`, so
    /// tests can't just assert `transcribeCallCount` synchronously after
    /// feeding audio.
    private final class MockTranscriber: Transcribing {
        var textToReturn: String = ""
        var errorToThrow: Error?
        private(set) var transcribeCallCount = 0
        var callExpectation: XCTestExpectation?

        func transcribe(_ samples: [Float]) async throws -> String {
            transcribeCallCount += 1
            callExpectation?.fulfill()
            if let errorToThrow { throw errorToThrow }
            return textToReturn
        }
    }

    @MainActor
    private final class SpyDelegate: WakeListenerDelegate {
        var armCount = 0
        var armExpectation: XCTestExpectation?
        var sameBreathCalls: [(text: String, language: String, sessionIsCurrent: Bool)] = []
        var sameBreathExpectation: XCTestExpectation?

        func wakeListenerDidArm() {
            armCount += 1
            armExpectation?.fulfill()
        }
        func wakeListenerDidStartCapture() {}
        func wakeListenerDidCapture(samples: [Float], sessionIsCurrent: Bool) {}
        func wakeListenerDidCaptureSameBreath(text: String, language: String, sessionIsCurrent: Bool) {
            sameBreathCalls.append((text, language, sessionIsCurrent))
            sameBreathExpectation?.fulfill()
        }
        func wakeListenerDidDisarm() {}
    }

    /// Feeds a complete `.listening` segment: enough sustained speech to
    /// clear `minSpeechDuration` (0.25s), then enough silence to clear
    /// `endSilence` (0.5s) and trigger `segmentEnded` → `handleListeningSegment`.
    /// RMS values chosen well clear of both the entry threshold and the
    /// adaptive hysteresis/relative-drop bars (see `SpeechSegmenter`), so the
    /// segment boundary is deterministic regardless of the adaptive floor.
    private func feedListeningSegment(_ listener: WakeListener, speechChunks: Int = 5, silenceChunks: Int = 6) {
        for _ in 0..<speechChunks {
            listener._testIngest(rms: 0.1)
        }
        for _ in 0..<silenceChunks {
            listener._testIngest(rms: 0.0001)
        }
    }

    // MARK: - 1. Verifier seam: tiny is used, main is not touched

    @MainActor
    func test_listeningSegmentUsesVerifierWhenSet() {
        let mockTiny = MockTranscriber()
        mockTiny.textToReturn = "conversación ambiental sin frase"
        let mainMock = MockTranscriber()
        let listener = WakeListener(transcriber: mainMock)
        let spy = SpyDelegate()
        listener.delegate = spy
        listener.setWakeVerifier(mockTiny)
        listener._testActivate(.listening)

        let callExpectation = expectation(description: "tiny transcribe called")
        mockTiny.callExpectation = callExpectation
        feedListeningSegment(listener)
        wait(for: [callExpectation], timeout: 2.0)

        // Let the queue.async completion settle fully before asserting —
        // there's nothing else to await on this (no-match) path.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)

        XCTAssertEqual(mockTiny.transcribeCallCount, 1)
        XCTAssertEqual(mainMock.transcribeCallCount, 0, "el principal NO se usa para verificar")
    }

    // MARK: - 2. Same-breath re-verifies with the main transcriber

    @MainActor
    func test_sameBreathReVerifiesWithMainTranscriber() {
        let mockTiny = MockTranscriber()
        mockTiny.textToReturn = "escuchame kiki escribe hola"
        let mainMock = MockTranscriber()
        mainMock.textToReturn = "escuchame kiki, escribe hola mundo"
        let listener = WakeListener(transcriber: mainMock)
        let spy = SpyDelegate()
        listener.delegate = spy
        listener.setWakeVerifier(mockTiny)
        listener._testActivate(.listening)

        let sameBreathExpectation = expectation(description: "same-breath delivered (re-verified)")
        spy.sameBreathExpectation = sameBreathExpectation
        feedListeningSegment(listener)
        wait(for: [sameBreathExpectation], timeout: 2.0)

        XCTAssertEqual(spy.sameBreathCalls.count, 1)
        XCTAssertEqual(spy.sameBreathCalls.first?.text, "escribe hola mundo",
                       "debe entregar el remainder del MAIN, no el del tiny")
        XCTAssertEqual(mockTiny.transcribeCallCount, 1)
        XCTAssertEqual(mainMock.transcribeCallCount, 1)
    }

    // MARK: - 3. Fallback to main's full text when main doesn't match

    @MainActor
    func test_sameBreathFallsBackToMainFullTextWhenMainDoesNotMatch() {
        let mockTiny = MockTranscriber()
        mockTiny.textToReturn = "escuchame kiki escribe hola"
        let mainMock = MockTranscriber()
        mainMock.textToReturn = "escribe hola mundo"
        let listener = WakeListener(transcriber: mainMock)
        let spy = SpyDelegate()
        listener.delegate = spy
        listener.setWakeVerifier(mockTiny)
        listener._testActivate(.listening)

        let sameBreathExpectation = expectation(description: "same-breath delivered (fallback full text)")
        spy.sameBreathExpectation = sameBreathExpectation
        feedListeningSegment(listener)
        wait(for: [sameBreathExpectation], timeout: 2.0)

        XCTAssertEqual(spy.sameBreathCalls.count, 1)
        XCTAssertEqual(spy.sameBreathCalls.first?.text, "escribe hola mundo",
                        "nunca se pierde dictado: sin match del main, se entrega su texto completo")
    }

    // MARK: - 4. Without a verifier, behaves exactly as before

    @MainActor
    func test_withoutVerifierBehavesAsBefore() {
        let mainMock = MockTranscriber()
        mainMock.textToReturn = "escuchame kiki escribe hola mundo"
        let listener = WakeListener(transcriber: mainMock)
        let spy = SpyDelegate()
        listener.delegate = spy
        listener._testActivate(.listening)

        let sameBreathExpectation = expectation(description: "same-breath delivered directly")
        spy.sameBreathExpectation = sameBreathExpectation
        feedListeningSegment(listener)
        wait(for: [sameBreathExpectation], timeout: 2.0)

        XCTAssertEqual(mainMock.transcribeCallCount, 1,
                        "sin verificador, el main ya verificó — no debe haber segunda transcripción")
        XCTAssertEqual(spy.sameBreathCalls.count, 1)
        XCTAssertEqual(spy.sameBreathCalls.first?.text, "escribe hola mundo")
    }

    // MARK: - 5. Arm-only path never calls the main transcriber

    @MainActor
    func test_armOnlyPathNeverCallsMainTranscriber() {
        let mockTiny = MockTranscriber()
        mockTiny.textToReturn = "escuchame kiki"
        let mainMock = MockTranscriber()
        let listener = WakeListener(transcriber: mainMock)
        let spy = SpyDelegate()
        listener.delegate = spy
        listener.setWakeVerifier(mockTiny)
        listener._testActivate(.listening)

        let armExpectation = expectation(description: "armed")
        spy.armExpectation = armExpectation
        feedListeningSegment(listener)
        wait(for: [armExpectation], timeout: 2.0)

        XCTAssertEqual(spy.armCount, 1)
        XCTAssertEqual(mainMock.transcribeCallCount, 0)
    }

    // MARK: - 6. Same-breath disagreement: main's empty remainder arms, doesn't silently drop

    @MainActor
    func test_sameBreathDisagreementWithEmptyRemainderArms() {
        let mockTiny = MockTranscriber()
        mockTiny.textToReturn = "escuchame kiki escribe algo"
        let mainMock = MockTranscriber()
        mainMock.textToReturn = "escuchame kiki"
        let listener = WakeListener(transcriber: mainMock)
        let spy = SpyDelegate()
        listener.delegate = spy
        listener.setWakeVerifier(mockTiny)
        listener._testActivate(.listening)

        let armExpectation = expectation(description: "armed after empty-remainder disagreement")
        spy.armExpectation = armExpectation
        feedListeningSegment(listener)
        wait(for: [armExpectation], timeout: 2.0)

        XCTAssertEqual(spy.armCount, 1)

        // Negative assertion: no same-breath capture should follow — give the
        // settle delay used elsewhere in this file for the no-match path.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)

        XCTAssertEqual(spy.sameBreathCalls.count, 0,
                       "no debe entregarse texto vacío como same-breath capture")
    }
}
