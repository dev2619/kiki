import AppKit

/// Copia inmutable del contenido del pasteboard, para restaurar
/// el clipboard del usuario después de pegar el dictado.
public struct ClipboardSnapshot {
    public let items: [[NSPasteboard.PasteboardType: Data]]
}

public enum ClipboardManager {
    public static func snapshot(of pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { entry, type in
                if let data = item.data(forType: type) { entry[type] = data }
            }
        }
        return ClipboardSnapshot(items: items)
    }

    public static func restore(_ snapshot: ClipboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    public static func setString(_ string: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
