import XCTest
import AppKit
@testable import KikiInsert

final class ClipboardManagerTests: XCTestCase {
    // Pasteboard con nombre propio: los tests NO tocan el clipboard real del usuario.
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.dev2619.kiki.tests"))
        pasteboard.clearContents()
    }

    func test_snapshotAndRestoreString() {
        ClipboardManager.setString("contenido original", on: pasteboard)
        let snapshot = ClipboardManager.snapshot(of: pasteboard)

        ClipboardManager.setString("texto dictado", on: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "texto dictado")

        ClipboardManager.restore(snapshot, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "contenido original")
    }

    func test_restoreEmptySnapshotLeavesPasteboardEmpty() {
        let emptySnapshot = ClipboardManager.snapshot(of: pasteboard)
        ClipboardManager.setString("algo", on: pasteboard)
        ClipboardManager.restore(emptySnapshot, to: pasteboard)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func test_snapshotPreservesMultipleTypes() {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("texto plano", forType: .string)
        item.setData(Data([0x01, 0x02]), forType: NSPasteboard.PasteboardType("com.dev2619.kiki.custom"))
        pasteboard.writeObjects([item])

        let snapshot = ClipboardManager.snapshot(of: pasteboard)
        ClipboardManager.setString("sobrescrito", on: pasteboard)
        ClipboardManager.restore(snapshot, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "texto plano")
        XCTAssertEqual(
            pasteboard.data(forType: NSPasteboard.PasteboardType("com.dev2619.kiki.custom")),
            Data([0x01, 0x02]))
    }

    func test_setStringReplacesContents() {
        ClipboardManager.setString("uno", on: pasteboard)
        ClipboardManager.setString("dos", on: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "dos")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }
}
