import Foundation

/// Configuration for the speech segmenter.
public struct SegmenterConfig: Equatable {
    /// RMS threshold below which audio is considered silence (default: 0.008)
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

    /// When `true`, `SpeechSegmenter` continuously re-estimates the ambient
    /// noise floor from silence-classified chunks and derives the
    /// speech/silence classification cutoff from it (see
    /// `SpeechSegmenter.effectiveThreshold`) instead of treating
    /// `speechRMSThreshold` as a fixed cutoff for the whole session.
    /// `speechRMSThreshold` still matters when this is `true`: it becomes the
    /// INITIAL/floor-seed value used before the floor has learned anything.
    ///
    /// Defaults to `false` — a deliberate, zero-risk choice: every existing
    /// caller (and the 18 pre-existing `SpeechSegmenterTests`) constructs
    /// `SegmenterConfig` with no knowledge that this flag exists, and their
    /// synthetic RMS patterns were written against a fixed threshold. Rather
    /// than risk quietly changing their classification outcomes, adaptive
    /// behavior is strictly opt-in; `WakeListener` is the one caller that
    /// turns it on explicitly, because field data showed the fixed threshold
    /// failing there specifically (loud rooms pin every chunk above
    /// threshold forever; quiet rooms fragment real speech below it).
    public let adaptiveThreshold: Bool

    /// Initialize with custom or default values.
    public init(
        speechRMSThreshold: Float = 0.008,
        endSilence: TimeInterval = 0.7,
        minSpeechDuration: TimeInterval = 0.4,
        maxSegmentDuration: TimeInterval = 30.0,
        adaptiveThreshold: Bool = false
    ) {
        self.speechRMSThreshold = speechRMSThreshold
        self.endSilence = endSilence
        self.minSpeechDuration = minSpeechDuration
        self.maxSegmentDuration = maxSegmentDuration
        self.adaptiveThreshold = adaptiveThreshold
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

    // MARK: - Adaptive noise floor (see `SegmenterConfig.adaptiveThreshold`)
    //
    // Design summary: the noise floor is an EMA of chunk RMS, updated only on
    // chunks NOT in `.speech` state (mid-utterance dips are pauses, not
    // ambient noise, and must not move the floor — see `updateNoiseFloor`).
    // The one wrinkle is the "stuck loud room" case: if ambient noise is
    // already above the seeded threshold, every chunk classifies as speech
    // forever, `.speech` perpetually hits `maxSegmentDuration` and discards
    // into `.awaitingSilence` — but chunks there STILL classify as speech
    // relative to the frozen threshold, so the segmenter can never observe a
    // silence-classified chunk to teach the floor the room's real level.
    // The chosen escape mechanism (single, clean rule): while in
    // `.awaitingSilence`, update the floor unconditionally — using the normal
    // alpha for chunks that already read as silence, and a slower "unstick"
    // alpha for chunks that still read as speech. That slower nudge is what
    // guarantees convergence in the loud-room case (see
    // `AdaptiveNoiseFloorTests.testLoudRoomConvergesToAboveAmbientWithinBound`
    // for the worked numbers and a synthetic regression test).

    /// EMA smoothing factor for silence-classified chunks (`.silence`, or
    /// `.awaitingSilence` chunks that already read below the current
    /// threshold). Small on purpose: the floor should track slow ambient
    /// drift, not jitter on every quiet chunk.
    private static let noiseFloorAlpha: Float = 0.05

    /// EMA smoothing factor for the `.awaitingSilence` "unstick" path: chunks
    /// that still read ABOVE the current effective threshold while the
    /// segmenter is waiting out a max-duration discard. Deliberately slower
    /// than `noiseFloorAlpha` — it must not let a single loud moment swing
    /// the floor, only grind it upward over repeated chunks until a
    /// persistently loud room's ambient level is finally recognized as "the
    /// new silence".
    private static let noiseFloorAlphaUnstick: Float = 0.01

    /// Multiplier from noise floor to classification threshold: keeps the
    /// cutoff comfortably above ambient noise (so normal room tone never
    /// misclassifies as speech) while staying low enough that real speech —
    /// typically several multiples of ambient RMS — still crosses it.
    private static let noiseFloorMultiplier: Float = 3.5

    /// Absolute floor on the effective threshold: even a dead-silent room
    /// (noise floor near zero) must not classify near-zero-RMS noise/whispers
    /// as speech by dropping the cutoff too low.
    private static let effectiveThresholdMin: Float = 0.004

    /// Absolute ceiling on the effective threshold: bounds how loud
    /// "silence" can be considered, so a pathological input can't push the
    /// segmenter into treating literally everything as noise forever.
    private static let effectiveThresholdMax: Float = 0.06

    private var noiseFloor: Float
    private var noiseFloorSeeded = false

    /// Effective speech/silence classification cutoff. Equal to
    /// `config.speechRMSThreshold` when `config.adaptiveThreshold` is
    /// `false` (or before the floor has been seeded); otherwise
    /// `clamp(noiseFloor * noiseFloorMultiplier, effectiveThresholdMin,
    /// effectiveThresholdMax)`. Exposed for observability (calibration
    /// logging in `WakeListener`).
    public private(set) var effectiveThreshold: Float

    // MARK: - Initialization
    public init(config: SegmenterConfig, sampleRate: Double = 16_000) {
        self.config = config
        self.sampleRate = sampleRate
        self.effectiveThreshold = config.speechRMSThreshold
        self.noiseFloor = config.speechRMSThreshold / Self.noiseFloorMultiplier
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

        let classificationThreshold = config.adaptiveThreshold ? effectiveThreshold : config.speechRMSThreshold
        let isSpeech = rms >= classificationThreshold
        // Captured BEFORE this chunk's state transition: floor updates gate
        // on the state the segmenter was in WHILE this chunk was observed,
        // not whatever it transitions to as a result of processing it.
        let stateDuringClassification = state

        let event: SegmenterEvent
        switch state {
        case .silence:
            event = processSilenceState(chunk: chunk, isSpeech: isSpeech)

        case .speech:
            event = processSpeechState(chunk: chunk, isSpeech: isSpeech)

        case .awaitingSilence:
            event = processAwaitingSilenceState(chunk: chunk, isSpeech: isSpeech)
        }

        if config.adaptiveThreshold {
            updateNoiseFloor(rms: rms, isSpeech: isSpeech, state: stateDuringClassification)
        }

        return event
    }

    /// Reset the segmenter to initial state (silence, empty buffers, and the
    /// adaptive noise floor back to its initial floor-seed value).
    public func reset() {
        state = .silence
        preRollBuffer = []
        accumulatedSpeechSamples = []
        trailingModeSilenceSamples = []
        accumulatedSampleCount = 0
        accumulatedSilenceSamples = 0
        noiseFloor = config.speechRMSThreshold / Self.noiseFloorMultiplier
        noiseFloorSeeded = false
        effectiveThreshold = config.speechRMSThreshold
    }

    // MARK: - Helper: Adaptive noise floor
    /// Update the noise floor EMA and recompute `effectiveThreshold`.
    /// - Parameters:
    ///   - rms: RMS of the chunk just classified.
    ///   - isSpeech: The classification result for that chunk.
    ///   - state: The segmenter's state WHILE that chunk was classified
    ///     (i.e. before this chunk's own transition).
    private func updateNoiseFloor(rms: Float, isSpeech: Bool, state: State) {
        guard noiseFloorSeeded else {
            // Seed with the first silence chunk's RMS; if the very first
            // chunk ever observed is speech, seed with the configured
            // threshold/multiplier instead so effectiveThreshold has a
            // sane, immediately-consistent starting point
            // (seed * multiplier == speechRMSThreshold).
            noiseFloor = isSpeech ? (config.speechRMSThreshold / Self.noiseFloorMultiplier) : rms
            noiseFloorSeeded = true
            recomputeEffectiveThreshold()
            return
        }

        switch state {
        case .speech:
            // Frozen: mid-utterance dips are pauses, not ambient noise, and
            // prolonged speech must never inflate the floor.
            return

        case .silence:
            guard !isSpeech else { return }
            noiseFloor = noiseFloor * (1 - Self.noiseFloorAlpha) + rms * Self.noiseFloorAlpha

        case .awaitingSilence:
            // See the class-level doc comment above `noiseFloorAlphaUnstick`:
            // this branch is what guarantees convergence in a loud room where
            // every chunk would otherwise read as speech forever.
            let alpha = isSpeech ? Self.noiseFloorAlphaUnstick : Self.noiseFloorAlpha
            noiseFloor = noiseFloor * (1 - alpha) + rms * alpha
        }

        recomputeEffectiveThreshold()
    }

    private func recomputeEffectiveThreshold() {
        let raw = noiseFloor * Self.noiseFloorMultiplier
        effectiveThreshold = min(max(raw, Self.effectiveThresholdMin), Self.effectiveThresholdMax)
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

