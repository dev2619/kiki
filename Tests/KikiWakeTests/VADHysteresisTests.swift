import XCTest
@testable import KikiWake

/// Tests for VAD enter/exit hysteresis in adaptive mode (`SegmenterConfig.adaptiveThreshold`).
///
/// Field evidence that motivates this fix: user dictations were captured at
/// only 1.3-1.6s for sentences that were obviously much longer. The
/// effective adaptive threshold measured in the field was 0.0143 against
/// observed speech peaks of 0.0215-0.0244 — only ~1.6x headroom. Soft speech
/// portions (word endings, unstressed syllables) commonly fall below that
/// single threshold, get classified as silence, and arm the `endSilence`
/// (1.5s) countdown DURING what is still an ongoing sentence — cutting it
/// off mid-utterance the moment the countdown expires.
///
/// The fix is classic enter/exit hysteresis: entering speech from silence
/// still requires clearing the full `effectiveThreshold`, but once already
/// in `.speech`, a chunk only needs to clear the lower `exitThreshold`
/// (`effectiveThreshold * 0.55`) to remain classified as speech. Soft
/// trailing speech stays "speech"; only audio that drops below the (lower)
/// exit threshold starts the `endSilence` clock.
///
/// IMPORTANT: hysteresis is adaptive-mode-only. Fixed mode (the 18
/// pre-existing `SpeechSegmenterTests`) keeps legacy single-threshold
/// semantics untouched.
final class VADHysteresisTests: XCTestCase {

    private let sampleRate: Double = 16_000
    private let samplesPerChunk = 1600 // 0.1s @ 16kHz

    private func chunk() -> [Float] {
        Array(repeating: Float(0.0), count: samplesPerChunk)
    }

    /// RED-first regression test for the field bug. The floor is seeded
    /// directly via `seedNoiseFloor` so entry/exit thresholds are
    /// deterministic from the first chunk: seed 0.00572 * noiseFloorMultiplier
    /// (2.5) = effectiveThreshold ~0.0143, matching the field-observed
    /// effective threshold exactly.
    func testSoftTrailingSpeechStaysInSpeechUntilTrueSilence() {
        // Seed noise floor so effectiveThreshold = seedNoiseFloor * 2.5.
        // seedNoiseFloor = 0.00572 -> effectiveThreshold ~= 0.0143,
        // exitThreshold = 0.0143 * 0.55 ~= 0.00787 (matches field evidence:
        // "umbral 0.0143 / salida 0.0079").
        let seed: Float = 0.00572
        let config = SegmenterConfig(
            speechRMSThreshold: 0.008,
            endSilence: 1.5,
            minSpeechDuration: 0.4,
            maxSegmentDuration: 30.0,
            adaptiveThreshold: true
        )
        let segmenter = SpeechSegmenter(config: config, seedNoiseFloor: seed)

        XCTAssertEqual(segmenter.effectiveThreshold, 0.0143, accuracy: 0.0005)
        XCTAssertEqual(segmenter.exitThreshold, 0.00787, accuracy: 0.0005)

        // Enter speech well above the entry threshold (a stressed syllable /
        // loud speech peak, matching field peaks of 0.0215-0.0244).
        let entryEvent = segmenter.process(chunk: chunk(), rms: 0.03)
        XCTAssertEqual(entryEvent, .speechStarted)

        // Soft trailing speech: below the ENTRY threshold (0.0143) but above
        // the EXIT threshold (~0.00787) for 2s (20 chunks). Without
        // hysteresis this would be misclassified as silence and, since 2s >
        // endSilence (1.5s), would falsely end the segment mid-sentence.
        let softTailRMS: Float = 0.009
        for i in 0..<20 {
            let event = segmenter.process(chunk: chunk(), rms: softTailRMS)
            if case .segmentEnded = event {
                XCTFail("Soft trailing speech (rms \(softTailRMS), above exit threshold \(segmenter.exitThreshold)) must NOT end the segment; failed at chunk \(i)")
            }
            if case .segmentDiscarded = event {
                XCTFail("Soft trailing speech must not be discarded; failed at chunk \(i)")
            }
        }

        // Now genuine silence: below the exit threshold. Must arm and
        // eventually expire `endSilence`, ending the segment (including the
        // soft tail that preceded it).
        let trueSilenceRMS: Float = 0.002
        var endedEvent: SegmenterEvent?
        for _ in 0..<20 { // up to 2s, comfortably past endSilence (1.5s)
            let event = segmenter.process(chunk: chunk(), rms: trueSilenceRMS)
            if case .segmentEnded = event {
                endedEvent = event
                break
            }
        }

        guard case .segmentEnded(let samples) = endedEvent ?? .none else {
            XCTFail("Expected segmentEnded once true silence sustains past endSilence")
            return
        }
        // The segment must include the loud entry chunk plus the full 2s
        // soft tail (minus the ~0.2s trailing-silence cap) — i.e. hysteresis
        // kept the soft tail INSIDE the speech segment instead of truncating
        // it the moment the soft tail began.
        let entryChunkSamples = samplesPerChunk
        let softTailSamples = 20 * samplesPerChunk
        XCTAssertGreaterThanOrEqual(
            samples.count,
            entryChunkSamples + softTailSamples,
            "Segment must include the full soft tail, not truncate at the first soft chunk"
        )
    }

    /// Sanity check that hysteresis does NOT prevent a real end-of-utterance:
    /// once RMS drops below the exit threshold and sustains for endSilence,
    /// the segment still ends normally.
    func testGenuineSilenceStillEndsSegmentPromptly() {
        let config = SegmenterConfig(
            speechRMSThreshold: 0.008,
            endSilence: 0.7,
            minSpeechDuration: 0.4,
            maxSegmentDuration: 30.0,
            adaptiveThreshold: true
        )
        let segmenter = SpeechSegmenter(config: config, seedNoiseFloor: 0.00572)

        _ = segmenter.process(chunk: chunk(), rms: 0.03) // speechStarted
        for _ in 0..<9 {
            let event = segmenter.process(chunk: chunk(), rms: 0.03)
            XCTAssertEqual(event, .none)
        }

        var endedEvent: SegmenterEvent?
        for _ in 0..<10 {
            let event = segmenter.process(chunk: chunk(), rms: 0.001) // well below exit threshold
            if case .segmentEnded = event {
                endedEvent = event
                break
            }
        }
        guard case .segmentEnded = endedEvent ?? .none else {
            XCTFail("Genuine silence below the exit threshold must still end the segment after endSilence")
            return
        }
    }

    /// Hysteresis must not apply when entering speech from silence: a chunk
    /// between the exit and entry thresholds must NOT trigger speechStarted.
    func testEntryStillRequiresFullEntryThresholdFromSilence() {
        let config = SegmenterConfig(
            speechRMSThreshold: 0.008,
            endSilence: 0.7,
            adaptiveThreshold: true
        )
        let segmenter = SpeechSegmenter(config: config, seedNoiseFloor: 0.00572)
        // effectiveThreshold ~0.0143, exitThreshold ~0.00787.
        // rms 0.010 clears exit but not entry -> from .silence this must NOT
        // start speech (hysteresis only lowers the bar once ALREADY speaking).
        let event = segmenter.process(chunk: chunk(), rms: 0.010)
        XCTAssertNotEqual(event, .speechStarted, "A chunk between exit and entry thresholds must not start speech from .silence")
    }

    /// Fixed mode (adaptiveThreshold: false) must keep legacy single-
    /// threshold behavior: a dip below `speechRMSThreshold` while in speech
    /// must be classified as silence immediately, matching the 18 untouched
    /// `SpeechSegmenterTests`.
    func testFixedModeHasNoHysteresis() {
        let config = SegmenterConfig(
            speechRMSThreshold: 0.02,
            endSilence: 0.7,
            minSpeechDuration: 0.4,
            adaptiveThreshold: false
        )
        let segmenter = SpeechSegmenter(config: config)

        let started = segmenter.process(chunk: chunk(), rms: 0.05)
        XCTAssertEqual(started, .speechStarted)

        // Sustain speech past minSpeechDuration (0.4s = 4 chunks) so the
        // eventual segment end isn't discarded as "corto".
        for _ in 0..<4 {
            _ = segmenter.process(chunk: chunk(), rms: 0.05)
        }

        // A dip that would clear a 0.55 exit ratio (0.02 * 0.55 = 0.011) but
        // not the fixed threshold (0.02) must still classify as silence in
        // fixed mode (no hysteresis).
        var endedEvent: SegmenterEvent?
        for _ in 0..<10 { // up to 1s of dip at rms 0.015; endSilence (0.7s) must fire well within this
            let event = segmenter.process(chunk: chunk(), rms: 0.015)
            if case .segmentEnded = event {
                endedEvent = event
                break
            }
        }
        guard case .segmentEnded = endedEvent ?? .none else {
            XCTFail("Fixed mode must classify rms 0.015 (below fixed threshold 0.02) as silence with no hysteresis, ending the segment")
            return
        }
    }
}
