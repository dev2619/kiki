import XCTest
@testable import KikiCore

final class ModelLoadProgressTests: XCTestCase {
    func testBothPhasesAtZeroIsZero() {
        XCTAssertEqual(ModelLoadProgress.overall(phase1: 0, phase2: 0), 0, accuracy: 0.0001)
    }

    func testBothPhasesCompleteIsOne() {
        XCTAssertEqual(ModelLoadProgress.overall(phase1: 1, phase2: 1), 1, accuracy: 0.0001)
    }

    func testPhase1CompleteAloneEqualsItsWeight() {
        XCTAssertEqual(
            ModelLoadProgress.overall(phase1: 1, phase2: 0),
            ModelLoadProgress.phase1Weight,
            accuracy: 0.0001)
    }

    func testPhase2CompleteAloneEqualsItsWeight() {
        XCTAssertEqual(
            ModelLoadProgress.overall(phase1: 0, phase2: 1),
            ModelLoadProgress.phase2Weight,
            accuracy: 0.0001)
    }

    func testWeightsSumToOne() {
        XCTAssertEqual(ModelLoadProgress.phase1Weight + ModelLoadProgress.phase2Weight, 1, accuracy: 0.0001)
    }

    func testHalfwayEachPhaseIsHalfwayOverall() {
        XCTAssertEqual(ModelLoadProgress.overall(phase1: 0.5, phase2: 0.5), 0.5, accuracy: 0.0001)
    }

    func testMidTransitionOnlyPhase1Progressing() {
        // Fase 2 (Qwen) todavía no arrancó mientras fase 1 (Whisper) va al 60%.
        let expected = 0.6 * ModelLoadProgress.phase1Weight
        XCTAssertEqual(ModelLoadProgress.overall(phase1: 0.6, phase2: 0), expected, accuracy: 0.0001)
    }

    func testNegativeInputsClampToZero() {
        XCTAssertEqual(ModelLoadProgress.overall(phase1: -1, phase2: -5), 0, accuracy: 0.0001)
    }

    func testOverOneInputsClampToOne() {
        XCTAssertEqual(ModelLoadProgress.overall(phase1: 2, phase2: 1.5), 1, accuracy: 0.0001)
    }

    func testMonotonicAsPhase1Increases() {
        let low = ModelLoadProgress.overall(phase1: 0.2, phase2: 0)
        let high = ModelLoadProgress.overall(phase1: 0.8, phase2: 0)
        XCTAssertLessThan(low, high)
    }
}
