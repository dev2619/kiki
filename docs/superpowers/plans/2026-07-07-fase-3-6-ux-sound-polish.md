# kiki Fase 3.6 — "UX & Sound Polish" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax.

**Goal (specs derivadas del feedback del owner, 2026-07-07):**
1. **Responsividad del modo manos libres:** reducir la latencia percibida frase→chime y hacer medible cada etapa.
2. **Confirmación sonora:** cues de audio en los momentos clave (frase detectada, inicio de captura, texto insertado, fin de sesión) — el usuario debe SABER que kiki lo escucha sin mirar la pantalla.
3. **Atajo global** para activar/desactivar manos libres sin tocar el menú: **⌥⌘K**.
4. **Estado en el ícono, sin emoji:** eliminar el "👂"; el estado manos-libres se comunica con una **variante del glifo** de la barra (template, con punto de estado integrado al mark).
5. **Rediseño de Ajustes** a nivel Wispr Flow: sidebar de navegación, formularios agrupados macOS-nativos, estados vacíos con afecto, sección Acerca de, refresco en vivo del historial.

**Architecture:** cambios confinados a KikiWake (tuning + telemetría), target Kiki (sonidos, atajo, ícono, Settings UI). Cero cambios en KikiCore/STT/Refine/Insert/Store públicos (solo lecturas).

## Global Constraints

- Los heredados (tests verdes 190/4, xcodebuild, kiki-dev, Conventional Commits sin Co-Authored-By, stage por filename, KikiLog, rama `feature/fase-3-6-ux-polish`)
- Sonidos: SOLO NSSound de sistema (sin assets nuevos): arm=`Glass`, captureStart=`Tink`, inserted=`Pop`, disarm=`Bottle`. Toggle "Sonidos de confirmación" en Ajustes→General, UserDefaults `kiki.soundCuesEnabled`, default **true**. El cue `inserted` suena en AMBOS modos (hotkey y wake); arm/captureStart/disarm solo aplican a wake.
- Atajo global: **⌥⌘K** (keyCode 40 + [.option, .command]) — patrón HotkeyMonitor; al alternar muestra pill HUD transitorio 1.2s: "Manos libres activado"/"desactivado" y suena Glass/Bottle.
- Ícono: `MenuBarIcon@2x.png` (normal) + NUEVO `MenuBarIconActive@2x.png` — mismo mark barra-punto-barra-punto MÁS un punto pequeño centrado bajo la línea base (estado = escucha ambiente ON). Ambos template (negro+alfa), dibujados programáticamente con las proporciones existentes (script en el repo scripts/generate-menubar-icons.py con el venv de Pillow o rehecho en Swift — decisión del implementador, documentada). `button.title` queda SIEMPRE vacío.
- Latencia wake: `listeningEndSilence` 0.7→**0.5s**; log de desglose por etapa en cada wake-check: `kiki wake: check — segmento X.Xs, transcripción Y.Ys, match sí/no` (sin contenido si no hay match).
- Settings: SwiftUI `NavigationSplitView` (sidebar con SF Symbols: General `gearshape`, Diccionario `character.book.closed`, Snippets `text.badge.plus`, Historial `clock`, Acerca `info.circle`), `.formStyle(.grouped)`, accent violeta (#7C5CFC) vía `.tint`, ventana min 640×420 con recordación de sección (UserDefaults), estados vacíos con símbolo+texto amable, Historial se refresca al enfocar la ventana Y tras cada dictado (NotificationCenter local), Acerca muestra AppIcon + versión (CFBundleShortVersionString) + link al repo. Mantener TODA la funcionalidad existente (CRUD diccionario/snippets, copiar/borrar historial, toggle manos libres espejo + NUEVO: hint del atajo ⌥⌘K y toggle de sonidos).

## Tasks

### Task 1: Wake latency + telemetría + cues de sonido + atajo global + ícono activo
**Files:** `Sources/KikiWake/WakeListener.swift` (endSilence 0.5 + logs desglose), `Sources/Kiki/SoundCues.swift` (nuevo — enum + play(cue) respetando el toggle), `Sources/Kiki/WakeToggleShortcut.swift` (nuevo — ⌥⌘K global, patrón HotkeyMonitor), `Sources/Kiki/AppDelegate.swift` (cablear cues en delegate + dictationStateDidChange inserted, atajo → toggleWake, HUD pill transitorio, updateStatusIcon sin title + variante activa), `App/MenuBarIconActive{,@2x}.png` (+ script generador), `Makefile` (copiar nuevos PNG), `Sources/Kiki/HUDController.swift`+`HUDView.swift` (pill transitorio de texto breve `showTransient(_ text: String)`).
Verificación: suite verde, make bundle + ambos glifos en Resources, no launch.
Commit: `feat(app): sound cues, global hands-free shortcut and stateful menu bar glyph`

### Task 2: Rediseño Settings (NavigationSplitView)
**Files:** `Sources/Kiki/SettingsWindow.swift` (reescritura UI), `Sources/Kiki/SettingsViewModel.swift` (extender: soundCuesEnabled, refresco por notificación, sección recordada), `Sources/Kiki/AppDelegate.swift` (post-dictado → NotificationCenter para refresco de historial).
Todo el detalle de diseño en Global Constraints. Mantener adapters/stores intactos.
Verificación: suite verde, make bundle, no launch.
Commit: `feat(app): settings redesign — sidebar navigation, grouped forms, live history`

### Task 3: README + cierre
Actualizar secciones (atajo, sonidos, ícono de estado, Ajustes) + notas de alcance. Commit docs.

## Self-review
- Los 5 specs del owner mapeados: latencia (T1), sonido (T1), atajo (T1), emoji→glifo (T1), settings (T2). Sin cambios de pipeline core → riesgo bajo. El punto-de-estado en glifo template mantiene tinte del sistema (un solo color, forma comunica estado).
