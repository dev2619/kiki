import XCTest
@testable import KikiWake

/// Tests for `SpeechSegmenter.flush()` — the fix for BUG 1 in the noisy-room field
/// report: intentionally stopping hands-free mid-utterance (⌥⌘K toggle-off or the
/// menu toggle-off) must not silently discard audio the user already spoke just
/// because end-of-speech was never detected. See `WakeListener.stopAndFlush()` for
/// the caller that uses this on the intentional-stop path only (plain `stop()` —
/// used by dictation-pause coordination and by `cancelCapture()`/Esc — still
/// discards, unchanged).
final class SpeechSegmenterFlushTests: XCTestCase {

    private let samplesPerChunk = 1600 // 0.1s @ 16kHz

    private func chunk(value: Float = 0.5) -> [Float] {
        Array(repeating: value, count: samplesPerChunk)
    }

    private func makeConfig(minSpeechDuration: TimeInterval = 0.4) -> SegmenterConfig {
        SegmenterConfig(
            speechRMSThreshold: 0.02,
            endSilence: 0.7,
            minSpeechDuration: minSpeechDuration,
            maxSegmentDuration: 30.0)
    }

    // MARK: - Nothing in progress

    func testFlushReturnsNilWhenInSilence() {
        let segmenter = SpeechSegmenter(config: makeConfig())
        XCTAssertNil(segmenter.flush(), "Nothing accumulated yet — flush() has nothing to hand back")
    }

    // MARK: - In-progress speech above minSpeechDuration is flushed

    func testFlushReturnsInProgressSpeechAboveMinDuration() {
        let segmenter = SpeechSegmenter(config: makeConfig())

        // 0.6s of speech (6 chunks), no silence yet — segment still "in progress".
        let started = segmenter.process(chunk: chunk(), rms: 0.05)
        XCTAssertEqual(started, .speechStarted)
        for _ in 0..<5 {
            let event = segmenter.process(chunk: chunk(), rms: 0.05)
            XCTAssertEqual(event, .none)
        }

        guard let flushed = segmenter.flush() else {
            XCTFail("Expected flush() to return the in-progress segment")
            return
        }
        XCTAssertGreaterThanOrEqual(flushed.count, 6 * samplesPerChunk, "Flushed samples must include all speech accumulated so far")
    }

    // MARK: - Flush resets state so a fresh segment can start immediately after

    func testFlushResetsStateForFreshSegment() {
        let segmenter = SpeechSegmenter(config: makeConfig())

        _ = segmenter.process(chunk: chunk(), rms: 0.05) // speechStarted
        for _ in 0..<5 {
            _ = segmenter.process(chunk: chunk(), rms: 0.05)
        }
        _ = segmenter.flush()

        // A fresh speechStarted must fire again — proves state was reset to
        // `.silence`, not left dangling in `.speech`/`.awaitingSilence`.
        let silenceChunk = Array(repeating: Float(0.0), count: samplesPerChunk)
        for _ in 0..<5 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.001)
        }
        let event = segmenter.process(chunk: chunk(), rms: 0.05)
        XCTAssertEqual(event, .speechStarted, "flush() must fully reset segment state")
    }

    // MARK: - Below minSpeechDuration: flush yields nil, but still resets

    func testFlushReturnsNilWhenBelowMinSpeechDuration() {
        let segmenter = SpeechSegmenter(config: makeConfig(minSpeechDuration: 0.4))

        // Only 0.2s of speech (2 chunks) — below the 0.4s minimum.
        let started = segmenter.process(chunk: chunk(), rms: 0.05)
        XCTAssertEqual(started, .speechStarted)
        _ = segmenter.process(chunk: chunk(), rms: 0.05)

        XCTAssertNil(segmenter.flush(), "Too-short in-progress speech must not be flushed as a real utterance")

        // State must still be reset (silence), same as a real flush.
        let event = segmenter.process(chunk: chunk(), rms: 0.05)
        XCTAssertEqual(event, .speechStarted, "flush() must reset state even when it returns nil")
    }

    // MARK: - Nothing to flush once a segment was already discarded (awaitingSilence)

    func testFlushReturnsNilDuringAwaitingSilence() {
        let config = SegmenterConfig(
            speechRMSThreshold: 0.02,
            endSilence: 0.7,
            minSpeechDuration: 0.4,
            maxSegmentDuration: 1.0)
        let segmenter = SpeechSegmenter(config: config)

        _ = segmenter.process(chunk: chunk(), rms: 0.05) // speechStarted
        var discarded: SegmenterEvent = .none
        for _ in 0..<15 {
            let event = segmenter.process(chunk: chunk(), rms: 0.05)
            if case .segmentDiscarded = event {
                discarded = event
                break
            }
        }
        guard case .segmentDiscarded(let reason) = discarded, reason == "máximo" else {
            XCTFail("Setup failed: expected a máximo discard before testing flush() in awaitingSilence")
            return
        }

        XCTAssertNil(segmenter.flush(), "An already-discarded (máximo) segment has nothing 'in progress' left to flush")
    }

    // MARK: - Pre-roll is included in a flush, same as a normal segment end

    func testFlushIncludesPreRoll() {
        let segmenter = SpeechSegmenter(config: makeConfig())
        let silenceChunk = Array(repeating: Float(0.0), count: samplesPerChunk)

        for _ in 0..<10 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.001)
        }
        let started = segmenter.process(chunk: chunk(), rms: 0.05)
        XCTAssertEqual(started, .speechStarted)
        for _ in 0..<5 {
            _ = segmenter.process(chunk: chunk(), rms: 0.05)
        }

        guard let flushed = segmenter.flush() else {
            XCTFail("Expected a flushed segment")
            return
        }
        // 0.6s of speech (9600 samples) plus at least some pre-roll from the
        // saturated ring buffer.
        XCTAssertGreaterThan(flushed.count, 6 * samplesPerChunk, "Flush must include pre-roll ahead of the speech, same as a normal segment end")
    }
}
