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

    /// Sliding window of recent per-chunk RMS observed WHILE in `.speech`
    /// state (adaptive mode only), used by relative-drop end detection (see
    /// `endDropRatio` / `windowedPeakRMS`). Each entry is `(rms, sampleCount)`;
    /// the window is bounded to the most recent `peakWindowSeconds` of speech
    /// by sample count, so a single loud transient's influence on the peak
    /// EXPIRES after that window instead of persisting for the whole
    /// utterance. Reset (and re-seeded with the triggering chunk) at every
    /// silence→speech transition, and cleared whenever a segment ends, is
    /// discarded, or is flushed.
    ///
    /// Was originally an unbounded running max, which caused a regression: a
    /// single loud transient (an emphasized word, a door slam) permanently
    /// raised the relative end bar (`peak * endDropRatio`), so subsequent
    /// normal speech classified as silence and the segment ended
    /// mid-sentence — reproduced even in a quiet room.
    private var speechRMSWindow: [(rms: Float, sampleCount: Int)] = []
    /// Running total of `sampleCount` across `speechRMSWindow`, kept in sync
    /// so eviction doesn't have to re-sum the window each chunk.
    private var speechRMSWindowSampleCount: Int = 0

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
    ///
    /// Lowered from 3.5 to 2.5 (soft-speaker headroom): field evidence
    /// showed dictations captured at only 1.3-1.6s for obviously longer
    /// sentences, with the effective threshold (0.0143) sitting only ~1.6x
    /// below observed speech peaks (0.0215-0.0244). At 3.5x, quieter
    /// speakers' word endings and unstressed syllables routinely fell below
    /// the cutoff, got classified as silence, and armed `endSilence` mid-
    /// sentence. 2.5x keeps the same ambient-noise rejection margin (still
    /// comfortably above room tone) while giving soft speech more headroom
    /// to clear the entry threshold. See also `exitThresholdRatio` below,
    /// which addresses the complementary half of the same bug (soft speech
    /// dipping below threshold mid-utterance, once already speaking).
    private static let noiseFloorMultiplier: Float = 2.5

    /// Hysteresis ratio (adaptive mode only): once a chunk has already been
    /// classified as speech (`state == .speech`), subsequent chunks only
    /// need to clear `effectiveThreshold * exitThresholdRatio` — a lower bar
    /// than the entry threshold — to still count as speech. This is the
    /// classic enter/exit hysteresis fix for the soft-speech truncation bug:
    /// word endings and unstressed syllables commonly dip 30-50% below the
    /// entry threshold while remaining continuous speech. Without
    /// hysteresis, each such dip gets classified as silence and starts
    /// arming the `endSilence` countdown, which can expire DURING a quiet
    /// portion of an ongoing sentence and cut it off mid-utterance. With
    /// hysteresis, only audio that drops below the (lower) exit threshold —
    /// i.e. genuinely quiet, not just a soft syllable — starts that clock.
    ///
    /// Deliberately scoped to adaptive mode only: fixed mode's single-
    /// threshold classification is exercised by the 18 legacy
    /// `SpeechSegmenterTests`, which encode that exact semantics and must
    /// not change.
    private static let exitThresholdRatio: Float = 0.55

    /// Relative end-of-speech drop ratio (adaptive mode only): once a speech
    /// segment is under way, the bar to REMAIN classified as speech is
    /// `max(exitThreshold, windowedPeakRMS * endDropRatio)` — i.e. well below
    /// this utterance's own RECENT peak volume, not just below some absolute
    /// noise floor. This is the fix for the field bug where absolute-energy
    /// end-of-speech detection fails entirely in a noisy room: ambient RMS
    /// (e.g. 0.045) can sit permanently above even the (already-lowered)
    /// exit threshold (e.g. 0.0022), so the segment never classifies as
    /// silence and never ends at all — see the field log ("pico RMS últimos
    /// 10s: 0.0453 (umbral 0.0040 / salida 0.0022)" followed by a partial
    /// window forcibly stopped with nothing processed). Tracking the
    /// segment's own peak sidesteps that: a user's voice dropping to 35% of
    /// its own recent loudest moment mid-utterance is a reliable "I stopped
    /// talking" signal regardless of how loud the room is — as long as the
    /// room noise itself isn't as loud as the speech (see the HONEST LIMIT
    /// below). `max()` with `exitThreshold` keeps quiet-room legacy behavior
    /// intact: there `windowedPeakRMS * endDropRatio` is typically BELOW the
    /// absolute exit threshold, so the absolute check still governs and
    /// normal speech still ends the same way it always did.
    ///
    /// The peak is WINDOWED (see `speechRMSWindow` / `peakWindowSeconds`), not
    /// an unbounded running max: otherwise a single loud transient would raise
    /// the bar permanently and truncate the rest of the utterance.
    ///
    /// HONEST LIMIT (documented, not silently glossed over): if ambient
    /// noise is close to, or louder than, the user's own speech level, there
    /// is no meaningful relative drop to detect — energy-based VAD
    /// fundamentally cannot find end-of-speech in that regime, relative or
    /// absolute. That case needs a neural VAD (e.g. Silero), tracked as
    /// backlog. This fix handles the much more common "moderate noise +
    /// clearly audible voice over it" case, not extreme noise where speech
    /// and ambient are comparably loud. `WakeListener.stopAndFlush()`
    /// provides a manual escape hatch (flush in-progress audio on
    /// intentional stop) for whatever this can't detect automatically.
    private static let endDropRatio: Float = 0.35

    /// Duration of the sliding peak window (adaptive mode only) that backs
    /// relative-drop end detection (see `speechRMSWindow` / `endDropRatio`):
    /// the relative end bar is derived from the max RMS over the last
    /// ~`peakWindowSeconds` of speech, so a loud transient stops inflating the
    /// bar once it ages past this window. Chosen so normal continued speech
    /// survives a transient — after a transient ages out, the bar falls back
    /// to `recentNormalRMS * endDropRatio`, well under normal speech.
    private static let peakWindowSeconds: Double = 2.0

    /// Absolute floor on the effective threshold: even a dead-silent room
    /// (noise floor near zero) must not classify near-zero-RMS noise/whispers
    /// as speech by dropping the cutoff too low.
    private static let effectiveThresholdMin: Float = 0.004

    /// Absolute ceiling on the effective threshold: bounds how loud
    /// "silence" can be considered, so a pathological input can't push the
    /// segmenter into treating literally everything as noise forever.
    private static let effectiveThresholdMax: Float = 0.06

    private var noiseFloorEstimate: Float
    private var noiseFloorSeeded = false

    /// The learned ambient noise floor, or `nil` when there is nothing
    /// meaningful to carry over (adaptive mode off, or the floor hasn't
    /// been seeded by any chunk / external seed yet). Exposed so a caller
    /// that REPLACES its segmenter instance on regime transitions (as
    /// `WakeListener` does on arm/disarm/cancel/start) can thread the
    /// learned floor into the replacement via `init(seedNoiseFloor:)` —
    /// otherwise the floor dies with each instance and a loud room
    /// re-deadlocks the fresh segmenter until it re-converges from scratch.
    public var noiseFloor: Float? {
        (config.adaptiveThreshold && noiseFloorSeeded) ? noiseFloorEstimate : nil
    }

    /// Effective speech/silence classification cutoff. Equal to
    /// `config.speechRMSThreshold` when `config.adaptiveThreshold` is
    /// `false` (or before the floor has been seeded); otherwise
    /// `clamp(noiseFloor * noiseFloorMultiplier, effectiveThresholdMin,
    /// effectiveThresholdMax)`. Exposed for observability (calibration
    /// logging in `WakeListener`).
    public private(set) var effectiveThreshold: Float

    /// Hysteresis exit threshold used while ALREADY in `.speech` state
    /// (adaptive mode only): `effectiveThreshold * exitThresholdRatio`, i.e.
    /// a lower bar than the entry threshold so soft trailing speech doesn't
    /// get misclassified as silence mid-utterance. See `exitThresholdRatio`
    /// for the full rationale. Exposed for observability alongside
    /// `effectiveThreshold` (calibration logging in `WakeListener`).
    public var exitThreshold: Float {
        effectiveThreshold * Self.exitThresholdRatio
    }

    // MARK: - Initialization
    /// - Parameters:
    ///   - seedNoiseFloor: Optional noise floor learned by a PREVIOUS
    ///     segmenter instance (see `noiseFloor`). When provided and
    ///     `config.adaptiveThreshold` is on, the floor starts at this value
    ///     already seeded — the next silence chunk EMAs from it instead of
    ///     replacing it — and `effectiveThreshold` is derived from it
    ///     immediately (clamped as usual). Ignored when adaptive mode is
    ///     off.
    public init(config: SegmenterConfig, sampleRate: Double = 16_000, seedNoiseFloor: Float? = nil) {
        self.config = config
        self.sampleRate = sampleRate
        if config.adaptiveThreshold, let seedNoiseFloor {
            self.noiseFloorEstimate = seedNoiseFloor
            self.noiseFloorSeeded = true
            let raw = seedNoiseFloor * Self.noiseFloorMultiplier
            self.effectiveThreshold = min(max(raw, Self.effectiveThresholdMin), Self.effectiveThresholdMax)
        } else {
            self.effectiveThreshold = config.speechRMSThreshold
            self.noiseFloorEstimate = config.speechRMSThreshold / Self.noiseFloorMultiplier
        }
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

        // Hysteresis (adaptive mode only, see `exitThresholdRatio`): once
        // already classified as `.speech`, a chunk only needs to clear the
        // lower exit threshold to remain speech; entering speech from
        // `.silence`/`.awaitingSilence` still requires the full entry
        // threshold. Fixed mode keeps the legacy single-threshold check
        // untouched — the 18 `SpeechSegmenterTests` encode that semantics.
        let classificationThreshold: Float
        if config.adaptiveThreshold {
            if case .speech = state {
                // Relative-drop end detection (see `endDropRatio` doc): the
                // bar to REMAIN classified as speech is whichever is higher
                // of the absolute exit threshold and a fraction of this
                // utterance's RECENT peak. `windowedPeakRMS` reflects the
                // window BEFORE this chunk (appended below, after
                // classification), so this is never self-referential.
                classificationThreshold = max(exitThreshold, windowedPeakRMS * Self.endDropRatio)
            } else {
                classificationThreshold = effectiveThreshold
            }
        } else {
            classificationThreshold = config.speechRMSThreshold
        }
        let isSpeech = rms >= classificationThreshold
        // Advance the sliding peak window with THIS chunk once classification
        // is decided (never from the classification itself — see comment
        // above). Every chunk observed while in `.speech` is appended
        // (regardless of its own speech/silence classification) so the window
        // ages by elapsed time, letting a loud transient's influence expire.
        // Adaptive-mode-only: fixed mode never reads the window. The entry
        // chunk's window is seeded separately below once `.speechStarted` is
        // known.
        if config.adaptiveThreshold, case .speech = state {
            appendToSpeechWindow(rms: rms, sampleCount: chunk.count)
        }
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

        // Seed the new segment's peak window with the triggering chunk's RMS.
        // Only `processSilenceState` can produce `.speechStarted`, so this
        // only ever fires on a genuine silence→speech transition.
        // Adaptive-mode-only: fixed mode never reads the window.
        if config.adaptiveThreshold, event == .speechStarted {
            resetSpeechWindow()
            appendToSpeechWindow(rms: rms, sampleCount: chunk.count)
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
        resetSpeechWindow()
        noiseFloorEstimate = config.speechRMSThreshold / Self.noiseFloorMultiplier
        noiseFloorSeeded = false
        effectiveThreshold = config.speechRMSThreshold
    }

    // MARK: - Helper: Sliding peak window (relative-drop end detection)
    /// Max RMS over the current sliding window (see `speechRMSWindow`); `0`
    /// when the window is empty. This is the "recent peak" the relative end
    /// bar is derived from.
    private var windowedPeakRMS: Float {
        speechRMSWindow.reduce(Float(0)) { max($0, $1.rms) }
    }

    private var peakWindowMaxSamples: Int { Int(sampleRate * Self.peakWindowSeconds) }

    /// Append a chunk's RMS to the sliding window and evict the oldest entries
    /// while the window exceeds `peakWindowSeconds` — always keeping at least
    /// the most recent entry so `windowedPeakRMS` never goes empty
    /// mid-utterance.
    private func appendToSpeechWindow(rms: Float, sampleCount: Int) {
        speechRMSWindow.append((rms, sampleCount))
        speechRMSWindowSampleCount += sampleCount
        while speechRMSWindowSampleCount > peakWindowMaxSamples, speechRMSWindow.count > 1 {
            let removed = speechRMSWindow.removeFirst()
            speechRMSWindowSampleCount -= removed.sampleCount
        }
    }

    private func resetSpeechWindow() {
        speechRMSWindow = []
        speechRMSWindowSampleCount = 0
    }

    /// Flush the in-progress speech segment (if any) and reset segmenter
    /// state, WITHOUT waiting for silence. Used for an intentional
    /// user-initiated stop (e.g. toggling hands-free off mid-utterance — see
    /// `WakeListener.stopAndFlush()`) so audio already spoken is not
    /// silently discarded just because end-of-speech was never detected.
    /// This is the manual escape hatch for exactly the case relative-drop
    /// end detection cannot always cover — see the HONEST LIMIT on
    /// `endDropRatio`.
    /// - Returns: pre-roll + accumulated speech samples (plus a capped
    ///   trailing-silence tail, same allowance as a normal segment end) if a
    ///   segment was in progress and had already reached `minSpeechDuration`;
    ///   otherwise `nil` (nothing in progress, or too short to count as a
    ///   real utterance). Either way, segment state is reset — the next
    ///   `process()` call starts fresh from `.silence`.
    public func flush() -> [Float]? {
        guard case .speech = state else {
            // Nothing "in progress" to flush: `.silence` has no accumulated
            // speech, and `.awaitingSilence` holds an already-discarded
            // ("máximo") segment, not one still in progress.
            return nil
        }

        let speechDurationSeconds = Double(accumulatedSampleCount) / sampleRate
        guard speechDurationSeconds >= config.minSpeechDuration else {
            state = .silence
            resetSegment()
            return nil
        }

        var finalSamples = preRollBuffer
        finalSamples.append(contentsOf: accumulatedSpeechSamples)
        let tailToInclude = min(trailingTailMaxSize, trailingModeSilenceSamples.count)
        if tailToInclude > 0 {
            finalSamples.append(contentsOf: trailingModeSilenceSamples.prefix(tailToInclude))
        }

        state = .silence
        resetSegment()
        return finalSamples
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
            noiseFloorEstimate = isSpeech ? (config.speechRMSThreshold / Self.noiseFloorMultiplier) : rms
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
            noiseFloorEstimate = noiseFloorEstimate * (1 - Self.noiseFloorAlpha) + rms * Self.noiseFloorAlpha

        case .awaitingSilence:
            // See the class-level doc comment above `noiseFloorAlphaUnstick`:
            // this branch is what guarantees convergence in a loud room where
            // every chunk would otherwise read as speech forever.
            let alpha = isSpeech ? Self.noiseFloorAlphaUnstick : Self.noiseFloorAlpha
            noiseFloorEstimate = noiseFloorEstimate * (1 - alpha) + rms * alpha
        }

        recomputeEffectiveThreshold()
    }

    private func recomputeEffectiveThreshold() {
        let raw = noiseFloorEstimate * Self.noiseFloorMultiplier
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
            resetSpeechWindow()
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
        resetSpeechWindow()
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

