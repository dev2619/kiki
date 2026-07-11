import XCTest
@testable import KikiStore

final class ModelCatalogTests: XCTestCase {
    let suiteName = "kiki.tests.models"
    var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // 1. Catalogs have 3 options and exactly one isBase each.
    func testCatalogsHaveThreeOptionsAndExactlyOneBase() {
        for kind in [ModelKind.stt, ModelKind.refine] {
            let options = ModelCatalog.options(for: kind)
            XCTAssertEqual(options.count, 3, "\(kind) should have exactly 3 options")
            XCTAssertEqual(options.filter { $0.isBase }.count, 1, "\(kind) should have exactly one base option")
        }
    }

    // 2. effectiveModelId without a stored preference returns the base id.
    func testEffectiveModelIdWithoutPreferenceReturnsBase() {
        for kind in [ModelKind.stt, ModelKind.refine] {
            let expected = ModelCatalog.baseOption(for: kind).id
            XCTAssertEqual(ModelPreference.effectiveModelId(for: kind, defaults: defaults), expected)
        }
    }

    // 3. effectiveModelId with a valid stored preference returns that preference.
    func testEffectiveModelIdWithValidPreferenceReturnsPreference() {
        let nonBase = ModelCatalog.sttOptions.first { !$0.isBase }!
        defaults.set(nonBase.id, forKey: ModelPreference.defaultsKey(for: .stt))

        XCTAssertEqual(ModelPreference.effectiveModelId(for: .stt, defaults: defaults), nonBase.id)
    }

    // 4. effectiveModelId with a preference outside the catalog (retired model) falls back to base.
    func testEffectiveModelIdWithRetiredPreferenceFallsBackToBase() {
        defaults.set("some-retired-model-id", forKey: ModelPreference.defaultsKey(for: .refine))

        XCTAssertEqual(
            ModelPreference.effectiveModelId(for: .refine, defaults: defaults),
            ModelCatalog.baseOption(for: .refine).id
        )
    }

    // 5. setPreferred + effectiveModelId round-trip.
    func testSetPreferredRoundTrip() {
        let nonBase = ModelCatalog.refineOptions.first { !$0.isBase }!

        ModelPreference.setPreferred(nonBase.id, for: .refine, defaults: defaults)

        XCTAssertEqual(ModelPreference.effectiveModelId(for: .refine, defaults: defaults), nonBase.id)
    }

    // 6. Exact UserDefaults keys.
    func testDefaultsKeysAreExact() {
        XCTAssertEqual(ModelPreference.defaultsKey(for: .stt), "kiki.sttModel")
        XCTAssertEqual(ModelPreference.defaultsKey(for: .refine), "kiki.refineModel")
    }
}
