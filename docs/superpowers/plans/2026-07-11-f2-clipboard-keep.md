# F2 — Transcripción al clipboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Después de dictar, la transcripción queda en el portapapeles (además de insertarse en el cursor); restaurar el clipboard anterior pasa a ser un toggle opcional apagado por defecto.

**Architecture:** `PasteInserter` (KikiInsert) gana dos seams inyectables: `restoresClipboard: () -> Bool` (leído en cada insert, para que el toggle aplique en caliente) y `sendPaste: () throws -> Void` (default = Cmd+V sintético; inyectable para poder testear el flujo de restore sin postear eventos reales). El toggle vive en `SettingsViewModel` con el patrón @Published+UserDefaults existente y `AppDelegate` cablea la preferencia al construir el inserter.

**Tech Stack:** Swift 5.10, SPM, XCTest, AppKit (NSPasteboard).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-11-cuatro-features-v1-design.md` §F2
- Default nuevo: la transcripción QUEDA en el clipboard (restore OFF por defecto)
- UserDefaults key: `kiki.restoreClipboard` (sigue el naming `kiki.*` existente: `kiki.alwaysListening`, `kiki.historyCap`)
- Tests SIEMPRE con pasteboard nombrado (`NSPasteboard(name:)`), nunca `.general`
- Tests: `swift test` (o `make test`); el binario de app se buildea con `make build` (xcodebuild — Cmlx/Metal)
- Git: rama `feature/clipboard-keep` desde main; Conventional Commits; sin `Co-Authored-By`; stage por filename
- Versión final: `0.9.2` (CFBundleShortVersionString), CFBundleVersion `3`

---

### Task 1: PasteInserter — seams inyectables + comportamiento keep-by-default (TDD)

**Files:**
- Modify: `Sources/KikiInsert/PasteInserter.swift`
- Test: `Tests/KikiInsertTests/PasteInserterTests.swift` (nuevo archivo; los tests existentes de `ClipboardManagerTests.swift` no se tocan)

**Interfaces:**
- Consumes: `ClipboardManager.snapshot/setString/restore` (existentes, sin cambios), `DictationError.insertionFailed`.
- Produces: `PasteInserter.init(pasteboard: NSPasteboard = .general, restoreDelay: TimeInterval = 0.4, restoresClipboard: @escaping () -> Bool = { false }, sendPaste: (() throws -> Void)? = nil)` — Task 2 usa `restoresClipboard`.

- [ ] **Step 1: Escribir los tests que fallan**

`Tests/KikiInsertTests/PasteInserterTests.swift`:
```swift
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
```

- [ ] **Step 2: Correr los tests para verificar que fallan**

Run: `cd /Users/jarvis/Documents/gitHub/kiki && swift test --filter PasteInserterTests 2>&1 | tail -5`
Expected: error de compilación — `PasteInserter.init` no tiene los parámetros `restoresClipboard`/`sendPaste`.

- [ ] **Step 3: Implementar**

`Sources/KikiInsert/PasteInserter.swift` (reemplazo completo del archivo):
```swift
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
```

- [ ] **Step 4: Correr los tests para verificar que pasan**

Run: `swift test --filter PasteInserterTests 2>&1 | tail -3`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 5: Suite completa**

Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1`
Expected: 0 failures (los gated siguen skipped).

- [ ] **Step 6: Commit**

```bash
git add Sources/KikiInsert/PasteInserter.swift Tests/KikiInsertTests/PasteInserterTests.swift
git commit -m "feat(insert): keep transcription in clipboard by default with injectable restore"
```

---

### Task 2: Toggle en Ajustes + cableo en AppDelegate

**Files:**
- Modify: `Sources/Kiki/SettingsViewModel.swift` (nueva @Published + key, junto a `alwaysListening`)
- Modify: `Sources/Kiki/SettingsWindow.swift` (nueva Section en el Form, después de la Section "Traducir al dictar")
- Modify: `Sources/Kiki/AppDelegate.swift:165` (construcción de `PasteInserter`)

**Interfaces:**
- Consumes: `PasteInserter.init(restoresClipboard:)` de Task 1.
- Produces: `SettingsViewModel.restoreClipboardDefaultsKey` (`nonisolated static let`, valor `"kiki.restoreClipboard"`).

- [ ] **Step 1: Agregar la propiedad al SettingsViewModel**

En `Sources/Kiki/SettingsViewModel.swift`, junto a `alwaysListening` (después de su bloque, ~línea 164), agregar:

```swift
    /// F2 (spec 2026-07-11): tras dictar, la transcripción queda en el
    /// clipboard por defecto. Este toggle opt-in restaura el contenido
    /// anterior del clipboard ~0.4s después del paste (comportamiento
    /// pre-0.9.2). Sin efectos de ciclo de vida: `PasteInserter` lee la
    /// preferencia en cada insert vía closure, así que el cambio aplica
    /// en caliente sin notificaciones.
    @Published var restoreClipboardAfterDictation: Bool {
        didSet {
            UserDefaults.standard.set(
                restoreClipboardAfterDictation, forKey: Self.restoreClipboardDefaultsKey)
        }
    }

    /// `nonisolated`: `AppDelegate` construye el `PasteInserter` (y su
    /// closure lee esta key) fuera del init de SettingsViewModel.
    nonisolated static let restoreClipboardDefaultsKey = "kiki.restoreClipboard"
```

En el `init` de `SettingsViewModel`, junto a la inicialización de las demás @Published desde UserDefaults (buscar donde se inicializa `alwaysListening`), agregar siguiendo el mismo patrón exacto del archivo:

```swift
        self.restoreClipboardAfterDictation =
            UserDefaults.standard.bool(forKey: Self.restoreClipboardDefaultsKey)
```

(Default `false` = keep in clipboard; `bool(forKey:)` de una key inexistente ya devuelve `false`, no hace falta register.)

- [ ] **Step 2: Agregar la Section al SettingsWindow**

En `Sources/Kiki/SettingsWindow.swift`, después de la `Section` del toggle "Traducir al dictar" (~línea 196), agregar:

```swift
            Section {
                Toggle("Restaurar clipboard anterior tras dictar", isOn: $viewModel.restoreClipboardAfterDictation)
            } footer: {
                Text("Con esto desactivado (por defecto), el texto dictado queda en tu portapapeles después de insertarse — listo para pegarlo con ⌘V en cualquier otro lado. Actívalo si prefieres que kiki devuelva al portapapeles lo que tenías copiado antes de dictar.")
            }
```

- [ ] **Step 3: Cablear la preferencia en AppDelegate**

En `Sources/Kiki/AppDelegate.swift` línea ~165, cambiar:

```swift
            inserter: PasteInserter(),
```

por:

```swift
            inserter: PasteInserter(restoresClipboard: {
                UserDefaults.standard.bool(forKey: SettingsViewModel.restoreClipboardDefaultsKey)
            }),
```

- [ ] **Step 4: Build de app + suite**

Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1 && make build 2>&1 | tail -2`
Expected: 0 failures y `BUILD SUCCEEDED` (xcodebuild).

- [ ] **Step 5: Verificación manual mínima**

Run: `make run` — en Ajustes debe aparecer la nueva sección con el toggle apagado; dictar algo y verificar con ⌘V en otra app que la transcripción quedó en el clipboard; activar el toggle, dictar de nuevo y verificar que el clipboard vuelve a lo anterior.

- [ ] **Step 6: Commit**

```bash
git add Sources/Kiki/SettingsViewModel.swift Sources/Kiki/SettingsWindow.swift Sources/Kiki/AppDelegate.swift
git commit -m "feat(app): settings toggle to restore clipboard after dictation (default keep)"
```

---

### Task 3: Versión 0.9.2 + release notes

**Files:**
- Modify: `App/Info.plist` (CFBundleShortVersionString `0.9.1`→`0.9.2`, CFBundleVersion `2`→`3`)
- Modify: `docs/RELEASE_NOTES.md` (reescribir para 0.9.2, mismo formato del 0.9.1)

**Interfaces:**
- Consumes: todo lo anterior mergeado en la rama.
- Produces: release listo para `make dmg` + tag `v0.9.2`.

- [ ] **Step 1: Bump de versión en App/Info.plist**

Cambiar `<string>0.9.1</string>` (CFBundleShortVersionString) por `<string>0.9.2</string>` y `<string>2</string>` (CFBundleVersion) por `<string>3</string>`.

- [ ] **Step 2: Release notes**

Reescribir `docs/RELEASE_NOTES.md` con el encabezado `# kiki 0.9.2` y la sección de novedades:

```markdown
# kiki 0.9.2

Dictado por voz con IA, 100% local, para macOS (Apple Silicon).

## ✨ Novedades de esta versión

### La transcripción queda en tu portapapeles
Después de dictar, el texto se inserta donde está el cursor **y queda copiado en el portapapeles** — pégalo con ⌘V en cualquier otra app sin volver a dictar.
- Nuevo interruptor **"Restaurar clipboard anterior tras dictar"** (Ajustes): actívalo si prefieres el comportamiento anterior (kiki devolvía al portapapeles lo que tenías copiado antes de dictar).
```

Y conservar la sección "## 📦 Instalación" del 0.9.1 tal cual (mismos 4 pasos), actualizando el nombre del .dmg a `kiki-0.9.2.dmg`.

- [ ] **Step 3: Verificación final**

Run: `swift test 2>&1 | grep -E "Executed .* tests" | tail -1 && make bundle 2>&1 | tail -1`
Expected: 0 failures, `OK → build/kiki.app` (o equivalente del Makefile actual).

- [ ] **Step 4: Commit**

```bash
git add App/Info.plist docs/RELEASE_NOTES.md
git commit -m "chore: bump version to 0.9.2 (transcription stays in clipboard)"
```

---

## Self-review (hecho al escribir el plan)

- **Cobertura del spec §F2:** keep por defecto ✅ (Task 1), toggle OFF default con key `kiki.restoreClipboard` ✅ (Task 2), tests con pasteboard nombrado ✅ (Task 1), consistencia con fallo de paste ✅ (Task 1 test 4), bump 0.9.2 + notes ✅ (Task 3).
- **Placeholders:** ninguno.
- **Consistencia de tipos:** `restoresClipboard: @escaping () -> Bool` idéntico en Task 1 (init) y Task 2 (cableo); key `kiki.restoreClipboard` idéntica en ViewModel y AppDelegate (vía la constante, no string duplicado).
