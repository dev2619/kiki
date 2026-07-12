import XCTest
@testable import KikiCore

// MARK: - Mocks

/// Scripted `Transcribing` for `LiveTranscriptionCoordinator`. Calls are
/// 1-based (`callCount` after increment). `delaySeconds` (real Task.sleep,
/// capped low — see per-test comments) simulates a "slow" pass so tests can
/// observe overlap-prevention deterministically; it is independent from the
/// coordinator's injected `now()` clock, which tests advance manually to
/// control interval/new-audio gating without depending on wall-clock time.
final class MockLiveTranscriber: Transcribing {
    var scriptedTexts: [String] = []
    var errorAtCall: [Int: Error] = [:]
    var delaySeconds: TimeInterval = 0
    private(set) var callCount = 0
    private(set) var receivedSamples: [[Float]] = []
    /// Fired at the START of each call (before any delay) so tests can
    /// synchronize on "a pass has started" without racing real time.
    var onCallStarted: ((Int) -> Void)?

    func transcribe(_ samples: [Float]) async throws -> String {
        callCount += 1
        let index = callCount
        receivedSamples.append(samples)
        onCallStarted?(index)
        if delaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        if let error = errorAtCall[index] {
            throw error
        }
        if index <= scriptedTexts.count {
            return scriptedTexts[index - 1]
        }
        return scriptedTexts.last ?? ""
    }
}

/// Scripted `Transcribing` + `LenientTranscribing` mock — regression coverage
/// for the F1 fix (2026-07-12): `LiveTranscriptionCoordinator`'s interim
/// passes must call `transcribeLenient` when the transcriber exposes it
/// (never the strict, gated `transcribe`), while the FINAL pass
/// (`finish()`) must always call the strict `transcribe`, gates included,
/// because its result can be inserted. Tracks lenient/strict call counts
/// separately so tests can assert exactly which path fired.
final class MockLenientLiveTranscriber: Transcribing, LenientTranscribing {
    var scriptedLenientTexts: [String] = []
    var scriptedStrictTexts: [String] = []
    private(set) var lenientCallCount = 0
    private(set) var strictCallCount = 0
    private(set) var lenientReceivedSamples: [[Float]] = []
    private(set) var strictReceivedSamples: [[Float]] = []

    func transcribeLenient(_ samples: [Float]) async throws -> String {
        lenientCallCount += 1
        let index = lenientCallCount
        lenientReceivedSamples.append(samples)
        if index <= scriptedLenientTexts.count {
            return scriptedLenientTexts[index - 1]
        }
        return scriptedLenientTexts.last ?? ""
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        strictCallCount += 1
        let index = strictCallCount
        strictReceivedSamples.append(samples)
        if index <= scriptedStrictTexts.count {
            return scriptedStrictTexts[index - 1]
        }
        return scriptedStrictTexts.last ?? ""
    }
}

/// Mutable injectable clock — tests advance it explicitly to control
/// `minPassInterval` gating without depending on wall-clock timing.
private final class MutableNow {
    private var current: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = date
    }
    func advance(_ seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
    func now() -> Date { current }
}

private func samples(count: Int) -> [Float] {
    Array(repeating: 0.05, count: count)
}

// MARK: - Tests

@MainActor
final class LiveTranscriptionCoordinatorTests: XCTestCase {

    // MARK: (1) append no dispara pass hasta acumular minNewAudio

    func test_appendDoesNotTriggerPassUntilMinNewAudioAccumulates() {
        let transcriber = MockLiveTranscriber()
        transcriber.scriptedTexts = ["result"]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0.8, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        // Below the 6_400-sample threshold (0.4s * 16kHz) — must not fire.
        coordinator.append(samples(count: 3_000))

        let settle = expectation(description: "settle below threshold")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)
        XCTAssertEqual(transcriber.callCount, 0, "A pass must not start before minNewAudioSeconds worth of samples accumulate")

        let firstCallStarted = expectation(description: "pass started")
        transcriber.onCallStarted = { _ in firstCallStarted.fulfill() }
        coordinator.append(samples(count: 3_600)) // total 6_600 >= 6_400 threshold
        wait(for: [firstCallStarted], timeout: 1.0)

        XCTAssertEqual(transcriber.callCount, 1)
        XCTAssertEqual(transcriber.receivedSamples.first?.count, 6_600)
    }

    // MARK: (2) pases nunca solapados; el siguiente arranca al terminar si hay audio nuevo y pasó el intervalo

    func test_passesNeverOverlapAndChainWhenAudioAndIntervalAllow() {
        let transcriber = MockLiveTranscriber()
        transcriber.delaySeconds = 0.1
        transcriber.scriptedTexts = ["first", "second"]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0.8, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        let firstCallStarted = expectation(description: "first pass started")
        transcriber.onCallStarted = { index in if index == 1 { firstCallStarted.fulfill() } }
        coordinator.append(samples(count: 6_400)) // launches pass1 at simulated t0
        wait(for: [firstCallStarted], timeout: 1.0)

        // Advance the simulated clock past minPassInterval (measured from pass1's start)
        // BEFORE the second append so the in-flight guard (not interval) is what blocks pass2.
        nowBox.advance(1.0)

        // Plenty of new audio arrives WHILE pass1 is still in flight (sleeping).
        coordinator.append(samples(count: 6_400)) // total 12_800

        let settleWhileInFlight = expectation(description: "settle while pass1 in flight")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { settleWhileInFlight.fulfill() }
        wait(for: [settleWhileInFlight], timeout: 1.0)
        XCTAssertEqual(transcriber.callCount, 1, "a second pass must not start while one is in flight, even with enough new audio")

        let secondCallStarted = expectation(description: "second pass started")
        transcriber.onCallStarted = { index in if index == 2 { secondCallStarted.fulfill() } }
        wait(for: [secondCallStarted], timeout: 1.0)

        XCTAssertEqual(transcriber.callCount, 2, "pass2 must auto-chain once pass1 completes, since new audio arrived and the interval elapsed")
        XCTAssertEqual(transcriber.receivedSamples[1].count, 12_800, "the chained pass must transcribe the FULL buffer")
    }

    // MARK: (3) onPartial recibe el texto de cada pass completado, en orden

    func test_onPartialFiresForEachCompletedPassInOrder() {
        let transcriber = MockLiveTranscriber()
        transcriber.scriptedTexts = ["hola", "hola mundo"]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        var partials: [String] = []
        let firstPartial = expectation(description: "first partial")
        coordinator.onPartial = { text in
            partials.append(text)
            if partials.count == 1 { firstPartial.fulfill() }
        }
        coordinator.append(samples(count: 6_400))
        wait(for: [firstPartial], timeout: 1.0)
        XCTAssertEqual(partials, ["hola"])

        let secondPartial = expectation(description: "second partial")
        coordinator.onPartial = { text in
            partials.append(text)
            if partials.count == 2 { secondPartial.fulfill() }
        }
        coordinator.append(samples(count: 6_400)) // more new audio; interval is 0
        wait(for: [secondPartial], timeout: 1.0)

        XCTAssertEqual(partials, ["hola", "hola mundo"], "partials must arrive in pass-completion order")
    }

    // MARK: (4) parcial vacío (gate de alucinación) NO borra un parcial previo no-vacío

    func test_emptyPartialDoesNotOverwritePreviousNonEmptyPartial() {
        let transcriber = MockLiveTranscriber()
        transcriber.scriptedTexts = ["hello", ""]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        var partials: [String] = []
        let firstPartial = expectation(description: "first partial")
        coordinator.onPartial = { text in
            partials.append(text)
            firstPartial.fulfill()
        }
        coordinator.append(samples(count: 6_400))
        wait(for: [firstPartial], timeout: 1.0)
        XCTAssertEqual(partials, ["hello"])

        // Second pass returns "" (hallucination gate) — must NOT fire onPartial again.
        coordinator.append(samples(count: 6_400))

        let settle = expectation(description: "settle after second pass")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)

        XCTAssertEqual(transcriber.callCount, 2, "the second pass must still run — the gate is on delivery, not on running")
        XCTAssertEqual(partials, ["hello"], "an empty result must not overwrite the previously-delivered non-empty partial")
    }

    // MARK: (5) finish() espera el pass en vuelo, corre el pass final con TODO el buffer

    func test_finishWaitsForInFlightPassThenRunsFinalPassOverFullBuffer() {
        let transcriber = MockLiveTranscriber()
        transcriber.delaySeconds = 0.1
        transcriber.scriptedTexts = ["partial pass", "final pass text"]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0.8, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        let firstCallStarted = expectation(description: "first pass started")
        transcriber.onCallStarted = { index in if index == 1 { firstCallStarted.fulfill() } }
        coordinator.append(samples(count: 6_400))
        wait(for: [firstCallStarted], timeout: 1.0)

        // More audio arrives while pass1 is still in flight — the final pass
        // must cover this too.
        coordinator.append(samples(count: 3_200)) // total 9_600

        var finishResult: String?
        let finishExpectation = expectation(description: "finish completes")
        Task { @MainActor in
            finishResult = await coordinator.finish()
            finishExpectation.fulfill()
        }
        wait(for: [finishExpectation], timeout: 2.0)

        XCTAssertEqual(finishResult, "final pass text")
        XCTAssertEqual(transcriber.callCount, 2, "finish() must wait for the in-flight pass, then run exactly one final pass")
        XCTAssertEqual(transcriber.receivedSamples[1].count, 9_600, "the final pass must cover the FULL buffer, including audio appended while the previous pass was in flight")
    }

    // MARK: (6) finish() con pass final que lanza → devuelve el último parcial

    func test_finishReturnsLastPartialWhenFinalPassThrows() {
        let transcriber = MockLiveTranscriber()
        transcriber.scriptedTexts = ["first partial"]
        transcriber.errorAtCall = [2: NSError(domain: "test", code: 1)]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        var partials: [String] = []
        let firstPartial = expectation(description: "first partial")
        coordinator.onPartial = { text in
            partials.append(text)
            firstPartial.fulfill()
        }
        coordinator.append(samples(count: 6_400))
        wait(for: [firstPartial], timeout: 1.0)
        XCTAssertEqual(partials, ["first partial"])

        var finishResult: String?
        let finishExpectation = expectation(description: "finish completes")
        Task { @MainActor in
            finishResult = await coordinator.finish()
            finishExpectation.fulfill()
        }
        wait(for: [finishExpectation], timeout: 1.0)

        XCTAssertEqual(finishResult, "first partial", "when the final pass throws, finish() must fall back to the last non-empty partial")
    }

    // MARK: (self-review regression) finish() must suppress chaining triggered
    // by the in-flight pass it's waiting on — otherwise a second background
    // pass could launch concurrently with finish()'s own final pass and
    // deliver a stray onPartial after finish() has already returned.

    func test_finishSuppressesChainingFromTheInFlightPassItWaitsOn() {
        let transcriber = MockLiveTranscriber()
        transcriber.delaySeconds = 0.1
        transcriber.scriptedTexts = ["partial pass", "final pass text"]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        var partials: [String] = []
        coordinator.onPartial = { partials.append($0) }

        let firstCallStarted = expectation(description: "first pass started")
        transcriber.onCallStarted = { index in if index == 1 { firstCallStarted.fulfill() } }
        coordinator.append(samples(count: 6_400))
        wait(for: [firstCallStarted], timeout: 1.0)

        // Enough new audio arrives while pass1 is in flight to satisfy the
        // chaining condition (minPassInterval is 0) once pass1 completes —
        // the exact condition that used to race with finish()'s own final pass.
        coordinator.append(samples(count: 6_400)) // total 12_800

        var finishResult: String?
        let finishExpectation = expectation(description: "finish completes")
        Task { @MainActor in
            finishResult = await coordinator.finish()
            finishExpectation.fulfill()
        }
        wait(for: [finishExpectation], timeout: 2.0)

        XCTAssertEqual(finishResult, "final pass text")
        XCTAssertEqual(transcriber.callCount, 2, "finish() must run exactly one final pass — no extra chained pass")
        XCTAssertEqual(transcriber.receivedSamples[1].count, 12_800, "the final pass must cover the full buffer")
        XCTAssertEqual(partials, ["partial pass"], "only the in-flight pass's own partial fires — no onPartial after finish()")

        // Give any (erroneous) chained pass a chance to complete and misfire.
        let settle = expectation(description: "settle after finish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)
        XCTAssertEqual(transcriber.callCount, 2, "no pass may launch after finish() completes")
        XCTAssertEqual(partials, ["partial pass"], "no onPartial may fire after finish() completes")
    }

    // MARK: (7) cancel() → onPartial no vuelve a dispararse ni finish pendiente entrega

    func test_cancelStopsFuturePartialsAndPendingFinish() async {
        let transcriber = MockLiveTranscriber()
        transcriber.delaySeconds = 0.1
        transcriber.scriptedTexts = ["should never be delivered"]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0.8, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        var partials: [String] = []
        coordinator.onPartial = { partials.append($0) }

        let firstCallStarted = expectation(description: "first pass started")
        transcriber.onCallStarted = { index in if index == 1 { firstCallStarted.fulfill() } }
        coordinator.append(samples(count: 6_400))
        await fulfillment(of: [firstCallStarted], timeout: 1.0)

        var finishResult: String?
        let finishExpectation = expectation(description: "finish resolves")
        Task { @MainActor in
            finishResult = await coordinator.finish()
            finishExpectation.fulfill()
        }
        // Give the finish() Task a chance to start and reach its own await
        // point (awaiting the in-flight pass) before cancelling — exercises
        // the generation-mismatch-after-resume path, not just an early guard.
        await Task.yield()
        await Task.yield()

        coordinator.cancel()

        await fulfillment(of: [finishExpectation], timeout: 1.0)

        XCTAssertEqual(finishResult, "", "a finish() pending at cancel() time must not deliver the in-flight pass's text")
        XCTAssertTrue(partials.isEmpty, "cancel() must prevent onPartial from ever firing, even for a pass already in flight when cancel() was called")
        XCTAssertEqual(transcriber.callCount, 1, "no further passes must launch after cancel()")
    }

    // MARK: (8b) finish(fullAudio:) transcribes the CALLER-supplied buffer,
    // not the internal one accumulated via append() — regression coverage
    // for the tail-audio-loss fix: chunks hop audio-thread → MainActor via
    // unstructured Tasks, so at release some hops can still be in flight and
    // the internal buffer can miss the last ~85-170ms that the recorder's
    // own (authoritative) buffer already has.

    func test_finishWithFullAudioOverridesInternalBuffer() async {
        let transcriber = MockLiveTranscriber()
        transcriber.scriptedTexts = ["final from full audio"]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0.8, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        // Internal buffer only sees 1_600 samples via append (no pass fires —
        // well below the 6_400-sample threshold).
        coordinator.append(samples(count: 1_600))

        // The recorder's authoritative buffer has more (simulates in-flight
        // chunk hops that never reached the coordinator by release time).
        let authoritativeAudio = samples(count: 4_800)

        let finishResult = await coordinator.finish(fullAudio: authoritativeAudio)

        XCTAssertEqual(finishResult, "final from full audio")
        XCTAssertEqual(transcriber.callCount, 1)
        XCTAssertEqual(transcriber.receivedSamples.first?.count, 4_800, "finish(fullAudio:) must transcribe the caller-supplied buffer, not the internal 1_600-sample buffer")
    }

    // MARK: (8) concurrent double-finish must run only one final pass

    func test_concurrentDoubleFinishRunsSingleFinalPass() {
        let transcriber = MockLiveTranscriber()
        transcriber.delaySeconds = 0.05 // Slow pass so both finish() calls can start
        transcriber.scriptedTexts = ["partial pass", "final pass text"]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0.8, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        let firstCallStarted = expectation(description: "first pass started")
        transcriber.onCallStarted = { index in if index == 1 { firstCallStarted.fulfill() } }
        coordinator.append(samples(count: 6_400))
        wait(for: [firstCallStarted], timeout: 1.0)

        // Append more audio while pass1 is in flight — the final pass will see this.
        coordinator.append(samples(count: 3_200)) // total 9_600

        var finishResult1: String?
        var finishResult2: String?
        let finishExpectation1 = expectation(description: "finish1 completes")
        let finishExpectation2 = expectation(description: "finish2 completes")

        // Launch two finish() calls concurrently — both will pass the first guard,
        // but only the first through the re-check should run the final pass.
        Task { @MainActor in
            finishResult1 = await coordinator.finish()
            finishExpectation1.fulfill()
        }
        Task { @MainActor in
            finishResult2 = await coordinator.finish()
            finishExpectation2.fulfill()
        }

        wait(for: [finishExpectation1, finishExpectation2], timeout: 2.0)

        XCTAssertEqual(transcriber.callCount, 2, "only one regular pass + one final pass (no double final)")
        // The final pass (call 2) should transcribe the full buffer.
        if transcriber.receivedSamples.count > 1 {
            XCTAssertEqual(transcriber.receivedSamples[1].count, 9_600, "the final pass must see the full buffer")
        }
        // At least one finish() call returns the final pass result; both should have non-nil values.
        XCTAssertNotNil(finishResult1, "first finish() must return a value")
        XCTAssertNotNil(finishResult2, "second finish() must return a value")
        // The final pass result should be somewhere in the returned values.
        XCTAssert(finishResult1 == "final pass text" || finishResult2 == "final pass text",
                  "at least one finish() call must return the final pass result")
    }

    // MARK: (9) F1 fix 2026-07-12 — interim passes use transcribeLenient when available

    func test_interimPassesUseLenientTranscriptionWhenTranscriberSupportsIt() {
        let transcriber = MockLenientLiveTranscriber()
        transcriber.scriptedLenientTexts = ["hola leniente"]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0.8, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        var partials: [String] = []
        let firstPartial = expectation(description: "first partial")
        coordinator.onPartial = { text in
            partials.append(text)
            firstPartial.fulfill()
        }
        coordinator.append(samples(count: 6_400))
        wait(for: [firstPartial], timeout: 1.0)

        XCTAssertEqual(partials, ["hola leniente"])
        XCTAssertEqual(transcriber.lenientCallCount, 1, "an interim pass must call transcribeLenient when the transcriber supports it")
        XCTAssertEqual(transcriber.strictCallCount, 0, "an interim pass must never call the strict, gated transcribe when transcribeLenient is available")
    }

    // MARK: (10) F1 fix 2026-07-12 — finish() always uses strict transcription

    func test_finalPassAlwaysUsesStrictTranscriptionEvenWhenLenientIsAvailable() {
        let transcriber = MockLenientLiveTranscriber()
        transcriber.scriptedLenientTexts = ["parcial leniente"]
        transcriber.scriptedStrictTexts = ["final estricto"]
        let nowBox = MutableNow()
        let coordinator = LiveTranscriptionCoordinator(
            transcriber: transcriber, minPassInterval: 0.8, minNewAudioSeconds: 0.4,
            sampleRate: 16_000, now: nowBox.now)
        coordinator.start()

        let firstPartial = expectation(description: "interim partial via lenient path")
        coordinator.onPartial = { _ in firstPartial.fulfill() }
        coordinator.append(samples(count: 6_400))
        wait(for: [firstPartial], timeout: 1.0)

        var finishResult: String?
        let finishExpectation = expectation(description: "finish completes")
        Task { @MainActor in
            finishResult = await coordinator.finish()
            finishExpectation.fulfill()
        }
        wait(for: [finishExpectation], timeout: 1.0)

        XCTAssertEqual(finishResult, "final estricto")
        XCTAssertEqual(transcriber.strictCallCount, 1, "finish() must always call the strict, gated transcribe — its result can be inserted")
        XCTAssertEqual(transcriber.lenientCallCount, 1, "only the interim pass should have used transcribeLenient; finish() must not")
    }
}
