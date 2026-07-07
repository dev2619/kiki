import XCTest
@testable import KikiWake

/// Tests for the adaptive noise-floor threshold (`SegmenterConfig.adaptiveThreshold`).
///
/// Field evidence that motivates this feature (see task-4 field-calibration notes):
/// a user's mic sustained 0.024-0.045 RMS in a live/loud environment against a
/// FIXED threshold of 0.008 -> every chunk classified as speech forever, so
/// segments always hit the max-duration cap and got discarded whole (wake
/// phrase never reached Whisper). The SAME user in a quiet moment had genuine
/// speech fragments discarded as "corto" because the fixed threshold sat above
/// their room's ambient level. A fixed threshold cannot serve both; these
/// tests exercise the adaptive replacement.
///
/// IMPORTANT: this file must NEVER touch `SpeechSegmenterTests.swift` — those
/// 18 tests exercise legacy (non-adaptive) behavior and must keep passing
/// unmodified. `adaptiveThreshold` defaults to `false` precisely so those
/// tests are unaffected; every test below constructs its config with
/// `adaptiveThreshold: true` explicitly.
final class AdaptiveNoiseFloorTests: XCTestCase {

    private let sampleRate: Double = 16_000
    private let samplesPerChunk = 1600 // 0.1s @ 16kHz

    private func chunk() -> [Float] {
        Array(repeating: Float(0.0), count: samplesPerChunk)
    }

    // MARK: - Default flag

    func testAdaptiveThresholdDefaultsToFalse() {
        let config = SegmenterConfig()
        XCTAssertFalse(config.adaptiveThreshold, "Must default to false: zero risk to existing legacy behavior/tests. WakeListener opts in explicitly.")
    }

    // MARK: - Adaptive off preserves legacy behavior

    func testAdaptiveOffKeepsEffectiveThresholdPinnedToConfigured() {
        let config = SegmenterConfig(speechRMSThreshold: 0.008, adaptiveThreshold: false)
        let segmenter = SpeechSegmenter(config: config)

        XCTAssertEqual(segmenter.effectiveThreshold, 0.008)

        // Feed a loud-room pattern that WOULD move the floor a lot if adaptive
        // were on; effectiveThreshold must not budge when the flag is off.
        for _ in 0..<50 {
            _ = segmenter.process(chunk: chunk(), rms: 0.03)
        }
        XCTAssertEqual(segmenter.effectiveThreshold, 0.008, "adaptiveThreshold: false must freeze effectiveThreshold at the configured value")
    }

    // MARK: - Quiet room: floor learns low, speech at 0.02 triggers

    func testQuietRoomFloorLearnsLowAndSpeechTriggers() {
        let config = SegmenterConfig(speechRMSThreshold: 0.008, adaptiveThreshold: true)
        let segmenter = SpeechSegmenter(config: config)

        // Quiet ambient noise, well below the seeded threshold.
        for _ in 0..<30 {
            _ = segmenter.process(chunk: chunk(), rms: 0.001)
        }

        // The floor should have learned the quiet room and converged near
        // ambient level (times the multiplier), well below the original 0.02
        // speech level we're about to feed.
        XCTAssertLessThan(segmenter.effectiveThreshold, 0.02, "Floor should learn a low ambient level so real speech at 0.02 clears it")

        let event = segmenter.process(chunk: chunk(), rms: 0.02)
        XCTAssertEqual(event, .speechStarted, "Speech at 0.02 must trigger once the floor has learned this quiet room")
    }

    // MARK: - Floor frozen during speech (mid-utterance dips are not noise)

    func testFloorFrozenDuringSpeechState() {
        let config = SegmenterConfig(
            speechRMSThreshold: 0.008,
            endSilence: 0.7,
            adaptiveThreshold: true
        )
        let segmenter = SpeechSegmenter(config: config)

        // Seed the floor with a quiet room first.
        for _ in 0..<20 {
            _ = segmenter.process(chunk: chunk(), rms: 0.001)
        }
        let thresholdBeforeSpeech = segmenter.effectiveThreshold

        // Enter speech.
        let started = segmenter.process(chunk: chunk(), rms: 0.05)
        XCTAssertEqual(started, .speechStarted)
        XCTAssertEqual(segmenter.effectiveThreshold, thresholdBeforeSpeech, "Floor must not move on the very chunk that starts speech")

        // Prolonged speech, including a brief silence-classified dip that
        // stays under `endSilence` (a natural pause mid-utterance, not
        // ambient noise) - the floor must not move at all while in .speech.
        for _ in 0..<20 {
            _ = segmenter.process(chunk: chunk(), rms: 0.05)
        }
        for _ in 0..<3 {
            // Dip below threshold, but short of endSilence (0.7s = 7 chunks).
            _ = segmenter.process(chunk: chunk(), rms: 0.001)
        }
        XCTAssertEqual(segmenter.effectiveThreshold, thresholdBeforeSpeech, "Floor must stay frozen through a mid-utterance dip while still in .speech")

        // Resume speech to avoid ending the segment as a side effect.
        _ = segmenter.process(chunk: chunk(), rms: 0.05)
        XCTAssertEqual(segmenter.effectiveThreshold, thresholdBeforeSpeech, "Floor must still be frozen after resuming speech")
    }

    // MARK: - Clamping bounds

    func testEffectiveThresholdClampedToMinimum() {
        let config = SegmenterConfig(speechRMSThreshold: 0.008, adaptiveThreshold: true)
        let segmenter = SpeechSegmenter(config: config)

        // Near-silent room: floor would otherwise converge toward ~0.
        for _ in 0..<200 {
            _ = segmenter.process(chunk: chunk(), rms: 0.00001)
        }
        XCTAssertEqual(segmenter.effectiveThreshold, 0.004, accuracy: 0.0001, "Effective threshold must clamp at the documented minimum (0.004)")
    }

    func testEffectiveThresholdClampedToMaximum() {
        // Seed with a huge configured threshold so the very first (speech)
        // chunk seeds the floor via the threshold/3.5 fallback already above
        // the max clamp.
        let config = SegmenterConfig(speechRMSThreshold: 1.0, adaptiveThreshold: true)
        let segmenter = SpeechSegmenter(config: config)

        // First chunk: rms 0.5 is below the raw initial threshold (1.0), so
        // it classifies as silence and seeds the floor directly at 0.5 -
        // already enough to blow past the max clamp once multiplied.
        _ = segmenter.process(chunk: chunk(), rms: 0.5)
        XCTAssertEqual(segmenter.effectiveThreshold, 0.06, accuracy: 0.0001, "Effective threshold must clamp at the documented maximum (0.06)")

        // Feeding more of the same must not push it any higher.
        for _ in 0..<20 {
            _ = segmenter.process(chunk: chunk(), rms: 0.5)
        }
        XCTAssertEqual(segmenter.effectiveThreshold, 0.06, accuracy: 0.0001)
    }

    // MARK: - Loud room convergence (THE field bug)
    //
    // Synthetic loud-room scenario: constant rms 0.03 from t0 against a
    // threshold seeded at 0.008 (the shipped default). Without an escape
    // mechanism, every chunk reads as "speech" forever (0.03 >= 0.008), so
    // segments perpetually hit maxSegmentDuration and get discarded via
    // "máximo", re-entering `.awaitingSilence` -- but chunks there STILL read
    // as speech relative to the frozen threshold, so the segmenter can never
    // reach true silence to reset. This test proves the `.awaitingSilence`
    // "unstick" EMA (alpha 0.01, applied even to chunks that still classify
    // as speech while awaiting silence) breaks the deadlock: the floor keeps
    // grinding upward from these otherwise-ignored chunks until
    // effectiveThreshold finally exceeds the room's real ambient level.
    //
    // Worked numbers (see constants in SpeechSegmenter): noiseFloorAlphaUnstick
    // = 0.01, noiseFloorMultiplier = 3.5, seed = 0.008 / 3.5 = 0.0022857.
    // Target: noiseFloor > 0.03 / 3.5 = 0.0085714 (so effectiveThreshold > 0.03).
    // Solving 0.03 - (0.03 - 0.0022857) * 0.99^n > 0.0085714 gives n ~= 25.6,
    // i.e. ~26 awaitingSilence chunks (~2.6s). With maxSegmentDuration = 1.0s
    // to reach awaitingSilence quickly, total convergence lands at roughly
    // 3.6s from t0 - comfortably inside the 6s bound this test asserts.
    func testLoudRoomConvergesToAboveAmbientWithinBound() {
        let config = SegmenterConfig(
            speechRMSThreshold: 0.008,
            endSilence: 0.7,
            minSpeechDuration: 0.4,
            maxSegmentDuration: 1.0,
            adaptiveThreshold: true
        )
        let segmenter = SpeechSegmenter(config: config)

        let loudRMS: Float = 0.03
        let convergenceBoundSeconds: Double = 6.0
        let maxChunks = Int(convergenceBoundSeconds / 0.1)

        var convergedAtChunk: Int?
        var sawMaximoDiscard = false

        for i in 0..<maxChunks {
            let event = segmenter.process(chunk: chunk(), rms: loudRMS)
            if case .segmentDiscarded(let reason) = event, reason == "máximo" {
                sawMaximoDiscard = true
            }
            if convergedAtChunk == nil && segmenter.effectiveThreshold > loudRMS {
                convergedAtChunk = i
            }
        }

        XCTAssertTrue(sawMaximoDiscard, "Sustained loud rms above the seeded threshold must still hit the max-duration discard at least once")
        guard let convergedAtChunk else {
            XCTFail("effectiveThreshold never exceeded the loud-room rms (0.03) within \(convergenceBoundSeconds)s - the segmenter would stay stuck forever")
            return
        }
        let convergedAtSeconds = Double(convergedAtChunk) * 0.1
        XCTAssertLessThanOrEqual(convergedAtSeconds, convergenceBoundSeconds, "Loud-room convergence must complete within \(convergenceBoundSeconds)s")
        XCTAssertGreaterThan(segmenter.effectiveThreshold, loudRMS, "Final effective threshold must exceed the loud room's ambient rms so it is classified as silence again")
    }

    // MARK: - Reset restores adaptive state

    func testResetRestoresInitialEffectiveThreshold() {
        let config = SegmenterConfig(speechRMSThreshold: 0.008, adaptiveThreshold: true)
        let segmenter = SpeechSegmenter(config: config)

        for _ in 0..<30 {
            _ = segmenter.process(chunk: chunk(), rms: 0.001)
        }
        XCTAssertNotEqual(segmenter.effectiveThreshold, 0.008, "Sanity: floor must have moved from the seed by now")

        segmenter.reset()
        XCTAssertEqual(segmenter.effectiveThreshold, 0.008, "reset() must restore the initial/floor-seed effective threshold")
    }
}
