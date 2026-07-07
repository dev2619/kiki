import XCTest
@testable import KikiWake

/// Tests for relative-drop end-of-speech detection (`SpeechSegmenter.endDropRatio`),
/// the fix for BUG 2 in the noisy-room field report: absolute-energy exit detection
/// cannot find silence when ambient noise sits above even the (already-lowered) exit
/// threshold — the speech segment then never ends. See the field log that motivated
/// this fix:
///   "pico RMS últimos 10s: 0.0453 (umbral 0.0040 / salida 0.0022)"
/// followed immediately by "ventana parcial 8.1s → detenido" with NOTHING processed —
/// the adaptive threshold had converged to its minimum (0.004, exit 0.0022) while
/// ambient noise stayed at ~0.045, permanently above the exit bar.
///
/// IMPORTANT: this file must NEVER touch `SpeechSegmenterTests.swift` (the 18
/// legacy, fixed-mode tests) or fixed-mode behavior at all — relative-drop end
/// detection is adaptive-mode only (see `endDropRatio`'s doc comment in
/// `SpeechSegmenter.swift`). Every config below sets `adaptiveThreshold: true`
/// explicitly.
final class SpeechSegmenterRelativeEndTests: XCTestCase {

    private let samplesPerChunk = 1600 // 0.1s @ 16kHz

    private func chunk() -> [Float] {
        Array(repeating: Float(0.0), count: samplesPerChunk)
    }

    private func makeConfig(
        endSilence: TimeInterval = 0.7,
        minSpeechDuration: TimeInterval = 0.4,
        maxSegmentDuration: TimeInterval = 30.0
    ) -> SegmenterConfig {
        SegmenterConfig(
            speechRMSThreshold: 0.008,
            endSilence: endSilence,
            minSpeechDuration: minSpeechDuration,
            maxSegmentDuration: maxSegmentDuration,
            adaptiveThreshold: true)
    }

    // MARK: - (a) Noisy room: absolute exit can't find silence, relative drop does
    //
    // Worked numbers: seed the noise floor with a single silence chunk at rms 0.005
    // (the very first chunk directly seeds `noiseFloorEstimate`, see
    // `SpeechSegmenter.updateNoiseFloor`). That gives:
    //   effectiveThreshold = clamp(0.005 * 2.5, 0.004, 0.06)  = 0.0125
    //   exitThreshold      = 0.0125 * 0.55                    = 0.006875
    // Enter speech at rms 0.06 (comfortably above the 0.0125 entry bar) ->
    // segmentPeakRMS = 0.06, so the relative end bar becomes
    //   max(exitThreshold, segmentPeakRMS * 0.35) = max(0.006875, 0.021) = 0.021
    // Ambient-between-words at rms 0.03 stays >= 0.021 -> still classified SPEECH,
    // so the segment does NOT end even though it's sustained far past `endSilence`
    // (this is exactly the noisy-room shape from the field log: ambient noise well
    // above the absolute exit threshold, the condition that deadlocks absolute-only
    // detection). Speech then drops to rms 0.015: 0.015 < 0.021 -> classified
    // SILENCE, and once sustained for `endSilence` (0.7s = 7 chunks) the segment
    // finally ends.
    func testNoisyRoomEndsOnRelativeDropBelowOwnPeak() {
        let config = makeConfig()
        let segmenter = SpeechSegmenter(config: config)

        // Seed the noise floor.
        let seedEvent = segmenter.process(chunk: chunk(), rms: 0.005)
        XCTAssertEqual(seedEvent, .none)
        XCTAssertEqual(segmenter.effectiveThreshold, 0.0125, accuracy: 0.0001)
        XCTAssertEqual(segmenter.exitThreshold, 0.006875, accuracy: 0.0001)

        // Enter speech at 0.06.
        let started = segmenter.process(chunk: chunk(), rms: 0.06)
        XCTAssertEqual(started, .speechStarted)
        for _ in 0..<5 {
            let event = segmenter.process(chunk: chunk(), rms: 0.06)
            XCTAssertEqual(event, .none)
        }

        // Ambient-between-words at 0.03 (>= the relative bar of 0.021), sustained
        // for 1s (10 chunks) — well past `endSilence` (0.7s) if it were wrongly
        // classified as silence. Must NOT end the segment.
        for _ in 0..<10 {
            let event = segmenter.process(chunk: chunk(), rms: 0.03)
            XCTAssertEqual(event, .none, "Ambient noise above the relative bar must not end the segment")
        }

        // Speech drops to 0.015 (< 0.021) and stays there for endSilence (0.7s = 7 chunks).
        var endedEvent: SegmenterEvent?
        for _ in 0..<8 {
            let event = segmenter.process(chunk: chunk(), rms: 0.015)
            if case .segmentEnded = event {
                endedEvent = event
                break
            }
            if case .segmentDiscarded = event {
                XCTFail("Unexpected discard: \(event)")
            }
        }

        guard case .segmentEnded(let samples) = endedEvent ?? .none else {
            XCTFail("Expected segmentEnded once speech dropped below its own relative bar and stayed there for endSilence — this is the exact case absolute-only detection cannot handle")
            return
        }
        XCTAssertGreaterThan(samples.count, 0)
    }

    // MARK: - (b) A brief dip that stays above the relative bar must not end the segment

    func testBriefDipAboveRelativeBarStaysInSpeech() {
        let config = makeConfig()
        let segmenter = SpeechSegmenter(config: config)

        _ = segmenter.process(chunk: chunk(), rms: 0.005) // seed floor (see test above for the numbers)

        let started = segmenter.process(chunk: chunk(), rms: 0.06)
        XCTAssertEqual(started, .speechStarted)
        for _ in 0..<5 {
            _ = segmenter.process(chunk: chunk(), rms: 0.06)
        }

        // Dip to 0.025 (> the relative bar of 0.021), sustained for 1s (10 chunks) —
        // must NOT end the segment even though it's well past endSilence (0.7s).
        for _ in 0..<10 {
            let event = segmenter.process(chunk: chunk(), rms: 0.025)
            XCTAssertEqual(event, .none, "A dip that stays above the relative bar is still speech, not silence")
        }

        // Resume loud speech — the segment must still be open (no premature end).
        let resumeEvent = segmenter.process(chunk: chunk(), rms: 0.06)
        XCTAssertEqual(resumeEvent, .none)

        // Now genuinely end it: drop below the bar and sustain endSilence.
        var endedEvent: SegmenterEvent?
        for _ in 0..<8 {
            let event = segmenter.process(chunk: chunk(), rms: 0.015)
            if case .segmentEnded = event {
                endedEvent = event
                break
            }
        }
        guard case .segmentEnded = endedEvent ?? .none else {
            XCTFail("Expected the segment to eventually end on a genuine drop below the relative bar")
            return
        }
    }

    // MARK: - (c) Quiet room: legacy (absolute-exit-governed) behavior preserved
    //
    // Same seeded floor as above (effectiveThreshold 0.0125, exitThreshold 0.006875),
    // but a MODEST speech peak (0.014, just above the entry bar) instead of a loud
    // one. segmentPeakRMS * endDropRatio = 0.014 * 0.35 = 0.0049, which is BELOW
    // exitThreshold (0.006875) — so `max(exitThreshold, segmentPeakRMS * 0.35)`
    // must fall back to exitThreshold, exactly the pre-fix (legacy, absolute-only)
    // behavior. A drop to 0.006 is above what a peak-only relative bar (0.0049)
    // would require, but below the absolute exit threshold (0.006875): the segment
    // must still end, proving `max()` picked the right (higher, more conservative)
    // threshold rather than the relative fix accidentally loosening normal
    // quiet-room end detection.
    func testQuietRoomAbsoluteExitStillGovernsWhenPeakIsModest() {
        let config = makeConfig()
        let segmenter = SpeechSegmenter(config: config)

        _ = segmenter.process(chunk: chunk(), rms: 0.005) // seed floor
        XCTAssertEqual(segmenter.exitThreshold, 0.006875, accuracy: 0.0001)

        let started = segmenter.process(chunk: chunk(), rms: 0.014)
        XCTAssertEqual(started, .speechStarted)
        for _ in 0..<5 {
            _ = segmenter.process(chunk: chunk(), rms: 0.014)
        }

        // Drop to 0.006: above a peak-only relative bar (0.0049) but below the
        // absolute exit threshold (0.006875) — must still end via max().
        var endedEvent: SegmenterEvent?
        for _ in 0..<8 {
            let event = segmenter.process(chunk: chunk(), rms: 0.006)
            if case .segmentEnded = event {
                endedEvent = event
                break
            }
        }
        guard case .segmentEnded = endedEvent ?? .none else {
            XCTFail("Absolute exit threshold must still govern when it's the more conservative (higher) bound — max() semantics must not regress quiet-room behavior")
            return
        }
    }

    // MARK: - (d) A loud transient must NOT permanently truncate the utterance
    //
    // Regression test for the Critical-2 review finding: with an UNBOUNDED
    // running max, a single loud transient (an emphasized word, a door slam)
    // would raise the relative end bar (max(exit, peak*0.35)) for the rest of
    // the utterance, so normal speech after it classified as silence and the
    // segment ended mid-sentence — reproduced even in a quiet room. The fix is
    // a WINDOWED peak (~2s), so the transient's influence expires.
    //
    // Worked numbers (16kHz, 0.1s chunks, peakWindowSeconds = 2.0 -> 20
    // chunks, endDropRatio = 0.35): seed floor low so exitThreshold is near
    // the min clamp. Enter and hold speech at rms 0.05 (window peak 0.05,
    // bar max(exit, 0.0175) = 0.0175). One transient chunk at rms 0.2 pushes
    // the window peak to 0.2, so the bar jumps to 0.07 and subsequent 0.05
    // chunks classify as silence. endSilence here is 2.5s (25 chunks),
    // DELIBERATELY longer than the 2.0s window so the transient ages out
    // BEFORE endSilence could fire: after ~20 post-transient chunks the 0.2
    // is evicted, window peak returns to 0.05, bar returns to 0.0175, and
    // 0.05 re-classifies as speech, resetting the silence countdown.
    //
    // Under the OLD unbounded max, the bar would stay 0.07 forever, every
    // 0.05 chunk would stay silence, and at 25 chunks (2.5s) the segment
    // would falsely end — which this test's 26-chunk no-end assertion catches.
    func testLoudTransientDoesNotPermanentlyTruncateUtterance() {
        let config = makeConfig(endSilence: 2.5)
        let segmenter = SpeechSegmenter(config: config)

        _ = segmenter.process(chunk: chunk(), rms: 0.005) // seed floor

        let started = segmenter.process(chunk: chunk(), rms: 0.05)
        XCTAssertEqual(started, .speechStarted)
        for _ in 0..<5 {
            _ = segmenter.process(chunk: chunk(), rms: 0.05)
        }

        // Single loud transient.
        _ = segmenter.process(chunk: chunk(), rms: 0.2)

        // Resume normal speech at 0.05 for 26 chunks (2.6s) — longer than
        // endSilence (2.5s). Under the buggy unbounded max this would falsely
        // end at 2.5s; with the windowed peak the transient ages out at ~2.0s
        // and 0.05 re-classifies as speech, so the segment must NOT end.
        for i in 0..<26 {
            let event = segmenter.process(chunk: chunk(), rms: 0.05)
            if case .segmentEnded = event {
                XCTFail("A single transient must not truncate the utterance; falsely ended at post-transient chunk \(i)")
            }
            if case .segmentDiscarded = event {
                XCTFail("Unexpected discard at post-transient chunk \(i)")
            }
        }

        // Sanity: the segment can STILL end normally once real silence
        // (below the recovered ~0.0175 bar) sustains for endSilence.
        var endedEvent: SegmenterEvent?
        for _ in 0..<30 {
            let event = segmenter.process(chunk: chunk(), rms: 0.001)
            if case .segmentEnded = event {
                endedEvent = event
                break
            }
        }
        guard case .segmentEnded = endedEvent ?? .none else {
            XCTFail("Segment must still end on genuine sustained silence after the transient recovery")
            return
        }
    }
}
