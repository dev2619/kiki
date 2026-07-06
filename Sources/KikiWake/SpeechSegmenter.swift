import Foundation

/// Configuration for the speech segmenter.
public struct SegmenterConfig: Equatable {
    /// RMS threshold below which audio is considered silence (default: 0.02)
    public let speechRMSThreshold: Float

    /// Duration of sustained silence (in seconds) required to end a speech segment
    /// (default: 0.7 for listening, typically 1.5 for dictation)
    public let endSilence: TimeInterval

    /// Minimum speech duration (in seconds) for a segment to be emitted
    /// rather than discarded (default: 0.4)
    public let minSpeechDuration: TimeInterval

    /// Maximum allowed speech duration (in seconds) before forcing segment end
    /// and awaiting silence to reset (default: 30.0)
    public let maxSegmentDuration: TimeInterval

    /// Initialize with custom or default values.
    public init(
        speechRMSThreshold: Float = 0.02,
        endSilence: TimeInterval = 0.7,
        minSpeechDuration: TimeInterval = 0.4,
        maxSegmentDuration: TimeInterval = 30.0
    ) {
        self.speechRMSThreshold = speechRMSThreshold
        self.endSilence = endSilence
        self.minSpeechDuration = minSpeechDuration
        self.maxSegmentDuration = maxSegmentDuration
    }
}

/// Events emitted by the speech segmenter.
public enum SegmenterEvent: Equatable {
    /// No meaningful event occurred.
    case none

    /// Speech has started (silence→speech transition).
    case speechStarted

    /// A valid speech segment has ended.
    /// - Parameter samples: Audio samples from the segment (including pre-roll).
    case segmentEnded(samples: [Float])

    /// A speech segment was discarded.
    /// - Parameter reason: Reason for discard ("corto" for too short, "máximo" for exceeding max duration).
    case segmentDiscarded(reason: String)
}

/// Energy-based speech segmenter with pre-roll ring buffer.
///
/// A pure state machine that processes audio chunks and emits segmentation events
/// based on sustained energy (RMS) above/below a threshold. Maintains a pre-roll buffer
/// (~0.3s) of recent silence to capture the start of speech without clipping.
public final class SpeechSegmenter {
    private let config: SegmenterConfig
    private let sampleRate: Double

    // MARK: - State machine
    private enum State {
        case silence
        case speech
        case awaitingSilence // After max duration exceeded; ignore input until silence resumes
    }

    private var state: State = .silence

    // MARK: - Pre-roll ring buffer
    /// Stores recent silent chunks (approximately 0.3s worth)
    private var preRollBuffer: [Float] = []
    private let preRollDurationSeconds: Double = 0.3
    private var preRollMaxSize: Int { Int(sampleRate * preRollDurationSeconds) }

    /// Maximum trailing silence to include in emitted segment (~0.2s)
    private let trailingTailDurationSeconds: Double = 0.2
    private var trailingTailMaxSize: Int { Int(sampleRate * trailingTailDurationSeconds) }

    // MARK: - Accumulated samples and timing
    /// All samples collected during current speech segment (excluding pre-roll at emission)
    private var accumulatedSpeechSamples: [Float] = []

    /// Trailing silence samples (will be partially included in segment)
    private var trailingModeSilenceSamples: [Float] = []

    /// Total accumulated samples since segment start (for duration tracking)
    private var accumulatedSampleCount: Int = 0

    /// Accumulated samples during silence in speech state (for duration detection only)
    private var accumulatedSilenceSamples: Int = 0

    // MARK: - Initialization
    public init(config: SegmenterConfig, sampleRate: Double = 16_000) {
        self.config = config
        self.sampleRate = sampleRate
    }

    // MARK: - Main processing
    /// Process a single audio chunk with its RMS energy.
    /// - Parameters:
    ///   - chunk: Audio samples (typically 1600 @ 16kHz = 0.1s)
    ///   - rms: Root-mean-square energy of the chunk
    /// - Returns: A SegmenterEvent indicating state changes or segment completion
    public func process(chunk: [Float], rms: Float) -> SegmenterEvent {
        // Empty chunks are treated as silence
        guard !chunk.isEmpty else {
            return .none
        }

        let isSpeech = rms >= config.speechRMSThreshold

        switch state {
        case .silence:
            return processSilenceState(chunk: chunk, isSpeech: isSpeech)

        case .speech:
            return processSpeechState(chunk: chunk, isSpeech: isSpeech)

        case .awaitingSilence:
            return processAwaitingSilenceState(chunk: chunk, isSpeech: isSpeech)
        }
    }

    /// Reset the segmenter to initial state (silence, empty buffers).
    public func reset() {
        state = .silence
        preRollBuffer = []
        accumulatedSpeechSamples = []
        trailingModeSilenceSamples = []
        accumulatedSampleCount = 0
        accumulatedSilenceSamples = 0
    }

    // MARK: - State machine transitions
    private func processSilenceState(chunk: [Float], isSpeech: Bool) -> SegmenterEvent {
        if isSpeech {
            // Silence → Speech transition
            state = .speech
            accumulatedSampleCount = chunk.count  // Count the initial speech chunk
            accumulatedSilenceSamples = 0

            // Start accumulating speech samples (pre-roll will be added at segment end)
            accumulatedSpeechSamples = chunk

            return .speechStarted
        } else {
            // Remain in silence; maintain pre-roll buffer
            updatePreRollBuffer(chunk: chunk)
            return .none
        }
    }

    private func processSpeechState(chunk: [Float], isSpeech: Bool) -> SegmenterEvent {
        // Check if segment exceeds max duration BEFORE adding to samples.
        // Pending trailingModeSilenceSamples count toward the cap ONLY on the
        // speech path: that is when they get flushed into the segment in this
        // same call, so ignoring them would let a near-boundary dip-then-resume
        // push the segment past maxSegmentDuration one chunk before the cap is
        // caught. On the silence path the pending silence never enters the
        // segment (beyond the capped ~0.2s tail at emission), so counting it
        // there would falsely discard any valid utterance longer than
        // (maxSegmentDuration - endSilence) during its normal end-of-utterance
        // silence.
        let pendingFlushCount = isSpeech ? trailingModeSilenceSamples.count : 0
        let projectedSampleCount = accumulatedSampleCount + pendingFlushCount + chunk.count
        let wouldExceedMax = Double(projectedSampleCount) / sampleRate >= config.maxSegmentDuration
        if wouldExceedMax {
            // Max duration exceeded; discard and enter awaitingSilence
            state = .awaitingSilence
            accumulatedSilenceSamples = 0
            accumulatedSpeechSamples = []
            trailingModeSilenceSamples = []
            accumulatedSampleCount = 0
            // Clear pre-roll on discard: the ring may hold speech from the
            // just-discarded monologue rather than genuine silence, so it must
            // not leak into whatever segment starts next. Contrast with
            // resetSegment() below, which intentionally keeps the pre-roll —
            // on a normal segment end the ring already holds real silence and
            // self-heals within ~0.3s regardless.
            preRollBuffer = [] // Clear pre-roll on discard
            return .segmentDiscarded(reason: "máximo")
        }

        if isSpeech {
            // Continue in speech; flush any trailing silence back to speech
            accumulatedSpeechSamples.append(contentsOf: trailingModeSilenceSamples)
            accumulatedSampleCount += trailingModeSilenceSamples.count
            trailingModeSilenceSamples = []
            accumulatedSilenceSamples = 0

            // Add speech chunk
            accumulatedSampleCount += chunk.count
            accumulatedSpeechSamples.append(contentsOf: chunk)
            return .none
        } else {
            // Silence chunk detected during speech
            trailingModeSilenceSamples.append(contentsOf: chunk)
            accumulatedSilenceSamples += chunk.count
            let silenceDurationSeconds = Double(accumulatedSilenceSamples) / sampleRate

            if silenceDurationSeconds >= config.endSilence {
                // Sustained silence reached; emit segment with limited trailing silence
                state = .silence
                let event = emitSegmentWithTrailingLimit()
                accumulatedSilenceSamples = 0
                trailingModeSilenceSamples = []
                return event
            }

            return .none
        }
    }

    private func processAwaitingSilenceState(chunk: [Float], isSpeech: Bool) -> SegmenterEvent {
        if isSpeech {
            // Still speech; keep ignoring
            accumulatedSilenceSamples = 0
            return .none
        } else {
            // Accumulate silence samples
            accumulatedSilenceSamples += chunk.count
            updatePreRollBuffer(chunk: chunk)
            let silenceDurationSeconds = Double(accumulatedSilenceSamples) / sampleRate

            // Check if we've sustained silence long enough to reset
            if silenceDurationSeconds >= config.endSilence {
                state = .silence
                accumulatedSampleCount = 0
                accumulatedSilenceSamples = 0
                return .none
            }

            return .none
        }
    }

    // MARK: - Helper: Pre-roll buffer management
    private func updatePreRollBuffer(chunk: [Float]) {
        preRollBuffer.append(contentsOf: chunk)
        // Keep only the most recent preRollMaxSize samples
        if preRollBuffer.count > preRollMaxSize {
            let excess = preRollBuffer.count - preRollMaxSize
            preRollBuffer.removeFirst(excess)
        }
    }

    // MARK: - Helper: Emit completed segment
    /// Emit segment with trailing silence limited to ~0.2s tail.
    /// Called when sustained silence (>= endSilence) is detected.
    private func emitSegmentWithTrailingLimit() -> SegmenterEvent {
        let speechDurationSeconds = Double(accumulatedSampleCount) / sampleRate

        if speechDurationSeconds < config.minSpeechDuration {
            // Too short; discard
            resetSegment()
            return .segmentDiscarded(reason: "corto")
        }

        // Combine pre-roll + speech + limited trailing silence
        var finalSamples = preRollBuffer
        finalSamples.append(contentsOf: accumulatedSpeechSamples)

        // Include only up to trailingTailMaxSize samples of trailing silence
        let tailToInclude = min(trailingTailMaxSize, trailingModeSilenceSamples.count)
        if tailToInclude > 0 {
            finalSamples.append(contentsOf: trailingModeSilenceSamples.prefix(tailToInclude))
        }

        resetSegment()
        return .segmentEnded(samples: finalSamples)
    }

    private func resetSegment() {
        accumulatedSpeechSamples = []
        trailingModeSilenceSamples = []
        accumulatedSampleCount = 0
        accumulatedSilenceSamples = 0
        // Pre-roll buffer is NOT cleared; it stays for the next utterance.
        // Intentional asymmetry vs. the "máximo" discard path above (which DOES
        // clear it): a normal segment end is preceded by genuine sustained
        // silence, so the ring already holds silence and self-heals within its
        // own ~0.3s window regardless. After a "máximo" discard there was no
        // silence — the ring may still hold speech from the discarded
        // monologue — so it must be cleared there to avoid leaking into the
        // next segment's pre-roll.
    }
}

