import XCTest
@testable import KikiStore
@testable import KikiCore

final class DictionaryStoreTests: XCTestCase {
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

    func testRoundTripPersistence() {
        let store1 = DictionaryStore(directory: tempDir)
        store1.add("hello")
        store1.add("world")

        let store2 = DictionaryStore(directory: tempDir)
        XCTAssertEqual(store2.terms.sorted(), ["hello", "world"])
    }

    func testAddDuplicateIsNoOp() {
        let store = DictionaryStore(directory: tempDir)
        store.add("hello")
        store.add("hello")
        store.add("HELLO")
        store.add("  HELLO  ")

        XCTAssertEqual(store.terms.count, 1)
        XCTAssertTrue(store.terms.contains("hello"))
    }

    func testRemove() {
        let store = DictionaryStore(directory: tempDir)
        store.add("hello")
        store.add("world")
        store.remove("hello")

        XCTAssertEqual(store.terms, ["world"])
    }

    func testRemoveNonExistentIsNoOp() {
        let store = DictionaryStore(directory: tempDir)
        store.add("hello")
        store.remove("nonexistent")

        XCTAssertEqual(store.terms, ["hello"])
    }

    func testCorruptFileReturnsEmpty() {
        let fileURL = tempDir.appendingPathComponent("dictionary.json")
        try? "not valid json {{{".data(using: .utf8)?.write(to: fileURL)

        let store = DictionaryStore(directory: tempDir)
        XCTAssertEqual(store.terms, [])
    }

    func testEmptyStoreIsEmpty() {
        let store = DictionaryStore(directory: tempDir)
        XCTAssertEqual(store.terms, [])
    }
}

final class SnippetStoreTests: XCTestCase {
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

    func testRoundTripPersistence() {
        let snippet1 = Snippet(trigger: "mysnip", template: "hello world")
        let snippet2 = Snippet(trigger: "test", template: "test template")

        let store1 = SnippetStore(directory: tempDir)
        store1.add(snippet1)
        store1.add(snippet2)

        let store2 = SnippetStore(directory: tempDir)
        XCTAssertEqual(store2.snippets.count, 2)
        XCTAssertTrue(store2.snippets.contains(snippet1))
        XCTAssertTrue(store2.snippets.contains(snippet2))
    }

    func testAddDuplicateTriggerIsNoOp() {
        let snippet1 = Snippet(trigger: "mysnip", template: "first")
        let snippet2 = Snippet(trigger: "MYSNIP", template: "second")
        let snippet3 = Snippet(trigger: "  mysnip  ", template: "third")

        let store = SnippetStore(directory: tempDir)
        store.add(snippet1)
        store.add(snippet2)
        store.add(snippet3)

        XCTAssertEqual(store.snippets.count, 1)
        // First one should be kept
        XCTAssertTrue(store.snippets.contains(snippet1))
    }

    func testRemove() {
        let snippet1 = Snippet(trigger: "mysnip", template: "first")
        let snippet2 = Snippet(trigger: "test", template: "second")

        let store = SnippetStore(directory: tempDir)
        store.add(snippet1)
        store.add(snippet2)
        store.remove(trigger: "mysnip")

        XCTAssertEqual(store.snippets.count, 1)
        XCTAssertTrue(store.snippets.contains(snippet2))
    }

    func testRemoveNonExistentIsNoOp() {
        let snippet = Snippet(trigger: "mysnip", template: "test")
        let store = SnippetStore(directory: tempDir)
        store.add(snippet)
        store.remove(trigger: "nonexistent")

        XCTAssertEqual(store.snippets.count, 1)
    }

    func testCorruptFileReturnsEmpty() {
        let fileURL = tempDir.appendingPathComponent("snippets.json")
        try? "not valid json {{{".data(using: .utf8)?.write(to: fileURL)

        let store = SnippetStore(directory: tempDir)
        XCTAssertEqual(store.snippets, [])
    }

    func testEmptyStoreIsEmpty() {
        let store = SnippetStore(directory: tempDir)
        XCTAssertEqual(store.snippets, [])
    }
}

final class HistoryStoreTests: XCTestCase {
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

    func testRoundTripPersistence() {
        let entry1 = HistoryEntry(date: Date(), rawText: "raw1", finalText: "final1", profile: "default", audioSeconds: 1.0)
        let entry2 = HistoryEntry(date: Date(), rawText: "raw2", finalText: "final2", profile: "default", audioSeconds: 2.0)

        let store1 = HistoryStore(directory: tempDir)
        store1.append(entry1)
        store1.append(entry2)

        let store2 = HistoryStore(directory: tempDir)
        XCTAssertEqual(store2.entries.count, 2)
    }

    func testDefaultCapIs200() {
        let store = HistoryStore(directory: tempDir)
        XCTAssertEqual(store.cap, 200)
    }

    func testCustomCap() {
        let store = HistoryStore(directory: tempDir, cap: 100)
        XCTAssertEqual(store.cap, 100)
    }

    func testHistoryCap() {
        let store = HistoryStore(directory: tempDir, cap: 10)

        // Add 15 entries
        for i in 0..<15 {
            let entry = HistoryEntry(
                date: Date().addingTimeInterval(Double(i)),
                rawText: "raw\(i)",
                finalText: "final\(i)",
                profile: "default",
                audioSeconds: Double(i)
            )
            store.append(entry)
        }

        XCTAssertEqual(store.entries.count, 10)
        // Should keep the NEWEST entries (5-14)
        XCTAssertEqual(store.entries.first?.rawText, "raw5")
        XCTAssertEqual(store.entries.last?.rawText, "raw14")
    }

    func testHistoryCapPersists() {
        let store1 = HistoryStore(directory: tempDir, cap: 5)

        for i in 0..<10 {
            let entry = HistoryEntry(
                date: Date().addingTimeInterval(Double(i)),
                rawText: "raw\(i)",
                finalText: "final\(i)",
                profile: "default",
                audioSeconds: Double(i)
            )
            store1.append(entry)
        }

        let store2 = HistoryStore(directory: tempDir, cap: 5)
        XCTAssertEqual(store2.entries.count, 5)
        XCTAssertEqual(store2.entries.first?.rawText, "raw5")
        XCTAssertEqual(store2.entries.last?.rawText, "raw9")
    }

    func testClear() {
        let store = HistoryStore(directory: tempDir)
        let entry = HistoryEntry(date: Date(), rawText: "raw", finalText: "final", profile: "default", audioSeconds: 1.0)
        store.append(entry)
        store.clear()

        XCTAssertEqual(store.entries, [])
    }

    func testClearPersists() {
        let store1 = HistoryStore(directory: tempDir)
        let entry = HistoryEntry(date: Date(), rawText: "raw", finalText: "final", profile: "default", audioSeconds: 1.0)
        store1.append(entry)
        store1.clear()

        let store2 = HistoryStore(directory: tempDir)
        XCTAssertEqual(store2.entries, [])
    }

    func testCorruptFileReturnsEmpty() {
        let fileURL = tempDir.appendingPathComponent("history.json")
        try? "not valid json {{{".data(using: .utf8)?.write(to: fileURL)

        let store = HistoryStore(directory: tempDir)
        XCTAssertEqual(store.entries, [])
    }

    func testEmptyStoreIsEmpty() {
        let store = HistoryStore(directory: tempDir)
        XCTAssertEqual(store.entries, [])
    }
}
