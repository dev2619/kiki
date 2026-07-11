import XCTest
import AppKit
@testable import KikiInsert
import KikiCore

final class PasteInserterTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.dev2619.kiki.inserter-tests"))
        pasteboard.clearContents()
    }

    private func makeInserter(
        restores: Bool,
        sendPaste: @escaping () throws -> Void = {}
    ) -> PasteInserter {
        PasteInserter(
            pasteboard: pasteboard,
            restoreDelay: 0.05,
            restoresClipboard: { restores },
            sendPaste: sendPaste)
    }

    func test_defaultKeepsTranscriptionInClipboard() throws {
        ClipboardManager.setString("contenido anterior", on: pasteboard)
        let inserter = makeInserter(restores: false)

        try inserter.insert("texto dictado")

        // Tras el delay de restore, la transcripción SIGUE en el clipboard.
        let expectation = expectation(description: "post-delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "texto dictado")
    }

    func test_restoreToggleRestoresPreviousClipboard() throws {
        ClipboardManager.setString("contenido anterior", on: pasteboard)
        let inserter = makeInserter(restores: true)

        try inserter.insert("texto dictado")
        // Inmediatamente después del paste, la transcripción está en el clipboard.
        XCTAssertEqual(pasteboard.string(forType: .string), "texto dictado")

        let expectation = expectation(description: "post-delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "contenido anterior")
    }

    func test_toggleIsReadPerInsertNotAtInit() throws {
        // El closure se evalúa en cada insert: cambiar el setting aplica en caliente.
        var restores = false
        let inserter = PasteInserter(
            pasteboard: pasteboard,
            restoreDelay: 0.05,
            restoresClipboard: { restores },
            sendPaste: {})

        ClipboardManager.setString("previo-1", on: pasteboard)
        try inserter.insert("dictado-1")
        let first = expectation(description: "first")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { first.fulfill() }
        wait(for: [first], timeout: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictado-1")

        restores = true
        ClipboardManager.setString("previo-2", on: pasteboard)
        try inserter.insert("dictado-2")
        let second = expectation(description: "second")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { second.fulfill() }
        wait(for: [second], timeout: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "previo-2")
    }

    func test_pasteFailureLeavesTextInClipboardEvenWithRestoreOn() throws {
        ClipboardManager.setString("contenido anterior", on: pasteboard)
        let inserter = makeInserter(restores: true, sendPaste: {
            throw DictationError.insertionFailed("simulado")
        })

        XCTAssertThrowsError(try inserter.insert("texto dictado"))

        // Falla de paste: el texto queda en el clipboard (spec §7) y NO se restaura.
        let expectation = expectation(description: "post-delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "texto dictado")
    }
}
