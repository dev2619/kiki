# F3 — Gestor de modelos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sección "Modelos" en Ajustes: catálogo curado de modelos de transcripción (Whisper) y refinado (Qwen/MLX) que el usuario descarga y activa según su hardware, con el base garantizado y hot-swap sin reiniciar.

**Architecture:** Un `ModelCatalog` estático (app target) describe las opciones; `ModelPreference` resuelve la preferencia persistida (UserDefaults) con fallback al base. `WhisperTranscriber` y `LLMRefiner` ganan `switchModel(to:progressHandler:)` que carga el modelo nuevo en background y conmuta al estar listo (mismo mecanismo interno de `prepare`). AppDelegate construye ambos con la preferencia resuelta al arrancar. La UI de settings lista filas con estado (activo/descargado/descargar) y progreso de descarga reusando `ModelLoadProgressModel`-style bindings locales.

**Tech Stack:** Swift 5.10, WhisperKit v1.0, MLX (mlx-swift-examples), SwiftUI, XCTest.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-11-cuatro-features-v1-design.md` §F3
- UserDefaults keys: `kiki.sttModel`, `kiki.refineModel` (naming `kiki.*`)
- El base STT (`large-v3_turbo_954MB`) y el base LLM (`Qwen2.5-3B-Instruct-4bit`) son los defaults y SIEMPRE quedan disponibles como fallback; el primer arranque los descarga como hoy (esa lógica no cambia)
- Hot-swap con prewarm (lección del bug "Procesando…" eterno): el modelo activo sigue sirviendo hasta que el nuevo está listo; si el switch falla, se conserva el activo y se loggea
- El tiny del wake (F4) NO aparece en el catálogo (es interno)
- Todo error a `KikiLog`; degradación elegante siempre
- Tests: `swift test`; app con `make build`; NO `make run`
- Git: rama `feature/model-manager`; Conventional Commits; sin `Co-Authored-By`; stage por filename
- Versión final: `0.11.0` (CFBundleVersion `5`)

---

### Task 1: ModelCatalog + ModelPreference (TDD)

**Files:**
- Create: `Sources/Kiki/ModelCatalog.swift`
- Test: `Tests/KikiAppLogicTests/ModelCatalogTests.swift` — ATENCIÓN: el target de tests para código del app target no existe (el ejecutable no es testeable vía SPM). Por eso `ModelCatalog`/`ModelPreference` van en **KikiStore** (módulo de settings/persistencia, ya testeable): Create `Sources/KikiStore/ModelCatalog.swift` y `Tests/KikiStoreTests/ModelCatalogTests.swift`. Si `Tests/KikiStoreTests/` no existe, crearlo (Package.swift ya tiene el testTarget si existe; si no, agregarlo con dependencia KikiStore).

**Interfaces:**
- Produces (Tasks 2-3 consumen):
```swift
public enum ModelKind: String { case stt, refine }

public struct ModelOption: Equatable, Identifiable {
    public let id: String          // identificador para el motor (WhisperKit variant / repo MLX)
    public let displayName: String // "Rápido (small)", "Balanceado ★", ...
    public let sizeLabel: String   // "~216 MB"
    public let detail: String      // una línea de posicionamiento
    public let isBase: Bool
}

public enum ModelCatalog {
    public static let sttOptions: [ModelOption]      // 3 opciones, base = large-v3_turbo_954MB
    public static let refineOptions: [ModelOption]   // 3 opciones, base = Qwen2.5-3B-Instruct-4bit
    public static func options(for kind: ModelKind) -> [ModelOption]
    public static func baseOption(for kind: ModelKind) -> ModelOption
}

public enum ModelPreference {
    public static func defaultsKey(for kind: ModelKind) -> String   // "kiki.sttModel"/"kiki.refineModel"
    /// id efectivo: preferencia persistida si existe Y está en el catálogo; si no, el base.
    public static func effectiveModelId(for kind: ModelKind, defaults: UserDefaults = .standard) -> String
    public static func setPreferred(_ id: String, for kind: ModelKind, defaults: UserDefaults = .standard)
}
```

- [ ] **Step 1: Tests que fallan** — `Tests/KikiStoreTests/ModelCatalogTests.swift` con `UserDefaults(suiteName: "kiki.tests.models")!` limpiado en setUp (removePersistentDomain). Casos: (1) catálogos tienen 3 opciones y exactamente un `isBase` cada uno; (2) `effectiveModelId` sin preferencia → id del base; (3) con preferencia válida → esa; (4) con preferencia fuera de catálogo (modelo retirado) → base; (5) `setPreferred` + `effectiveModelId` round-trip; (6) keys exactas `kiki.sttModel`/`kiki.refineModel`.
- [ ] **Step 2: RED** — `swift test --filter ModelCatalogTests` → compile failure.
- [ ] **Step 3: Implementar.** Catálogo STT: ids `"small"` (verificar el nombre exacto multilingüe del repo whisperkit-coreml ANTES de fijarlo — `openai_whisper-small` esperado, ~216MB; NUNCA `.en`), `"large-v3_turbo_954MB"` (base ★), `"large-v3_turbo"` (con detail advirtiendo compilación ANE larga la primera vez). Catálogo refine: `"mlx-community/Qwen2.5-1.5B-Instruct-4bit"`, `"mlx-community/Qwen2.5-3B-Instruct-4bit"` (base ★), `"mlx-community/Qwen2.5-7B-Instruct-4bit"` (detail: Macs 32GB+). El id del base STT debe ser EXACTAMENTE `WhisperTranscriber.preferredModel` y el del refine `LLMRefiner.preferredModel` — pero KikiStore no puede importar KikiSTT/KikiRefine (dependencias); duplicar el string está prohibido: en su lugar Task 2 agrega asserts de consistencia en AppDelegate (`assert(ModelCatalog.baseOption(for: .stt).id == WhisperTranscriber.preferredModel)`) — documentarlo en un comment del catálogo.
- [ ] **Step 4: GREEN + suite completa.**
- [ ] **Step 5: Commit** — `feat(store): curated model catalog with persisted preference resolution`

---

### Task 2: switchModel en WhisperTranscriber y LLMRefiner + arranque con preferencia

**Files:**
- Modify: `Sources/KikiSTT/WhisperTranscriber.swift`
- Modify: `Sources/KikiRefine/LLMRefiner.swift`
- Modify: `Sources/Kiki/AppDelegate.swift`

**Interfaces:**
- Consumes: `ModelPreference.effectiveModelId(for:)` (Task 1); `modelName` per-instance (F4 Task 1).
- Produces (Task 3 consume):
  - `WhisperTranscriber.switchModel(to model: String, progressHandler: (@Sendable (Double) -> Void)?) async throws`
  - `LLMRefiner.switchModel(to model: String, progressHandler: (@Sendable (Double) -> Void)?) async throws`
  - `WhisperTranscriber.currentModel: String { get }` (async, actor) y equivalente en LLMRefiner
  - AppDelegate: `transcriber`/`refiner` construidos con `ModelPreference.effectiveModelId`

- [ ] **Step 1: WhisperTranscriber.** `modelName` pasa de `let` a `private(set) var`. Nuevo método (leer `prepare`/`loadModel` actuales y reusar su pipeline descarga+prewarm+load):
```swift
    /// F3: carga `model` (descargando si hace falta, con prewarm) y conmuta
    /// al terminar. El modelo activo sigue sirviendo transcripciones mientras
    /// tanto (la conmutación es el último paso). Si falla, el activo queda
    /// intacto y el error se propaga al caller (la UI lo muestra; nada se
    /// persiste hasta el éxito).
    public func switchModel(to model: String, progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        guard model != modelName else { return }
        let newKit = try await loadModel(named: model, progressHandler: progressHandler)  // extraer de prepare el pipeline parametrizado por nombre
        whisperKit = newKit
        modelName = model
        KikiLog.log("kiki stt: modelo conmutado a \(model)")
    }
    public var currentModel: String { modelName }
```
  Refactor requerido: el cuerpo de `prepare` que hoy carga `modelName` se extrae a `loadModel(named:progressHandler:) async throws -> WhisperKit` y `prepare` lo llama con `modelName` (comportamiento idéntico — la suite existente lo verifica). El switch NO toca `isReady` (sigue true con el modelo viejo hasta conmutar).
- [ ] **Step 2: LLMRefiner.** Mismo patrón: extraer el pipeline de `prepare` a `loadModel(named:)`, agregar `switchModel(to:progressHandler:)` y `currentModel`. Leer el archivo primero — es una clase (no actor); respetar su mecanismo de sincronización existente (el que proteja `isReady`/el contenedor del modelo; si no hay, la conmutación debe hacerse en el mismo hilo/cola donde `refine` lee el modelo — investigar y seguir el patrón del archivo, reportar DONE_WITH_CONCERNS si es ambiguo).
- [ ] **Step 3: AppDelegate.** `let transcriber = WhisperTranscriber()` → `let transcriber = WhisperTranscriber(model: ModelPreference.effectiveModelId(for: .stt))`; análogo para `refiner` si `LLMRefiner.init` ya acepta modelo (si no, agregar `init(model:)` con default en Step 2). Agregar en `applicationDidFinishLaunching` los asserts de consistencia catálogo↔constantes (ver Task 1 Step 3). Import KikiStore ya existe.
- [ ] **Step 4: Fallback de arranque.** En `prepare` de ambos: si el modelo preferido (no-base) falla, intentar el base ANTES del fallback genérico actual, y loggear. (El resolver ya cae al base si la preferencia no está en catálogo; esto cubre "está en catálogo pero falla la carga".)
- [ ] **Step 5: Verificación** — `swift test` 0 failures (la suite existente cubre que prepare sigue igual); `make build` SUCCEEDED.
- [ ] **Step 6: Commit** — `feat(models): hot-swap model switching with preferred-model startup`

---

### Task 3: Settings — sección "Modelos"

**Files:**
- Modify: `Sources/Kiki/SettingsViewModel.swift` (sección nueva en el enum + estado de modelos)
- Create: `Sources/Kiki/ModelsSettingsView.swift`
- Modify: `Sources/Kiki/SettingsWindow.swift` (case nuevo del sidebar)
- Modify: `Sources/Kiki/AppDelegate.swift` (pasar referencias transcriber/refiner al SettingsViewModel)

**Interfaces:**
- Consumes: Task 1 catálogo/preferencia, Task 2 switchModel/currentModel.
- Produces: UI final.

- [ ] **Step 1:** `SettingsSection` gana `case models` (title "Modelos", entre history y about; leer cómo el enum mapea íconos/labels y seguirlo).
- [ ] **Step 2:** `SettingsViewModel` gana, siguiendo sus patrones:
```swift
    struct ModelRowState: Identifiable { let option: ModelOption; var isActive: Bool; var isDownloading: Bool; var progress: Double }
    @Published var sttRows: [ModelRowState]
    @Published var refineRows: [ModelRowState]
    func activateModel(_ option: ModelOption, kind: ModelKind)
```
  `activateModel` lanza `Task { @MainActor ... }` que llama al `switchModel` correspondiente con un progressHandler que salta a MainActor y actualiza `progress` de la fila; al éxito: `ModelPreference.setPreferred`, recomputar `isActive` de las filas, log. Al fallo: restaurar la fila, mostrar el error en un `@Published var modelsErrorMessage: String?` que la vista presenta, log. El view model necesita referencias a transcriber/refiner: inyectarlas por init (AppDelegate ya construye el view model — agregar parámetros). "Descargado ✓" (sin ser activo): detectar si el modelo ya está en el cache local es frágil entre motores — YAGNI: v1 muestra solo "Activo ●" o botón "Usar" (que descarga si hace falta, el progreso lo comunica); documentar en el spec-note de la vista.
- [ ] **Step 3:** `ModelsSettingsView` (nuevo archivo, SwiftUI Form): dos Sections ("Transcripción", "Refinado con IA"), fila = displayName + sizeLabel + detail (footer-style) + trailing: "● Activo" | ProgressView(value:) | Button("Usar"). Footer general: los cambios aplican al instante; el modelo base siempre queda como respaldo. Seguir el estilo visual del Form existente en SettingsWindow.
- [ ] **Step 4:** Cablear el case en el switch del sidebar de SettingsWindow.
- [ ] **Step 5:** Verificación — `swift test` 0 failures + `make build` SUCCEEDED. (La UI se valida en el smoke manual del cierre de F3.)
- [ ] **Step 6: Commit** — `feat(app): models settings section with download-and-activate flow`

---

### Task 4: Versión 0.11.0 + release notes

**Files:** `App/Info.plist` (0.10.0→0.11.0, CFBundleVersion 4→5), `docs/RELEASE_NOTES.md`.

- [ ] **Step 1:** Bump.
- [ ] **Step 2:** Notes (mismo formato; conservar Instalación con `kiki-0.11.0.dmg`):
```markdown
# kiki 0.11.0

Dictado por voz con IA, 100% local, para macOS (Apple Silicon).

## ✨ Novedades de esta versión

### Elige tus modelos (Ajustes → Modelos)
Nueva sección para adaptar kiki a tu Mac:
- **Transcripción:** rápido (~216 MB), balanceado (~1 GB, el de siempre) o máxima calidad (~3 GB).
- **Refinado con IA:** ligero (~1 GB), balanceado (~2 GB, el de siempre) o máxima calidad (~4.5 GB, para Macs con 32 GB+).
- Los cambios aplican al instante, sin reiniciar: el modelo nuevo se descarga con barra de progreso y kiki sigue funcionando con el actual hasta que está listo.
- El modelo base siempre queda como respaldo — si algo falla, kiki nunca se queda sin dictado.
```
- [ ] **Step 3:** `swift test` + `make bundle` → OK. Commit `chore: bump version to 0.11.0 (model manager)`.

---

## Self-review

- **Cobertura spec §F3:** catálogos curados STT+LLM ✅ (T1), keys/persistencia+fallback ✅ (T1/T2), hot-swap con prewarm y activo intacto en fallo ✅ (T2), UI con progreso sin bloquear dictado ✅ (T3), base garantizado ✅ (constraint + T2 Step 4). Desviación consciente vs spec: estado "descargado ✓" sin activar se simplifica a "Usar" (detección de cache inter-motor frágil — documentado en T3 Step 2); el spec se actualiza al mergear.
- **Placeholders:** contratos completos; el código de integración instruye lectura del archivo real (patrón validado en F2/F4).
- **Consistencia:** `switchModel(to:progressHandler:)` idéntico T2/T3; `ModelKind`/`ModelOption` idénticos T1/T3; ids base = constantes de motor via asserts (T2 Step 3).
