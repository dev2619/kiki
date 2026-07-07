import XCTest
@testable import KikiStore
@testable import KikiCore

@MainActor
final class DictionaryAdapterTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        let uuid = UUID().uuidString
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(uuid)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInitialSnapshotReflectsExistingStoreContents() {
        let store = DictionaryStore(directory: tempDir)
        store.add("hello")
        let adapter = DictionaryAdapter(store: store)

        XCTAssertEqual(adapter.terms(), ["hello"])
    }

    func testAddUpdatesSnapshotAndPersistsToStore() {
        let store = DictionaryStore(directory: tempDir)
        let adapter = DictionaryAdapter(store: store)

        adapter.add("world")

        XCTAssertEqual(adapter.terms(), ["world"])
        XCTAssertEqual(store.terms, ["world"])
    }

    func testRemoveUpdatesSnapshot() {
        let store = DictionaryStore(directory: tempDir)
        let adapter = DictionaryAdapter(store: store)
        adapter.add("hello")
        adapter.add("world")

        adapter.remove("hello")

        XCTAssertEqual(adapter.terms(), ["world"])
    }

    func testTermsIsSafeToCallFromABackgroundThread() {
        let store = DictionaryStore(directory: tempDir)
        let adapter = DictionaryAdapter(store: store)
        adapter.add("hello")

        let expectation = expectation(description: "background terms() read")
        DispatchQueue.global().async {
            // Simula el hilo del actor STT / executor concurrente del refiner:
            // terms() debe poder leerse fuera de MainActor sin crashear ni
            // devolver datos corruptos.
            let result = adapter.terms()
            XCTAssertEqual(result, ["hello"])
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }
}

final class SnippetAdapterTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        let uuid = UUID().uuidString
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(uuid)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExpandMatchesTriggerCaseAndAccentInsensitively() {
        let store = SnippetStore(directory: tempDir)
        store.add(Snippet(trigger: "café con leche", template: "☕️🥛"))
        let adapter = SnippetAdapter(store: store)

        XCTAssertEqual(adapter.expand("Café Con Leche"), "☕️🥛")
        XCTAssertEqual(adapter.expand("cafe con leche."), "☕️🥛")
    }

    func testExpandReturnsNilWhenNoTriggerMatches() {
        let store = SnippetStore(directory: tempDir)
        store.add(Snippet(trigger: "firma", template: "Saludos, Ana"))
        let adapter = SnippetAdapter(store: store)

        XCTAssertNil(adapter.expand("esto no es un trigger"))
    }
}

final class HistoryAdapterTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        let uuid = UUID().uuidString
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(uuid)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRecordAppendsToStoreWithProfileRawValue() {
        let store = HistoryStore(directory: tempDir)
        let adapter = HistoryAdapter(store: store)

        adapter.record(HistoryRecord(rawText: "raw", finalText: "final", profile: .email, audioSeconds: 1.5))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.rawText, "raw")
        XCTAssertEqual(store.entries.first?.finalText, "final")
        XCTAssertEqual(store.entries.first?.profile, "email")
        XCTAssertEqual(store.entries.first?.audioSeconds, 1.5)
    }
}
