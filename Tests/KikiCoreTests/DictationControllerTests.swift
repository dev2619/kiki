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
}
