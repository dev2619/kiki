# kiki Fase 3 — "Personalización" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ventana de Ajustes con: diccionario personal (inyectado en Whisper y en el LLM), snippets de voz (trigger hablado → plantilla, expansión determinística), e historial de dictados (crudo vs final, copiable). Persistencia local en JSON.

**Architecture:** módulo nuevo `KikiStore` (stores Codable con escritura atómica a `~/Library/Application Support/kiki/`). El diccionario fluye a `WhisperTranscriber` (initial prompt) y a `RefinePrompt` (lista de términos). Los snippets se expanden con matching determinístico ANTES del LLM (pre-pass en el pipeline del controller). El historial se registra al insertar texto, vía protocolo opcional del controller. UI: ventana SwiftUI simple con secciones.

**DECISIÓN (default de calidad, enmienda al spec §4):** KikiStore usa **JSON con escritura atómica** en vez de SQLite — volúmenes v1 diminutos (decenas de términos/snippets, historial cap 200), cero dependencias, testeable puro. SQLite queda como evolución si el historial crece. Historial persistido LOCAL únicamente, cap 200 entradas (privacidad: borrable desde la UI con un botón).

**Tech Stack:** Swift, SwiftUI (ventana settings), FileManager/Codable, XCTest. Sin dependencias nuevas.

## Global Constraints

- Los heredados: 16kHz, KikiLog, Conventional Commits sin Co-Authored-By, stage por filename, firma kiki-dev, build xcodebuild vía Makefile, suite verde antes de cada commit (base actual: 132 executed / 4 skipped)
- Directorio de datos: `~/Library/Application Support/kiki/` (crear si falta) — archivos `dictionary.json`, `snippets.json`, `history.json`
- Escritura atómica: `Data.write(to:options:.atomic)`; lecturas toleran archivo ausente/corrupto (→ estado vacío + KikiLog, nunca crash)
- Historial: cap **200** entradas (FIFO), campos: fecha ISO8601, texto crudo, texto final, perfil, duración de audio en segundos
- Diccionario: lista de términos (strings); inyección Whisper vía initial prompt; inyección LLM como línea adicional del system prompt
- Snippets: `trigger` (frase hablada) → `template` (texto a insertar); matching determinístico normalizado (mismas reglas de normalización que WakePhraseMatcher: lowercase + sin acentos + sin puntuación); si el dictado ENTERO (normalizado) coincide con un trigger → se inserta la plantilla SIN pasar por el LLM
- Trabajar en rama `feature/fase-3-personalizacion`

## File Structure

```
Sources/
├── KikiStore/
│   ├── Models.swift              — DictionaryEntry(término), Snippet(trigger, template), HistoryEntry
│   ├── JSONStore.swift           — genérico: load/save atómico Codable con tolerancia a corrupción
│   └── Stores.swift              — DictionaryStore, SnippetStore, HistoryStore (API tipada sobre JSONStore)
├── KikiCore/
│   ├── Protocols.swift           — MODIFICAR: + HistoryRecording + SnippetExpanding + DictionaryProviding
│   └── DictationController.swift — MODIFICAR: snippet pre-pass + history hook
├── KikiSTT/WhisperTranscriber.swift — MODIFICAR: initial prompt con términos del diccionario
├── KikiRefine/RefinePrompt.swift — MODIFICAR: términos del diccionario en el system prompt
├── KikiWake/… (sin cambios)
└── Kiki/
    ├── SettingsWindow.swift      — ventana SwiftUI (secciones General/Diccionario/Snippets/Historial)
    └── AppDelegate.swift         — MODIFICAR: item de menú "Ajustes…", cableo stores
Tests/
├── KikiStoreTests/ (JSONStore + stores, con directorio temporal)
├── KikiCoreTests/DictationControllerTests.swift (+ snippet pre-pass + history hook)
└── KikiRefineTests/RefinePromptTests.swift (+ términos)
```

Nota de diseño: los protocolos (`HistoryRecording`, `SnippetExpanding`, `DictionaryProviding`) viven en KikiCore; KikiStore/adaptadores los implementan — mismo patrón de las fases anteriores. Firmas exactas:

```swift
public struct HistoryRecord: Equatable {
    public let rawText: String
    public let finalText: String
    public let profile: AppProfile
    public let audioSeconds: Double
    public init(rawText: String, finalText: String, profile: AppProfile, audioSeconds: Double)
}
public protocol HistoryRecording: AnyObject {
    func record(_ entry: HistoryRecord)   // síncrono; la persistencia interna puede ser async
}
public protocol SnippetExpanding: AnyObject {
    /// Devuelve la plantilla si el texto (dictado completo) coincide con un trigger; nil si no.
    func expand(_ text: String) -> String?
}
public protocol DictionaryProviding: AnyObject {
    func terms() -> [String]
}
```

`DictationController.init` gana al final: `snippets: SnippetExpanding? = nil, history: HistoryRecording? = nil`. En el pipeline (dentro de `processTranscriptContent`, tras el trim y ANTES de refineOrFallback): si `snippets?.expand(trimmed)` devuelve plantilla → insertar plantilla directamente (log "kiki core: snippet expandido") y saltar el LLM. El history hook se dispara tras `inserter.insert(...)` exitoso con crudo+final+perfil (audioSeconds: pásalo como parámetro del pipeline — `process(samples:)` lo calcula de samples.count/16000; `processTranscript` pasa 0).

---

### Task 1: KikiStore — JSONStore genérico + stores tipados (TDD)

**Files:** Create `Sources/KikiStore/{Models,JSONStore,Stores}.swift`, `Tests/KikiStoreTests/StoresTests.swift`; Modify `Package.swift` (target KikiStore deps [KikiCore] + testTarget)

**Interfaces (Produces):**
```swift
public struct Snippet: Codable, Equatable { public let trigger: String; public let template: String; public init(...) }
public struct HistoryEntry: Codable, Equatable { public let date: Date; public let rawText: String; public let finalText: String; public let profile: String; public let audioSeconds: Double; public init(...) }
public final class DictionaryStore { public init(directory: URL); public private(set) var terms: [String]; public func add(_ term: String); public func remove(_ term: String); }
public final class SnippetStore { public init(directory: URL); public private(set) var snippets: [Snippet]; public func add(_ s: Snippet); public func remove(trigger: String) }
public final class HistoryStore { public init(directory: URL, cap: Int = 200); public private(set) var entries: [HistoryEntry]; public func append(_ e: HistoryEntry); public func clear() }
```
Todos: cargan en init (archivo ausente → vacío; JSON corrupto → vacío + KikiLog); cada mutación persiste atómicamente; `add` de término/trigger duplicado (normalizado case-insensitive) es no-op; HistoryStore recorta FIFO al cap.

**Tests (TDD, directorio temporal por test con `FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)`):** round-trip persistencia (crear store → mutar → nuevo store mismo dir → estado igual); archivo corrupto → vacío sin crash; duplicados no-op; cap del historial (append 205 → 200, quedan los últimos); clear persiste; remove inexistente no-op.

Commit: `feat(store): JSON-backed dictionary, snippet and history stores`

---

### Task 2: KikiCore — snippet pre-pass + history hook (TDD)

**Files:** Modify `Sources/KikiCore/Protocols.swift`, `Sources/KikiCore/DictationController.swift`, `Tests/KikiCoreTests/DictationControllerTests.swift`

Protocolos y semántica EXACTOS de la sección File Structure de arriba. El pipeline interno gana el parámetro audioSeconds (default 0 para processTranscript público; process(samples:) calcula samples.count/sampleRate).

**Tests nuevos (mocks MockSnippets/MockHistory):** snippet match → plantilla insertada, LLM NO llamado (MockRefiner registra invocaciones), history registra plantilla como final; sin match → flujo normal; history registra crudo+final+perfil en dictado normal; history con refinado degradado registra raw==final; sin history/snippets (nil) → comportamiento fase 2B intacto (25 tests existentes sin tocar); audioSeconds correcto desde process(samples:).

Commit: `feat(core): deterministic snippet expansion and dictation history hook`

---

### Task 3: Inyección del diccionario en STT y LLM

**Files:** Modify `Sources/KikiSTT/WhisperTranscriber.swift`, `Sources/KikiRefine/RefinePrompt.swift` (+ `LLMRefiner.swift` si hace falta pasar términos), `Tests/KikiRefineTests/RefinePromptTests.swift`

1. **WhisperTranscriber** (es actor): nueva propiedad `public var dictionaryProvider: DictionaryProviding?` con setter async o método `setDictionaryProvider(_:)`. En `transcribe`: si hay términos, construir initial prompt. **Verificar la API real de WhisperKit 1.0** para prompts: `DecodingOptions.promptTokens` (tokens, requiere tokenizer — accesible vía `whisperKit.tokenizer.encode(text:)`) o similar; el implementador está AUTORIZADO a adaptar (patrón fases previas, consultar .build/checkouts/WhisperKit). El prompt textual: `"Glosario: término1, término2, …"` truncado a ~120 tokens. Si la API no lo permite razonablemente, documentar y hacer solo la inyección LLM (reportar DONE_WITH_CONCERNS).
2. **RefinePrompt**: `messages(for:profile:)` gana parámetro `dictionaryTerms: [String] = []`; si no vacío, añade al system prompt: `"Términos del usuario (respeta su escritura exacta): término1, término2, …"`. TDD: con términos aparece la línea; vacío no; user message intacto.
3. **LLMRefiner**: recibe los términos (propiedad `dictionaryProvider` análoga) y los pasa a RefinePrompt.

**Verificación:** unit tests de RefinePrompt; gated STT run una vez (`KIKI_STT_TEST=1 swift test --filter WhisperTranscriberIntegrationTests`) para no romper transcripción (el fixture no usa diccionario — debe seguir verde).

Commit: `feat(stt+refine): personal dictionary injection into Whisper prompt and LLM system prompt`

---

### Task 4: Ventana de Ajustes (SwiftUI) + cableo

**Files:** Create `Sources/Kiki/SettingsWindow.swift`; Modify `Sources/Kiki/AppDelegate.swift`, `Package.swift` (Kiki deps += KikiStore)

1. **SettingsWindow**: NSWindow con NSHostingView (patrón HUD pero ventana normal, `styleMask: [.titled, .closable]`, título "kiki — Ajustes", se muestra con `makeKeyAndOrderFront` + `NSApp.activate`). Contenido SwiftUI con `TabView` o secciones: 
   - **Diccionario**: List de términos + TextField añadir + botón eliminar por fila.
   - **Snippets**: List trigger→template + form añadir (2 campos) + eliminar.
   - **Historial**: List (fecha corta, final truncado; tooltip/expandido muestra crudo), botón "Copiar" por fila (NSPasteboard.general), botón "Borrar historial".
   - **General**: read-only info (hotkey Fn, frases wake, estado modelos) + toggle espejo de "Manos libres".
   Estados observables: wrappers `@Observable`/ObservableObject sobre los stores (refresco simple: recargar tras cada mutación).
2. **AppDelegate**: crear stores en `Application Support/kiki` real; item de menú "Ajustes…" (antes de Manos libres, keyEquivalent ","); adaptadores: DictionaryStore → DictionaryProviding (para transcriber y refiner), SnippetStore → SnippetExpanding (matching con la normalización de WakePhraseMatcher — extraer/reusar su normalizador, KikiWake ya es dependencia... si no lo es del target Kiki, duplicar la normalización en un helper de KikiStore y documentar), HistoryStore → HistoryRecording; pasar snippets/history al DictationController init; set del dictionaryProvider en transcriber/refiner tras crearlos.

**Verificación:** `swift test` verde; `make bundle` OK + metallib guard. NO lanzar la app.

Commit: `feat(app): settings window with dictionary, snippets and history`

---

### Task 5: README + cierre de fase

- README: sección "Personalización (Fase 3)": Ajustes desde el menú, diccionario (mejora reconocimiento de términos propios — la palanca de precisión), snippets (frase exacta → plantilla, sin LLM), historial local (cap 200, borrable, nunca sale del Mac); actualizar Arquitectura (KikiStore) y Notas de alcance (Fase 3 hecha; Fase 4 pendiente: onboarding, .dmg; backlog acumulado intacto).
- Verificación completa: `swift test` + `make bundle`.
- Commit `docs: phase 3 README — personalization` (sin push).

---

## Self-review

- Spec §6 features: diccionario ✅ (T1/T3/T4, inyección en los DOS puntos del spec §5), snippets ✅ (T1/T2/T4 — matching determinístico en vez de "en KikiRefine" del spec: más fiable, cero latencia; el LLM no toca plantillas), historial ✅ (T1/T2/T4), settings UI ✅ (T4 — incluye toggle wake espejo; umbral/tiempos del wake quedan como constantes v1, backlog). Auto-aprendizaje del diccionario → v2 (spec ya lo difería).
- KikiStore JSON vs SQLite: enmienda registrada arriba con racional; migración abierta.
- Sin placeholders; firmas exactas en Tasks 1-2; Task 3 con autoridad de adaptación de API (patrón validado); Task 4 detalla UI sin sobre-especificar SwiftUI.
- Consistencia: HistoryRecord/protocolos definidos una vez (T2) y consumidos en T4; Snippet/HistoryEntry (T1) usados por los adaptadores (T4).
