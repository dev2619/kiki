import AppKit
import KikiCore

/// Inserta texto en la app activa: pone el texto en el clipboard y
/// sintetiza Cmd+V. Por defecto la transcripción QUEDA en el clipboard
/// (F2, spec 2026-07-11) lista para pegar en otro lado; restaurar el
/// clipboard anterior es opt-in vía `restoresClipboard` (toggle en Ajustes,
/// leído en cada insert para que el cambio aplique en caliente).
public final class PasteInserter: TextInserting {
    private let pasteboard: NSPasteboard
    private let restoreDelay: TimeInterval
    private let restoresClipboard: () -> Bool
    private let sendPaste: () throws -> Void

    /// - Parameters:
    ///   - restoresClipboard: se evalúa en cada `insert`; `true` restaura el
    ///     clipboard anterior tras `restoreDelay`. Default `false` (keep).
    ///   - sendPaste: seam de test para el Cmd+V sintético; `nil` = real.
    public init(
        pasteboard: NSPasteboard = .general,
        restoreDelay: TimeInterval = 0.4,
        restoresClipboard: @escaping () -> Bool = { false },
        sendPaste: (() throws -> Void)? = nil
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.restoresClipboard = restoresClipboard
        self.sendPaste = sendPaste ?? PasteInserter.synthesizeCmdV
    }

    public func insert(_ text: String) throws {
        let snapshot = ClipboardManager.snapshot(of: pasteboard)
        ClipboardManager.setString(text, on: pasteboard)
        // Si el paste falla, el texto queda en el clipboard (spec §7) para
        // pegarlo a mano — por eso no hay restore en el camino de error.
        try sendPaste()
        guard restoresClipboard() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [pasteboard] in
            ClipboardManager.restore(snapshot, to: pasteboard)
        }
    }

    private static func synthesizeCmdV() throws {
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
