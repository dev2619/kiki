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
}
