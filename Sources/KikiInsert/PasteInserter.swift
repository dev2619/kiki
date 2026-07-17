import AppKit
import KikiCore

/// Inserta el texto dictado según dos toggles independientes, ambos leídos
/// en CADA `insert` (aplican en caliente):
///
/// - `copyEnabled` ("Copiar al portapapeles"): si el texto QUEDA en el
///   portapapeles tras dictar.
/// - `autoPasteEnabled` ("Pegar automáticamente"): si se sintetiza ⌘V para
///   insertarlo en la app activa.
///
/// Las 4 combinaciones (2026-07-16, reemplaza al viejo `restoresClipboard`):
/// - pegar + copiar (default): ⌘V y el texto queda en el portapapeles.
/// - solo copiar: queda en el portapapeles, sin ⌘V (el usuario pega a mano).
/// - pegar sin dejar rastro: se pega con ⌘V y se RESTAURA el portapapeles
///   anterior (el texto no queda). Es el único caso que toma snapshot.
/// - ninguno: no toca portapapeles ni cursor (el transcript igual va a
///   Historial en la capa superior).
public final class PasteInserter: TextInserting {
    private let pasteboard: NSPasteboard
    private let restoreDelay: TimeInterval
    private let copyEnabled: () -> Bool
    private let autoPasteEnabled: () -> Bool
    private let sendPaste: () throws -> Void

    /// - Parameters:
    ///   - copyEnabled: se evalúa en cada `insert`; `true` deja el texto en el
    ///     portapapeles. Default `true`.
    ///   - autoPasteEnabled: se evalúa en cada `insert`; `true` sintetiza ⌘V.
    ///     Default `true`.
    ///   - sendPaste: seam de test para el Cmd+V sintético; `nil` = real.
    public init(
        pasteboard: NSPasteboard = .general,
        restoreDelay: TimeInterval = 0.4,
        copyEnabled: @escaping () -> Bool = { true },
        autoPasteEnabled: @escaping () -> Bool = { true },
        sendPaste: (() throws -> Void)? = nil
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.copyEnabled = copyEnabled
        self.autoPasteEnabled = autoPasteEnabled
        self.sendPaste = sendPaste ?? PasteInserter.synthesizeCmdV
    }

    public func insert(_ text: String) throws {
        let keep = copyEnabled()
        let paste = autoPasteEnabled()

        // Ni copiar ni pegar: nada que hacer con portapapeles/cursor (el
        // transcript igual queda en Historial en la capa superior).
        guard keep || paste else { return }

        guard paste else {
            // Solo copiar: dejar el texto en el portapapeles, sin ⌘V.
            ClipboardManager.setString(text, on: pasteboard)
            return
        }

        // Pegar: hace falta el texto en el portapapeles para el ⌘V. El
        // snapshot SOLO se toma si hay que restaurar (keep == false) — evita
        // la copia profunda del portapapeles (imágenes/archivos) en el caso
        // común (perezoso, 1d).
        let snapshot = keep ? nil : ClipboardManager.snapshot(of: pasteboard)
        ClipboardManager.setString(text, on: pasteboard)
        // Si el paste falla, el texto queda en el portapapeles (spec §7) para
        // pegarlo a mano — el throw evita el restore de abajo, así no se pierde.
        try sendPaste()
        if let snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { [pasteboard] in
                ClipboardManager.restore(snapshot, to: pasteboard)
            }
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
