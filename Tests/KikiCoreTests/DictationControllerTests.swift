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
    var delaySeconds: TimeInterval = 0

    func refine(_ text: String, profile: AppProfile) async throws -> String {
        receivedTexts.append(text)
        receivedProfiles.append(profile)
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

@MainActor
final class SpyDelegate: DictationControllerDelegate {
    var states: [DictationState] = []
    var errors: [DictationError] = []

    func dictationStateDidChange(_ state: DictationState) { states.append(state) }
    func dictationDidFail(_ error: DictationError) { errors.append(error) }
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
        refiner.textToReturn = "texto pulido."
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context)
        controller.delegate = delegate

        transcriber.textToReturn = "hello world"
        controller.hotkeyPressed()
        await controller.hotkeyReleased()

        XCTAssertEqual(inserter.inserted, ["texto pulido."])
    }

    func test_refinerReceivesProfileFromContext() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "refined"
        let context = MockContext()
        context.profileToReturn = .code
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context)
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
            refiner: refiner, context: nil)
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
            refiner: refiner, context: context)
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
            refiner: refiner, context: context, refineTimeout: 0.1)
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
            refiner: refiner, context: context)
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
            refiner: refiner, context: context)
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
            refiner: refiner, context: context)
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
        refiner.textToReturn = "texto pulido."
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context)
        controller.delegate = delegate

        await controller.processTranscript("hello world")

        XCTAssertEqual(inserter.inserted, ["texto pulido."])
        XCTAssertEqual(refiner.receivedTexts, ["hello world"])
        XCTAssertTrue(delegate.states.contains(.processing))
        XCTAssertEqual(controller.state, .idle)
    }

    func test_processTranscriptEmptyIsNoop() async {
        let refiner = MockRefiner()
        refiner.textToReturn = "texto pulido."
        let context = MockContext()
        controller = DictationController(
            recorder: recorder, transcriber: transcriber, inserter: inserter,
            refiner: refiner, context: context)
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
}
