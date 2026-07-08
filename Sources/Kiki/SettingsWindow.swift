import AppKit
import SwiftUI
import KikiStore

/// Acento de marca kiki (#7C5CFC), aplicado con `.tint` en la raíz de
/// `SettingsRootView` — Fase 3.6, Task 2.
private let kikiAccent = Color(red: 0x7C / 255.0, green: 0x5C / 255.0, blue: 0xFC / 255.0)

/// Ventana normal (no HUD) de Ajustes: `NSWindow` con `NSHostingView`,
/// singleton reutilizado entre aperturas (patrón similar a `HUDController`
/// pero con ventana titulada/cerrable en vez de panel flotante borderless).
///
/// `isReleasedWhenClosed = false` es la clave de la reutilización: cerrar la
/// ventana (botón rojo o Cmd+W) solo la oculta, no la destruye — `window`
/// sigue apuntando a la misma instancia, así que `show()` puede reordenarla
/// al frente en vez de reconstruir toda la jerarquía SwiftUI cada vez.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let viewModel: SettingsViewModel
    private var keyObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    deinit {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    /// Activa la app de verdad antes de mostrar la ventana. `NSApp.activate`
    /// (sin `ignoringOtherApps:`, API moderna post-macOS 14) es, por sí solo,
    /// insuficiente para una app `.accessory` (menu bar, sin ítem en Dock):
    /// bajo activación cooperativa (Sonoma+, más estricta en macOS 26) el
    /// sistema puede ordenar la ventana al frente sin transferirle el foco de
    /// entrada real — la ventana se ve "key" (traffic lights coloreados) pero
    /// los eventos de mouse nunca llegan a AppKit/SwiftUI. Subir a `.regular`
    /// mientras Ajustes está abierta fuerza una activación real (aparece un
    /// ícono de Dock — visible pero estándar para este patrón) y se revierte
    /// a `.accessory` en `windowWillClose` para volver al modo puramente
    /// menu-bar. Idempotente ante aperturas/cierres repetidos: `show()`
    /// siempre re-sube a `.regular` sin importar el estado previo, y el
    /// observer de cierre siempre baja a `.accessory`.
    func show() {
        viewModel.refreshAll()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Hosteamos vía NSHostingController (no `contentView = NSHostingView`):
        // el controller instala la vista SwiftUI en la cadena de responders y
        // en el hit-testing de la ventana de forma correcta para una ventana
        // creada por código desde una app de menu bar. Asignar el NSHostingView
        // directo como contentView deja la vista dibujada pero sin recibir
        // eventos de mouse en este escenario.
        let host = NSHostingController(rootView: SettingsRootView(viewModel: viewModel))
        let newWindow = NSWindow(contentViewController: host)
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        newWindow.title = "kiki — Ajustes"
        newWindow.isReleasedWhenClosed = false
        newWindow.minSize = NSSize(width: 640, height: 420)
        newWindow.setContentSize(NSSize(width: 680, height: 460))
        newWindow.center()
        window = newWindow

        // Refresco en vivo del Historial (Fase 3.6, Task 2): además del
        // refresh explícito de arriba (al invocar `show()`), la ventana
        // vuelve a refrescar todo su estado cada vez que recupera el foco —
        // cubre el caso de dejarla abierta en segundo plano mientras se
        // dictan cosas y volver a ella sin cerrarla/reabrirla.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: newWindow,
            queue: .main
        ) { [weak viewModel] _ in
            Task { @MainActor in viewModel?.refreshAll() }
        }

        // Vuelve a `.accessory` (puro menu-bar, sin Dock) al cerrar Ajustes —
        // simétrico con el `setActivationPolicy(.regular)` de arriba. Sin
        // esto, el ícono de Dock quedaría pegado incluso con la ventana
        // cerrada.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: newWindow,
            queue: .main
        ) { _ in
            Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
        }

        newWindow.makeKeyAndOrderFront(nil)
    }
}

struct SettingsRootView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        NavigationSplitView {
            // Botones explícitos por fila en vez de `List(selection:)`: en
            // macOS 26 la selección de List dentro de NavigationSplitView no
            // respondía a clicks (diagnóstico 2026-07-07: el binding de
            // selección nunca se disparaba, mientras los controles del panel
            // de detalle sí recibían eventos). Los botones no dependen del
            // hit-testing de la selección de List — siempre responden.
            List {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        viewModel.selectedSection = section
                    } label: {
                        Label(section.title, systemImage: section.symbolName)
                            .foregroundStyle(
                                section == viewModel.selectedSection ? kikiAccent : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        section == viewModel.selectedSection
                            ? kikiAccent.opacity(0.15) : Color.clear)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            Group {
                switch viewModel.selectedSection {
                case .general:
                    GeneralSectionView(viewModel: viewModel)
                case .dictionary:
                    DictionarySectionView(viewModel: viewModel)
                case .snippets:
                    SnippetsSectionView(viewModel: viewModel)
                case .history:
                    HistorySectionView(viewModel: viewModel)
                case .about:
                    AboutSectionView()
                }
            }
            .navigationTitle(viewModel.selectedSection.title)
        }
        .tint(kikiAccent)
        .frame(minWidth: 640, minHeight: 420)
    }
}

// MARK: - General

private struct GeneralSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { viewModel.wakeEnabled },
                    set: { _ in viewModel.requestToggleWake() }
                )) {
                    HStack(spacing: 8) {
                        Text("Manos libres: \"escúchame kiki\"")
                        shortcutBadge("⌥⌘K")
                    }
                }
                Toggle("Sonidos de confirmación", isOn: $viewModel.soundCuesEnabled)
            } header: {
                Text("Manos libres")
            } footer: {
                Text("Actívalo y di \"escúchame kiki\" para dictar sin tocar nada, o alterna el modo en cualquier momento con ⌥⌘K. Los sonidos de confirmación marcan cuándo kiki empieza a escuchar, detecta tu voz, inserta el texto o se desactiva — sin que tengas que mirar la pantalla.")
            }

            Section {
                Toggle("Escucha siempre activa", isOn: $viewModel.alwaysListening)
            } footer: {
                Text("Con esto activado (por defecto), decir \"escúchame kiki\" empieza a dictar sin tocar nada — ni el toggle de arriba ni ⌥⌘K. Para que la frase funcione en cualquier momento, el micrófono queda abierto todo el tiempo que kiki esté corriendo (macOS muestra el punto naranja de uso de micrófono de forma permanente en la barra de menú). Si el ruido de fondo te molesta, prueba activando \"Aislamiento de voz\" en Centro de Control → micrófono.")
            }

            Section {
                Toggle("Refinar dictado con IA", isOn: $viewModel.refineEnabled)
            } footer: {
                Text("Con esto activado (por defecto), kiki limpia el dictado con IA: quita muletillas (\"eh\", \"o sea\") y arregla puntuación y mayúsculas, sin cambiar tus palabras. Desactívalo si prefieres insertar exactamente lo que transcribe el dictado, sin ninguna corrección automática.")
            }

            Section {
                Toggle("Traducir al dictar", isOn: $viewModel.translateEnabled)
            } footer: {
                Text("Con esto activado, kiki traduce cada dictado al otro idioma (español↔inglés) en vez de solo limpiarlo. Con esto desactivado (por defecto), kiki nunca cambia el idioma en el que dictaste.")
            }

            Section("Dictado") {
                LabeledContent("Atajo", value: viewModel.hotkeyDescription)
                LabeledContent("Frases de activación", value: viewModel.wakePhrasesDescription)
            }

            Section("Modelos cargados") {
                LabeledContent("Transcripción", value: viewModel.sttModelDescription)
                LabeledContent("Refinado", value: viewModel.refineModelDescription)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Diccionario

private struct DictionarySectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var newTerm = ""
    // `@FocusState` con autofocus en `.onAppear` (Fase 3.8 — fix Diccionario/
    // Snippets): en macOS 26, el click-to-focus normal sobre un `TextField`
    // dentro de un `Form`/`Section` anidado en el detail pane de un
    // `NavigationSplitView` hosteado por `NSHostingController` puede no
    // ganar first-responder de forma fiable (mismo síntoma-clase que el bug
    // de `List(selection:)` que obligó a reemplazar el sidebar por botones —
    // ver `SettingsRootView`). Forzar el foco explícitamente vía
    // `@FocusState` en vez de depender solo del click da un camino de
    // entrada de teclado que no depende del hit-testing de mouse-down de
    // AppKit, así que el campo queda listo para escribir apenas se entra a
    // la sección, sin bloquear tampoco el click manual (`.focused` sigue
    // permitiendo foco por click normalmente).
    @FocusState private var newTermFocused: Bool

    var body: some View {
        Form {
            Section {
                if viewModel.terms.isEmpty {
                    ContentUnavailableView(
                        "Sin términos todavía",
                        systemImage: "character.book.closed",
                        description: Text("Añade nombres propios, siglas o palabras técnicas para que kiki las reconozca.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(viewModel.terms, id: \.self) { term in
                        DeletableRow(onDelete: { viewModel.removeTerm(term) }) {
                            Text(term)
                        }
                    }
                }
            } header: {
                Text("Diccionario personal")
            } footer: {
                Text("kiki reconocerá y escribirá estos términos exactamente como los escribas.")
            }

            Section {
                HStack {
                    TextField("Nuevo término (p. ej. un nombre propio)", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .focused($newTermFocused)
                        .onSubmit(addTerm)
                    Button(action: addTerm) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { DispatchQueue.main.async { newTermFocused = true } }
    }

    private func addTerm() {
        viewModel.addTerm(newTerm)
        newTerm = ""
    }
}

// MARK: - Snippets

private struct SnippetsSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var trigger = ""
    @State private var template = ""
    // Ver comentario en `DictionarySectionView.newTermFocused` — mismo fix,
    // mismo motivo: autofocus explícito del primer campo de texto en vez de
    // depender solo del click.
    @FocusState private var triggerFocused: Bool

    var body: some View {
        Form {
            Section {
                if viewModel.snippets.isEmpty {
                    ContentUnavailableView(
                        "Sin snippets todavía",
                        systemImage: "text.badge.plus",
                        description: Text("Crea atajos de voz: di el trigger y kiki insertará la plantilla completa en su lugar.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(viewModel.snippets, id: \.trigger) { snippet in
                        DeletableRow(onDelete: { viewModel.removeSnippet(trigger: snippet.trigger) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snippet.trigger).bold()
                                Text(snippet.template)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } header: {
                Text("Snippets de voz")
            } footer: {
                Text("Di el trigger mientras dictas y kiki lo reemplazará por la plantilla completa — útil para firmas, saludos o texto repetitivo.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Trigger (lo que dictas)", text: $trigger)
                        .textFieldStyle(.roundedBorder)
                        .focused($triggerFocused)
                        .onSubmit(addSnippet)
                    TextField("Plantilla (lo que se inserta)", text: $template)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSnippet)
                    HStack {
                        Spacer()
                        Button(action: addSnippet) {
                            Label("Añadir", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { DispatchQueue.main.async { triggerFocused = true } }
    }

    private func addSnippet() {
        // No limpiar los campos si `template`/`trigger` está vacío (p. ej.
        // Enter en "Trigger" antes de llenar "Plantilla"): `addSnippet` del
        // ViewModel no añade nada en ese caso (guard interno), así que
        // limpiar igual perdería lo que el usuario ya escribió.
        guard !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        viewModel.addSnippet(trigger: trigger, template: template)
        trigger = ""
        template = ""
    }
}

// MARK: - Historial

private struct HistorySectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var confirmingClear = false

    /// Opciones fijas del Picker de cap — el mismo set que el owner pidió
    /// ("sensible options"). `historyCap` puede en teoría contener otro valor
    /// (p. ej. si un usuario editó `UserDefaults` a mano), en cuyo caso el
    /// Picker simplemente no marca ningún tag como seleccionado hasta que el
    /// usuario elige una opción de la lista — no hace falta normalizar ese
    /// caso raro aquí.
    private static let capOptions = [50, 100, 200, 500, 1000]

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        Form {
            Section {
                TextField("Buscar en el historial", text: $viewModel.historySearchQuery)
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                if viewModel.historyEntries.isEmpty {
                    ContentUnavailableView(
                        "Sin dictados registrados",
                        systemImage: "clock",
                        description: Text("Tus dictados aparecerán aquí a medida que uses kiki.")
                    )
                    .frame(maxWidth: .infinity)
                } else if viewModel.filteredHistoryEntries.isEmpty {
                    ContentUnavailableView(
                        "Sin resultados para \"\(viewModel.historySearchQuery)\"",
                        systemImage: "magnifyingglass",
                        description: Text("Prueba con otro término de búsqueda.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    // Identidad estable por fecha: con el refresco en vivo, un
                    // id posicional haría saltar el estado expandido de fila
                    // cuando entra un dictado nuevo.
                    ForEach(viewModel.filteredHistoryEntries, id: \.date) { entry in
                        HistoryRow(
                            entry: entry,
                            relativeFormatter: Self.relativeFormatter,
                            onCopy: { viewModel.copyToClipboard(entry.finalText) })
                    }
                }
            } header: {
                Text("Historial de dictados")
            } footer: {
                Text("kiki guarda tus últimos dictados localmente para que puedas revisarlos o copiarlos de nuevo.")
            }

            Section {
                Picker("Cantidad a conservar", selection: $viewModel.historyCap) {
                    ForEach(Self.capOptions, id: \.self) { option in
                        Text("\(option)").tag(option)
                    }
                }
                .pickerStyle(.menu)
            } footer: {
                Text("kiki guarda las últimas \(viewModel.historyCap) dictadas; las más antiguas se descartan.")
            }

            if !viewModel.historyEntries.isEmpty {
                Section {
                    Button("Borrar historial", role: .destructive) {
                        confirmingClear = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "¿Borrar todo el historial de dictados?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Borrar historial", role: .destructive) {
                viewModel.clearHistory()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Esta acción no se puede deshacer.")
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let relativeFormatter: RelativeDateTimeFormatter
    let onCopy: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(entry.rawText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 4)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.finalText)
                        .lineLimit(2)
                }
                Spacer()
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copiar al portapapeles")
            }
        }
    }
}

// MARK: - Acerca de

private struct AboutSectionView: View {
    private var appIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    if let appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 96, height: 96)
                    } else {
                        // Fallback si no corre empaquetada como .app (p. ej.
                        // `swift run`): AppIcon.icns solo existe dentro de
                        // Contents/Resources tras `make bundle`.
                        Image(systemName: "waveform.circle.fill")
                            .resizable()
                            .frame(width: 96, height: 96)
                            .foregroundStyle(kikiAccent)
                    }
                    Text("kiki")
                        .font(.title.bold())
                    Text("Versión \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Dictado por voz con IA — 100% local")
                        .font(.callout)
                    Link("github.com/dev2619/kiki", destination: URL(string: "https://github.com/dev2619/kiki")!)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shared

/// Fila con botón de borrado (`trash`) SIEMPRE visible (Fase 3.8 — fix
/// Diccionario/Snippets: la versión anterior solo mostraba el botón al
/// pasar el mouse por encima, lo cual además de ser poco descubrible
/// dependía de eventos `onHover`/`mouseMoved` que en esta ventana
/// (`NSHostingController` programático, foco poco fiable en macOS 26 — ver
/// nota en `DictionarySectionView.newTermFocused`) no son tan confiables
/// como un click directo sobre un botón siempre presente. El menú contextual
/// (clic derecho) se mantiene como vía alternativa.
private struct DeletableRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            content()
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Eliminar", role: .destructive, action: onDelete)
        }
    }
}
