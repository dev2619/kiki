import XCTest
import KikiCore
@testable import KikiWake

/// Tests for `WakeListener.onArmedChunk` (F1 Task 5): raw armed-mode chunks
/// forwarded for a display-only `LiveTranscriptionCoordinator` in
/// `AppDelegate` — never for the transcription actually delivered. Border
/// precision is explicitly NOT a requirement (see the property's doc), so
/// these tests only assert the gating invariants: never outside `.armed`,
/// fires while a speech segment is actively being captured, and stops once
/// the segment ends.
///
/// Drives the state machine through the same `#if DEBUG` test seams
/// (`_testActivate` / `_testIngest`) as `WakeListenerFlushTests`, so no live
/// `AVAudioEngine` is involved.
final class WakeListenerArmedChunkTests: XCTestCase {
    /// Minimal stub — these tests never reach a real transcription.
    private final class StubTranscriber: Transcribing {
        func transcribe(_ samples: [Float]) async throws -> String { "" }
    }

    /// Same shape as `WakeListenerFlushTests.feedInProgressSpeech`: enough
    /// speech to cross `armedConfig`'s default `minSpeechDuration` (0.4s)
    /// without trailing silence, so the segment stays in progress.
    private func feedInProgressSpeech(_ listener: WakeListener, chunks: Int = 8) {
        for _ in 0..<chunks {
            listener._testIngest(rms: 0.08)
        }
    }

    func test_onArmedChunkNeverFiresOutsideArmed() {
        let listener = WakeListener(transcriber: StubTranscriber())
        var received: [[Float]] = []
        listener.onArmedChunk = { received.append($0) }

        listener._testActivate(.listening)
        feedInProgressSpeech(listener)

        XCTAssertTrue(received.isEmpty, "onArmedChunk must never fire while .listening (waiting for the wake phrase, not a dictation session)")
    }

    func test_onArmedChunkFiresDuringActiveArmedSpeech() {
        let listener = WakeListener(transcriber: StubTranscriber())
        var received: [[Float]] = []
        listener.onArmedChunk = { received.append($0) }

        listener._testActivate(.armed)
        feedInProgressSpeech(listener)

        XCTAssertFalse(received.isEmpty, "onArmedChunk must fire for chunks belonging to an active armed-speech segment")
        XCTAssertLessThanOrEqual(received.count, 8, "never forwards more than the chunks actually fed")
    }

    func test_onArmedChunkStopsAfterSegmentEnds() {
        let listener = WakeListener(transcriber: StubTranscriber())
        var received: [[Float]] = []
        listener.onArmedChunk = { received.append($0) }

        listener._testActivate(.armed)
        feedInProgressSpeech(listener)
        XCTAssertGreaterThan(received.count, 0)

        // armedConfig's endSilence is 1.5s — feed well past that in silence
        // to force segmentEnded, then confirm forwarding has quiesced.
        for _ in 0..<20 { listener._testIngest(rms: 0.001) }
        let countAfterSilence = received.count

        for _ in 0..<10 { listener._testIngest(rms: 0.001) }
        XCTAssertEqual(received.count, countAfterSilence, "additional silence after the segment ended must not produce further armed chunks")
    }
}
