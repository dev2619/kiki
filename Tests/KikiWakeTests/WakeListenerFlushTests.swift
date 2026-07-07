import XCTest
import KikiCore
@testable import KikiWake

/// Tests for `WakeListener.stopAndFlush()` state gating — the fix for the
/// Critical-1 review finding (privacy regression): `stopAndFlush()` originally
/// only guarded `_state != .stopped`, so toggling hands-free off while merely
/// LISTENING (waiting for the wake phrase) with ambient conversation mid-flight
/// would flush that bystander audio → transcribe it → paste it into the focused
/// app. The fix flushes ONLY when `_state == .armed` (a dictation session the
/// user actually opened); `.listening` falls through to plain-stop (discard).
///
/// These drive the state machine through `#if DEBUG` test seams
/// (`_testActivate` / `_testIngest`) so no live `AVAudioEngine` is involved.
final class WakeListenerFlushTests: XCTestCase {

    /// Minimal stub — `stopAndFlush()` never transcribes, but `WakeListener`
    /// requires a `Transcribing` at init.
    private final class StubTranscriber: Transcribing {
        func transcribe(_ samples: [Float]) async throws -> String { "" }
    }

    @MainActor
    private final class SpyDelegate: WakeListenerDelegate {
        var captures: [[Float]] = []
        var captureExpectation: XCTestExpectation?
        func wakeListenerDidArm() {}
        func wakeListenerDidStartCapture() {}
        func wakeListenerDidCapture(samples: [Float], sessionIsCurrent: Bool) {
            captures.append(samples)
            captureExpectation?.fulfill()
        }
        func wakeListenerDidCaptureSameBreath(text: String, language: String, sessionIsCurrent: Bool) {}
        func wakeListenerDidDisarm() {}
    }

    /// Feed enough speech to put the segmenter in `.speech` past the regime's
    /// minSpeechDuration, without any trailing silence (so the segment stays
    /// in progress rather than emitting a normal `segmentEnded`).
    private func feedInProgressSpeech(_ listener: WakeListener, chunks: Int = 8) {
        for _ in 0..<chunks {
            listener._testIngest(rms: 0.08)
        }
    }

    // MARK: - Armed: in-progress speech IS flushed (the intended behavior)

    @MainActor
    func testArmedStopAndFlushDeliversInProgressCapture() {
        let listener = WakeListener(transcriber: StubTranscriber())
        let spy = SpyDelegate()
        listener.delegate = spy

        listener._testActivate(.armed)
        feedInProgressSpeech(listener)

        let expectation = expectation(description: "capture delivered")
        spy.captureExpectation = expectation
        listener.stopAndFlush()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(spy.captures.count, 1, "Armed stopAndFlush must deliver the in-progress dictation")
        XCTAssertGreaterThan(spy.captures.first?.count ?? 0, 0)
    }

    // MARK: - Listening: in-progress (ambient) speech is NOT flushed (privacy)

    @MainActor
    func testListeningStopAndFlushDoesNotDeliverCapture() {
        let listener = WakeListener(transcriber: StubTranscriber())
        let spy = SpyDelegate()
        listener.delegate = spy

        listener._testActivate(.listening)
        // Same in-progress speech shape as the armed test — the ONLY
        // difference is the state. Under the bug this ambient audio would be
        // flushed and delivered.
        feedInProgressSpeech(listener)

        listener.stopAndFlush()

        // Give any (erroneous) delivery Task a chance to run on the main loop,
        // then assert nothing was delivered.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)

        XCTAssertTrue(spy.captures.isEmpty, "Listening-state stopAndFlush must NOT deliver a capture — ambient audio waiting for the wake phrase must be discarded, not pasted")
    }
}
