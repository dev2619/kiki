import XCTest
@testable import KikiWake

final class SpeechSegmenterTests: XCTestCase {

    // MARK: - Helper: Create config with custom values
    private func makeConfig(
        threshold: Float = 0.02,
        endSilence: TimeInterval = 0.7,
        minSpeechDuration: TimeInterval = 0.4,
        maxSegmentDuration: TimeInterval = 30.0
    ) -> SegmenterConfig {
        SegmenterConfig(
            speechRMSThreshold: threshold,
            endSilence: endSilence,
            minSpeechDuration: minSpeechDuration,
            maxSegmentDuration: maxSegmentDuration
        )
    }

    // MARK: - Helper: Simulate chunk processing
    /// Simulate audio chunks at 16kHz (1600 samples = 0.1s)
    private func processChunks(
        segmenter: SpeechSegmenter,
        pattern: [(rms: Float, durationSeconds: Double)],
        chunkSizeSeconds: Double = 0.1
    ) -> [SegmenterEvent] {
        var events: [SegmenterEvent] = []
        let sampleRate: Double = 16_000
        let samplesPerChunk = Int(sampleRate * chunkSizeSeconds)

        for (rms, duration) in pattern {
            let numChunks = Int(duration / chunkSizeSeconds)
            let chunk = Array(repeating: Float(0.0), count: samplesPerChunk)

            for _ in 0..<numChunks {
                let event = segmenter.process(chunk: chunk, rms: rms)
                if event != .none {
                    events.append(event)
                }
            }
        }

        return events
    }

    // MARK: - Initialization & defaults
    func testConfigDefaults() {
        let config = SegmenterConfig()
        XCTAssertEqual(config.speechRMSThreshold, 0.008)
        XCTAssertEqual(config.endSilence, 0.7)
        XCTAssertEqual(config.minSpeechDuration, 0.4)
        XCTAssertGreaterThan(config.maxSegmentDuration, 0)
    }

    func testSegmenterInitialization() {
        let config = makeConfig()
        let segmenter = SpeechSegmenter(config: config)
        // Should initialize without crashing
        XCTAssertNotNil(segmenter)
    }

    // MARK: - Simple speech detection
    func testSilenceToSpeechTransition() {
        let config = makeConfig(endSilence: 0.7, minSpeechDuration: 0.4)
        let segmenter = SpeechSegmenter(config: config)

        // Silence (0.5s)
        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        _ = segmenter.process(chunk: silenceChunk, rms: 0.01)

        // Speech starts
        let speechChunk = Array(repeating: Float(0.1), count: 1600)
        let event = segmenter.process(chunk: speechChunk, rms: 0.05)

        XCTAssertEqual(event, .speechStarted)
    }

    // MARK: - Pre-roll capture
    func testPreRollIncludedInSegment() {
        let config = makeConfig(
            endSilence: 0.7,
            minSpeechDuration: 0.4,
            maxSegmentDuration: 30.0
        )
        let segmenter = SpeechSegmenter(config: config)

        // Simulate >=1.0s of pre-speech silence (10 chunks) to fully saturate
        // the pre-roll ring buffer beyond its 0.3s (4800-sample) cap.
        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        for _ in 0..<10 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }

        // Simulate 1s of speech
        let speechChunk = Array(repeating: Float(0.5), count: 1600)
        _ = segmenter.process(chunk: speechChunk, rms: 0.05) // speechStarted
        for _ in 0..<9 {
            _ = segmenter.process(chunk: speechChunk, rms: 0.05)
        }

        // Simulate silence - need 0.7s to trigger segment end
        var segmentEvent: SegmenterEvent? = nil
        for _ in 0..<10 {
            let event = segmenter.process(chunk: silenceChunk, rms: 0.01)
            if case .segmentEnded = event {
                segmentEvent = event
                break
            }
        }

        // Should emit segmentEnded
        guard case .segmentEnded(let samples) = segmentEvent ?? .none else {
            XCTFail("Expected segmentEnded event")
            return
        }

        // Pre-roll is capped at 0.3s (4800 samples); speech is exactly 1s
        // (16000 samples); trailing tail is capped at 0.2s (3200 samples).
        // Feeding >=1.0s of pre-speech silence (10 chunks) fully saturates the
        // pre-roll ring buffer beyond its cap, so an uncapped pre-roll
        // implementation would include far more than 4800 samples and fail
        // this exact upper bound.
        let preRollCap = 4800
        let speechSamples = 16000
        let tailAllowance = 3200
        XCTAssertGreaterThanOrEqual(samples.count, speechSamples, "Insufficient samples")
        XCTAssertLessThanOrEqual(
            samples.count,
            preRollCap + speechSamples + tailAllowance,
            "Too many samples in segment; pre-roll cap may be broken"
        )
    }

    // MARK: - Minimum speech duration
    func testShortSpeechDiscarded() {
        let config = makeConfig(
            endSilence: 0.7,
            minSpeechDuration: 0.4
        )
        let segmenter = SpeechSegmenter(config: config)

        // Silence
        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        for _ in 0..<5 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }

        // Speech for only 0.2s (< minSpeechDuration of 0.4s)
        let speechChunk = Array(repeating: Float(0.5), count: 1600)
        _ = segmenter.process(chunk: speechChunk, rms: 0.05) // speechStarted
        _ = segmenter.process(chunk: speechChunk, rms: 0.05)

        // Silence (sustain endSilence) - need 0.7s to trigger segment end
        var discardEvent: SegmenterEvent? = nil
        for _ in 0..<10 {
            let event = segmenter.process(chunk: silenceChunk, rms: 0.01)
            if case .segmentDiscarded = event {
                discardEvent = event
                break
            }
        }

        guard case .segmentDiscarded(let reason) = discardEvent ?? .none else {
            XCTFail("Expected segmentDiscarded event")
            return
        }
        XCTAssertEqual(reason, "corto")
    }

    // MARK: - Maximum segment duration
    func testMaxSegmentDurationExceeded() {
        let config = makeConfig(
            endSilence: 0.7,
            minSpeechDuration: 0.4,
            maxSegmentDuration: 1.5 // 1.5 seconds max
        )
        let segmenter = SpeechSegmenter(config: config)

        // Silence
        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        for _ in 0..<5 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }

        // Speech for 2s (exceeds maxSegmentDuration of 1.5s)
        let speechChunk = Array(repeating: Float(0.5), count: 1600)
        var discardedEvent: SegmenterEvent = .none

        _ = segmenter.process(chunk: speechChunk, rms: 0.05) // speechStarted
        for _ in 0..<19 {
            let event = segmenter.process(chunk: speechChunk, rms: 0.05)
            if case .segmentDiscarded = event {
                discardedEvent = event
                break
            }
        }

        guard case .segmentDiscarded(let reason) = discardedEvent else {
            XCTFail("Expected segmentDiscarded event")
            return
        }
        XCTAssertEqual(reason, "máximo")
    }

    // MARK: - Valid utterance near the cap must still emit, not falsely discard
    /// Regression test for the fix-round-1 overcorrection: counting pending
    /// `trailingModeSilenceSamples` toward the cap on EVERY chunk (including the
    /// silence path) falsely discarded valid utterances. The pending silence only
    /// flushes into the segment when speech RESUMES; on sustained end-of-utterance
    /// silence it never enters the segment (beyond the capped ~0.2s tail), so it
    /// must not count toward the cap there.
    ///
    /// Numbers (16kHz, 1600 samples/chunk = 0.1s), max 1.5s (24000), endSilence 0.7s:
    /// 1.0s speech (16000) + sustained silence. Buggy projection on the 5th silence
    /// chunk: 16000 + 6400 pending + 1600 = 24000 >= 24000 -> false "máximo".
    /// Correct behavior: silence reaches endSilence at 0.7s and emits segmentEnded.
    /// In general, any utterance longer than maxSegmentDuration - endSilence would
    /// falsely discard under the buggy projection.
    func testValidUtteranceNearCapStillEmits() {
        let config = makeConfig(
            endSilence: 0.7,
            minSpeechDuration: 0.4,
            maxSegmentDuration: 1.5
        )
        let segmenter = SpeechSegmenter(config: config)

        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        let speechChunk = Array(repeating: Float(0.5), count: 1600)

        // Initial silence
        for _ in 0..<5 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }

        // Valid 1.0s utterance (under the 1.5s cap)
        _ = segmenter.process(chunk: speechChunk, rms: 0.05) // speechStarted
        for _ in 0..<9 {
            let event = segmenter.process(chunk: speechChunk, rms: 0.05)
            XCTAssertEqual(event, .none, "No event expected during in-cap speech")
        }

        // Sustained end-of-utterance silence: must emit segmentEnded at endSilence,
        // never a "máximo" discard.
        var endedEvent: SegmenterEvent? = nil
        for _ in 0..<10 {
            let event = segmenter.process(chunk: silenceChunk, rms: 0.01)
            if case .segmentDiscarded(let reason) = event {
                XCTFail("Valid utterance falsely discarded (reason: \(reason)); pending trailing silence must not count toward the cap on the silence path")
                return
            }
            if case .segmentEnded = event {
                endedEvent = event
                break
            }
        }

        guard case .segmentEnded(let samples) = endedEvent ?? .none else {
            XCTFail("Expected segmentEnded for a valid utterance ending in sustained silence")
            return
        }
        XCTAssertGreaterThanOrEqual(samples.count, 16000, "Segment should contain the full 1.0s of speech")
    }

    // MARK: - Max duration must be enforced across a dip-then-resume, not one chunk late
    /// Regression test for the max-duration overshoot bug: `wouldExceedMax` was computed
    /// from `accumulatedSampleCount + chunk.count` BEFORE the pending
    /// `trailingModeSilenceSamples` flush (which happens in the same call when speech
    /// resumes) added more samples. A near-boundary dip that resumes into speech let the
    /// internal segment exceed `maxSegmentDuration` for one extra chunk before the
    /// "máximo" discard fired on the NEXT chunk.
    ///
    /// Numbers (16kHz, 1600 samples/chunk = 0.1s):
    /// - maxSegmentDuration = 1.5s (24000 samples), endSilence = 0.7s (11200 samples)
    /// - Speech: 8 chunks = 0.8s (12800 samples)
    /// - Dip: 6 chunks = 0.6s (9600 samples) of silence, below endSilence so no emit
    /// - Resume: 1 speech chunk (1600 samples)
    ///
    /// Buggy check on resume: (12800 + 1600) / 16000 = 0.9s < 1.5s -> no discard;
    /// the resume chunk is let through as .none. Internal accumulation after the
    /// trailing-silence flush lands exactly at (12800 + 9600 + 1600) / 16000 = 1.5s
    /// (the cap) without ever being flagged, so the very next chunk pushes it to
    /// 1.6s (0.1s PAST the cap) before "máximo" finally fires — one chunk late.
    /// The fix must include the pending trailing-silence count in the check so the
    /// discard fires on this exact resume call, never letting accumulation reach or
    /// pass the cap unflagged.
    func testMaxSegmentCapEnforcedOnDipThenResume() {
        let config = makeConfig(
            endSilence: 0.7,
            minSpeechDuration: 0.4,
            maxSegmentDuration: 1.5
        )
        let segmenter = SpeechSegmenter(config: config)

        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        let speechChunk = Array(repeating: Float(0.5), count: 1600)

        // Initial silence
        for _ in 0..<5 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }

        // Speech: 0.8s total (1 speechStarted chunk + 7 more)
        var priorEvents: [SegmenterEvent] = []
        priorEvents.append(segmenter.process(chunk: speechChunk, rms: 0.05)) // speechStarted
        for _ in 0..<7 {
            priorEvents.append(segmenter.process(chunk: speechChunk, rms: 0.05))
        }

        // Dip: 0.6s of silence, strictly under endSilence (0.7s) so no segment emitted
        for _ in 0..<6 {
            priorEvents.append(segmenter.process(chunk: silenceChunk, rms: 0.01))
        }

        // Sanity: nothing was discarded or ended before the resume chunk
        for event in priorEvents {
            if case .segmentDiscarded = event {
                XCTFail("Should not discard before the cap is actually crossed")
            }
            if case .segmentEnded = event {
                XCTFail("Dip is under endSilence; should not emit a segment yet")
            }
        }

        // Resume speech: this exact chunk crosses the cap once the pending
        // trailing-silence flush is accounted for. The discard must fire HERE.
        let resumeEvent = segmenter.process(chunk: speechChunk, rms: 0.05)

        guard case .segmentDiscarded(let reason) = resumeEvent else {
            XCTFail("Expected segmentDiscarded(\"máximo\") on the resume chunk that crosses the cap, got \(resumeEvent)")
            return
        }
        XCTAssertEqual(reason, "máximo")
    }

    // MARK: - Re-trigger protection after max exceeded
    func testNoReTriggerUntilSilence() {
        let config = makeConfig(
            endSilence: 0.7,
            minSpeechDuration: 0.4,
            maxSegmentDuration: 1.5
        )
        let segmenter = SpeechSegmenter(config: config)

        // Silence
        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        for _ in 0..<5 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }

        // Speech exceeds max and triggers discard
        let speechChunk = Array(repeating: Float(0.5), count: 1600)
        _ = segmenter.process(chunk: speechChunk, rms: 0.05) // speechStarted
        for _ in 0..<19 {
            _ = segmenter.process(chunk: speechChunk, rms: 0.05)
        }

        // Continue sending speech (should be ignored due to awaitingSilence flag)
        var speechStartedAgain = false
        for _ in 0..<10 {
            let event = segmenter.process(chunk: speechChunk, rms: 0.05)
            if event == .speechStarted {
                speechStartedAgain = true
            }
        }
        XCTAssertFalse(speechStartedAgain, "Should not emit speechStarted while awaitingSilence")

        // Now send silence (sustain endSilence)
        for _ in 0..<8 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }

        // New speech should now trigger speechStarted
        let newSpeechEvent = segmenter.process(chunk: speechChunk, rms: 0.05)
        XCTAssertEqual(newSpeechEvent, .speechStarted, "Should re-enable speechStarted after passing through silence")
    }

    // MARK: - Multiple utterances
    func testTwoSeparateUtterances() {
        let config = makeConfig(
            endSilence: 0.7,
            minSpeechDuration: 0.4,
            maxSegmentDuration: 30.0
        )
        let segmenter = SpeechSegmenter(config: config)

        var events: [SegmenterEvent] = []

        // First utterance: silence -> speech -> silence
        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        let speechChunk = Array(repeating: Float(0.5), count: 1600)

        // Initial silence
        for _ in 0..<5 {
            let event = segmenter.process(chunk: silenceChunk, rms: 0.01)
            if event != .none { events.append(event) }
        }

        // First speech (1s)
        for _ in 0..<10 {
            let event = segmenter.process(chunk: speechChunk, rms: 0.05)
            if event != .none { events.append(event) }
        }

        // Silence (endSilence sustained)
        for _ in 0..<8 {
            let event = segmenter.process(chunk: silenceChunk, rms: 0.01)
            if event != .none { events.append(event) }
        }

        // More silence before second utterance
        for _ in 0..<5 {
            let event = segmenter.process(chunk: silenceChunk, rms: 0.01)
            if event != .none { events.append(event) }
        }

        // Second speech (0.8s)
        for _ in 0..<8 {
            let event = segmenter.process(chunk: speechChunk, rms: 0.05)
            if event != .none { events.append(event) }
        }

        // Silence (endSilence sustained)
        for _ in 0..<8 {
            let event = segmenter.process(chunk: silenceChunk, rms: 0.01)
            if event != .none { events.append(event) }
        }

        // Should have: speechStarted, segmentEnded, speechStarted, segmentEnded
        let speechStartedCount = events.filter { $0 == .speechStarted }.count
        let segmentEndedCount = events.filter { event in
            if case .segmentEnded = event { return true }
            return false
        }.count

        XCTAssertEqual(speechStartedCount, 2, "Should emit speechStarted twice (once per utterance)")
        XCTAssertEqual(segmentEndedCount, 2, "Should emit segmentEnded twice (once per complete utterance)")
    }

    // MARK: - Reset functionality
    func testReset() {
        let config = makeConfig()
        let segmenter = SpeechSegmenter(config: config)

        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        let speechChunk = Array(repeating: Float(0.5), count: 1600)

        // Build up state
        for _ in 0..<5 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }

        let event1 = segmenter.process(chunk: speechChunk, rms: 0.05)
        XCTAssertEqual(event1, .speechStarted)

        // Reset
        segmenter.reset()

        // After reset, silence should exist, then speech should trigger speechStarted again
        for _ in 0..<5 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }

        let event2 = segmenter.process(chunk: speechChunk, rms: 0.05)
        XCTAssertEqual(event2, .speechStarted, "After reset, should be able to trigger speechStarted again")
    }

    // MARK: - No event for silence/speech within threshold
    func testNoneEventInSilence() {
        let config = makeConfig()
        let segmenter = SpeechSegmenter(config: config)

        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        let event = segmenter.process(chunk: silenceChunk, rms: 0.01)

        XCTAssertEqual(event, .none, "Should emit .none for silence chunks that don't trigger state changes")
    }

    func testNoneEventDuringSpeech() {
        let config = makeConfig()
        let segmenter = SpeechSegmenter(config: config)

        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        let speechChunk = Array(repeating: Float(0.5), count: 1600)

        // Get to speech state
        for _ in 0..<5 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }
        _ = segmenter.process(chunk: speechChunk, rms: 0.05) // speechStarted

        // Subsequent speech chunks should emit .none
        let event = segmenter.process(chunk: speechChunk, rms: 0.05)
        XCTAssertEqual(event, .none, "Should emit .none for speech chunks that don't trigger state changes")
    }

    // MARK: - Event equatability
    func testSegmenterEventEquality() {
        let event1 = SegmenterEvent.none
        let event2 = SegmenterEvent.none
        XCTAssertEqual(event1, event2)

        let event3 = SegmenterEvent.speechStarted
        XCTAssertNotEqual(event1, event3)

        let samples = Array(repeating: Float(0.0), count: 100)
        let event4 = SegmenterEvent.segmentEnded(samples: samples)
        let event5 = SegmenterEvent.segmentEnded(samples: samples)
        XCTAssertEqual(event4, event5)

        let event6 = SegmenterEvent.segmentDiscarded(reason: "corto")
        let event7 = SegmenterEvent.segmentDiscarded(reason: "corto")
        XCTAssertEqual(event6, event7)
    }

    // MARK: - Config equatability
    func testSegmenterConfigEquality() {
        let config1 = makeConfig(threshold: 0.02, endSilence: 0.7)
        let config2 = makeConfig(threshold: 0.02, endSilence: 0.7)
        XCTAssertEqual(config1, config2)

        let config3 = makeConfig(threshold: 0.03, endSilence: 0.7)
        XCTAssertNotEqual(config1, config3)
    }

    // MARK: - Edge case: Empty chunk
    func testEmptyChunk() {
        let config = makeConfig()
        let segmenter = SpeechSegmenter(config: config)
        let emptyChunk: [Float] = []

        // Should handle gracefully (empty chunk = 0 duration)
        let event = segmenter.process(chunk: emptyChunk, rms: 0.05)
        XCTAssertEqual(event, .none)
    }

    // MARK: - Edge case: Different sample rates
    func testDifferentSampleRate() {
        let config = makeConfig()
        let segmenter = SpeechSegmenter(config: config, sampleRate: 8_000)

        // At 8kHz, 800 samples = 0.1s (not 1600)
        let silenceChunk = Array(repeating: Float(0.0), count: 800)
        let speechChunk = Array(repeating: Float(0.5), count: 800)

        // Silence
        for _ in 0..<5 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }

        let event = segmenter.process(chunk: speechChunk, rms: 0.05)
        XCTAssertEqual(event, .speechStarted, "Should work correctly with different sample rates")
    }

    // MARK: - Trailing silence not included in segment
    func testTrailingSilenceNotIncluded() {
        let config = makeConfig(
            endSilence: 0.7,
            minSpeechDuration: 0.4,
            maxSegmentDuration: 30.0
        )
        let segmenter = SpeechSegmenter(config: config)

        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        let speechChunk = Array(repeating: Float(0.5), count: 1600)

        // Silence
        for _ in 0..<5 {
            _ = segmenter.process(chunk: silenceChunk, rms: 0.01)
        }

        // Speech (1s)
        _ = segmenter.process(chunk: speechChunk, rms: 0.05) // speechStarted
        for _ in 0..<9 {
            _ = segmenter.process(chunk: speechChunk, rms: 0.05)
        }

        // Silence (sustain endSilence 0.7s) - find the segment end event
        var segmentEvent: SegmenterEvent? = nil
        for _ in 0..<10 {
            let event = segmenter.process(chunk: silenceChunk, rms: 0.01)
            if case .segmentEnded = event {
                segmentEvent = event
                break
            }
        }

        guard case .segmentEnded(let samples) = segmentEvent ?? .none else {
            XCTFail("Expected segmentEnded")
            return
        }

        // Segment should be pre-roll (~4800) + speech (16000) = ~20800
        // Should NOT include the full 0.8s of trailing silence (12800 samples)
        // Allowing ~0.2s tail (3200 samples), so max ~24000
        XCTAssertLessThan(samples.count, 25000, "Segment should not include excessive trailing silence")
    }
}
