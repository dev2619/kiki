import AppKit
import KikiCore

/// Inserta texto en la app activa: pone el texto en el clipboard,
/// sintetiza Cmd+V y restaura el clipboard original tras un delay.
public final class PasteInserter: TextInserting {
    private let pasteboard: NSPasteboard
    private let restoreDelay: TimeInterval

    public init(pasteboard: NSPasteboard = .general, restoreDelay: TimeInterval = 0.4) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
    }

    public func insert(_ text: String) throws {
        let snapshot = ClipboardManager.snapshot(of: pasteboard)
        ClipboardManager.setString(text, on: pasteboard)
        do {
            try synthesizeCmdV()
        } catch {
            // Falló el paste: dejamos el texto en el clipboard (spec §7)
            // para que el usuario pueda pegarlo a mano. No restauramos.
            throw error
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [pasteboard] in
            ClipboardManager.restore(snapshot, to: pasteboard)
        }
    }

    private func synthesizeCmdV() throws {
        let vKeyCode: CGKeyCode = 9
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            throw DictationError.insertionFailed("no se pudo crear el CGEvent de Cmd+V")
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
