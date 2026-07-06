# kiki Fase 2A — "Inteligencia" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** El texto dictado pasa por un LLM local (MLX, Qwen 4-bit) que quita muletillas, puntúa y adapta el tono al contexto de la app activa antes de pegarse — con degradación elegante al texto crudo si el LLM falla o tarda >5s.

**Architecture:** Dos módulos nuevos consumidos por el pipeline existente: `KikiContext` (app activa → perfil de tono vía NSWorkspace) y `KikiRefine` (LLM local vía MLXLLM). `DictationController` gana un paso opcional de refinado entre transcripción e inserción, inyectado por protocolo (`Refining`) igual que los demás colaboradores.

**Tech Stack:** Swift 5.10, SPM, MLX Swift (`mlx-swift-examples` → producto `MLXLLM`), modelo `mlx-community/Qwen2.5-3B-Instruct-4bit` (~1.8GB), NSWorkspace, XCTest.

## Global Constraints

- Igual que Fase 1: macOS 14+, tools 5.10, 16 kHz pipeline, Conventional Commits sin Co-Authored-By, stage por filename, logging vía `KikiLog` (cero telemetría), firma `kiki-dev` (Makefile ya configurado)
- Nueva dependencia permitida: `https://github.com/ml-explore/mlx-swift-examples` (productos `MLXLLM`/`MLXLMCommon`). Ninguna otra.
- Modelo LLM: `mlx-community/Qwen2.5-3B-Instruct-4bit`. Si el registro/API de MLXLLM difiere de lo escrito aquí, el implementador está AUTORIZADO a adaptar las llamadas (como Task 5 de Fase 1) consultando `.build/checkouts/mlx-swift-examples/` — las interfaces públicas de kiki NO cambian.
- **Timeout de refinado: 5s** (spec §7) → si vence o falla, se pega el texto crudo de Whisper. El dictado NUNCA se pierde por culpa del LLM.
- El refinado responde en el MISMO idioma del dictado (es/en).
- Tests unit con LLM mockeado; test de integración real gated por `KIKI_LLM_TEST=1`.
- Trabajar en rama `feature/fase-2a-inteligencia`.

## File Structure

```
Sources/
├── KikiContext/
│   └── AppContext.swift            — AppProfile enum + ContextProviding + FrontmostAppContext (NSWorkspace)
├── KikiRefine/
│   ├── RefinePrompt.swift          — plantillas de prompt por perfil (función pura, testeable)
│   └── LLMRefiner.swift            — wrapper MLXLLM, conforma Refining, timeout 5s
├── KikiCore/
│   ├── Protocols.swift             — MODIFICAR: + AppProfile import indirecto NO (AppProfile vive en KikiCore para evitar dependencia circular) → AppProfile + Refining + ContextProviding se declaran AQUÍ
│   └── DictationController.swift   — MODIFICAR: paso de refinado opcional
└── Kiki/
    └── AppDelegate.swift           — MODIFICAR: cableo refiner + context, estado LLM en menú
Tests/
├── KikiContextTests/AppContextTests.swift
├── KikiRefineTests/RefinePromptTests.swift
├── KikiRefineTests/LLMRefinerIntegrationTests.swift   — gated
└── KikiCoreTests/DictationControllerTests.swift       — MODIFICAR: + casos de refinado
```

Nota de diseño: `AppProfile`, `Refining` y `ContextProviding` se declaran en **KikiCore** (los consume el controller); `KikiContext` y `KikiRefine` los implementan. KikiContext depende de KikiCore + AppKit; KikiRefine depende de KikiCore + MLXLLM.

---

### Task 1: Protocolos de Fase 2 en KikiCore + refinado en el controller (TDD)

**Files:**
- Modify: `Sources/KikiCore/Protocols.swift`
- Modify: `Sources/KikiCore/DictationController.swift`
- Modify: `Tests/KikiCoreTests/DictationControllerTests.swift`

**Interfaces (Produces — firmas exactas):**
```swift
public enum AppProfile: String, Equatable, CaseIterable {
    case code, chat, email, docs, neutral
}

public protocol ContextProviding: AnyObject {
    func currentProfile() -> AppProfile
}

public protocol Refining: AnyObject {
    /// Devuelve el texto refinado. Lanza si falla; el controller degrada a crudo.
    func refine(_ text: String, profile: AppProfile) async throws -> String
}
```
`DictationController.init` gana DOS parámetros opcionales al final: `refiner: Refining? = nil, context: ContextProviding? = nil`. Nuevo estado NO se agrega (el refinado ocurre dentro de `.processing`).

**Semántica del refinado en `hotkeyReleased()`** (reemplaza el bloque entre transcripción e inserción):
```swift
let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
if !trimmed.isEmpty {
    let final = await refineOrFallback(trimmed)
    try inserter.insert(final)
    KikiLog.log("kiki core: texto insertado")
} else {
    KikiLog.log("kiki core: transcripción vacía, nada que insertar")
}
```
con:
```swift
private func refineOrFallback(_ text: String) async -> String {
    guard let refiner else { return text }
    let profile = context?.currentProfile() ?? .neutral
    do {
        let started = Date()
        let refined = try await withThrowingTimeout(seconds: 5) {
            try await refiner.refine(text, profile: profile)
        }
        let trimmedRefined = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRefined.isEmpty else {
            KikiLog.log("kiki core: refinado vacío — uso texto crudo")
            return text
        }
        KikiLog.log("kiki core: refinado (\(profile.rawValue)) en \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return trimmedRefined
    } catch {
        KikiLog.log("kiki core: refinado falló (\(error)) — uso texto crudo")
        return text
    }
}
```
`withThrowingTimeout` es un helper en KikiCore (task group: primera en terminar gana, la otra se cancela):
```swift
func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DictationError.transcriptionFailed("refinado excedió \(seconds)s")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

**Tests nuevos (TDD — escribir primero, ver fallar, implementar, ver pasar):**
- `test_refinerOutputIsInserted` — MockRefiner devuelve "texto pulido." → inserted == ["texto pulido."]
- `test_refinerReceivesProfileFromContext` — MockContext devuelve .code → MockRefiner registró profile .code
- `test_nilContextUsesNeutralProfile`
- `test_refinerErrorFallsBackToRawText` — MockRefiner lanza → inserted == [texto crudo], sin dictationDidFail (la degradación NO es un error de dictado), estado termina .idle
- `test_refinerTimeoutFallsBackToRawText` — MockRefiner duerme 6s (usar timeout de test corto: init con `refineTimeout: 0.1` — agregar parámetro `refineTimeout: TimeInterval = 5` al init para testeabilidad) → crudo insertado
- `test_emptyRefinerOutputFallsBackToRawText`
- `test_withoutRefinerBehavesAsPhase1` — refiner nil → los 11 tests existentes siguen pasando sin cambios de comportamiento

(El literal `5` del timeout pasa a `refineTimeout` del init — los call sites de producción no cambian.)

- [ ] Step 1: tests nuevos en RED (compilación falla: Refining no existe)
- [ ] Step 2: protocolos en Protocols.swift + controller + helper
- [ ] Step 3: `swift test --filter DictationControllerTests` → 18 tests, 0 failures
- [ ] Step 4: suite completa verde
- [ ] Step 5: commit `feat(core): optional LLM refinement step with 5s graceful fallback`

---

### Task 2: KikiContext — perfil por app activa (TDD)

**Files:**
- Create: `Sources/KikiContext/AppContext.swift`
- Create: `Tests/KikiContextTests/AppContextTests.swift`
- Modify: `Package.swift` (target KikiContext deps [KikiCore] + testTarget)

**Interfaces (Produces):**
```swift
public struct BundleProfileMap {
    public static let standard: [String: AppProfile]  // mapa por defecto
    public static func profile(forBundleId: String?, map: [String: AppProfile] = standard) -> AppProfile
}
public final class FrontmostAppContext: ContextProviding {
    public init()
    public func currentProfile() -> AppProfile  // NSWorkspace.shared.frontmostApplication
}
```

Mapa estándar (matching por prefijo de bundle id — `hasPrefix`, porque Electron apps versionan sufijos):
- `.code`: com.microsoft.VSCode, com.apple.dt.Xcode, com.googlecode.iterm2, com.apple.Terminal, dev.warp.Warp, com.jetbrains. (prefijo), com.sublimetext.
- `.chat`: com.tinyspeck.slackmacgap, com.hnc.Discord, ru.keepcoder.Telegram, net.whatsapp.WhatsApp, com.apple.MobileSMS
- `.email`: com.apple.mail, com.microsoft.Outlook, com.google. (NO — demasiado amplio; usar com.google.Gmail si existe; dejar solo mail/outlook/spark: com.readdle.smartemail-Mac)
- `.docs`: com.apple.Notes, com.apple.TextEdit, md.obsidian, com.microsoft.Word, com.google.Chrome NO (browser ≠ docs) — Notion: notion.id
- resto → `.neutral`

**Tests:** mapping exacto por caso (VS Code→code, Slack→chat, Mail→email, Notes→docs), prefijo JetBrains, bundle desconocido→neutral, nil→neutral. `FrontmostAppContext` no se unit-testea (NSWorkspace real) — la función pura `BundleProfileMap.profile` sí.

- [ ] Steps: RED → implementar → GREEN → suite completa → commit `feat(context): frontmost app profile detection`

---

### Task 3: KikiRefine — prompts por perfil (TDD, función pura)

**Files:**
- Create: `Sources/KikiRefine/RefinePrompt.swift`
- Create: `Tests/KikiRefineTests/RefinePromptTests.swift`
- Modify: `Package.swift` (target KikiRefine deps [KikiCore] — MLXLLM se agrega en Task 4; testTarget)

**Interfaces (Produces):**
```swift
public enum RefinePrompt {
    /// System prompt + user message para el chat template del LLM.
    public static func messages(for text: String, profile: AppProfile) -> (system: String, user: String)
}
```

System prompt base (ES/EN neutro — el modelo responde en el idioma del texto):
```
Eres el editor de dictado de kiki. Reescribe la transcripción del usuario:
corrige puntuación y mayúsculas, elimina muletillas (eh, um, este, like) y
falsos comienzos, y une frases cortadas. CONSERVA el idioma original, el
significado y las palabras del usuario tanto como sea posible. NO agregues
contenido, NO respondas preguntas del texto, NO expliques nada.
Responde ÚNICAMENTE con el texto reescrito, sin comillas ni prefijos.
```
Sufijos por perfil: `.code` → "Contexto: editor de código/terminal. Términos técnicos, nombres de comandos y de librerías van exactos, sin traducir."; `.chat` → "Contexto: chat informal. Tono conversacional, conciso."; `.email` → "Contexto: correo profesional. Tono claro y cortés, frases completas."; `.docs` → "Contexto: documento. Prosa clara y bien estructurada."; `.neutral` → sin sufijo.

**Tests:** cada perfil incluye su sufijo, neutral no; el user message es exactamente el texto; el system contiene las reglas clave ("ÚNICAMENTE", "idioma original").

- [ ] Steps: RED → implementar → GREEN → commit `feat(refine): per-profile prompt templates`

---

### Task 4: KikiRefine — LLMRefiner con MLX (integración gated)

**Files:**
- Modify: `Package.swift` — dependencia `.package(url: "https://github.com/ml-explore/mlx-swift-examples", branch: "main")` (o el último tag estable que resuelva; el implementador decide y documenta) + KikiRefine deps += [MLXLLM, MLXLMCommon]
- Create: `Sources/KikiRefine/LLMRefiner.swift`
- Create: `Tests/KikiRefineTests/LLMRefinerIntegrationTests.swift`

**Interfaces (Produces):**
```swift
public final class LLMRefiner: Refining {
    public static let preferredModel = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    public init()
    public private(set) var isReady: Bool
    public func prepare() async throws   // descarga+carga el modelo; llamar al arrancar
    public func refine(_ text: String, profile: AppProfile) async throws -> String
}
```

Implementación de referencia (ADAPTAR a la API real de mlx-swift-examples; consultar `.build/checkouts/mlx-swift-examples/Libraries/MLXLMCommon` — patrón `LLMModelFactory.shared.loadContainer(configuration:)` + `ModelConfiguration(id:)` + `modelContainer.perform { context in ... }` con `MLXLMCommon.generate`):
- `prepare()`: cargar container con `ModelConfiguration(id: Self.preferredModel)`, log de duración vía KikiLog.
- `refine`: construir mensajes con `RefinePrompt.messages`, chat template del tokenizer, `generate` con `maxTokens: 512, temperature: 0.3`, devolver el texto generado. Lanza `DictationError.transcriptionFailed("LLM no cargado")` si `prepare()` no corrió.
- GPU/memoria: `MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)` tras generar si la API lo expone (documentar decisión).

**Integration test (gated `KIKI_LLM_TEST=1`, descarga ~1.8GB):**
```swift
func test_refinesSpanishDictation() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["KIKI_LLM_TEST"] == "1", ...)
    let refiner = LLMRefiner()
    try await refiner.prepare()
    let raw = "eh bueno este quería decirte que eh la reunión de mañana mejor la movemos al jueves"
    let refined = try await refiner.refine(raw, profile: .chat)
    let lower = refined.lowercased()
    XCTAssertFalse(lower.contains("eh "), "muletilla sobrevivió: \(refined)")
    XCTAssertTrue(lower.contains("reunión") || lower.contains("reunion"))
    XCTAssertTrue(lower.contains("jueves"))
    XCTAssertLessThan(refined.count, raw.count + 40, "el LLM agregó contenido: \(refined)")
}
```
- [ ] Steps: implementar → `swift build` → test gated skip por defecto → correr real UNA vez (`KIKI_LLM_TEST=1`, timeout generoso) → suite completa → commit `feat(refine): local MLX LLM refiner with Qwen 3B 4-bit`

---

### Task 5: Cableo en la app

**Files:**
- Modify: `Sources/Kiki/AppDelegate.swift`
- Modify: `Package.swift` (executable Kiki deps += KikiContext, KikiRefine)

Cambios:
1. Propiedades: `let refiner = LLMRefiner()`, `let appContext = FrontmostAppContext()`.
2. `DictationController(recorder:transcriber:inserter:refiner:context:)` — pasar ambos.
3. `loadModelInBackground()` carga AMBOS modelos secuencialmente (Whisper primero — es lo crítico); menú tag 1: "Cargando modelos…" → "Listo — mantén Fn para dictar". Si el LLM falla al cargar: log + menú "Listo (sin refinado IA)" — kiki sigue funcionando como Fase 1 (refiner con isReady false lanza al refinar → fallback a crudo ya cubierto por Task 1; verificar que ese camino no dispare dictationDidFail).
4. `make bundle` — verificar que los `.bundle` de MLX (metallib) se copien; si `swift build -c release` genera `mlx-swift-examples_*.bundle`, el Makefile ya los copia con el glob existente. Si MLX requiere recursos adicionales, documentar y ajustar el glob.

Verificación (protocolo controlador): build release + bundle + suite verde. Smoke humano al final de la fase.

- [ ] Steps: cablear → build/bundle/tests → commit `feat(app): wire LLM refinement and app context into dictation pipeline`

---

### Task 6: README + cierre

- README: sección "Fase 2A" (refinado local, modelo Qwen 1.8GB adicional, total ~3GB de modelos), actualizar requisitos de disco, tabla de perfiles por app, cómo desactivar (por ahora: no cableado = futuro toggle en settings Fase 3), test gated `KIKI_LLM_TEST=1`.
- Actualizar "Notas de alcance": Fase 2B (wake word) pendiente como plan aparte.
- Verificación final completa + commit `docs: phase 2A README` (sin push — el controlador hace merge).

---

## Self-review

- Cobertura spec Fase 2 parcial deliberada: KikiRefine ✓ (spec §4/§6), KikiContext ✓ (spec §6), KikiWake → plan 2B separado (research de openWakeWord/entrenamiento merece su propio ciclo). Diccionario/snippets → Fase 3 (spec §9).
- Degradación elegante spec §7 ✓ (timeout 5s → crudo, LLM caído → app funciona como Fase 1).
- Sin placeholders: código completo en Tasks 1-3; Task 4 autoriza adaptación de API explícitamente (patrón validado en Fase 1 Task 5).
- Consistencia: `Refining`/`ContextProviding`/`AppProfile` declarados una vez en KikiCore (Task 1), consumidos con las mismas firmas en Tasks 2-5.
