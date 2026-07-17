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
        copy: Bool,
        paste: Bool,
        sendPaste: @escaping () throws -> Void = {}
    ) -> PasteInserter {
        PasteInserter(
            pasteboard: pasteboard,
            restoreDelay: 0.05,
            copyEnabled: { copy },
            autoPasteEnabled: { paste },
            sendPaste: sendPaste)
    }

    private func waitABit() {
        let expectation = expectation(description: "post-delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
    }

    // Combinación por defecto: pegar + copiar → el texto queda en el clipboard.
    func test_pasteAndCopy_keepsTranscriptionInClipboard() throws {
        ClipboardManager.setString("contenido anterior", on: pasteboard)
        var pasteCount = 0
        let inserter = makeInserter(copy: true, paste: true, sendPaste: { pasteCount += 1 })

        try inserter.insert("texto dictado")

        XCTAssertEqual(pasteCount, 1, "debe pegar con ⌘V")
        waitABit()
        XCTAssertEqual(pasteboard.string(forType: .string), "texto dictado")
    }

    // Pegar sin dejar rastro (copy off): pega y restaura el clipboard previo.
    func test_pasteWithoutCopy_restoresPreviousClipboard() throws {
        ClipboardManager.setString("contenido anterior", on: pasteboard)
        let inserter = makeInserter(copy: false, paste: true)

        try inserter.insert("texto dictado")
        // Justo tras el paste, la transcripción está en el clipboard (para ⌘V).
        XCTAssertEqual(pasteboard.string(forType: .string), "texto dictado")

        waitABit()
        XCTAssertEqual(pasteboard.string(forType: .string), "contenido anterior")
    }

    // Solo copiar (paste off): deja el texto en el clipboard, sin ⌘V.
    func test_copyOnly_setsClipboardWithoutPasting() throws {
        ClipboardManager.setString("contenido anterior", on: pasteboard)
        var pasteCount = 0
        let inserter = makeInserter(copy: true, paste: false, sendPaste: { pasteCount += 1 })

        try inserter.insert("texto dictado")

        XCTAssertEqual(pasteCount, 0, "no debe sintetizar ⌘V")
        waitABit()
        XCTAssertEqual(pasteboard.string(forType: .string), "texto dictado")
    }

    // Ninguno: no toca clipboard ni cursor.
    func test_neither_leavesClipboardUntouched() throws {
        ClipboardManager.setString("contenido anterior", on: pasteboard)
        var pasteCount = 0
        let inserter = makeInserter(copy: false, paste: false, sendPaste: { pasteCount += 1 })

        try inserter.insert("texto dictado")

        XCTAssertEqual(pasteCount, 0)
        waitABit()
        XCTAssertEqual(pasteboard.string(forType: .string), "contenido anterior")
    }

    // Los toggles se leen en CADA insert (aplican en caliente).
    func test_togglesReadPerInsert() throws {
        var copy = true
        let inserter = PasteInserter(
            pasteboard: pasteboard,
            restoreDelay: 0.05,
            copyEnabled: { copy },
            autoPasteEnabled: { true },
            sendPaste: {})

        ClipboardManager.setString("previo-1", on: pasteboard)
        try inserter.insert("dictado-1")
        waitABit()
        XCTAssertEqual(pasteboard.string(forType: .string), "dictado-1", "copy on → queda")

        copy = false
        ClipboardManager.setString("previo-2", on: pasteboard)
        try inserter.insert("dictado-2")
        waitABit()
        XCTAssertEqual(pasteboard.string(forType: .string), "previo-2", "copy off → restaura")
    }

    // Falla de paste con copy off: el texto queda en el clipboard (spec §7) y
    // NO se restaura (para no perderlo).
    func test_pasteFailureLeavesTextInClipboard() throws {
        ClipboardManager.setString("contenido anterior", on: pasteboard)
        let inserter = makeInserter(copy: false, paste: true, sendPaste: {
            throw DictationError.insertionFailed("simulado")
        })

        XCTAssertThrowsError(try inserter.insert("texto dictado"))

        waitABit()
        XCTAssertEqual(pasteboard.string(forType: .string), "texto dictado")
    }
}
