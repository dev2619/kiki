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
        XCTAssertEqual(config.speechRMSThreshold, 0.02)
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

        // Simulate ~0.5s of silence
        let silenceChunk = Array(repeating: Float(0.0), count: 1600)
        for _ in 0..<5 {
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

        // Pre-roll: up to 0.3s (~4800 samples, but may be more due to rounding)
        // Speech: 10 chunks (16000 samples)
        // Trailing: ~0.2s tail (~3200 samples)
        // Total: pre-roll (4800-8000) + speech (16000) + tail (0-3200) = 20800-27200
        let expectedMinSamples = 16000 + 3200  // At least speech + small tail
        let expectedMaxSamples = 8000 + 16000 + 3200  // Pre-roll + speech + tail
        XCTAssertGreaterThanOrEqual(samples.count, expectedMinSamples, "Insufficient samples")
        XCTAssertLessThanOrEqual(samples.count, expectedMaxSamples, "Too many samples in segment")
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
