import XCTest
@testable import KikiCore

// MARK: - Mocks

final class MockRecorder: AudioRecording {
    var started = false
    var stopCalled = false
    var samplesToReturn: [Float] = Array(repeating: 0.1, count: 16_000) // 1 s
    var startError: Error?

    func start() throws {
        if let startError { throw startError }
        started = true
    }

    func stop() -> [Float] {
        stopCalled = true
        return samplesToReturn
    }
}

final class MockTranscriber: Transcribing {
    var textToReturn = "hello world"
    var errorToThrow: Error?
    var receivedSamples: [Float] = []

    func transcribe(_ samples: [Float]) async throws -> String {
        receivedSamples = samples
        if let errorToThrow { throw errorToThrow }
        return textToReturn
    }
}

final class MockInserter: TextInserting {
    var inserted: [String] = []
    var errorToThrow: Error?

    func insert(_ text: String) throws {
        if let errorToThrow { throw errorToThrow }
        inserted.append(text)
    }
}

final class MockContext: ContextProviding {
    var profileToReturn: AppProfile = .neutral
    var receivedCallCount = 0

    func currentProfile() -> AppProfile {
        receivedCallCount += 1
        return profileToReturn
    }
}

final class MockRefiner: Refining {
    var textToReturn: String?
    var errorToThrow: Error?
    var receivedTexts: [String] = []
    var receivedProfiles: [AppProfile] = []
    var receivedLanguages: [String] = []
    var receivedTranslateFlags: [Bool] = []
    var delaySeconds: TimeInterval = 0

    func refine(_ text: String, profile: AppProfile, language: String = "es", translate: Bool = false) async throws -> String {
        receivedTexts.append(text)
        receivedProfiles.append(profile)
        receivedLanguages.append(language)
        receivedTranslateFlags.append(translate)
        if delaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        if let errorToThrow { throw errorToThrow }
        guard let textToReturn else {
            throw DictationError.transcriptionFailed("MockRefiner: no text to return")
        }
        return textToReturn
    }
}

/// Mock de `LanguageDetecting` (Fase: fidelidad de idioma). Simula el idioma
/// que `WhisperTranscriber` habría detectado para la última transcripción.
final class MockLanguageProvider: LanguageDetecting {
    var languageToReturn = "es"

    func detectedLanguage() async -> String {
        languageToReturn
    }
}

@MainActor
final class SpyDelegate: DictationControllerDelegate {
    var states: [DictationState] = []
    var errors: [DictationError] = []
    var insertCount = 0
    var insertedText: String?
    var livePartials: [String?] = []
    /// Combined chronological log (Fix 2 bubble-contract regression test):
    /// interleaves insert/live-partial events in call order, so a test can
    /// assert the partial-clear (nil) fires AFTER insertion instead of just
    /// checking each array independently (which can't express relative order).
    var events: [String] = []

    func dictationStateDidChange(_ state: DictationState) { states.append(state) }
    func dictationDidFail(_ error: DictationError) { errors.append(error) }
    func dictationDidInsert(_ text: String) {
        insertCount += 1
        events.append("insert")
        insertedText = text
    }
    func dictationLivePartialDidChange(_ text: String?) {
        livePartials.append(text)
        events.append(text.map { "livePartial:\($0)" } ?? "livePartial:nil")
    }
}

final class MockSnippets: SnippetExpanding {
    var matchesToReturn: [String: String] = [:] // trigger -> template
    var expandInvocations: [String] = []

    func expand(_ text: String) -> String? {
        expandInvocations.append(text)
        return matchesToReturn[text]
    }
}

final class MockHistory: HistoryRecording {
    var recordings: [HistoryRecord] = []

    func record(_ entry: HistoryRecord) {
        recordings.append(entry)
    }
}

// MARK: - Tests

@MainActor
final class DictationControllerTests: XCTestCase {
    private var recorder: MockRecorder!
    private var transcriber: MockTranscriber!
    private var inserter: MockInserter!
    private var delegate: SpyDelegate!
    private var controller: DictationController!

    override func setUp() async throws {
        recorder = MockRecorder()
        transcriber = MockTranscriber()
        inserter = MockInserter()
        delegate = SpyDelegate()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter)
        controller.delegate = delegate
    }

    func test_pressStartsRecording() {
        controller.hotkeyPressed()
        XCTAssertTrue(recorder.started)
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(delegate.states, [.recording])
    }

    func test_releaseTranscribesInsertsAndReturnsToIdle() async {
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.states, [.recording, .processing, .idle])
        XCTAssertEqual(transcriber.receivedSamples.count, 16_000)
    }

    func test_shortTapIsCancelledWithoutTranscribing() async {
        recorder.samplesToReturn = Array(repeating: 0.1, count: 1_000) // < 0.3 s * 16 kHz
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(delegate.errors.isEmpty)
    }

    func test_emptyTranscriptionInsertsNothing() async {
        transcriber.textToReturn = "  \n "
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(controller.state, .idle)
    }

    func test_transcriptionResultIsTrimmed() async {
        transcriber.textToReturn = "  hola mundo \n"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertEqual(inserter.inserted, ["hola mundo"])
    }

    func test_recorderStartFailureReportsErrorAndStaysIdle() {
        recorder.startError = NSError(domain: "test", code: 1)
        controller.hotkeyPressed()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.errors.count, 1)
        guard case .audioUnavailable = delegate.errors.first else {
            return XCTFail("expected .audioUnavailable, got \(String(describing: delegate.errors.first))")
        }
    }

    func test_transcriberErrorReturnsToIdleAndReports() async {
        transcriber.errorToThrow = NSError(domain: "test", code: 2)
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.errors.count, 1)
        guard case .transcriptionFailed = delegate.errors.first else {
            return XCTFail("expected .transcriptionFailed, got \(String(describing: delegate.errors.first))")
        }
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    func test_inserterErrorReturnsToIdleAndReports() async {
        inserter.errorToThrow = DictationError.insertionFailed("no pudo pegar")
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.errors, [.insertionFailed("no pudo pegar")])
    }

    func test_pressWhileRecordingIsIgnored() {
        controller.hotkeyPressed()
        controller.hotkeyPressed()
        XCTAssertEqual(delegate.states, [.recording])
    }

    func test_releaseWhileIdleIsIgnored() async {
        await controller.hotkeyReleased()
        XCTAssertFalse(recorder.stopCalled)
        XCTAssertTrue(delegate.states.isEmpty)
    }

    func test_cancelWhileRecordingReturnsToIdleWithoutInserting() {
        controller.hotkeyPressed()
        controller.cancel()
        XCTAssertTrue(recorder.stopCalled)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(inserter.inserted.isEmpty)
    }

    // MARK: - Refinement Tests (Phase 2)

    func test_refinerOutputIsInserted() async {
        let refiner = MockRefiner()
        // Salida fiel (misma vocabulario, solo puntuación/mayúscula) — no debe
        // disparar la guardia de fidelidad de RefineFidelity.
        refiner.textToReturn = "Hello world."
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "hello world"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["Hello world."])
    }

    func test_refinerReceivesProfileFromContext() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "refined"
        let context = MockContext()
        context.profileToReturn = .code
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "raw text"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(refiner.receivedProfiles, [.code])
    }

    func test_nilContextUsesNeutralProfile() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "refined"
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: nil, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "raw text"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(refiner.receivedProfiles, [.neutral])
    }

    func test_refinerErrorFallsBackToRawText() async {
        let refiner = MockRefiner()
        refiner.errorToThrow = NSError(domain: "test", code: 99)
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "crudo"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["crudo"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(delegate.errors.isEmpty) // No dictationDidFail call
    }

    func test_refinerTimeoutFallsBackToRawText() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "refined"
        refiner.delaySeconds = 0.2 // Will exceed 0.1s timeout
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, refineTimeout: 0.1, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "crudo"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["crudo"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(delegate.errors.isEmpty)
    }

    func test_emptyRefinerOutputFallsBackToRawText() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "   \n  " // Empty after trimming
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "crudo"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["crudo"])
        XCTAssertEqual(controller.state, .idle)
    }

    func test_suspiciouslyLongRefinerOutputFallsBackToRawText() async {
        let refiner = MockRefiner()
        // trimmedRefined.count > text.count * 2 + 40 must trigger the guard.
        // "crudo" has 5 chars, so the threshold is 5*2+40 = 50; return
        // something comfortably past that (way more than 2x+40) to simulate
        // a runaway/prompt-injected generation.
        refiner.textToReturn = String(repeating: "x", count: 500)
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "crudo"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["crudo"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(delegate.errors.isEmpty)
    }

    func test_suspiciouslyShortRefinerOutputFallsBackToRawText() async {
        let refiner = MockRefiner()
        // trimmedRefined.count < text.count / 3 must trigger the guard.
        // A 60-char raw input has threshold 60/3 = 20; "ok." (3 chars) is
        // far below that, simulating a degenerate reply (e.g. the LLM
        // answered the dictation instead of rewriting it).
        let raw = String(repeating: "a", count: 60)
        refiner.textToReturn = "ok."
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = raw
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, [raw])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(delegate.errors.isEmpty)
    }

    func test_withoutRefinerBehavesAsPhase1() async {
        controller.hotkeyPressed()
        await controller.hotkeyReleased()
        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.states, [.recording, .processing, .idle])
    }

    // MARK: - Direct Process Tests

    func test_processSamplesRunsFullPipeline() async {
        let validSamples: [Float] = Array(repeating: 0.1, count: 16_000) // 1 s >= minimumSamples
        transcriber.textToReturn = "hello world"

        await controller.process(samples: validSamples)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertTrue(delegate.states.contains(.processing))
        XCTAssertEqual(transcriber.receivedSamples.count, 16_000)
    }

    func test_processSamplesRespectsMinimumDuration() async {
        let shortSamples: [Float] = Array(repeating: 0.1, count: 1_000) // < 0.3 s * 16 kHz
        transcriber.textToReturn = "hello world"

        await controller.process(samples: shortSamples)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertTrue(transcriber.receivedSamples.isEmpty)
        XCTAssertTrue(delegate.states.isEmpty)
    }

    func test_processTranscriptRefinesAndInserts() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "Hello world."
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0)
        controller.delegate = delegate

        await controller.processTranscript("hello world")

        XCTAssertEqual(inserter.inserted, ["Hello world."])
        XCTAssertEqual(refiner.receivedTexts, ["hello world"])
        XCTAssertTrue(delegate.states.contains(.processing))
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: - processTranscript bypassEnhancement (F1 Task 5: wake same-breath
    // + live mode ON must also skip refine/translate, mirroring processLive)

    func test_processTranscriptBypassEnhancementSkipsRefiner() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "should never be used"
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            translateEnabled: { true }, refineEnabled: { true })
        controller.delegate = delegate

        await controller.processTranscript("hello world", bypassEnhancement: true)

        XCTAssertEqual(inserter.inserted, ["hello world"])
        XCTAssertTrue(refiner.receivedTexts.isEmpty, "bypassEnhancement must skip refine/translate even when both toggles are on")
        XCTAssertEqual(controller.state, .idle)
    }

    func test_processTranscriptDefaultStillRefines() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "Hello world."
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0)
        controller.delegate = delegate

        await controller.processTranscript("hello world")

        XCTAssertEqual(inserter.inserted, ["Hello world."], "omitting bypassEnhancement must preserve existing refine behavior")
        XCTAssertEqual(refiner.receivedTexts, ["hello world"])
    }

    func test_processTranscriptEmptyIsNoop() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "texto pulido."
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0)
        controller.delegate = delegate

        let statesBefore = delegate.states.count
        await controller.processTranscript("   \n  ")

        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertTrue(refiner.receivedTexts.isEmpty)
        // Empty transcript should not trigger transitions (stays at initial count)
        XCTAssertEqual(delegate.states.count, statesBefore)
        XCTAssertEqual(controller.state, .idle)
    }

    func test_processWhileBusyIsIgnored() async {
        let validSamples: [Float] = Array(repeating: 0.1, count: 16_000)
        transcriber.textToReturn = "hello world"

        // Simulate busy state by starting recording
        controller.hotkeyPressed()
        let statesAfterPress = delegate.states.count

        // Call process while in a non-idle state (.recording)
        await controller.process(samples: validSamples)

        // Should ignore the process call (no new state transitions beyond what happened)
        XCTAssertEqual(controller.state, .recording)
        XCTAssertTrue(inserter.inserted.isEmpty)
        // Only the initial .recording state should have been captured
        XCTAssertEqual(delegate.states.count, statesAfterPress)
        XCTAssertTrue(delegate.errors.isEmpty)
    }

    // MARK: - Insertion Delegate Hook (Fase 3.6, task-361: cue de sonido "inserted")

    func test_dictationDidInsertFiresOnInsert() async {
        transcriber.textToReturn = "hello world"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(delegate.insertCount, 1)
    }

    func test_dictationDidInsertDoesNotFireOnInsertionFailure() async {
        inserter.errorToThrow = DictationError.insertionFailed("no pudo pegar")
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(delegate.insertCount, 0)
    }

    // MARK: - Snippet + History Tests (Phase 3)

    func test_snippetMatchInsertsTemplateAndSkipsLLM() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "refined output"
        let snippets = MockSnippets()
        snippets.matchesToReturn = ["hello": "Hello,\n\nHow can I help you?"]
        let context = MockContext()

        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context,
            snippets: snippets, history: nil)
        controller.delegate = delegate

        transcriber.textToReturn = "hello"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        // Template should be inserted, not refined output
        XCTAssertEqual(inserter.inserted, ["Hello,\n\nHow can I help you?"])
        // Refiner should not have been called
        XCTAssertTrue(refiner.receivedTexts.isEmpty)
        // Snippet expansion should have been called
        XCTAssertEqual(snippets.expandInvocations, ["hello"])
        XCTAssertEqual(controller.state, .idle)
    }

    func test_snippetMissFollowsNormalFlow() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "World."
        let snippets = MockSnippets()
        snippets.matchesToReturn = ["hello": "template"] // no match for "world"
        let context = MockContext()

        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context,
            snippets: snippets, history: nil, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "world"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        // Should follow normal refined flow
        XCTAssertEqual(inserter.inserted, ["World."])
        // Refiner should have been called
        XCTAssertEqual(refiner.receivedTexts, ["world"])
        // Snippet expansion should have been called
        XCTAssertEqual(snippets.expandInvocations, ["world"])
        XCTAssertEqual(controller.state, .idle)
    }

    func test_historyRecordsRawAndFinal() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "refined text"
        let context = MockContext()
        context.profileToReturn = .code
        let history = MockHistory()

        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context,
            snippets: nil, history: history, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "raw text"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(history.recordings.count, 1)
        let record = history.recordings[0]
        XCTAssertEqual(record.rawText, "raw text")
        XCTAssertEqual(record.finalText, "refined text")
        XCTAssertEqual(record.profile, .code)
        XCTAssertEqual(record.audioSeconds, 1.0) // 16_000 samples / 16_000 sampleRate
    }

    func test_historyRecordsFallbackAsRawEqualsFinal() async {
        let refiner = MockRefiner()
        refiner.errorToThrow = NSError(domain: "test", code: 1)
        let context = MockContext()
        context.profileToReturn = .email
        let history = MockHistory()

        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context,
            snippets: nil, history: history, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "crudo"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(history.recordings.count, 1)
        let record = history.recordings[0]
        XCTAssertEqual(record.rawText, "crudo")
        XCTAssertEqual(record.finalText, "crudo") // fallback: raw == final
        XCTAssertEqual(record.profile, .email)
    }

    func test_snippetMatchRecordsHistory() async {
        let snippets = MockSnippets()
        snippets.matchesToReturn = ["trigger": "template text"]
        let context = MockContext()
        context.profileToReturn = .chat
        let history = MockHistory()

        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            context: context,
            snippets: snippets, history: history)
        controller.delegate = delegate

        transcriber.textToReturn = "trigger"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(history.recordings.count, 1)
        let record = history.recordings[0]
        XCTAssertEqual(record.rawText, "trigger")
        XCTAssertEqual(record.finalText, "template text")
        XCTAssertEqual(record.profile, .chat)
    }

    func test_nilSnippetsAndHistoryPreservePhase2Behavior() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "Test."
        let context = MockContext()

        // Explicitly nil (no snippets, no history)
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context,
            snippets: nil, history: nil, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "test"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["Test."])
        XCTAssertEqual(controller.state, .idle)
    }

    func test_audioSecondsComputedFromSamples() async {
        let history = MockHistory()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            snippets: nil, history: history)
        controller.delegate = delegate

        // 32_000 samples at 16_000 Hz = 2.0 seconds
        recorder.samplesToReturn = Array(repeating: 0.1, count: 32_000)
        transcriber.textToReturn = "hello"

        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(history.recordings.count, 1)
        let record = history.recordings[0]
        XCTAssertEqual(record.audioSeconds, 2.0)
    }

    func test_processTranscriptPassesZeroAudioSeconds() async {
        let history = MockHistory()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            snippets: nil, history: history)
        controller.delegate = delegate

        await controller.processTranscript("hello world")

        XCTAssertEqual(history.recordings.count, 1)
        let record = history.recordings[0]
        XCTAssertEqual(record.audioSeconds, 0.0)
    }

    func test_historyNotRecordedOnInsertionFailure() async {
        let history = MockHistory()
        inserter.errorToThrow = DictationError.insertionFailed("failed")
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            snippets: nil, history: history)
        controller.delegate = delegate

        transcriber.textToReturn = "hello"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        // No history record on insertion failure
        XCTAssertTrue(history.recordings.isEmpty)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(delegate.errors.isEmpty)
    }

    // MARK: - Short-Text Refinement Skip (field bug: LLM damages tiny fragments)
    //
    // Field evidence: "Necesito que transcribas" (24 chars) came back from the
    // refiner as "transcribas"; "¿Qué escuchas?" came back as "¿Qué escucha?".
    // Short fragments have no muletillas ("um", "eh") for the LLM to clean up,
    // so a small model asked to "refine" them tends to damage them instead.
    // `minRefinableLength` (default 25) skips refinement entirely below that
    // length and inserts the raw transcript.

    func test_shortTextSkipsRefiner() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "should never be used"
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context)
        controller.delegate = delegate

        let shortText = String(repeating: "a", count: 24) // < minRefinableLength (25)
        transcriber.textToReturn = shortText
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertTrue(refiner.receivedTexts.isEmpty, "Refiner must not be invoked for inputs shorter than minRefinableLength")
        XCTAssertEqual(inserter.inserted, [shortText])
    }

    func test_boundaryLengthTextInvokesRefiner() async {
        let refiner = MockRefiner()
        let boundaryText = String(repeating: "a", count: 25) // == minRefinableLength
        // Salida fiel (mismo token, solo un punto añadido) — no dispara la
        // guardia de fidelidad de RefineFidelity.
        let refinedBoundary = boundaryText + "."
        refiner.textToReturn = refinedBoundary
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context)
        controller.delegate = delegate

        transcriber.textToReturn = boundaryText
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(refiner.receivedTexts, [boundaryText], "Refiner must be invoked at exactly minRefinableLength")
        XCTAssertEqual(inserter.inserted, [refinedBoundary])
    }

    // MARK: - Fidelity fallback (bugfix 2026-07-08)
    //
    // Bug de campo: "Dame la lista de repositorios ya automatizados" salió como
    // "Lista de repositorios automatizados:" — el refinador parafraseó. La
    // guardia de fidelidad detecta cuando el refinado introduce vocabulario
    // nuevo (respondió/reformuló en vez de limpiar) y cae al texto crudo.

    func test_paraphraseWithNewVocabularyFallsBackToRaw() async {
        let refiner = MockRefiner()
        // Respuesta con vocabulario totalmente ajeno al dictado (modo de fallo
        // dañino): el usuario dictó una orden, el modelo "respondió".
        refiner.textToReturn = "Son las tres de la tarde en punto."
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0)
        controller.delegate = delegate

        let raw = "dame la lista de repositorios automatizados"
        transcriber.textToReturn = raw
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(refiner.receivedTexts, [raw], "Refiner is still invoked")
        XCTAssertEqual(inserter.inserted, [raw], "Unfaithful refinement must fall back to the raw transcription")
    }

    func test_refineDisabledInsertsRawTranscription() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "Hello world."
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            refineEnabled: { false })
        controller.delegate = delegate

        transcriber.textToReturn = "hello world"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertTrue(refiner.receivedTexts.isEmpty, "Refiner must not be called when refinement is disabled")
        XCTAssertEqual(inserter.inserted, ["hello world"], "Disabled refinement inserts the raw transcription verbatim")
    }

    func test_refineDisabledStillTranslatesWhenTranslateOn() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "Hello world."
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            translateEnabled: { true }, refineEnabled: { false })
        controller.delegate = delegate

        transcriber.textToReturn = "hola mundo"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(refiner.receivedTexts, ["hola mundo"], "Translate mode runs even with refinement disabled")
        XCTAssertEqual(inserter.inserted, ["Hello world."], "Translation output is inserted")
    }

    // MARK: - Language Threading (fidelity fix: field bug — Whisper detects
    // the spoken language correctly, but it never reached the refiner, so
    // Qwen 3B mistranslated/hallucinated English dictation into bad Spanish.
    // `languageProvider` (optional, nil by default) is how the detected
    // language reaches `Refining.refine`.

    func test_nilLanguageProviderDefaultsToSpanish() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "refined"
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            languageProvider: nil)
        controller.delegate = delegate

        transcriber.textToReturn = "raw text"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(refiner.receivedLanguages, ["es"], "Without a languageProvider, language must default to \"es\" — the pre-fix behavior — so existing setups keep working unchanged")
    }

    func test_languageProviderThreadsDetectedLanguageToRefiner() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "refined"
        let context = MockContext()
        let languageProvider = MockLanguageProvider()
        languageProvider.languageToReturn = "en"
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            languageProvider: languageProvider)
        controller.delegate = delegate

        transcriber.textToReturn = "are you understanding my english"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(refiner.receivedLanguages, ["en"], "Detected language from the languageProvider must reach the refiner")
    }

    func test_processTranscriptThreadsLanguageFromProvider() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "refined"
        let context = MockContext()
        let languageProvider = MockLanguageProvider()
        languageProvider.languageToReturn = "en"
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            languageProvider: languageProvider)
        controller.delegate = delegate

        await controller.processTranscript("hello world")

        XCTAssertEqual(refiner.receivedLanguages, ["en"], "processTranscript (same-breath wake path) must also thread the detected language")
    }

    // Regression for the same-breath TOCTOU: on the wake same-breath path,
    // WakeListener transcribes the text itself and captures the detected
    // language in the same serialized unit, then delivers both together. The
    // listener stays .listening (mic tap live) through several unstructured-Task
    // hops before stop() fires, so a trailing/ambient segment can re-run
    // transcribe() and overwrite the provider's lastDetectedLanguage BEFORE the
    // controller would read it. processTranscript(_:language:) must use the
    // language delivered WITH the text, never a disconnected provider read.
    func test_processTranscriptWithExplicitLanguageIgnoresMutatedProvider() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "refined"
        let context = MockContext()
        // Provider now reports "es" — simulating an interleaved second
        // transcribe() (e.g. a trailing ambient segment) that already
        // overwrote lastDetectedLanguage after the same-breath text was
        // produced in English.
        let languageProvider = MockLanguageProvider()
        languageProvider.languageToReturn = "es"
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            languageProvider: languageProvider)
        controller.delegate = delegate

        // The same-breath text was detected as English; the language is
        // delivered explicitly alongside it.
        await controller.processTranscript("are you understanding my english", language: "en")

        XCTAssertEqual(
            refiner.receivedLanguages, ["en"],
            "Explicit same-breath language must win over the (now stale) provider value — closing the TOCTOU")
    }

    // MARK: - Translate Mode (opt-in feature: default OFF, pins output to the
    // OTHER language when ON; bypasses minRefinableLength and relaxes the
    // length guards since translation legitimately changes text length)

    func test_translateDisabledByDefault() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "refined"
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0)
        controller.delegate = delegate

        transcriber.textToReturn = "raw text"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(refiner.receivedTranslateFlags, [false], "translateEnabled defaults to a closure returning false")
    }

    func test_translateFlagPassedToRefinerWhenEnabled() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "translated"
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            translateEnabled: { true })
        controller.delegate = delegate

        transcriber.textToReturn = "raw text"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(refiner.receivedTranslateFlags, [true])
    }

    func test_translateBypassesMinRefinableLength() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "hi"
        let context = MockContext()
        // minRefinableLength stays at its normal default (25) — translate
        // must bypass it, not require callers to also pass minRefinableLength: 0.
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context,
            translateEnabled: { true })
        controller.delegate = delegate

        transcriber.textToReturn = "hola" // 4 chars, far under minRefinableLength
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(refiner.receivedTexts, ["hola"], "Translate mode must invoke the refiner even for very short text")
        XCTAssertEqual(inserter.inserted, ["hi"])
    }

    func test_translateRelaxesSuspiciouslyLongGuard() async {
        let refiner = MockRefiner()
        // 50 raw chars: normal ceiling is 50*2+40=140, translate's relaxed
        // ceiling is 50*3.5=175. A 150-char translation exceeds the normal
        // guard (would wrongly fall back to raw) but fits under translate's.
        let raw = String(repeating: "a", count: 50)
        refiner.textToReturn = String(repeating: "x", count: 150)
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            translateEnabled: { true })
        controller.delegate = delegate

        transcriber.textToReturn = raw
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, [String(repeating: "x", count: 150)], "Translate mode's relaxed ceiling (3.5x, no +40 slack) must accept a 150-char translation of 50-char input that the normal 2x+40=140 guard would reject")
    }

    func test_translateRelaxesSuspiciouslyShortGuard() async {
        let refiner = MockRefiner()
        // 60 raw chars * 0.3 = 18; a 20-char translation is below the normal
        // 1/3 threshold (20) but still passes the relaxed 0.3x (18) floor.
        let raw = String(repeating: "a", count: 60)
        refiner.textToReturn = String(repeating: "b", count: 19)
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            translateEnabled: { true })
        controller.delegate = delegate

        transcriber.textToReturn = raw
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, [String(repeating: "b", count: 19)], "Translate mode's relaxed floor (0.3x) must accept a shorter translation that the normal 1/3 guard would reject")
    }

    // MARK: - Live Dictation Mode (F1 Task 3)
    //
    // `liveEnabled`/`liveCoordinatorFactory` let `hotkeyPressed` start a
    // `LiveTranscriptionCoordinator` alongside the recorder. The live decision
    // is CAPTURED at press time (`activeLiveSession`) so a mid-dictation
    // settings toggle can't change the flow of an in-flight dictation. On
    // release, the coordinator's `finish()` result — NOT a re-transcription
    // of the recorder's samples — is what gets inserted, and refine/translate
    // are always skipped for a live dictation regardless of their toggles.
    // Reuses `MockLiveTranscriber` from `LiveTranscriptionCoordinatorTests.swift`
    // (same test target).

    private func makeLiveCoordinator(
        scriptedTexts: [String], minNewAudioSeconds: Double = 60
    ) -> (LiveTranscriptionCoordinator, MockLiveTranscriber) {
        let liveTranscriber = MockLiveTranscriber()
        liveTranscriber.scriptedTexts = scriptedTexts
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: liveTranscriber, minPassInterval: 0,
            minNewAudioSeconds: minNewAudioSeconds, sampleRate: 16_000)
        return (coordinator, liveTranscriber)
    }

    func test_liveModePressStartsRecordingAndCoordinatorPartialsFlowToDelegate() {
        let (coordinator, liveTranscriber) = makeLiveCoordinator(
            scriptedTexts: ["hola live"], minNewAudioSeconds: 0.1) // 1_600 samples
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            liveEnabled: { true }, liveCoordinatorFactory: { coordinator })
        controller.delegate = delegate

        controller.hotkeyPressed()
        XCTAssertTrue(recorder.started)
        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(delegate.states, [.recording])

        controller.liveChunk(Array(repeating: Float(0.1), count: 2_000))

        let settle = expectation(description: "partial delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)

        XCTAssertEqual(liveTranscriber.callCount, 1)
        XCTAssertEqual(delegate.livePartials, ["hola live"], "the coordinator's onPartial must forward to the delegate")
    }

    func test_liveReleaseInsertsCoordinatorFinishResultNotRetranscription() async {
        let (coordinator, _) = makeLiveCoordinator(scriptedTexts: ["final live text"])
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            liveEnabled: { true }, liveCoordinatorFactory: { coordinator })
        controller.delegate = delegate

        transcriber.textToReturn = "should never be used"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["final live text"])
        XCTAssertTrue(transcriber.receivedSamples.isEmpty, "the batch transcriber must never run for a live dictation")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.livePartials.last ?? "sentinel", nil, "partial must be cleared (nil) on release")
    }

    func test_liveReleaseNeverCallsRefinerEvenWhenRefineEnabled() async {
        let (coordinator, _) = makeLiveCoordinator(scriptedTexts: ["final live text"])
        let refiner = MockRefiner()
        refiner.textToReturn = "should never be used"
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            refineEnabled: { true },
            liveEnabled: { true }, liveCoordinatorFactory: { coordinator })
        controller.delegate = delegate

        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertTrue(refiner.receivedTexts.isEmpty, "refiner must never be invoked for a live dictation, even with refineEnabled true")
        XCTAssertEqual(inserter.inserted, ["final live text"])
    }

    func test_liveReleaseNeverCallsTranslateEvenWhenTranslateEnabled() async {
        let (coordinator, _) = makeLiveCoordinator(scriptedTexts: ["final live text"])
        let refiner = MockRefiner()
        refiner.textToReturn = "should never be used"
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            translateEnabled: { true }, refineEnabled: { false },
            liveEnabled: { true }, liveCoordinatorFactory: { coordinator })
        controller.delegate = delegate

        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertTrue(refiner.receivedTexts.isEmpty, "translate must never run for a live dictation, even with translateEnabled true")
        XCTAssertTrue(refiner.receivedTranslateFlags.isEmpty)
        XCTAssertEqual(inserter.inserted, ["final live text"])
    }

    func test_liveReleaseRecordsHistory() async {
        let (coordinator, _) = makeLiveCoordinator(scriptedTexts: ["final live text"])
        let history = MockHistory()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            history: history,
            liveEnabled: { true }, liveCoordinatorFactory: { coordinator })
        controller.delegate = delegate

        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(history.recordings.count, 1)
        let record = history.recordings[0]
        XCTAssertEqual(record.rawText, "final live text")
        XCTAssertEqual(record.finalText, "final live text")
    }

    func test_liveReleaseEmptyFinalInsertsNothing() async {
        let (coordinator, _) = makeLiveCoordinator(scriptedTexts: ["   \n "])
        let history = MockHistory()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            history: history,
            liveEnabled: { true }, liveCoordinatorFactory: { coordinator })
        controller.delegate = delegate

        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertTrue(inserter.inserted.isEmpty, "an empty live final transcript must behave like the batch empty-transcription path")
        XCTAssertTrue(history.recordings.isEmpty)
        XCTAssertEqual(controller.state, .idle)
    }

    func test_liveDisabledFallsBackToBatchPathEvenWithFactoryProvided() async {
        let (coordinator, liveTranscriber) = makeLiveCoordinator(scriptedTexts: ["should never be used"])
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            liveEnabled: { false }, liveCoordinatorFactory: { coordinator })
        controller.delegate = delegate

        transcriber.textToReturn = "batch text"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["batch text"])
        XCTAssertEqual(liveTranscriber.callCount, 0, "the coordinator's transcriber must never run when liveEnabled() is false at press")
    }

    func test_liveFactoryNilFallsBackToBatchPathEvenWhenLiveEnabledTrue() async {
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            liveEnabled: { true }, liveCoordinatorFactory: nil)
        controller.delegate = delegate

        transcriber.textToReturn = "batch text"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["batch text"])
    }

    func test_cancelDuringLiveClearsPartialAndInsertsNothing() {
        let (coordinator, liveTranscriber) = makeLiveCoordinator(scriptedTexts: ["should never be delivered"])
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            liveEnabled: { true }, liveCoordinatorFactory: { coordinator })
        controller.delegate = delegate

        controller.hotkeyPressed()
        controller.cancel()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(inserter.inserted.isEmpty)
        XCTAssertEqual(delegate.livePartials, [nil], "cancel must clear the live partial via a nil delivery")
        XCTAssertEqual(liveTranscriber.callCount, 0)
    }

    func test_liveShortTapCancelsWithoutInserting() async {
        let (coordinator, liveTranscriber) = makeLiveCoordinator(scriptedTexts: ["should never be delivered"])
        recorder.samplesToReturn = Array(repeating: 0.1, count: 1_000) // < 0.3 s * 16 kHz
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            liveEnabled: { true }, liveCoordinatorFactory: { coordinator })
        controller.delegate = delegate

        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertTrue(inserter.inserted.isEmpty, "a short tap in live mode must not insert anything")
        XCTAssertEqual(liveTranscriber.callCount, 0, "the coordinator's transcriber must not be called for a short tap (no final pass)")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.livePartials.last ?? "sentinel", nil, "partial must be cleared (nil) on release")
    }

    func test_toggleDisablingLiveMidDictationStillCompletesAsLive() async {
        let (coordinator, _) = makeLiveCoordinator(scriptedTexts: ["final live text"])
        var liveFlag = true
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            liveEnabled: { liveFlag }, liveCoordinatorFactory: { coordinator })
        controller.delegate = delegate

        controller.hotkeyPressed()
        XCTAssertEqual(controller.state, .recording)

        liveFlag = false // toggle flips mid-dictation, AFTER press
        transcriber.textToReturn = "should never be used"
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["final live text"], "the in-flight dictation must complete as live even though liveEnabled() now returns false")
        XCTAssertTrue(transcriber.receivedSamples.isEmpty, "the batch transcriber must not run for a dictation captured as live")
    }

    func test_liveChunkIsNoopWithoutActiveLiveSession() {
        // liveEnabled defaults to false / no factory — `controller` (setUp's
        // default instance) never has an active live session.
        controller.hotkeyPressed()
        controller.liveChunk(Array(repeating: Float(0.1), count: 4_000)) // must not crash
        XCTAssertEqual(controller.state, .recording)
    }

    // MARK: - Bubble contract during the final live pass (Fix 2): the bubble
    // stays through `.processing` (HUDView already renders a spinner-in-bubble
    // branch for that state + liveText != nil) and clears (nil) only AFTER
    // the final transcript has been inserted — never before, so the user
    // never sees a bare "Procesando…" pill flash in between.

    func test_livePartialCanArriveDuringFinalPassAndClearsAfterInsert() async {
        // Low minNewAudioSeconds + a delayed transcriber so a pass is
        // genuinely in flight at release — `finish()` must wait for it
        // (delivering its own onPartial, possibly during `.processing`)
        // before running the final pass.
        let liveTranscriber = MockLiveTranscriber()
        liveTranscriber.delaySeconds = 0.1
        liveTranscriber.scriptedTexts = ["partial during recording", "final live text"]
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: liveTranscriber, minPassInterval: 0,
            minNewAudioSeconds: 0.05, sampleRate: 16_000) // 800 samples
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            liveEnabled: { true }, liveCoordinatorFactory: { coordinator })
        controller.delegate = delegate

        let firstPassStarted = expectation(description: "first pass started")
        liveTranscriber.onCallStarted = { index in if index == 1 { firstPassStarted.fulfill() } }

        controller.hotkeyPressed()
        controller.liveChunk(Array(repeating: Float(0.1), count: 1_600)) // launches pass1 (0.1s delay)
        await fulfillment(of: [firstPassStarted], timeout: 1.0)

        // Release while pass1 is still in flight — finish() waits for it,
        // then runs the final pass.
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["final live text"])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(delegate.livePartials.last ?? "sentinel", nil, "the delegate's LAST live-partial event must clear the bubble")

        // No crash / ordering violation: a partial (from the in-flight pass
        // finish() awaited) may legitimately arrive while state == .processing.
        XCTAssertTrue(delegate.states.contains(.processing))

        guard let insertIndex = delegate.events.firstIndex(of: "insert") else {
            return XCTFail("insert event never fired")
        }
        guard let finalNilIndex = delegate.events.lastIndex(of: "livePartial:nil") else {
            return XCTFail("live-partial nil clear never fired")
        }
        XCTAssertGreaterThan(finalNilIndex, insertIndex, "the bubble must clear (nil) AFTER insertion — never before .processing, per Fix 2's contract")
    }

    func test_processLiveSkipsRefineAndTranslate() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "should never be used"
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context, minRefinableLength: 0,
            translateEnabled: { true }, refineEnabled: { true })
        controller.delegate = delegate

        let validSamples: [Float] = Array(repeating: 0.1, count: 16_000)
        transcriber.textToReturn = "wake live batch text"

        await controller.processLive(samples: validSamples)

        XCTAssertEqual(inserter.inserted, ["wake live batch text"])
        XCTAssertTrue(refiner.receivedTexts.isEmpty, "processLive must skip refine/translate — it's a wake live delivery")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(transcriber.receivedSamples.count, 16_000, "processLive still batch-transcribes the delivered samples")
    }
}
