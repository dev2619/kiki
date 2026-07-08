# kiki Fase 3.8 — "Usabilidad" Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Ejecución SECUENCIAL (subagentes comparten árbol).

**Specs (feedback owner 2026-07-08):**
1. Diccionario y Snippets NO responden (add/delete/typing) — diagnosticar causa real y arreglar.
2. Historial: cap configurable desde Ajustes (default 200) + filtro/búsqueda de la lista.
3. **Escucha siempre activa**: decir "escúchame kiki" arma manos libres sin tocar toggle ni tecla — el wake listener corre desde el arranque, continuo, independiente del toggle. Setting "Escucha siempre activa" (default ON por pedido explícito). Documentar: mic abierto permanente (indicador naranja de macOS siempre on) + sugerir Voice Isolation de macOS.
4. Ícono de estado: verificar/hacer más distinguible la variante activa de kiki (el naranja es de macOS, fuera de alcance).

## Global Constraints
Heredados (tests verdes 275/6, xcodebuild, kiki-dev, Conventional Commits sin Co-Authored-By, stage por filename). Diagnosticar con evidencia (logging/firstResponder) antes de fixes de interacción — no adivinar. Verificación en vivo autorizada donde el bug solo se observe en runtime.

## Tasks (secuenciales)

### Task 1: Diagnosticar + arreglar interactividad de Diccionario/Snippets
Diagnóstico primero: los add usan `Button(action:)` + `TextField().onSubmit`. El diagnóstico previo mostró que los TOGGLES del detail pane sí disparaban, pero los TextField podrían no recibir foco de teclado (firstResponder era un PlatformSwitch). Instrumentar addTerm/addSnippet + probar si el TextField acepta escritura (foco). Root-cause: ¿el botón no dispara? ¿el TextField no toma foco/escritura? ¿el add dispara pero la lista no refresca? Fix según hallazgo. Verificar en vivo (autorizado). Test si hay lógica pura extraíble.
Commit: `fix(app): functional dictionary and snippets editing in settings`

### Task 2: Historial — cap configurable + filtro
- HistoryStore.cap ya es parámetro (default 200). Persistir en UserDefaults `kiki.historyCap` (default 200); Ajustes → Historial: control (Stepper o Picker: 50/100/200/500/1000) que actualiza el cap y recorta al vuelo. AppDelegate construye HistoryStore con el cap guardado.
- Filtro: TextField de búsqueda arriba de la lista; filtra entries por substring (case/acento-insensible) sobre rawText+finalText en el ViewModel (computed filtered list). Estado vacío "sin resultados".
Commit: `feat(app): configurable history cap and search filter`

### Task 3: Escucha siempre activa (always-listening wake)
- Setting `kiki.alwaysListening` (default true). Cuando true: AppDelegate arranca el WakeListener en `.listening` al terminar de cargar el modelo (markReady), independiente de `wakeEnabled`, y lo mantiene corriendo (re-start tras cada dictado, como hoy hace la coordinación de pausa). Decir la frase → arma sesión (flujo actual de applyMatch/arm). El toggle "Manos libres" y ⌥⌘K siguen existiendo para armado directo, pero YA NO son requisito para que la frase funcione.
- Semántica: con alwaysListening ON, `wakeEnabled` deja de ser el gate del listener; el listener corre siempre. El icono activo refleja "escuchando" cuando alwaysListening o wakeEnabled. Cuidar: no dos engines simultáneos con el dictado por tecla (la coordinación de pausa ya para el listener durante .recording/.processing y lo reanuda; extender para reanudar a `.listening` cuando alwaysListening aunque wakeEnabled sea false).
- Ajustes → General: toggle "Escucha siempre activa (di 'escúchame kiki' sin activar nada)" con footer explicando el mic-siempre-abierto + tip Voice Isolation.
- Privacidad: sin frase = nada se transcribe-persiste (regla actual intacta); documentar en README el mic permanente.
Commit: `feat(wake): always-listening mode — wake phrase works with zero prior action`

### Task 4: Ícono activo más claro + README
- Verificar que updateStatusIcon aplica MenuBarIconActive cuando (alwaysListening || wakeEnabled) y que la variante es visualmente distinguible; si el punto de estado es sutil, considerar tint/opacidad. Aclarar en README que el indicador naranja es de macOS (mic en uso), no de kiki.
- README: sección escucha siempre activa + cap configurable + filtro historial + nota Voice Isolation.
Commit: `docs+app: clarify active icon and document 3.8 usability features`

## Self-review
Todos los items del owner mapeados. Task 3 es el de más riesgo (concurrencia de engines) — traza la coordinación de pausa con alwaysListening. Mic-siempre-abierto documentado honestamente.
